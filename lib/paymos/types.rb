# frozen_string_literal: true

module Paymos
  # The read model, ported field-for-field from the Python SDK.
  #
  # Every amount is a STRING of raw integer units, never a number. A token with 18 decimals runs
  # past what a float holds exactly, so a JSON parser that produced numbers here would round
  # somebody's balance without saying so. Use Amounts.format_units to show one and
  # Amounts.parse_units to build one.
  #
  # The server speaks snake_case and the models keep it: no renaming layer to drift.

  # Reading the wire. A field the server always sends is required: its absence is a contract
  # fault and raises a typed error, instead of defaulting to "" or 0 and letting a zero-decimals
  # asset or an empty amount reach the money path. A field the server may omit — it drops nulls
  # rather than sending them — is read with `&.` and comes back nil.
  module Wire
    module_function

    def object!(o, what)
      return o if o.is_a?(Hash)

      raise PaymosError, "malformed response: #{what} is not a JSON object"
    end

    def array!(o, what)
      return o if o.is_a?(Array)

      raise PaymosError, "malformed response: #{what} is not a JSON array"
    end

    def field!(o, key)
      v = o[key]
      raise PaymosError, "malformed response: missing \"#{key}\"" if v.nil?

      v
    end

    def str!(o, key)
      field!(o, key).to_s
    end

    def int!(o, key)
      Integer(field!(o, key))
    rescue ArgumentError, TypeError
      raise PaymosError, "malformed response: \"#{key}\" is not an integer"
    end

    def int(o, key)
      o[key].nil? ? nil : int!(o, key)
    end
  end

  # `fingerprint` is the lowercase hex SHA-256 of the asset's raw token id, the key a signed
  # transfer names it by. The co-sign guard binds every disclosed transfer to the send asset
  # through it. Optional on the wire: an older server omits it, and reads keep working — only a
  # co-sign refuses without it.
  Asset = Struct.new(:asset, :symbol, :chain, :decimals, :fingerprint, keyword_init: true) do
    def self.from_wire(o)
      Wire.object!(o, "asset")
      new(asset: Wire.str!(o, "asset"), symbol: Wire.str!(o, "symbol"), chain: Wire.str!(o, "chain"),
          decimals: Wire.int!(o, "decimals"), fingerprint: o["fingerprint"]&.to_s&.downcase)
    end
  end

  Balance = Struct.new(:asset, :symbol, :chain, :decimals, :amount_raw, :usd, keyword_init: true) do
    def self.from_wire(o)
      Wire.object!(o, "balance")
      new(asset: Wire.str!(o, "asset"), symbol: Wire.str!(o, "symbol"), chain: Wire.str!(o, "chain"),
          decimals: Wire.int!(o, "decimals"), amount_raw: Wire.str!(o, "amount_raw"),
          usd: o["usd"]&.to_s)
    end
  end

  # `route` is nil when no route leg applies (the server omits it); `estimate` is false for an
  # exact same-asset spread, true for a rate-derived cross-asset one.
  RouteFee = Struct.new(:amount, :estimate, keyword_init: true) do
    def self.from_wire(o)
      return nil if o.nil?

      Wire.object!(o, "fees.route")
      new(amount: Wire.str!(o, "amount"), estimate: o["estimate"] == true)
    end
  end

  # `usd` is a hash of platform / network / route / total, each an independently nullable string,
  # or nil when the server sent no USD view at all.
  Fees = Struct.new(:asset, :platform, :network, :route, :total, :usd, keyword_init: true) do
    def self.from_wire(o)
      return nil if o.nil?

      Wire.object!(o, "fees")
      usd = o["usd"].is_a?(Hash) ? o["usd"].transform_values { |v| v&.to_s } : nil
      new(asset: Wire.str!(o, "asset"), platform: Wire.str!(o, "platform"),
          network: Wire.str!(o, "network"), route: RouteFee.from_wire(o["route"]),
          total: Wire.str!(o, "total"), usd: usd)
    end
  end

  Amount = Struct.new(:amount, :asset, keyword_init: true) do
    def self.from_wire(o)
      Wire.object!(o, "amount leg")
      new(amount: Wire.str!(o, "amount"), asset: Wire.str!(o, "asset"))
    end
  end

  # What arrives. `min` is the floor the operation is allowed to deliver, and it is guaranteed.
  Receive = Struct.new(:amount, :min, :asset, keyword_init: true) do
    def self.from_wire(o)
      Wire.object!(o, "receive")
      new(amount: Wire.str!(o, "amount"), min: Wire.str!(o, "min"), asset: Wire.str!(o, "asset"))
    end
  end

  # `debit` is the MAXIMUM this quote may take from the vault, reserve against slippage
  # included — a ceiling, not a prediction. The co-sign refuses sources that together move more
  # than this; for exact_out it is computed by the server, so cap it with max_debit when nobody
  # reviews the quote. An exact-output route routinely spends less and returns the difference.
  # Compare the finished movement's `send` to see what it actually cost.
  #
  # `movement_id` and `sources` are absent on a dry preview: nothing was created, nothing is to
  # be signed. A real quote carries both, `sources` being how many commitments sign/begin wants.
  Quote = Struct.new(:movement_id, :mode, :send, :debit, :receive, :fees, :expires_at, :sources,
                     keyword_init: true) do
    def self.from_wire(o)
      Wire.object!(o, "quote")
      new(movement_id: o["movement_id"]&.to_s, mode: Wire.str!(o, "mode"),
          send: Amount.from_wire(Wire.field!(o, "send")),
          debit: Amount.from_wire(Wire.field!(o, "debit")),
          receive: Receive.from_wire(Wire.field!(o, "receive")),
          fees: Fees.from_wire(Wire.field!(o, "fees")),
          expires_at: Wire.str!(o, "expires_at"), sources: Wire.int(o, "sources"))
    end
  end

  # `send` is what the movement actually cost the vault: the approved maximum minus anything the
  # route handed back. This is the figure that matches the on-chain balance — reconcile on it.
  # It is NOT the quote's `debit`, which is the ceiling that was approved before the route ran.
  #
  # A history row carries no `fees`; neither does a movement before it settles on a destination
  # chain carry `dest_chain_*` or `completed_at`. All four come back nil when absent.
  Movement = Struct.new(:id, :type, :status, :send, :receive, :fees, :dest_chain_tx_hash,
                        :dest_chain_explorer_url, :created_at, :completed_at,
                        keyword_init: true) do
    def self.from_wire(o)
      Wire.object!(o, "movement")
      new(id: Wire.str!(o, "id"), type: Wire.str!(o, "type"), status: Wire.str!(o, "status"),
          send: Amount.from_wire(Wire.field!(o, "send")),
          receive: Receive.from_wire(Wire.field!(o, "receive")),
          fees: Fees.from_wire(o["fees"]),
          dest_chain_tx_hash: o["dest_chain_tx_hash"]&.to_s,
          dest_chain_explorer_url: o["dest_chain_explorer_url"]&.to_s,
          created_at: Wire.str!(o, "created_at"), completed_at: o["completed_at"]&.to_s)
    end
  end
end
