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
  #   1. PAYMOS_NATIVE_LIB — a full path to a local binary. The offline escape hatch, and the
  #      operator's own choice: no hash below applies to it.
  #   2. The per-user cache, where a previous run already left a verified binary.
  #   3. The paymos-wallet-core GitHub release — downloaded, verified, then cached.
  #
  # How a download and a cached file are verified depends on PINNED_CORE_SHA256. With an entry for
  # this version and platform, that compiled-in hash is the ONLY one accepted: the release's own
  # .sha256 is not even fetched, the library extracted from the archive must hash to the pin before
  # it is written, and the cached file is re-hashed against it on every load — a mismatch anywhere
  # refuses, and nothing crosses the FFI boundary. Without an entry, the archive is checked against
  # the .sha256 published beside it in the same release, which catches a corrupted download but not
  # a replaced release, and a cached file is trusted as written.
  #
  # Whatever the source, the loaded binary must self-report the version this SDK is pinned to
  # (fail-closed), and only then do its exports serve calls.
  module Native
    # The paymos-wallet-core release this SDK build is pinned to. Bump when the core releases;
    # the release matrix already treats a core change as a change to every FFI SDK.
    CORE_VERSION = "0.1.0"

    # Core version → platform ("linux-x64", "linux-arm64", "win-x64", "win-arm64", "osx-x64",
    # "osx-arm64") → the lowercase hex SHA-256 of the LIBRARY FILE inside
    # paymos-wallet-native-v<version>-<platform>.tar.gz — libwallet_mpc.so, wallet_mpc.dll or
    # libwallet_mpc.dylib as extracted, not the archive. Empty in this build: until it is filled, a
    # download is checked only against the release's own .sha256. Fill it from a build you trust;
    # the Go, C#, Java and PHP SDKs carry the same table.
    PINNED_CORE_SHA256 = {
      # "0.1.0" => {
      #   "linux-x64" => "<sha256 of libwallet_mpc.so>",
      #   "linux-arm64" => "<sha256 of libwallet_mpc.so>",
      #   "win-x64" => "<sha256 of wallet_mpc.dll>",
      # },
    }.freeze

    RELEASE_BASE = "https://github.com/paymos-labs/paymos-wallet-core/releases/download"

    # The archive holds one library of about a megabyte. These bounds stop a replaced release from
    # spending the integrator's memory on a huge download or a decompression bomb.
    MAX_ARCHIVE_BYTES = 64 << 20
    MAX_LIBRARY_BYTES = 64 << 20

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

      resolve_cached_or_downloaded(cache_root, rid, CORE_VERSION, RELEASE_BASE, PINNED_CORE_SHA256) do |url, limit|
        download(url, limit)
      end
    end

    # The compiled-in hash for +version+ on +rid+, lowercased, or nil.
    def pinned_hash(pins, version, rid)
      hash = pins.dig(version, rid).to_s.strip.downcase
      hash.empty? ? nil : hash
    end

    # The cached core for +rid+, downloading (through the block: url, limit → body) and installing
    # it first when there is none — verified against +pins+ when they cover the platform (and then
    # re-hashed on every call), otherwise against the release's own checksum. Parameterised so the
    # tests can drive it without a network.
    def resolve_cached_or_downloaded(cache_root, rid, version, release_base, pins, &download)
      cached = File.join(cache_root, "v#{version}", rid, lib_name(rid))
      pinned = pinned_hash(pins, version, rid)

      unless File.exist?(cached)
        archive_name = "paymos-wallet-native-v#{version}-#{rid}.tar.gz"
        archive = download.call("#{release_base}/v#{version}/#{archive_name}", MAX_ARCHIVE_BYTES)
        if pinned.nil?
          # No compiled-in hash: the release's own checksum, which proves the download intact and
          # nothing more.
          checksum = download.call("#{release_base}/v#{version}/#{archive_name}.sha256", 4096)
          verify_sha256!(archive, checksum, archive_name)
        end
        library = read_single_file_tar_gz(archive, MAX_LIBRARY_BYTES)
        check_pinned!(library, pinned, archive_name) if pinned # refused before a byte is written
        install(library, cached)
      end

      # A pinned core is re-hashed on every load, cached or just installed: the cache is only a
      # file on disk, and the pin is the only thing that says what may run.
      if pinned
        begin
          check_pinned!(File.binread(cached), pinned, cached)
        rescue PaymosError => e
          raise PaymosError, "#{e.message}. Nothing was loaded; delete #{cached} to fetch the core again " \
                             "— the download is held to the same hash."
        rescue SystemCallError => e
          raise PaymosError, "cannot read the cached co-signing core #{cached}: #{e.message}"
        end
      end
      cached
    end

    def check_pinned!(payload, want, what)
      got = ::Digest::SHA256.hexdigest(payload)
      return if got == want

      raise PaymosError, "SHA-256 mismatch for #{what}: this SDK pins #{want}, got #{got}"
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

    def download(url, limit, hops = 5)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.request_get(uri.request_uri.empty? ? "/" : uri.request_uri) do |resp|
          # GitHub release downloads redirect to a CDN — follow, bounded.
          if resp.is_a?(Net::HTTPRedirection) && hops.positive?
            return download(resp["location"], limit, hops - 1)
          end
          unless resp.is_a?(Net::HTTPSuccess)
            raise PaymosError,
                  "failed to download the co-signing core: #{url} answered #{resp.code}. " \
                  "Set PAYMOS_NATIVE_LIB to a local libwallet_mpc build to run offline"
          end
          # Read in chunks so a body past the limit stops the transfer instead of growing.
          body = String.new(encoding: Encoding::BINARY)
          resp.read_body do |chunk|
            body << chunk
            if body.bytesize > limit
              raise PaymosError, "failed to download the co-signing core: #{url} is over #{limit} bytes — refusing it"
            end
          end
          return body
        end
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

    # The first regular file of one of our own single-file archives, refused when its header
    # declares more than +limit+ bytes — the reader inflates no more than an entry declares, so a
    # bomb stops at the header.
    def read_single_file_tar_gz(archive, limit)
      Gem::Package::TarReader.new(Zlib::GzipReader.wrap(StringIO.new(archive))) do |tar|
        tar.each do |entry|
          if entry.header.size > limit
            raise PaymosError, "the downloaded core archive holds a file over #{limit} bytes — refusing to install it"
          end
          next unless entry.file?

          return entry.read || ""
        end
      end
      raise PaymosError, "the downloaded core archive carried no file — refusing to install it"
    rescue Zlib::Error, Gem::Package::Error => e
      raise PaymosError, "the downloaded core archive is unreadable: #{e.message}"
    end

    # Writes the library through a temporary file, so a reader never meets half of it.
    def install(library, destination)
      FileUtils.mkdir_p(File.dirname(destination))
      tmp = destination + ".tmp"
      File.binwrite(tmp, library)
      FileUtils.mv(tmp, destination)
    end
  end
end
