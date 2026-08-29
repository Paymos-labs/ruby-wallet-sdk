# frozen_string_literal: true

require "securerandom"

module Paymos
  # The entry point, ported from the Python SDK via the TypeScript, Rust, .NET and Go ones.
  # Same methods, same guarantees, same refusals.
  #
  # Everything that moves money goes through a 2-of-2 co-sign in which this process holds one
  # half of the key and never sends it anywhere. The server cannot sign alone and neither can
  # this — which is only worth anything if this side refuses to sign things it has not checked:
  #
  #   the quote must echo what was approved   — a decimals bug or a lying server changes the
  #                                             numbers, and the numbers are compared before a
  #                                             commitment
  #   the debit may be capped                 — for an exact_out payout the input side is
  #                                             computed by the server, so max_debit is the
  #                                             caller's ceiling
  #   never blind-sign                        — the server discloses each message, this side
  #                                             recomputes the digest and refuses unless the
  #                                             package binds to it
  #
  # Any of those failing raises before a single signature share exists.
  class Wallet
    # A movement in any of these states has already been signed; a retry must not sign again.
    PROGRESSED = %w[signed relaying relayed settling completed failed].freeze
    # A movement is settled (no more polling) once it reaches one of these.
    TERMINAL = %w[completed failed refunded expired cancelled].freeze

    DEFAULT_BASE_URL = "https://wallet.paymos.io"

    def initialize(secret, base_url: nil, timeout: Http::DEFAULT_TIMEOUT, transport: nil)
      @secret = VaultSecret.parse(secret)
      base_url ||= ENV["PAYMOS_BASE_URL"] || DEFAULT_BASE_URL
      @http = Http.new(base_url, @secret.api_key, timeout: timeout, transport: transport)
      @asset_cache = nil
    end

    # Reads PAYMOS_VAULT_SECRET, the way a deployed process is configured.
    def self.from_env(**opts)
      secret = ENV["PAYMOS_VAULT_SECRET"]
      raise PaymosError, "PAYMOS_VAULT_SECRET is not set" if secret.nil? || secret.empty?

      new(secret, **opts)
    end

    # ── reads ────────────────────────────────────────────────────────────────

    def assets
      body = @http.get("/vault/v1/assets")
      (body["assets"] || []).map { |a| Asset.from_wire(a) }
    end

    def balances
      body = @http.get("/vault/v1/balances")
      (body["balances"] || []).map { |b| Balance.from_wire(b) }
    end

    def movement(movement_id)
      Movement.from_wire(@http.get("/vault/v1/movements/#{URI.encode_www_form_component(movement_id)}"))
    end

    # A page of the caller's movement history (newest first, summary rows without fee legs).
    # Returns [items, next_cursor]; pass next_cursor back as cursor for the next page
    # (nil when exhausted). The server speaks keyset pagination: items + next_cursor.
    def movements(limit: 50, cursor: nil)
      body = @http.get("/vault/v1/movements", { "limit" => limit, "cursor" => cursor })
      items = (body["items"] || []).map { |m| Movement.from_wire(m) }
      [items, body["next_cursor"]]
    end

    # Polls until the movement leaves the states that are still in flight.
    def wait(movement_id, timeout: 300, poll: 2.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        mv = movement(movement_id)
        return mv if TERMINAL.include?(mv.status)

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise PaymosError, "timed out waiting for movement #{movement_id}"
        end

        sleep(poll)
      end
    end

    # ── quotes ───────────────────────────────────────────────────────────────

    # A dry preview. Nothing is created and nothing is signed.
    def quote_swap(send:, receive:, amount:, slippage_bps: 50)
      validate_amount(amount, send)
      decimals_of(receive)
      quote("/vault/v1/quote/swap",
            { send: send, receive: receive, amount: amount, slippage_bps: slippage_bps },
            dry: true)
    end

    # A dry preview. Nothing is created and nothing is signed.
    def quote_withdraw(asset:, amount:, to:, mode: "exact_out")
      validate_amount(amount, asset)
      quote("/vault/v1/quote/withdraw",
            { asset: asset, amount: amount, to: to, mode: mode },
            dry: true)
    end

    # ── money ────────────────────────────────────────────────────────────────

    def swap(send:, receive:, amount:, slippage_bps: 50, min_receive: nil, max_debit: nil,
             idempotency_key: nil)
      require_share("swap")
      send_dec = validate_amount(amount, send)
      recv_dec = decimals_of(receive)

      q = quote("/vault/v1/quote/swap",
                { send: send, receive: receive, amount: amount, slippage_bps: slippage_bps },
                dry: false, idempotency_key: idempotency_key || fresh_idempotency_key)

      if min_receive
        floor = Integer(Amounts.parse_units(min_receive, recv_dec))
        if Integer(q.receive.min) < floor
          raise SlippageExceeded,
                "guaranteed receive #{q.receive.min} is below the requested minimum #{floor} " \
                "(#{min_receive} #{receive})"
        end
      end
      # A swap is exact_in, so the send leg must be exactly what was approved.
      verify_quote_echo(q, send, receive, expect_send_raw: Integer(Amounts.parse_units(amount, send_dec)))
      enforce_max_debit(q, max_debit, send_dec)
      cosign(q)
      movement(require_movement_id(q))
    end

    def withdraw(asset:, amount:, to:, mode: "exact_out", max_debit: nil, idempotency_key: nil)
      require_share("withdraw")
      dec = validate_amount(amount, asset)

      q = quote("/vault/v1/quote/withdraw",
                { asset: asset, amount: amount, to: to, mode: mode },
                dry: false, idempotency_key: idempotency_key || fresh_idempotency_key)

      # A withdraw is same-asset. For exact_out the approved amount is the guaranteed OUT; for
      # total_in it is the total DEBIT — and the send leg is total minus fees, so pinning send
      # would false-fail every time.
      expected = Integer(Amounts.parse_units(amount, dec))
      if mode == "total_in"
        verify_quote_echo(q, asset, asset, max_debit_raw: expected)
      else
        verify_quote_echo(q, asset, asset, expect_receive_raw: expected)
      end

      enforce_max_debit(q, max_debit, dec)
      cosign(q)
      movement(require_movement_id(q))
    end

    private

    def require_share(op)
      return if @secret.has_share?

      raise PaymosError, "#{op} needs a full-scope secret: this one carries no co-signing share"
    end

    def asset_map
      @asset_cache ||= assets.to_h { |a| [a.asset, a] }
    end

    def decimals_of(asset)
      found = asset_map[asset]
      raise PaymosError, "unknown asset: #{asset}" unless found

      found.decimals
    end

    def validate_amount(amount, asset)
      dec = decimals_of(asset)
      Amounts.parse_units(amount, dec) # raises on a bad decimal before anything reaches the server
      dec
    end

    def quote(path, body, dry:, idempotency_key: nil)
      headers = idempotency_key ? { "idempotency-key" => idempotency_key } : {}
      Quote.from_wire(@http.post(path, body.merge(dry: dry), headers))
    end

    def require_movement_id(q)
      q.movement_id or raise PaymosError, "quote created no movement — cannot sign a dry preview"
    end

    # Refuse to sign unless the server's quote echoes what the caller approved.
    def verify_quote_echo(q, send_asset, receive_asset,
                          expect_send_raw: nil, expect_receive_raw: nil, max_debit_raw: nil)
      if q.send.asset != send_asset || q.receive.asset != receive_asset
        raise PaymosError,
              "quote is for #{q.send.asset}→#{q.receive.asset}, not the " \
              "#{send_asset}→#{receive_asset} that was approved"
      end
      if expect_send_raw && Integer(q.send.amount) != expect_send_raw
        raise PaymosError, "quote sends #{q.send.amount}, not the approved #{expect_send_raw}"
      end
      if expect_receive_raw && Integer(q.receive.min) < expect_receive_raw
        raise PaymosError, "quote guarantees #{q.receive.min}, below the approved #{expect_receive_raw}"
      end
      if max_debit_raw && Integer(q.debit.amount) > max_debit_raw
        raise PaymosError, "quote debits #{q.debit.amount}, above the approved #{max_debit_raw}"
      end
    end

    def enforce_max_debit(q, max_debit, decimals)
      return unless max_debit

      cap = Integer(Amounts.parse_units(max_debit, decimals))
      return unless Integer(q.debit.amount) > cap

      raise PaymosError, "quote debits #{q.debit.amount}, above the cap #{cap} (#{max_debit})"
    end

    # Drives the 2-of-2 round: commit per source, verify the disclosure, sign, aggregate.
    def cosign(q)
      mid = require_movement_id(q)
      n = q.sources.to_i
      raise PaymosError, "quote is missing its source count — cannot co-sign" if n < 1

      kp = client_key_package
      commitments = []
      nonces = []
      n.times do
        c, nn = Native.commit(kp)
        commitments << c
        nonces << nn
      end

      begin
        begin_resp = @http.post("/vault/v1/movements/#{mid}/sign/begin", { commitments: commitments })
      rescue PaymosError, StandardError
        # An ambiguous failure after the server already progressed the movement is not a reason
        # to sign it a second time.
        return if PROGRESSED.include?(movement(mid).status)

        raise
      end

      packages = begin_resp["signing_packages"] || []
      if packages.length != n
        raise PaymosError,
              "co-sign protocol mismatch: expected #{n} signing packages, got #{packages.length}"
      end

      verify_signing_disclosure(q, packages, begin_resp["messages"], kp)

      shares = packages.each_with_index.map { |pkg, i| Native.sign(pkg, nonces[i], kp) }
      res = @http.post("/vault/v1/movements/#{mid}/sign/aggregate",
                       { token: begin_resp["token"], shares: shares })
      return if res.is_a?(Hash) && res["ok"] == true

      msg = res.is_a?(Hash) ? res["error"] : nil
      raise PaymosError, (msg.is_a?(String) && !msg.empty? ? msg : "sign failed")
    end

    def client_key_package
      share = @secret.share
      raise PaymosError, "this secret carries no co-signing share" if share.nil?

      JSON.parse(share)
    end

    # Never blind-sign. The server discloses, per source, the plaintext message it wants signed.
    # For each one this recomputes the digest and confirms the package about to be signed binds
    # to exactly that message; confirms the message is a single transfer from THIS vault; and
    # confirms the sources together move no more than the approved debit. Any mismatch aborts
    # before a share is produced.
    def verify_signing_disclosure(q, packages, messages, kp)
      unless messages.is_a?(Array) && messages.length == packages.length
        raise PaymosError,
              "co-sign refused: the server did not disclose the signing messages — refusing to blind-sign"
      end
      expected_signer = kp["verifying_key"].to_s.downcase
      total = 0

      packages.each_with_index do |pkg, i|
        disc = messages[i] || {}
        message = disc["message"]
        nonce_hex = disc["nonce"]
        recipient = disc["recipient"]
        unless message.is_a?(String) && nonce_hex.is_a?(String) && recipient.is_a?(String)
          raise PaymosError, "co-sign refused: malformed disclosure for source #{i}"
        end

        # (1) binding: the package about to be signed hashes to EXACTLY the disclosed message.
        if nonce_hex.length.odd? || nonce_hex !~ /\A[0-9a-fA-F]+\z/
          raise PaymosError, "co-sign refused: bad nonce hex for source #{i}"
        end
        want = Digest.payload_digest_hex(message, [nonce_hex].pack("H*"), recipient)
        got = pkg["message"]
        unless got.is_a?(String) && got.downcase == want
          raise PaymosError, "co-sign refused: signing package #{i} does not bind to the disclosed message"
        end

        # (2) structure and own-vault: one transfer, signed from this vault and no other.
        parsed = begin
          JSON.parse(message)
        rescue JSON::ParserError => e
          raise PaymosError, "co-sign refused: unreadable message for source #{i}: #{e.message}"
        end
        list = parsed["intents"]
        unless list.is_a?(Array) && list.length == 1 && list[0]["intent"] == "transfer"
          raise PaymosError, "co-sign refused: source #{i} is not a single transfer"
        end
        signer_id = parsed["signer_id"].to_s.downcase
        if !expected_signer.empty? && signer_id != expected_signer
          raise PaymosError, "co-sign refused: source #{i} signs from a different vault"
        end
        tokens = list[0]["tokens"]
        unless tokens.is_a?(Hash) && tokens.length == 1
          raise PaymosError, "co-sign refused: source #{i} does not transfer exactly one token"
        end
        begin
          total += Integer(tokens.values.first)
        rescue ArgumentError, TypeError
          raise PaymosError, "co-sign refused: bad transfer amount for source #{i}"
        end
      end

      # (3) no inflation: the sources together move no more than the approved debit.
      approved = Integer(q.debit.amount)
      return unless total > approved

      raise PaymosError,
            "co-sign refused: sources move #{total}, above the approved debit #{approved}"
    end

    # uuid-v4-shaped hex without the dashes — the same shape the other SDKs generate.
    def fresh_idempotency_key
      SecureRandom.hex(16)
    end
  end
end
