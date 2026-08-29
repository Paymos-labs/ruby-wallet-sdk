# frozen_string_literal: true

require "base64"
require "json"

module Paymos
  # The "vs_live_…" vault secret: an API key, the vault id, and — for a full key — this side's
  # FROST signing share. Ported from the Python SDK, same envelope, same field names, so one
  # secret works with any of the SDKs.
  class VaultSecret
    PREFIX = "vs_live_"

    attr_reader :api_key, :vault_id, :share

    def initialize(api_key:, vault_id:, share: nil)
      @api_key = api_key
      @vault_id = vault_id
      @share = share
    end

    def has_share?
      !@share.nil?
    end

    def self.pack(api_key, vault_id, share)
      payload = JSON.generate({ k: api_key, v: vault_id, s: share })
      PREFIX + Base64.urlsafe_encode64(payload, padding: false)
    end

    def self.parse(secret)
      unless secret.is_a?(String) && secret.start_with?(PREFIX)
        raise PaymosError, "not a vs_live_ vault secret"
      end

      begin
        packed = secret[PREFIX.length..]
        # urlsafe_decode64 wants canonical padding; the envelope drops it.
        o = JSON.parse(Base64.urlsafe_decode64(packed + "=" * (-packed.length % 4)))
      rescue StandardError => e
        raise PaymosError, "malformed vault secret: #{e.message}"
      end
      api_key = o["k"]
      unless api_key.is_a?(String) && api_key.start_with?("vk_live_")
        raise PaymosError, "vault secret carries no valid api key"
      end
      vault_id = o["v"]
      raise PaymosError, "vault secret carries no valid vault id" unless vault_id.is_a?(Integer)

      new(api_key: api_key, vault_id: vault_id, share: o["s"]&.to_s)
    end

    # Never renders the share, and masks the key: a stray log line must not leak either.
    def to_s
      mask = @api_key.empty? ? "…" : "#{@api_key[0, 8]}…"
      "VaultSecret(apiKey=#{mask}, vaultId=#{@vault_id}, hasShare=#{has_share?})"
    end
    alias inspect to_s
  end
end
