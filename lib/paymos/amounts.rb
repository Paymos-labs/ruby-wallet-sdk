# frozen_string_literal: true

# Human decimal ↔ raw integer, ported from the Python SDK.
#
# Raw amounts are strings rather than numbers on purpose: floats round silently past 2^53, and
# the one failure nobody notices until it is somebody's balance is a rounded balance. These
# functions are string-only, so no amount is too long to parse exactly.
module Paymos
  module Amounts
    DECIMAL = /\A\d+(\.\d+)?\z/

    module_function

    # "1.5", 6 → "1500000". Raises on anything that is not a non-negative decimal.
    #
    # For comparing a human figure with a raw amount from a response — never for building the
    # amount: of a quote, swap or withdraw, or a min_receive: / max_debit:. Those take the human
    # string itself and the server scales it: withdraw(amount: "10000", …) — what
    # parse_units("0.01", 6) returns — pays out 10 000 USDC.
    def parse_units(human, decimals)
      raise PaymosError, "decimals must be >= 0" if decimals.negative?

      s = human.to_s.strip
      raise PaymosError, "not a non-negative decimal: #{human.inspect}" unless DECIMAL.match?(s)

      whole, _, frac = s.partition(".")
      frac ||= ""
      if frac.length > decimals
        raise PaymosError, "more than #{decimals} fractional digits: #{human.inspect}"
      end

      raw = (whole + frac.ljust(decimals, "0")).sub(/\A0+/, "")
      raw.empty? ? "0" : raw
    end

    # "1500000", 6 → "1.5": a raw amount from a response, as a human decimal. Trailing zeros in the
    # fraction are dropped.
    def format_units(raw, decimals)
      s = raw.to_s
      sign = s.start_with?("-") ? "-" : ""
      digits = sign.empty? ? s : s[1..]
      raise PaymosError, "not a raw integer amount: #{raw.inspect}" unless /\A\d+\z/.match?(digits)

      digits = digits.sub(/\A0+/, "")
      digits = "0" if digits.empty?
      sign = "" if digits == "0" # the sign of nothing is nothing
      return sign + digits if decimals.zero?

      padded = digits.rjust(decimals + 1, "0")
      whole = padded[0...-decimals]
      frac = padded[-decimals..].sub(/0+\z/, "")
      frac.empty? ? sign + whole : "#{sign}#{whole}.#{frac}"
    end
  end
end
