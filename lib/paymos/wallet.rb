# frozen_string_literal: true

require "digest"
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
  # Any of those failing raises before a single signature share exists. What none of them checks
  # is the recipient: the route's deposit address is chosen by the server and signed as disclosed.
  # And the debit ceiling is only as good as the approval — for exact_out the server computes the
  # debit, so an unattended payout should pass max_debit.
  class Wallet
    # A movement past "pending" is already committed to the co-sign and relay pipeline. When a
    # retry under the same Idempotency-Key replays a movement in one of these states, converge on
    # it rather than sign a second time. Only words the server actually sends (see the contract's
    # vocabulary.json) — "failed" is deliberately absent: a failed movement is not a success to
    # converge on, so its sign/begin rejection propagates.
    PROGRESSED = %w[processing completed refunded].freeze
    # A movement is settled (no more polling) once it reaches one of these.
    TERMINAL = %w[completed failed refunded expired cancelled].freeze

    DEFAULT_BASE_URL = "https://wallet.paymos.io"

    # The object class the blind-sign guard parses a disclosed message into. JSON.parse keeps the
    # LAST of a repeated object key (json >= 2.13 only warns); the verifier on chain re-parses the
    # signed bytes and rejects a repeated field. A message naming one key twice says two things, so
    # the second assignment of a key — at any depth, however it was escaped — is a parse error.
    # (Case is not the issue here: "intents" and "Intents" are two keys to both readers.)
    class UniqueKeyHash < Hash
      def []=(key, value)
        raise JSON::ParserError, "duplicate key #{key.inspect}" if key?(key)

        super
      end
    end
    private_constant :UniqueKeyHash

    # +pinned_fingerprints+ is an optional trust anchor for the co-sign guard, independent of the
    # server: { "USDC@base" => "<sha256 hex>" } or { "BTC@btc" => ["<hex>", "<hex>"] }. A pinned
    # label is checked against ONLY its pinned value(s), whatever /assets publishes; an unpinned
    # label falls back to the fingerprints /assets publishes under it. Compared lowercase.
    def initialize(secret, base_url: nil, timeout: Http::DEFAULT_TIMEOUT, transport: nil,
                   pinned_fingerprints: nil)
      @secret = VaultSecret.parse(secret)
      base_url ||= ENV["PAYMOS_BASE_URL"] || DEFAULT_BASE_URL
      @http = Http.new(base_url, @secret.api_key, timeout: timeout, transport: transport)
      @pinned = normalize_pins(pinned_fingerprints)
      @catalog = nil
      @asset_cache = nil
    end

    # What p, pp, irb and an error message show of a wallet: which vault, whether it can sign, the
    # key's vk_live_ prefix — never the key or the share. Ruby's default inspect would print every
    # instance variable, the transport's API key among them.
    def inspect
      "#<Paymos::Wallet vault_id=#{@secret.vault_id} has_share=#{@secret.has_share?} " \
        "api_key=#{VaultSecret.mask(@secret.api_key)}>"
    end
    alias to_s inspect

    # The same for JSON, ActiveSupport's as_json included.
    def as_json(*)
      { "vaultId" => @secret.vault_id, "hasShare" => @secret.has_share?, "apiKey" => VaultSecret.mask(@secret.api_key) }
    end

    def to_json(*args)
      as_json.to_json(*args)
    end

    # Reads PAYMOS_VAULT_SECRET, the way a deployed process is configured.
    def self.from_env(**opts)
      secret = ENV["PAYMOS_VAULT_SECRET"]
      raise PaymosError, "PAYMOS_VAULT_SECRET is not set" if secret.nil? || secret.empty?

      new(secret, **opts)
    end

    # ── reads ────────────────────────────────────────────────────────────────

    # The server answers both of these with a bare JSON array, not an object wrapping one.
    def assets
      Wire.array!(@http.get("/vault/v1/assets"), "assets").map { |a| Asset.from_wire(a) }
    end

    def balances
      Wire.array!(@http.get("/vault/v1/balances"), "balances").map { |b| Balance.from_wire(b) }
    end

    def movement(movement_id)
      Movement.from_wire(@http.get("/vault/v1/movements/#{URI.encode_www_form_component(movement_id)}"))
    end

    # A page of the caller's movement history (newest first, summary rows without fee legs).
    # Returns [items, next_cursor]; pass next_cursor back as cursor for the next page
    # (nil when exhausted). The server speaks keyset pagination: items + next_cursor.
    def movements(limit: 50, cursor: nil)
      body = Wire.object!(@http.get("/vault/v1/movements", { "limit" => limit, "cursor" => cursor }),
                          "movements page")
      items = Wire.array!(Wire.field!(body, "items"), "items").map { |m| Movement.from_wire(m) }
      [items, body["next_cursor"]&.to_s]
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
    #
    # +amount+ is a HUMAN decimal string in the send asset ("100", "0.5"); the server scales it by
    # the asset's decimals. The quote comes back in raw integer strings. Never pass
    # Amounts.parse_units output here: "10000" is ten thousand of the asset, not 0.01.
    def quote_swap(send:, receive:, amount:, slippage_bps: 50)
      validate_amount(amount, send)
      decimals_of(receive)
      quote("/vault/v1/quote/swap", swap_body(send, receive, amount, slippage_bps), dry: true)
    end

    # A dry preview. Nothing is created and nothing is signed.
    #
    # +amount+ is a HUMAN decimal string in +asset+ ("25", "0.01"); the server scales it. The quote
    # comes back in raw integer strings. Never pass Amounts.parse_units output here.
    def quote_withdraw(asset:, amount:, to:, mode: "exact_out")
      validate_amount(amount, asset)
      quote("/vault/v1/quote/withdraw",
            { asset: asset, amount: amount, to: to, mode: mode },
            dry: true)
    end

    # ── money ────────────────────────────────────────────────────────────────

    # Swaps +amount+ of +send+ for +receive+, delivered back to this vault: a real movement,
    # co-signed. Full-key secrets only.
    #
    # +amount+, +min_receive+ and +max_debit+ are HUMAN decimal strings ("100", "99.5") that the
    # server scales by each asset's decimals — never Amounts.parse_units output, which would be read
    # as that many whole units: swap(..., amount: "10000") swaps ten thousand USDC.
    def swap(send:, receive:, amount:, slippage_bps: 50, min_receive: nil, max_debit: nil,
             idempotency_key: nil)
      require_share("swap")
      key = idempotency_key_of(idempotency_key)
      send_dec = validate_amount(amount, send)
      recv_dec = decimals_of(receive)

      q = quote("/vault/v1/quote/swap", swap_body(send, receive, amount, slippage_bps),
                dry: false, idempotency_key: key)

      if min_receive
        floor = Integer(Amounts.parse_units(min_receive, recv_dec))
        if raw_int(q.receive.min, "receive.min") < floor
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

    # Pays +amount+ of +asset+ out to +to+: a real movement, co-signed. Full-key secrets only.
    #
    # +amount+ and +max_debit+ are HUMAN decimal strings ("25", "0.01") that the server scales by
    # the asset's decimals — never Amounts.parse_units output. withdraw(amount: "10000", ...), which
    # is what parse_units("0.01", 6) returns, pays out ten thousand USDC; the SDK and the server
    # agree on that number, so no check can tell it from an intended one.
    def withdraw(asset:, amount:, to:, mode: "exact_out", max_debit: nil, idempotency_key: nil)
      require_share("withdraw")
      key = idempotency_key_of(idempotency_key)
      dec = validate_amount(amount, asset)

      q = quote("/vault/v1/quote/withdraw",
                { asset: asset, amount: amount, to: to, mode: mode },
                dry: false, idempotency_key: key)

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

    # Every catalog entry, in the server's order. One label may appear more than once (two
    # contracts of one coin), which is why the fingerprint check reads this and not asset_map.
    def catalog
      @catalog ||= assets
    end

    # Label → entry, the FIRST one when a label is listed twice — the entry the server resolves
    # the label to, so decimals here match the server's scaling.
    def asset_map
      @asset_cache ||= catalog.each_with_object({}) { |a, h| h[a.asset] ||= a }
    end

    def normalize_pins(pins)
      return {} if pins.nil?
      raise PaymosError, "pinned_fingerprints must be a Hash of label => fingerprint(s)" unless pins.is_a?(Hash)

      pins.to_h do |label, value|
        list = value.is_a?(Array) ? value : [value]
        if list.empty? || !list.all? { |v| v.is_a?(String) && !v.empty? }
          raise PaymosError, "pinned_fingerprints[#{label.to_s.inspect}] must be a fingerprint string or a list of them"
        end

        [label.to_s, list.map(&:downcase).freeze]
      end.freeze
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

    # A swap is exact_in, and the echo check below assumes it: the mode is sent rather than left
    # to the server's default, so a changed default cannot turn the send leg into something else.
    def swap_body(send, receive, amount, slippage_bps)
      { send: send, receive: receive, amount: amount, mode: "exact_in", slippage_bps: Integer(slippage_bps) }
    end

    # Amounts on the wire are raw integer strings; anything else is a contract fault, raised typed.
    def raw_int(value, what)
      Integer(value, 10)
    rescue ArgumentError, TypeError
      raise PaymosError, "malformed response: #{what} #{value.inspect} is not a raw integer amount"
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
      if expect_send_raw && raw_int(q.send.amount, "send.amount") != expect_send_raw
        raise PaymosError, "quote sends #{q.send.amount}, not the approved #{expect_send_raw}"
      end
      # exact_out: the quoted receive is exactly what was approved (as Python checks), and the
      # guaranteed floor does not sit below it either.
      if expect_receive_raw && raw_int(q.receive.amount, "receive.amount") != expect_receive_raw
        raise PaymosError, "quote receives #{q.receive.amount}, not the approved #{expect_receive_raw}"
      end
      if expect_receive_raw && raw_int(q.receive.min, "receive.min") < expect_receive_raw
        raise PaymosError, "quote guarantees #{q.receive.min}, below the approved #{expect_receive_raw}"
      end
      if max_debit_raw && raw_int(q.debit.amount, "debit.amount") > max_debit_raw
        raise PaymosError, "quote debits #{q.debit.amount}, above the approved #{max_debit_raw}"
      end
    end

    def enforce_max_debit(q, max_debit, decimals)
      return unless max_debit

      cap = Integer(Amounts.parse_units(max_debit, decimals))
      return unless raw_int(q.debit.amount, "debit.amount") > cap

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
      rescue PaymosError
        # Round one rejected because a prior attempt under the same key already signed this
        # movement: converge on it — that is idempotence, not a double-sign. Anything else
        # (a pending or failed movement) propagates the original error.
        return if PROGRESSED.include?(movement(mid).status)

        raise
      end

      Wire.object!(begin_resp, "sign/begin")
      token = begin_resp["token"]
      unless token.is_a?(String) && !token.empty?
        raise PaymosError, "malformed response: sign/begin carried no token"
      end

      packages = Wire.array!(Wire.field!(begin_resp, "signing_packages"), "signing_packages")
      if packages.length != n
        raise PaymosError,
              "co-sign protocol mismatch: expected #{n} signing packages, got #{packages.length}"
      end

      verify_signing_disclosure(q, packages, begin_resp["messages"], kp, send_fingerprints(q))

      shares = packages.each_with_index.map { |pkg, i| Native.sign(pkg, nonces[i], kp) }
      res = @http.post("/vault/v1/movements/#{mid}/sign/aggregate",
                       { token: token, shares: shares })
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
    # to exactly that message; confirms the message is a single transfer from THIS vault of a
    # token whose id hashes to one of +fingerprints+; and confirms the sources together move no
    # more than the approved debit. Any mismatch aborts before a share is produced.
    def verify_signing_disclosure(q, packages, messages, kp, fingerprints)
      unless messages.is_a?(Array) && messages.length == packages.length
        raise PaymosError,
              "co-sign refused: the server did not disclose the signing messages — refusing to blind-sign"
      end
      # Without the vault's own key there is nothing to compare the signer against, and skipping
      # the comparison would sign a transfer out of any vault.
      expected_signer = kp.is_a?(Hash) ? kp["verifying_key"].to_s.downcase : ""
      if expected_signer.empty?
        raise PaymosError, "co-sign refused: the key package carries no verifying_key to check the signer against"
      end
      total = 0

      packages.each_with_index do |pkg, i|
        disc = messages[i].is_a?(Hash) ? messages[i] : {}
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
        got = pkg.is_a?(Hash) ? pkg["message"] : nil
        unless got.is_a?(String) && got.downcase == want
          raise PaymosError, "co-sign refused: signing package #{i} does not bind to the disclosed message"
        end

        # (2) structure and own-vault: one transfer, signed from this vault and no other. Read the
        # way the verifier on chain reads it: a repeated key is refused (UniqueKeyHash), never
        # resolved to its last value. JSON.parse's max_nesting (100) bounds the depth.
        parsed = begin
          JSON.parse(message, object_class: UniqueKeyHash)
        rescue JSON::ParserError => e
          raise PaymosError, "co-sign refused: unreadable message for source #{i}: #{e.message}"
        end
        list = parsed.is_a?(Hash) ? parsed["intents"] : nil
        unless list.is_a?(Array) && list.length == 1 && list[0].is_a?(Hash) && list[0]["intent"] == "transfer"
          raise PaymosError, "co-sign refused: source #{i} is not a single transfer"
        end
        signer_id = parsed["signer_id"].to_s.downcase
        if signer_id != expected_signer
          raise PaymosError, "co-sign refused: source #{i} signs from a different vault"
        end
        tokens = list[0]["tokens"]
        unless tokens.is_a?(Hash) && tokens.length == 1
          raise PaymosError, "co-sign refused: source #{i} does not transfer exactly one token"
        end
        # (2b) the right token: every source moves the SEND asset, named by its raw id, and the id
        # must hash to a fingerprint for that label. The fingerprints come from the same server
        # that builds the messages unless the caller pinned them, so this catches a server bug or
        # a compromised signing path swapping in another asset — not a fully compromised server
        # that also lies in /assets. pinned_fingerprints is the anchor that does not depend on it.
        token_key = tokens.keys.first.to_s
        unless fingerprints.include?(::Digest::SHA256.hexdigest(token_key.encode(Encoding::UTF_8)))
          raise PaymosError, "co-sign refused: source #{i} transfers a token other than #{q.send.asset}"
        end
        # Each source must move a positive amount of plain ASCII digits. Integer() alone would take
        # "-900", "+5", "1_000" or " 5 " — and a negative source lets a server disclose A = 2D and
        # B = -D: the total D passes the debit check below while A alone moves 2D.
        amount = tokens.values.first
        unless amount.is_a?(String) && amount.match?(/\A[0-9]+\z/) && Integer(amount, 10).positive?
          raise PaymosError, "co-sign refused: bad transfer amount for source #{i}: #{amount.inspect}"
        end

        total += Integer(amount, 10)
      end

      # (3) no inflation past the APPROVED debit: the sources together move no more than it. For
      # exact_out that debit is server-computed; only max_debit puts a caller's ceiling on it.
      approved = raw_int(q.debit.amount, "debit.amount")
      return unless total > approved

      raise PaymosError,
            "co-sign refused: sources move #{total}, above the approved debit #{approved}"
    end

    # The fingerprints a disclosed token may hash to for the quote's send label. A pinned label
    # uses only its pins — the integrator vouches for them. Otherwise: every fingerprint /assets
    # publishes under that label whose decimals equal the FIRST entry's — one label is one coin,
    # so two contracts listed under it are both that coin, and taking only one would refuse a
    # legitimate co-sign on the other. An entry with other decimals is excluded: the debit is in
    # the first entry's units, and a raw amount of a differently scaled token could be worth
    # 10^Δ more while passing the sum check. None at all leaves nothing to bind the transfer to,
    # and the co-sign refuses rather than skip the check.
    def send_fingerprints(q)
      label = q.send.asset
      return @pinned[label] if @pinned.key?(label)

      entries = catalog.select { |a| a.asset == label }
      fps = entries.select { |a| a.decimals == entries.first&.decimals }.map(&:fingerprint)
                   .select { |fp| fp.is_a?(String) && fp.match?(/\A[0-9a-f]{64}\z/) }.uniq
      return fps unless fps.empty?

      raise PaymosError,
            "co-sign refused: the server did not publish an asset fingerprint for #{label} — update the server"
    end

    # The key a money call is sent under: the caller's, or a fresh one when they passed nil. An
    # empty or blank key is refused. It used to go out as an empty header ("" is truthy in Ruby),
    # which the server reads as no key at all: a retry paid again while the caller believed it was
    # deduplicated.
    def idempotency_key_of(key)
      return fresh_idempotency_key if key.nil?

      if key.to_s.strip.empty?
        raise PaymosError,
              "idempotency_key is empty — pass a durable key (a payout or job id) so a retry replays " \
              "the same movement, or leave it nil for a fresh one per call"
      end

      key
    end

    # uuid-v4-shaped hex without the dashes — the same shape the other SDKs generate.
    def fresh_idempotency_key
      SecureRandom.hex(16)
    end
  end
end
