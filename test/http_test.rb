# frozen_string_literal: true

# The error mapping, which is the whole reason this layer exists: a caller branches on a class
# instead of matching a string, and the classes must land the same way they do in Python.

require_relative "test_helper"

class HttpTest < Minitest::Test
  def wallet_over(status, body, headers = {})
    stub = lambda do |_method, _uri, _headers, _body|
      [status, headers, body]
    end
    Paymos::Wallet.new(Paymos::VaultSecret.pack("vk_live_x", 1, nil),
                       base_url: "https://example.test", transport: stub)
  end

  def test_returns_parsed_json_on_a_2xx
    # A bare array: what the server has always answered, and what the contract fixtures record.
    w = wallet_over(200, '[{"asset":"USDC@base","symbol":"USDC","chain":"base","decimals":6}]')
    assets = w.assets
    assert_equal 1, assets.length
    assert_equal "USDC@base", assets[0].asset
  end

  def test_maps_status_codes_to_types
    cases = [
      [401, Paymos::AuthError],
      [403, Paymos::Forbidden],
      [409, Paymos::Conflict],
      [404, Paymos::PaymosError],
      [500, Paymos::PaymosError]
    ]
    cases.each do |status, klass|
      err = assert_raises(Paymos::PaymosError) { wallet_over(status, '{"error":"boom"}').assets }
      assert_instance_of klass, err, "status #{status}"
      assert_equal status, err.status
    end
  end

  def test_classifies_a_400_by_its_message_first_match_winning
    cases = [
      ["cross-asset withdraw is not allowed", Paymos::CrossAssetWithdrawNotAllowed],
      ["slippage exceeded", Paymos::SlippageExceeded],
      ["quote expired", Paymos::QuoteExpired],
      ["insufficient balance", Paymos::InsufficientFunds],
      ["available balance is lower", Paymos::InsufficientFunds],
      ["No liquidity available, try again in a moment", Paymos::RouteUnavailable],
      ["route can't be quoted", Paymos::RouteUnavailable],
      ["something else entirely", Paymos::PaymosError]
    ]
    cases.each do |message, klass|
      err = assert_raises(Paymos::PaymosError) do
        wallet_over(400, JSON.generate({ error: message })).assets
      end
      assert_instance_of klass, err, message
    end
  end

  def test_carries_retry_after_on_a_429_when_the_server_sends_one
    err = assert_raises(Paymos::RateLimited) do
      wallet_over(429, '{"error":"slow down"}', { "retry-after" => "12" }).assets
    end
    assert_equal 12, err.retry_after

    err = assert_raises(Paymos::RateLimited) { wallet_over(429, '{"error":"slow down"}').assets }
    assert_nil err.retry_after
  end

  def test_falls_back_to_the_raw_body_when_there_is_no_error_envelope
    err = assert_raises(Paymos::PaymosError) { wallet_over(500, "upstream exploded").assets }
    assert_equal "upstream exploded", err.message
  end

  def test_wraps_a_transport_failure_instead_of_leaking_it
    failing = ->(_method, _uri, _headers, _body) { raise Errno::ECONNRESET, "connection reset" }
    w = Paymos::Wallet.new(Paymos::VaultSecret.pack("vk_live_x", 1, nil),
                           base_url: "https://example.test", transport: failing)
    err = assert_raises(Paymos::PaymosError) { w.assets }
    assert_nil err.status
  end

  def test_sends_the_bearer_token_and_the_idempotency_key
    seen = {}
    stub = lambda do |_method, uri, headers, body|
      seen[:path] = uri.path
      seen[:headers] = headers
      seen[:body] = body
      case uri.path
      when "/vault/v1/assets"
        [200, {}, '[{"asset":"USDC@base","symbol":"USDC","chain":"base","decimals":6}]']
      when "/vault/v1/quote/withdraw"
        # A deliberately wrong asset: the echo check fails AFTER the request was seen.
        [200, {}, '{"movement_id":"m1","mode":"exact_out",' \
                  '"send":{"amount":"24000000","asset":"OTHER"},' \
                  '"debit":{"amount":"25000000","asset":"USDC@base"},' \
                  '"receive":{"amount":"25000000","min":"25000000","asset":"USDC@base"},' \
                  '"fees":{"asset":"USDC@base","platform":"0","network":"0","total":"0"},' \
                  '"expires_at":"2026-01-01T00:00:00+00:00","sources":1}']
      else
        [404, {}, "{}"]
      end
    end
    w = Paymos::Wallet.new(Paymos::VaultSecret.pack("vk_live_secret", 1, '{"k":1}'),
                           base_url: "https://example.test", transport: stub)

    err = assert_raises(Paymos::PaymosError) do
      w.withdraw(asset: "USDC@base", amount: "25", to: "0xRecipient", idempotency_key: "abc")
    end
    assert_match(/not the USDC@base→USDC@base that was approved/, err.message)
    assert_equal "Bearer vk_live_secret", seen[:headers]["authorization"]
    assert_equal "abc", seen[:headers]["idempotency-key"]
  end
end
