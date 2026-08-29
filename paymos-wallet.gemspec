# frozen_string_literal: true

require_relative "lib/paymos/version"

Gem::Specification.new do |spec|
  spec.name = "paymos-wallet"
  spec.version = Paymos::VERSION
  spec.summary = "Non-custodial, headless SDK to control a wallet vault"
  spec.description = "Balances, fee-transparent quotes, swaps and on-chain withdrawals " \
                     "over a co-signed 2-of-2 vault. Same surface as the Python, TypeScript, " \
                     "Rust, .NET and Go SDKs."
  spec.homepage = "https://wallet.paymos.io"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  # Zero runtime dependencies: fiddle, net/http, json and digest are all stdlib. The native
  # co-signing core downloads at first use from the paymos-wallet-core releases.
  spec.metadata = { "rubygems_mfa_required" => "true" }
end
