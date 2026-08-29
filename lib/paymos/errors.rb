# frozen_string_literal: true

module Paymos
  # The ten error types of the SDK spec. PaymosError is the base case; the nine subclasses are
  # the classifications a caller branches on. The set is fixed by the SDK spec — deliberately no
  # NotFound, since a 404 surfaces as the base PaymosError.
  #
  # +message+ is the server's already client-safe reason; +status+ is the HTTP code that produced
  # it, or nil when the error did not come from a response.
  class PaymosError < StandardError
    attr_reader :status

    def initialize(message, status = nil)
      super(message)
      @status = status
    end
  end

  # 401 — the API key is missing, malformed, or not recognised.
  class AuthError < PaymosError; end

  # 403 — the key is valid but lacks the scope this call requires.
  class Forbidden < PaymosError; end

  # 400 — the vault's available balance cannot cover the amount plus fees.
  class InsufficientFunds < PaymosError; end

  # 400 — the referenced quote has expired; fetch a fresh one and retry.
  class QuoteExpired < PaymosError; end

  # 400 — the delivered amount fell outside the accepted slippage bound.
  class SlippageExceeded < PaymosError; end

  # 400 — a withdraw changed the asset; that is a swap, and it is rejected here.
  class CrossAssetWithdrawNotAllowed < PaymosError; end

  # 400 — no route could be quoted for this pair right now; retry shortly.
  class RouteUnavailable < PaymosError; end

  # 429 — too many requests. +retry_after+ is the Retry-After seconds when the server sent one.
  class RateLimited < PaymosError
    attr_reader :retry_after

    def initialize(message, status = nil, retry_after = nil)
      super(message, status)
      @retry_after = retry_after
    end
  end

  # 409 — idempotency-key conflict: reused with a different request, or a quote still forming.
  class Conflict < PaymosError; end
end
