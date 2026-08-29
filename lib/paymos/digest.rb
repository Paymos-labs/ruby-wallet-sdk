# frozen_string_literal: true

require "digest"

module Paymos
  # The exact 32 bytes the vault's signature is computed over — a byte-for-byte port of the
  # Python SDK's digest, which is itself pinned to the server by a cross-language golden vector.
  #
  # The SDK uses this to VERIFY, before a single FROST commitment leaves the process, that the
  # server disclosed the true message it is asking the vault to sign. Never blind-sign.
  #
  # digest = sha256 of:
  #   u32   tag                 fixed domain separation; must byte-match the server
  #   string message            u32-LE length prefix + utf-8
  #   bytes32 nonce             raw, exactly 32
  #   string recipient          u32-LE length prefix + utf-8
  #   option<string> callback   0x00 = none, else 0x01 + string
  module Digest
    # Part of the wire contract. Change it and the client and server stop agreeing forever.
    MSG_TAG = 2147484061

    module_function

    # The 32-byte sha256 digest the vault's ed25519 signature is over. nonce must be exactly 32.
    def payload_digest(message, nonce, recipient, callback_url = nil)
      unless nonce.bytesize == 32
        raise PaymosError, "nonce must be 32 bytes, got #{nonce.bytesize}"
      end

      w = [MSG_TAG].pack("V")
      w << len_prefixed_utf8(message)
      w << nonce
      w << len_prefixed_utf8(recipient)
      if callback_url.nil?
        w << "\x00".b
      else
        w << "\x01".b << len_prefixed_utf8(callback_url)
      end
      ::Digest::SHA256.digest(w)
    end

    # The digest as lowercase hex — the form the FROST signing package carries, so the two
    # compare.
    def payload_digest_hex(message, nonce, recipient, callback_url = nil)
      payload_digest(message, nonce, recipient, callback_url).unpack1("H*")
    end

    def len_prefixed_utf8(s)
      body = s.encode(Encoding::UTF_8).b
      [body.bytesize].pack("V") + body
    end
  end
end
