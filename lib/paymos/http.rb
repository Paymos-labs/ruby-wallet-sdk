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

    # +transport+ is the test seam: a callable taking (method, uri, headers, body_string) — method
    # being "GET" or "POST", body_string nil on a GET — and returning
    # [status, headers_hash, body_string]. Production leaves it nil and Net::HTTP does the work.
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
      request("GET", uri, {}, nil)
    end

    def post(path, body_hash, extra_headers = {})
      uri = URI.join(@base_url + "/", path.sub(%r{\A/}, ""))
      headers = { "content-type" => "application/json" }.merge(extra_headers)
      request("POST", uri, headers, JSON.generate(body_hash))
    end

    private

    def request(method, uri, headers, body)
      headers = { "authorization" => "Bearer #{@api_key}" }.merge(headers)

      status, resp_headers, text =
        if @transport
          begin
            @transport.call(method, uri, headers, body)
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
          req = (method == "POST" ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
          headers.each { |k, v| req[k] = v }
          req.body = body if body
          begin
            resp = http.request(req)
            [resp.code.to_i, resp.each_header.to_h, resp.body.to_s]
          rescue StandardError => e
            raise PaymosError, "transport error: #{e.message}"
          end
        end

      text = text.to_s
      parsed = nil
      json = false
      unless text.strip.empty?
        begin
          parsed = JSON.parse(text)
          json = true
        rescue JSON::ParserError
          # not JSON: json stays false and the branches below say what answered instead
        end
      end

      if status >= 200 && status < 300
        # Every vault endpoint answers JSON. A 2xx that is not JSON is somebody else answering —
        # a proxy, or the public site served where the API was expected — and handing nil to the
        # caller would turn it into a NoMethodError three frames later.
        return parsed if json

        raise PaymosError.new("expected JSON from #{uri.path}, got #{describe(text)} " \
                              "(status #{status}) — is the base URL the vault API?", status)
      end

      raise raise_for(status, parsed, text, (resp_headers || {})["retry-after"])
    end

    def message_of(parsed, status, text)
      if parsed.is_a?(Hash)
        %w[error detail].each do |key|
          msg = parsed[key]
          return msg if msg.is_a?(String) && !msg.empty?
        end
      end
      trimmed = text.strip
      return "request failed with status #{status}" if trimmed.empty?
      # An HTML error page is not a message: say what answered instead of pasting the page.
      return "request failed with status #{status}: got #{describe(trimmed)}, not the vault API" if html?(trimmed)

      trimmed
    end

    def html?(text)
      text.lstrip.match?(/\A<(!doctype|html|head|body|\?xml)/i)
    end

    def describe(text)
      return "an empty body" if text.strip.empty?
      return "an HTML page" if html?(text)

      "a non-JSON body"
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
