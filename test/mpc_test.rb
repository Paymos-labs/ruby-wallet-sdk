# frozen_string_literal: true

# Proves the Ruby SDK drives the same co-signing core the Python SDK and the server drive: a
# full 2-of-2 round — two parties, distributed key generation, commit, sign, aggregate — and the
# resulting ed25519 signature verifies. If this passes, the halves agree on what a signature is.
#
# The server-side operations are driven directly here rather than through the SDK, because the
# SDK deliberately cannot perform them: it holds one half and no more.

require_relative "test_helper"

class MpcTest < Minitest::Test
  CLIENT = 1
  SERVER = 2

  def call(req)
    Paymos::Native.call_op(req)
  end

  def package_for(packages, id)
    packages.find { |pair| pair[0] == id }[1]
  end

  def test_co_signs_a_real_2of2_signature_with_the_server_half
    a1 = call({ "op" => "dkg_part1", "id" => CLIENT, "max" => 2, "min" => 2 })
    b1 = call({ "op" => "dkg_part1", "id" => SERVER, "max" => 2, "min" => 2 })
    a2 = call({ "op" => "dkg_part2", "secret" => a1["secret"],
                "round1_packages" => [[SERVER, b1["package"]]] })
    b2 = call({ "op" => "dkg_part2", "secret" => b1["secret"],
                "round1_packages" => [[CLIENT, a1["package"]]] })
    a3 = call({ "op" => "dkg_part3", "secret" => a2["secret"],
                "round1_packages" => [[SERVER, b1["package"]]],
                "round2_packages" => [[SERVER, package_for(b2["packages"], CLIENT)]] })
    b3 = call({ "op" => "dkg_part3", "secret" => b2["secret"],
                "round1_packages" => [[CLIENT, a1["package"]]],
                "round2_packages" => [[CLIENT, package_for(a2["packages"], SERVER)]] })
    assert_equal a3["group_pubkey_hex"], b3["group_pubkey_hex"], "both halves derive one group key"

    # The client half goes through the SDK; the server half is driven directly, because the SDK
    # has no way to perform it and that is the point.
    client_commitments, client_nonces = Paymos::Native.commit(a3["key_package"])
    server = call({ "op" => "commit", "key_package" => b3["key_package"] })

    pkg = call({ "op" => "build_signing_package",
                 "commitments" => [[CLIENT, client_commitments], [SERVER, server["commitments"]]],
                 "message_hex" => "deadbeef" })

    client_share = Paymos::Native.sign(pkg["signing_package"], client_nonces, a3["key_package"])
    server_share = call({ "op" => "sign", "signing_package" => pkg["signing_package"],
                          "nonces" => server["nonces"], "key_package" => b3["key_package"] })

    agg = call({ "op" => "aggregate", "signing_package" => pkg["signing_package"],
                 "signature_shares" => [[CLIENT, client_share], [SERVER, server_share["signature_share"]]],
                 "public_key_package" => a3["public_key_package"] })
    assert_equal true, agg["verified"], "aggregate verifies: #{agg}"
  end

  def test_reports_a_failed_op_instead_of_returning_nonsense
    assert_raises(Paymos::PaymosError) { Paymos::Native.sign({}, {}, {}) }
  end

  def test_reports_the_pinned_core_version
    r = call({ "op" => "version" })
    assert_equal Paymos::Native::CORE_VERSION, r["version"]
  end
end
