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

  Asset = Struct.new(:asset, :symbol, :chain, :decimals, keyword_init: true) do
    def self.from_wire(o)
      new(asset: o["asset"].to_s, symbol: o["symbol"].to_s, chain: o["chain"].to_s,
          decimals: o["decimals"].to_i)
    end
  end

  Balance = Struct.new(:asset, :symbol, :chain, :decimals, :amount_raw, :usd, keyword_init: true) do
    def self.from_wire(o)
      new(asset: o["asset"].to_s, symbol: o["symbol"].to_s, chain: o["chain"].to_s,
          decimals: o["decimals"].to_i, amount_raw: o["amount_raw"].to_s, usd: o["usd"]&.to_s)
    end
  end

  RouteFee = Struct.new(:amount, :estimate, keyword_init: true) do
    def self.from_wire(o)
      new(amount: o["amount"].to_s, estimate: !!o["estimate"])
    end
  end

  Fees = Struct.new(:asset, :platform, :network, :route, :total, :usd, keyword_init: true) do
    def self.from_wire(o)
      return nil if o.nil?

      new(asset: o["asset"].to_s, platform: o["platform"].to_s, network: o["network"].to_s,
          route: RouteFee.from_wire(o["route"]), total: o["total"].to_s, usd: o["usd"])
    end
  end

  Amount = Struct.new(:amount, :asset, keyword_init: true) do
    def self.from_wire(o)
      new(amount: o["amount"].to_s, asset: o["asset"].to_s)
    end
  end

  # What arrives. `min` is the floor the operation is allowed to deliver, and it is guaranteed.
  Receive = Struct.new(:amount, :min, :asset, keyword_init: true) do
    def self.from_wire(o)
      new(amount: o["amount"].to_s, min: o["min"].to_s, asset: o["asset"].to_s)
    end
  end

  # `debit` is the MAXIMUM this quote may take from the vault, reserve against slippage
  # included — a ceiling, not a prediction. Approve against this and nothing can debit more
  # than you agreed to; an exact-output route routinely spends less and returns the difference.
  # Compare the finished movement's `send` to see what it actually cost.
  Quote = Struct.new(:movement_id, :mode, :send, :debit, :receive, :fees, :expires_at, :sources,
                     keyword_init: true) do
    def self.from_wire(o)
      new(movement_id: o["movement_id"]&.to_s, mode: o["mode"].to_s,
          send: Amount.from_wire(o["send"] || {}), debit: Amount.from_wire(o["debit"] || {}),
          receive: Receive.from_wire(o["receive"] || {}), fees: Fees.from_wire(o["fees"]),
          expires_at: o["expires_at"].to_s, sources: o["sources"]&.to_i)
    end
  end

  # `send` is what the movement actually cost the vault: the approved maximum minus anything the
  # route handed back. This is the figure that matches the on-chain balance — reconcile on it.
  # It is NOT the quote's `debit`, which is the ceiling that was approved before the route ran.
  Movement = Struct.new(:id, :type, :status, :send, :receive, :fees, :dest_chain_tx_hash,
                        :dest_chain_explorer_url, :created_at, :completed_at,
                        keyword_init: true) do
    def self.from_wire(o)
      new(id: o["id"].to_s, type: o["type"].to_s, status: o["status"].to_s,
          send: Amount.from_wire(o["send"] || {}), receive: Receive.from_wire(o["receive"] || {}),
          fees: Fees.from_wire(o["fees"]),
          dest_chain_tx_hash: o["dest_chain_tx_hash"]&.to_s,
          dest_chain_explorer_url: o["dest_chain_explorer_url"]&.to_s,
          created_at: o["created_at"].to_s, completed_at: o["completed_at"]&.to_s)
    end
  end
end
