# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Paymos
  # Authenticated transport, ported from the Python SDK so every language fails the same way.
  #
  # Attaches "Authorization: Bearer <api key>" to every request, returns parsed JSON on a 2xx,
  # and maps anything else onto a typed error through the server's envelope. The server's
  # contract: business errors are {"error": "…"} and the sign flow answers
  # {"ok":false,"status":"failed","error":"…"} — both carry the message under "error". Those
  # messages arrive already client-safe, so this layer maps them and never rewrites them, and it
  # never logs or echoes a request body.
  #
  # Transport failures are wrapped into a typed error with no status, so a caller on the money
  # path never catches a raw Net::HTTP error. The timeout is generous because the co-sign is a
  # multi-round exchange that outlasts anything a default would allow.
  class Http
    DEFAULT_TIMEOUT = 60

    # +transport+ is the test seam: a callable taking (method, uri, headers, body_string) and
    # returning [status, headers_hash, body_string]. Production leaves it nil and Net::HTTP
    # does the work.
    def initialize(base_url, api_key, timeout: DEFAULT_TIMEOUT, transport: nil)
      @base_url = base_url.sub(%r{/+\z}, "")
      @api_key = api_key
      @timeout = timeout
      @transport = transport
    end

    def get(path, params = {})
      uri = URI.join(@base_url + "/", path.sub(%r{\A/}, ""))
      query = params.reject { |_, v| v.nil? }
      uri.query = URI.encode_www_form(query) unless query.empty?
      request(Net::HTTP::Get, uri, {}, nil)
    end

    def post(path, body_hash, extra_headers = {})
      uri = URI.join(@base_url + "/", path.sub(%r{\A/}, ""))
      headers = { "content-type" => "application/json" }.merge(extra_headers)
      request(Net::HTTP::Post, uri, headers, JSON.generate(body_hash))
    end

    private

    def request(_method, uri, headers, body)
      headers = { "authorization" => "Bearer #{@api_key}" }.merge(headers)

      status, resp_headers, text =
        if @transport
          begin
            @transport.call(uri, headers, body)
          rescue PaymosError
            raise
          rescue StandardError => e
            raise PaymosError, "transport error: #{e.message}"
          end
        else
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = @timeout
          http.read_timeout = @timeout
          req = (body ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
          headers.each { |k, v| req[k] = v }
          req.body = body if body
          begin
            resp = http.request(req)
            [resp.code.to_i, resp.each_header.to_h, resp.body.to_s]
          rescue StandardError => e
            raise PaymosError, "transport error: #{e.message}"
          end
        end

      parsed = begin
        text.empty? ? nil : JSON.parse(text)
      rescue JSON::ParserError
        nil
      end

      return parsed if status >= 200 && status < 300

      raise raise_for(status, parsed, text, resp_headers["retry-after"])
    end

    def message_of(parsed, status, text)
      if parsed.is_a?(Hash)
        %w[error detail].each do |key|
          msg = parsed[key]
          return msg if msg.is_a?(String) && !msg.empty?
        end
      end
      trimmed = text.strip
      trimmed.empty? ? "request failed with status #{status}" : trimmed
    end

    # Map a 400's message to a type. First match wins, in this exact order.
    def classify400(message, status)
      m = message.downcase
      return CrossAssetWithdrawNotAllowed.new(message, status) if m.include?("cross-asset")
      return SlippageExceeded.new(message, status) if m.include?("slippage")
      return QuoteExpired.new(message, status) if m.include?("expired")
      ["insufficient", "not enough balance", "exceeds the vault", "available balance"].each do |t|
        return InsufficientFunds.new(message, status) if m.include?(t)
      end
      # The server's route and liquidity rejections come back sounding transient — "No liquidity
      # available … try again in a moment", "route can't be quoted". That whole family is one type.
      ["route", "can't be quoted", "liquidity", "try again in a moment"].each do |t|
        return RouteUnavailable.new(message, status) if m.include?(t)
      end
      PaymosError.new(message, status)
    end

    def raise_for(status, parsed, text, retry_after_header)
      message = message_of(parsed, status, text)
      case status
      when 401 then AuthError.new(message, status)
      when 403 then Forbidden.new(message, status)
      when 409 then Conflict.new(message, status)
      when 429
        retry_after = Integer(retry_after_header, exception: false)
        RateLimited.new(message, status, retry_after)
      when 400 then classify400(message, status)
      else
        # 404 has no type of its own by design; it and every other non-2xx land on the base error.
        PaymosError.new(message, status)
      end
    end
  end
end
