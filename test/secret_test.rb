# frozen_string_literal: true

require_relative "test_helper"

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
end
