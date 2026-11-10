# frozen_string_literal: true

require_relative "test_helper"
require "pp"

class SecretTest < Minitest::Test
  FULL = Paymos::VaultSecret.pack("vk_live_abc123", 42, '{"share":"x"}')
  READ = Paymos::VaultSecret.pack("vk_live_abc123", 42, nil)

  def test_packs_then_parses_full_and_read_only
    full = Paymos::VaultSecret.parse(FULL)
    assert_equal "vk_live_abc123", full.api_key
    assert_equal 42, full.vault_id
    assert full.has_share?

    read = Paymos::VaultSecret.parse(READ)
    refute read.has_share?
    assert_nil read.share
  end

  def test_rejects_anything_that_is_not_a_vault_secret
    ["sk_prod_not_ours", "vk_test_dev_key", "", "vs_live_@@@"].each do |bad|
      assert_raises(Paymos::PaymosError) { Paymos::VaultSecret.parse(bad) }
    end
  end

  def test_rejects_a_secret_whose_api_key_is_not_one_of_ours
    assert_raises(Paymos::PaymosError) { Paymos::VaultSecret.parse(Paymos::VaultSecret.pack("nope", 1, nil)) }
  end

  def test_never_renders_the_share_and_masks_the_key
    s = Paymos::VaultSecret.parse(FULL)
    [s.to_s, s.inspect].each do |rendered|
      refute_includes rendered, 'share":"x', "the share must never be rendered"
      refute_includes rendered, "abc123", "the key must be masked"
      assert_includes rendered, "vk_live_", "the non-secret prefix is fine to show"
    end
  end

  # "" is truthy in Ruby: `idempotency_key || fresh` sent it as an empty header, which the server
  # reads as no key at all. It is refused before anything reaches the server.
  def test_an_empty_idempotency_key_is_refused_before_any_request
    seen = []
    w = Paymos::Wallet.new(Paymos::VaultSecret.pack("vk_live_test", 1, '{"verifying_key":"vk"}'),
                           base_url: "https://vault.test",
                           transport: lambda { |_method, uri, *|
                             seen << uri.to_s
                             raise "nothing may reach the server: #{uri}"
                           })
    ["", " ", "\t"].each do |key|
      err = assert_raises(Paymos::PaymosError) do
        w.withdraw(asset: "USDC@base", amount: "10", to: "0xabc", idempotency_key: key)
      end
      assert_match(/\Aidempotency_key is empty/, err.message)
      err = assert_raises(Paymos::PaymosError) do
        w.swap(send: "USDC@base", receive: "USDT@base", amount: "5", idempotency_key: key)
      end
      assert_match(/\Aidempotency_key is empty/, err.message)
    end
    assert_empty seen
  end

  # p, pp, inspect and JSON of the secret, the wallet, its transport, or a job holding them. Ruby's
  # default inspect prints every instance variable: the wallet's transport carried the API key.
  def test_no_printer_renders_the_key_or_the_share
    s = Paymos::VaultSecret.parse(FULL)
    w = Paymos::Wallet.new(FULL, base_url: "https://vault.test", transport: ->(*) { [200, {}, "[]"] })
    http = Paymos::Http.new("https://vault.test", "vk_live_abc123")
    job = { "wallet" => w, "secret" => s, "http" => http }
    pretty = +""
    PP.pp(job, pretty)
    rendered = [s.inspect, w.inspect, w.to_s, http.inspect, job.inspect, pretty,
                JSON.generate(job), s.to_json, w.to_json, http.to_json, job.to_json]
    rendered.each do |r|
      refute_includes r, "abc123", "the key leaked: #{r}"
      refute_includes r, 'share":"x', "the share leaked: #{r}"
      refute_includes r, 'share\":\"x', "the share leaked: #{r}"
    end
    assert_equal "#<Paymos::Wallet vault_id=42 has_share=true api_key=vk_live_…>", w.inspect
  end
end
