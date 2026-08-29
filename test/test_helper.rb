# frozen_string_literal: true

require "minitest/autorun"
require "paymos"

# The native core for the mpc test comes from PAYMOS_NATIVE_LIB (set by the release preflight)
# or, in a source checkout, from the core's own release build under mpc/wallet-mpc/target.
unless ENV["PAYMOS_NATIVE_LIB"] && !ENV["PAYMOS_NATIVE_LIB"].empty?
  dir = File.expand_path("..", __dir__)
  2.times { dir = File.dirname(dir) } # test/ → sdk/ruby → repo root
  lib = File.join(dir, "mpc", "wallet-mpc", "target", "release",
                  Gem.win_platform? ? "wallet_mpc.dll" : "libwallet_mpc.so")
  ENV["PAYMOS_NATIVE_LIB"] = lib if File.exist?(lib)
end
