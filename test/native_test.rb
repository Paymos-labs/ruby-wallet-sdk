# frozen_string_literal: true

# Where the co-signing core comes from, and what it must hash to. The release is an in-memory
# stand-in; nothing here downloads anything or loads a library.

require_relative "test_helper"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "zlib"

class NativeTest < Minitest::Test
  RID = "linux-x64" # the resolver is told the platform; any one will do
  BASE = "https://release.test"
  ARCHIVE = "paymos-wallet-native-v#{Paymos::Native::CORE_VERSION}-#{RID}.tar.gz"

  def setup
    @cache = Dir.mktmpdir("paymos-core-")
  end

  def teardown
    FileUtils.rm_rf(@cache)
  end

  # A release archive in the shape native-artifacts.sh packs: one file, no directory.
  def archive(library)
    io = StringIO.new(String.new(encoding: Encoding::BINARY))
    gz = Zlib::GzipWriter.new(io)
    Gem::Package::TarWriter.new(gz) do |tar|
      tar.add_file_simple("libwallet_mpc.so", 0o755, library.bytesize) { |f| f.write(library) }
    end
    gz.finish
    io.string
  end

  # A stand-in release serving +library+; its .sha256 the archive's true one unless given.
  def release(library, checksum: nil)
    body = archive(library)
    prefix = "#{BASE}/v#{Paymos::Native::CORE_VERSION}/#{ARCHIVE}"
    { prefix => body, "#{prefix}.sha256" => "#{checksum || ::Digest::SHA256.hexdigest(body)}  #{ARCHIVE}\n" }
  end

  def resolve(files, pin, asked = [])
    pins = pin ? { Paymos::Native::CORE_VERSION => { RID => pin } } : {}
    Paymos::Native.resolve_cached_or_downloaded(@cache, RID, Paymos::Native::CORE_VERSION, BASE, pins) do |url, _limit|
      asked << url
      files.fetch(url) { raise Paymos::PaymosError, "404 #{url}" }
    end
  end

  # Empty until the owner fills it; a pasted entry with a typo fails here, not at a user's first payout.
  def test_every_shipped_pin_names_a_known_platform_and_is_a_sha256
    platforms = %w[linux-x64 linux-arm64 win-x64 win-arm64 osx-x64 osx-arm64]
    Paymos::Native::PINNED_CORE_SHA256.each do |version, by_rid|
      by_rid.each do |rid, hash|
        assert_includes platforms, rid, "#{version}: unknown platform"
        assert_match(/\A[0-9a-fA-F]{64}\z/, hash, "#{version}/#{rid}")
      end
    end
  end

  def test_a_pinned_hash_is_the_only_one_accepted_and_the_cache_is_rehashed
    library = "the trusted co-signing core"
    files = release(library, checksum: "0" * 64) # wrong, and never read
    pin = ::Digest::SHA256.hexdigest(library).upcase
    asked = []

    path = resolve(files, pin, asked)
    assert_equal library, File.binread(path)
    assert(asked.none? { |u| u.end_with?(".sha256") }, asked.inspect)

    before = asked.length
    assert_equal path, resolve(files, pin, asked)
    assert_equal before, asked.length, "a cached core loads without a download"

    File.binwrite(path, "a substituted library")
    err = assert_raises(Paymos::PaymosError) { resolve(files, pin) }
    assert_match(/SHA-256 mismatch/, err.message)
    assert_includes err.message, path
    assert File.exist?(path), "the refused file is left where it is"
  end

  def test_a_download_that_misses_the_pin_is_refused_before_anything_is_written
    files = release("a replaced release") # its own .sha256 is right
    err = assert_raises(Paymos::PaymosError) { resolve(files, ::Digest::SHA256.hexdigest("the trusted co-signing core")) }
    assert_match(/SHA-256 mismatch/, err.message)
    assert_empty Dir.glob(File.join(@cache, "**", "*")).select { |f| File.file?(f) }
  end

  def test_without_a_pin_the_release_checksum_decides_as_it_always_did
    library = "a core this SDK build carries no hash for"
    asked = []
    path = resolve(release(library), nil, asked)
    assert_equal 1, asked.count { |u| u.end_with?(".sha256") }

    File.binwrite(path, "changed on disk")
    assert_equal path, resolve(release(library), nil), "an unpinned cache is trusted as written"

    File.delete(path)
    err = assert_raises(Paymos::PaymosError) { resolve(release(library, checksum: "0" * 64), nil) }
    assert_match(/SHA-256 mismatch/, err.message)
  end

  def test_a_release_cannot_make_the_sdk_inflate_a_decompression_bomb
    err = assert_raises(Paymos::PaymosError) do
      Paymos::Native.read_single_file_tar_gz(archive("\0" * 200_000), 1024)
    end
    assert_match(/over 1024 bytes/, err.message)
    assert_equal 4096, Paymos::Native.read_single_file_tar_gz(archive("\0" * 4096), 4096).bytesize
  end
end
