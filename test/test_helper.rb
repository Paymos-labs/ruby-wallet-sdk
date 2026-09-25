# frozen_string_literal: true

require "minitest/autorun"
require "paymos"

# The native core for the mpc test comes from PAYMOS_NATIVE_LIB (set by the release preflight)
# or, in a source checkout, from the core's own release build under mpc/wallet-mpc/target.
unless ENV["PAYMOS_NATIVE_LIB"] && !ENV["PAYMOS_NATIVE_LIB"].empty?
  dir = File.expand_path("..", __dir__)
  2.times { dir = File.dirname(dir) } # test/ → sdk/ruby → repo root
  name = if Gem.win_platform? then "wallet_mpc.dll"
         elsif RUBY_PLATFORM.include?("darwin") then "libwallet_mpc.dylib"
         else "libwallet_mpc.so"
         end
  lib = File.join(dir, "mpc", "wallet-mpc", "target", "release", name)
  ENV["PAYMOS_NATIVE_LIB"] = lib if File.exist?(lib)
end
