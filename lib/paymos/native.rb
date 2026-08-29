# frozen_string_literal: true

require "digest"
require "fiddle"
require "fiddle/import"
require "fileutils"
require "json"
require "net/http"
require "rubygems/package"
require "stringio"
require "zlib"

module Paymos
  # The SDK's half of the 2-of-2 co-sign, over the same Rust core the Python SDK embeds and the
  # .NET server calls. Nobody reimplements FROST: this is a JSON op in, a JSON op out, and the
  # bytes signed here are the bytes those two would sign.
  #
  # Only two operations run client-side in production: commit (round one, per movement source)
  # and sign (round two, one share per signing package). build_signing_package and aggregate are
  # server-side operations and are deliberately absent.
  #
  # The binary comes from three places, in this order:
  #   1. PAYMOS_NATIVE_LIB — a full path to a local binary. The offline escape hatch.
  #   2. The per-user cache, where a previous run already left a verified binary.
  #   3. The paymos-wallet-core GitHub release — downloaded, SHA-256-checked against the
  #      release's checksum file, then cached. A mismatch refuses: a substituted binary never
  #      crosses the FFI boundary.
  # Whatever the source, the loaded binary must self-report the version this SDK is pinned to
  # (fail-closed), and only then do its exports serve calls.
  module Native
    # The paymos-wallet-core release this SDK build is pinned to. Bump when the core releases;
    # the release matrix already treats a core change as a change to every FFI SDK.
    CORE_VERSION = "0.1.0"

    RELEASE_BASE = "https://github.com/paymos-labs/paymos-wallet-core/releases/download"

    @mutex = Mutex.new
    @call_fn = nil
    @free_fn = nil

    module_function

    # Run one JSON op against the core; returns the parsed envelope, raising on a failed op.
    def call_op(request_hash)
      ensure_core
      req = JSON.generate(request_hash)
      out_len = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T, Fiddle::RUBY_FREE)
      out_ptr = @call_fn.call(req, req.bytesize, out_len)
      raise PaymosError, "mpc call returned nothing" if out_ptr.null?

      begin
        len = out_len[0, Fiddle::SIZEOF_SIZE_T].unpack1(Fiddle::SIZEOF_SIZE_T == 8 ? "Q" : "L")
        raw = out_ptr[0, len]
      ensure
        @free_fn.call(out_ptr, len || 0)
      end

      resp = JSON.parse(raw)
      unless resp.is_a?(Hash) && resp["ok"] == true
        msg = resp.is_a?(Hash) ? resp["error"] : nil
        raise PaymosError, (msg.is_a?(String) && !msg.empty? ? msg : "mpc call failed")
      end
      resp
    end

    # Round one for one signing session. Send the commitments to sign/begin; keep the nonces
    # private.
    def commit(key_package)
      r = call_op({ "op" => "commit", "key_package" => key_package })
      [r["commitments"], r["nonces"]]
    end

    # Round two: this side's signature share, which the server aggregates with its own.
    def sign(signing_package, nonces, key_package)
      r = call_op({ "op" => "sign", "signing_package" => signing_package,
                    "nonces" => nonces, "key_package" => key_package })
      r["signature_share"]
    end

    def ensure_core
      @mutex.synchronize do
        next if @call_fn

        path = resolve_path
        handle = Fiddle.dlopen(path)
        call_fn = Fiddle::Function.new(
          handle["mpc_call"],
          [Fiddle::TYPE_VOIDP, Fiddle::SIZEOF_SIZE_T == 8 ? Fiddle::TYPE_LONG_LONG : Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP],
          Fiddle::TYPE_VOIDP
        )
        free_fn = Fiddle::Function.new(
          handle["mpc_free"],
          [Fiddle::TYPE_VOIDP, Fiddle::SIZEOF_SIZE_T == 8 ? Fiddle::TYPE_LONG_LONG : Fiddle::TYPE_LONG],
          Fiddle::TYPE_VOID
        )
        verify_version!(call_fn, free_fn, path)
        @call_fn = call_fn
        @free_fn = free_fn
      end
    end

    # The version check goes through the freshly resolved exports — the core answers for itself.
    def verify_version!(call_fn, free_fn, path)
      req = JSON.generate({ "op" => "version" })
      out_len = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T, Fiddle::RUBY_FREE)
      out_ptr = call_fn.call(req, req.bytesize, out_len)
      raise PaymosError, "the loaded co-signing core does not answer — too old for this SDK" if out_ptr.null?

      begin
        len = out_len[0, Fiddle::SIZEOF_SIZE_T].unpack1(Fiddle::SIZEOF_SIZE_T == 8 ? "Q" : "L")
        resp = JSON.parse(out_ptr[0, len])
      ensure
        free_fn.call(out_ptr, len || 0)
      end
      version = resp["version"].to_s
      if version.empty?
        raise PaymosError, "the loaded co-signing core does not report a version — too old for this SDK"
      end
      return if version == CORE_VERSION

      raise PaymosError,
            "co-signing core version mismatch: #{path} reports v#{version}, this SDK is pinned to " \
            "v#{CORE_VERSION}. Set PAYMOS_NATIVE_LIB to a matching build or clear the paymos native cache."
    end

    def resolve_path
      rid = current_rid
      override = ENV["PAYMOS_NATIVE_LIB"]
      unless override.nil? || override.empty?
        raise PaymosError, "PAYMOS_NATIVE_LIB points at a missing file: #{override}" unless File.exist?(override)

        return override
      end

      cache_dir = File.join(cache_root, "v#{CORE_VERSION}", rid)
      cached = File.join(cache_dir, lib_name(rid))
      return cached if File.exist?(cached)

      archive_name = "paymos-wallet-native-v#{CORE_VERSION}-#{rid}.tar.gz"
      archive = download("#{RELEASE_BASE}/v#{CORE_VERSION}/#{archive_name}")
      checksum = download("#{RELEASE_BASE}/v#{CORE_VERSION}/#{archive_name}.sha256")
      verify_sha256!(archive, checksum, archive_name)
      extract_single_file_tar_gz(archive, cached)
      cached
    end

    def current_rid
      os = if Gem.win_platform?
             "win"
           elsif RUBY_PLATFORM =~ /darwin/
             "osx"
           elsif RUBY_PLATFORM =~ /linux/
             "linux"
           else
             raise PaymosError,
                   "unsupported OS: #{RUBY_PLATFORM}. Supported: linux/macos/windows on x64 and arm64"
           end
      arch = case RUBY_PLATFORM
             when /x86_64|x64/ then "x64"
             when /aarch64|arm64/ then "arm64"
             else
               raise PaymosError,
                     "unsupported CPU architecture: #{RUBY_PLATFORM}. Supported: x64, arm64"
             end
      "#{os}-#{arch}"
    end

    def lib_name(rid)
      return "wallet_mpc.dll" if rid.start_with?("win")
      return "libwallet_mpc.dylib" if rid.start_with?("osx")

      "libwallet_mpc.so"
    end

    def cache_root
      base = if Gem.win_platform?
               ENV["LOCALAPPDATA"]
             elsif RUBY_PLATFORM =~ /darwin/
               File.join(Dir.home, "Library", "Caches")
             else
               ENV["XDG_CACHE_HOME"] || File.join(Dir.home, ".cache")
             end
      raise PaymosError, "cannot locate a user cache directory" if base.nil? || base.empty?

      File.join(base, "paymos", "native")
    end

    def download(url, hops = 5)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        resp = http.get(uri.request_uri.empty? ? "/" : uri.request_uri)
        # GitHub release downloads redirect to a CDN — follow, bounded.
        if resp.is_a?(Net::HTTPRedirection) && hops.positive?
          return download(resp["location"], hops - 1)
        end
        unless resp.is_a?(Net::HTTPSuccess)
          raise PaymosError,
                "failed to download the co-signing core: #{url} answered #{resp.code}. " \
                "Set PAYMOS_NATIVE_LIB to a local libwallet_mpc build to run offline"
        end
        resp.body
      end
    rescue PaymosError
      raise
    rescue StandardError => e
      raise PaymosError,
            "failed to download the co-signing core: #{e.message}. " \
            "Set PAYMOS_NATIVE_LIB to a local libwallet_mpc build to run offline"
    end

    def verify_sha256!(payload, checksum_text, archive_name)
      # Format produced by `sha256sum`: "<hex>  <name>".
      expected = checksum_text.strip.split.first.to_s.downcase
      raise PaymosError, "empty checksum file for the co-signing core download" if expected.empty?

      actual = ::Digest::SHA256.hexdigest(payload)
      return if actual == expected

      raise PaymosError,
            "SHA-256 mismatch for #{archive_name}: expected #{expected}, got #{actual}. " \
            "The download was refused and nothing was loaded."
    end

    def extract_single_file_tar_gz(archive, destination)
      FileUtils.mkdir_p(File.dirname(destination))
      Gem::Package::TarReader.new(Zlib::GzipReader.wrap(StringIO.new(archive))) do |tar|
        tar.each do |entry|
          next unless entry.file?

          tmp = destination + ".tmp"
          File.binwrite(tmp, entry.read)
          FileUtils.mv(tmp, destination)
          return
        end
      end
      raise PaymosError, "the downloaded core archive carried no file — refusing to install it"
    end
  end
end
