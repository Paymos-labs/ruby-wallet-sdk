# frozen_string_literal: true

# The wire contract: every response here is one the real server recorded (sdk/contract/fixtures,
# vendored as contract/fixtures in the public mirror). Nothing below is a shape somebody imagined —
# that is how this SDK once shipped reading {"assets": [...]} from an endpoint that has always
# answered a bare array, with a green suite.
#
# The fixtures are served through the transport seam, so no request leaves the process, and the
# request the SDK sends is checked against the one the fixture was recorded from.

require_relative "test_helper"

module ContractFixtures
  # Walk up from this file: contract/fixtures (the public mirror), then sdk/contract/fixtures
  # (this repository). Not finding either is a failure, never a skip — a suite that quietly stops
  # reading the contract is the failure this file exists to prevent.
  def self.dir
    @dir ||= begin
      found = nil
      d = __dir__
      loop do
        %w[contract/fixtures sdk/contract/fixtures].each do |rel|
          cand = File.join(d, rel)
          if File.directory?(cand)
            found = cand
            break
          end
        end
        break if found

        parent = File.dirname(d)
        break if parent == d

        d = parent
      end
      found
    end
  end

  def self.load(name)
    raise "contract fixtures not found above #{__dir__}" unless dir

    JSON.parse(File.read(File.join(dir, "#{name}.json")))
  end
end

class ContractTest < Minitest::Test
  # What the Python SDK — the reference — holds. The Ruby sets must classify every status the
  # server can send exactly the same way.
  PY_TERMINAL = %w[completed failed refunded expired cancelled].freeze
  PY_PROGRESSED = %w[processing completed refunded].freeze

  # The verifying key the fixtures' disclosure names as signer.
  SIGNER = "vault.example"

  Request = Struct.new(:method, :path, :headers, :body, keyword_init: true)

  # Routes "METHOD /path" to a fixture response, or to a proc returning [status, body].
  class FakeServer
    attr_reader :requests

    def initialize(routes)
      @routes = routes
      @requests = []
    end

    def call(method, uri, headers, body)
      path = uri.request_uri
      @requests << Request.new(method: method, path: path, headers: headers,
                               body: body && JSON.parse(body))
      route = @routes["#{method} #{path}"] || @routes["#{method} #{uri.path}"]
      return [404, {}, '{"error":"not found"}'] unless route

      status, body_out = route.respond_to?(:call) ? route.call : route
      [status, {}, body_out.is_a?(String) ? body_out : JSON.generate(body_out)]
    end

    def sent(method, path)
      @requests.select { |r| r.method == method && r.path == path }
    end
  end

  def fx(name)
    ContractFixtures.load(name)
  end

  def response_of(name)
    f = fx(name)
    [f["response"]["status"], f["response"]["body"]]
  end

  def route_of(name)
    f = fx(name)
    { "#{f['request']['method']} #{f['request']['path']}" => response_of(name) }
  end

  def wallet(routes, share: nil)
    server = FakeServer.new(routes)
    w = Paymos::Wallet.new(Paymos::VaultSecret.pack("vk_live_test", 7, share),
                           base_url: "https://example.test", transport: server)
    [w, server]
  end

  def full_share
    JSON.generate({ "verifying_key" => SIGNER })
  end

  # The catalog every quote validates its amount against — itself a fixture.
  def catalog
    route_of("assets")
  end

  # Swap Native's two client-side ops for the duration of a block: the fixtures' crypto values are
  # placeholders, so this tests the protocol around the core, not the core (mpc_test does that).
  def with_native_stubbed
    calls = { commit: 0, sign: 0 }
    native = Paymos::Native.singleton_class
    originals = %i[commit sign].to_h { |m| [m, native.instance_method(m)] }
    replace = lambda do |name, impl|
      native.remove_method(name)
      native.define_method(name, impl)
    end
    replace.call(:commit, proc do |_kp|
      calls[:commit] += 1
      [{ "identifier" => "01", "hiding" => "aa", "binding" => "bb" }, { "n" => calls[:commit] }]
    end)
    replace.call(:sign, proc do |_pkg, _nonces, _kp|
      calls[:sign] += 1
      { "identifier" => "01", "share" => "cc" }
    end)
    yield calls
  ensure
    originals&.each { |name, um| replace.call(name, um) }
  end

  # Asserts the SDK sent exactly the fixture's request: method, path, and every body field. The
  # only field the SDK may add is `dry: false`, which the server takes as its default.
  def assert_sent_matches(server, name)
    want = fx(name)["request"]
    got = server.sent(want["method"], want["path"])
    assert_equal 1, got.length, "#{name}: expected one #{want['method']} #{want['path']}, saw #{server.requests.map(&:path)}"
    return if want["body"].nil?

    body = got[0].body.dup
    body.delete("dry") if body["dry"] == false && !want["body"].key?("dry")
    assert_equal want["body"], body, "#{name}: request body"
  end

  # ── fixture discovery ─────────────────────────────────────────────────────

  def test_finds_the_fixtures
    refute_nil ContractFixtures.dir, "contract/fixtures or sdk/contract/fixtures must exist above test/"
    assert File.exist?(File.join(ContractFixtures.dir, "assets.json"))
  end

  # ── reads ─────────────────────────────────────────────────────────────────

  def test_assets_parses_the_bare_array
    w, server = wallet(route_of("assets"))
    assets = w.assets
    assert_equal 2, assets.length
    assert_equal "USDC@base", assets[0].asset
    assert_equal "USDC", assets[0].symbol
    assert_equal "base", assets[0].chain
    assert_equal 6, assets[0].decimals
    assert_equal "a42c7e46411394e7c7719eef5be19239b2716b91d3a4a843fd3d2c0b6ca16b7c", assets[0].fingerprint
    assert_equal ::Digest::SHA256.hexdigest(SEND_TOKEN), assets[0].fingerprint
    assert_equal "4aa51775b928a58a1ff49de71caf2cd78e1bf728d2853d7193d14cf30728f039", assets[1].fingerprint
    assert_equal "USDT@base", assets[1].asset
    assert_sent_matches(server, "assets")
  end

  def test_balances_parses_the_bare_array
    w, server = wallet(route_of("balances"))
    b = w.balances
    assert_equal 1, b.length
    assert_equal "USDC@base", b[0].asset
    assert_equal "USDC", b[0].symbol
    assert_equal "base", b[0].chain
    assert_equal 6, b[0].decimals
    assert_equal "1000000000", b[0].amount_raw
    assert_equal "1000", b[0].usd
    assert_sent_matches(server, "balances")
  end

  def test_balances_tolerate_an_omitted_usd
    status, body = response_of("balances")
    body[0].delete("usd")
    w, = wallet({ "GET /vault/v1/balances" => [status, body] })
    assert_nil w.balances[0].usd
  end

  def test_an_object_where_the_array_belongs_is_a_typed_error
    w, = wallet({ "GET /vault/v1/assets" => [200, { "assets" => [] }] })
    err = assert_raises(Paymos::PaymosError) { w.assets }
    assert_match(/not a JSON array/, err.message)
  end

  def test_movements_page_with_cursor
    w, server = wallet(route_of("movements_page"))
    items, cursor = w.movements(limit: 2)
    assert_sent_matches(server, "movements_page")
    assert_equal "cursor_1", cursor
    assert_equal %w[mv_3 mv_2], items.map(&:id)

    first = items[0]
    assert_equal "swap", first.type
    assert_equal "pending", first.status
    assert_equal "5000000", first.send.amount
    assert_equal "USDC@base", first.send.asset
    assert_equal "5000000", first.receive.amount
    assert_equal "5000000", first.receive.min
    assert_equal "USDT@base", first.receive.asset
    assert_equal "2026-01-01T00:00:00.0000000+00:00", first.created_at
    # A history row omits everything that is null — no fees, no settlement, no completion.
    assert_nil first.fees
    assert_nil first.dest_chain_tx_hash
    assert_nil first.dest_chain_explorer_url
    assert_nil first.completed_at

    second = items[1]
    assert_equal "withdrawal", second.type
    assert_equal "10000000", second.send.amount
    assert_equal "9975062", second.receive.amount
    assert_equal "9975062", second.receive.min
  end

  def test_movements_follows_the_cursor_and_ends_on_nil
    status, body = response_of("movements_page")
    last = body.reject { |k, _| k == "next_cursor" } # the server omits a null cursor
    w, server = wallet({ "GET /vault/v1/movements?limit=2" => [status, body],
                         "GET /vault/v1/movements?limit=2&cursor=cursor_1" => [status, last] })
    _, cursor = w.movements(limit: 2)
    _, cursor2 = w.movements(limit: 2, cursor: cursor)
    assert_nil cursor2
    assert_equal 1, server.sent("GET", "/vault/v1/movements?limit=2&cursor=cursor_1").length
  end

  def test_movement_with_fees
    w, server = wallet(route_of("movement"))
    m = w.movement("mv_3")
    assert_sent_matches(server, "movement")
    assert_equal "mv_3", m.id
    assert_equal "swap", m.type
    assert_equal "pending", m.status
    assert_equal "5000000", m.send.amount
    assert_equal "USDC@base", m.send.asset
    assert_equal "USDT@base", m.receive.asset
    assert_equal "2026-01-01T00:00:00.0000000+00:00", m.created_at
    assert_nil m.completed_at
    assert_nil m.dest_chain_tx_hash
    assert_fees(m.fees, asset: "USDC@base", platform: "0", network: "0", route: "0",
                        estimate: true, total: "0",
                        usd: { "platform" => "0", "network" => "0", "route" => "0", "total" => "0" })
  end

  def test_fees_tolerate_an_omitted_route_and_usd
    status, body = response_of("movement")
    body["fees"].delete("route")
    body["fees"].delete("usd")
    w, = wallet({ "GET /vault/v1/movements/mv_3" => [status, body] })
    fees = w.movement("mv_3").fees
    assert_nil fees.route
    assert_nil fees.usd
    assert_equal "0", fees.total
  end

  def assert_fees(fees, asset:, platform:, network:, route:, estimate:, total:, usd:)
    refute_nil fees
    assert_equal asset, fees.asset
    assert_equal platform, fees.platform
    assert_equal network, fees.network
    assert_equal route, fees.route.amount
    assert_equal estimate, fees.route.estimate
    assert_equal total, fees.total
    assert_equal usd, fees.usd
  end

  # ── quotes (dry previews) ─────────────────────────────────────────────────

  def test_quote_withdraw_dry
    w, server = wallet(catalog.merge(route_of("quote_withdraw_dry")))
    q = w.quote_withdraw(asset: "USDC@base", amount: "10",
                         to: "0xabc0000000000000000000000000000000000000")
    assert_sent_matches(server, "quote_withdraw_dry")
    assert_nil server.sent("POST", "/vault/v1/quote/withdraw")[0].headers["idempotency-key"],
               "a dry preview carries no Idempotency-Key"
    assert_nil q.movement_id
    assert_nil q.sources
    assert_equal "exact_out", q.mode
    assert_equal "10000000", q.send.amount
    assert_equal "USDC@base", q.send.asset
    assert_equal "10025000", q.debit.amount
    assert_equal "USDC@base", q.debit.asset
    assert_equal "10000000", q.receive.amount
    assert_equal "10000000", q.receive.min
    assert_equal "USDC@base", q.receive.asset
    assert_equal "2026-01-01T00:00:00.0000000+00:00", q.expires_at
    assert_fees(q.fees, asset: "USDC@base", platform: "25000", network: "0", route: "0",
                        estimate: false, total: "25000",
                        usd: { "platform" => "0.025", "network" => "0", "route" => "0", "total" => "0.025" })
    # Human ↔ raw: the request carried the human "10", the response is raw at the catalog's decimals.
    assert_equal "10", Paymos::Amounts.format_units(q.receive.amount, 6)
    assert_equal "10.025", Paymos::Amounts.format_units(q.debit.amount, 6)
  end

  def test_quote_swap_dry
    w, server = wallet(catalog.merge(route_of("quote_swap_dry")))
    q = w.quote_swap(send: "USDC@base", receive: "USDT@base", amount: "5")
    assert_sent_matches(server, "quote_swap_dry")
    body = server.sent("POST", "/vault/v1/quote/swap")[0].body
    assert_kind_of Integer, body["slippage_bps"]
    assert_equal true, body["dry"]
    assert_nil q.movement_id
    assert_nil q.sources
    assert_equal "exact_in", q.mode
    assert_equal "5000000", q.send.amount
    assert_equal "5000000", q.debit.amount
    assert_equal "5000000", q.receive.amount
    assert_equal "5000000", q.receive.min
    assert_equal "USDT@base", q.receive.asset
    assert_equal "2026-01-01T00:00:00.0000000+00:00", q.expires_at
    assert_fees(q.fees, asset: "USDC@base", platform: "0", network: "0", route: "0",
                        estimate: true, total: "0",
                        usd: { "platform" => "0", "network" => "0", "route" => "0", "total" => "0" })
  end

  # ── real quotes (the first leg of swap / withdraw) ─────────────────────────

  # Round one is refused and the movement is still pending: the co-sign stops there, with the
  # quote request already on the record to compare against the fixture.
  def begin_refused(mid)
    { "POST /vault/v1/movements/#{mid}/sign/begin" => response_of("sign_begin_error"),
      "GET /vault/v1/movements/#{mid}" => [200, response_of("movement")[1].merge("id" => mid)] }
  end

  def test_quote_withdraw_creates_a_movement
    w, server = wallet(catalog.merge(route_of("quote_withdraw")).merge(begin_refused("mv_1")),
                       share: full_share)
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) do
        w.withdraw(asset: "USDC@base", amount: "10", to: "0xabc0000000000000000000000000000000000000",
                   idempotency_key: "job-1")
      end
      assert_equal "commitments are required", err.message
      # sources: 2 → two commitments, one per source.
      assert_equal 2, calls[:commit]
      assert_equal 0, calls[:sign]
    end
    assert_sent_matches(server, "quote_withdraw")
    req = server.sent("POST", "/vault/v1/quote/withdraw")[0]
    assert_equal "job-1", req.headers["idempotency-key"]
    assert_equal false, req.body["dry"]
    assert_equal 2, server.sent("POST", "/vault/v1/movements/mv_1/sign/begin")[0].body["commitments"].length

    q = Paymos::Quote.from_wire(response_of("quote_withdraw")[1])
    assert_equal "mv_1", q.movement_id
    assert_equal 2, q.sources
    assert_equal "exact_out", q.mode
    assert_equal "10025000", q.debit.amount
    assert_fees(q.fees, asset: "USDC@base", platform: "25000", network: "0", route: "0",
                        estimate: false, total: "25000",
                        usd: { "platform" => "0.025", "network" => "0", "route" => "0", "total" => "0.025" })
  end

  def test_quote_withdraw_total_in
    w, server = wallet(catalog.merge(route_of("quote_withdraw_total_in")).merge(begin_refused("mv_2")),
                       share: full_share)
    with_native_stubbed do
      assert_raises(Paymos::PaymosError) do
        w.withdraw(asset: "USDC@base", amount: "10", to: "0xabc0000000000000000000000000000000000000",
                   mode: "total_in")
      end
    end
    assert_sent_matches(server, "quote_withdraw_total_in")
    refute_nil server.sent("POST", "/vault/v1/quote/withdraw")[0].headers["idempotency-key"]
    # The echo check passed (the debit equals the approved total), so round one was reached.
    assert_equal 1, server.sent("POST", "/vault/v1/movements/mv_2/sign/begin").length

    q = Paymos::Quote.from_wire(response_of("quote_withdraw_total_in")[1])
    assert_equal "mv_2", q.movement_id
    assert_equal "total_in", q.mode
    assert_equal "9975062", q.send.amount
    assert_equal "10000000", q.debit.amount
    assert_equal "9975062", q.receive.amount
    assert_equal "9975062", q.receive.min
    assert_equal 2, q.sources
    assert_equal "24938", q.fees.total
    assert_equal "0.024938", q.fees.usd["total"]
  end

  def test_quote_swap_creates_a_movement
    w, server = wallet(catalog.merge(route_of("quote_swap")).merge(begin_refused("mv_3")),
                       share: full_share)
    with_native_stubbed do |calls|
      assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
      assert_equal 1, calls[:commit]
    end
    assert_sent_matches(server, "quote_swap")
    refute_nil server.sent("POST", "/vault/v1/quote/swap")[0].headers["idempotency-key"]

    q = Paymos::Quote.from_wire(response_of("quote_swap")[1])
    assert_equal "mv_3", q.movement_id
    assert_equal 1, q.sources
    assert_equal "exact_in", q.mode
    assert_equal "USDT@base", q.receive.asset
  end

  def test_max_debit_refuses_before_any_commitment
    w, server = wallet(catalog.merge(route_of("quote_withdraw")), share: full_share)
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) do
        w.withdraw(asset: "USDC@base", amount: "10", to: "0xabc0000000000000000000000000000000000000",
                   max_debit: "10.02")
      end
      assert_match(/above the cap 10020000/, err.message)
      assert_equal 0, calls[:commit]
    end
    assert_empty server.sent("POST", "/vault/v1/movements/mv_1/sign/begin")
  end

  def test_min_receive_refuses_before_any_commitment
    w, = wallet(catalog.merge(route_of("quote_swap")), share: full_share)
    with_native_stubbed do |calls|
      assert_raises(Paymos::SlippageExceeded) do
        w.swap(send: "USDC@base", receive: "USDT@base", amount: "5", min_receive: "5.01")
      end
      assert_equal 0, calls[:commit]
    end
  end

  def test_an_echo_that_differs_from_the_approval_is_refused
    status, body = response_of("quote_withdraw")
    body["receive"] = body["receive"].merge("amount" => "9000000")
    w, = wallet(catalog.merge("POST /vault/v1/quote/withdraw" => [status, body]), share: full_share)
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) do
        w.withdraw(asset: "USDC@base", amount: "10", to: "0xabc0000000000000000000000000000000000000")
      end
      assert_match(/not the approved 10000000/, err.message)
      assert_equal 0, calls[:commit]
    end
  end

  # ── the co-sign rounds ────────────────────────────────────────────────────

  def swap_routes(begin_body, aggregate)
    catalog.merge(route_of("quote_swap"))
           .merge("POST /vault/v1/movements/mv_3/sign/begin" => [200, begin_body],
                  "POST /vault/v1/movements/mv_3/sign/aggregate" => aggregate)
           .merge(route_of("movement"))
  end

  # The recorded sign/begin, with its placeholder disclosure: the package does not bind to the
  # message (and the nonce is not 32 bytes). The blind-sign guard must refuse before a share exists.
  def test_sign_begin_placeholders_are_refused_by_the_blind_sign_guard
    begin_body = response_of("sign_begin")[1]
    assert_equal "sign-session-token", begin_body["token"]
    assert_equal 1, begin_body["signing_packages"].length
    assert_equal %w[message nonce recipient], begin_body["messages"][0].keys.sort

    w, server = wallet(swap_routes(begin_body, response_of("sign_aggregate")), share: full_share)
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) do
        w.swap(send: "USDC@base", receive: "USDT@base", amount: "5")
      end
      assert_match(/co-sign refused|nonce must be 32 bytes/, err.message)
      assert_equal 0, calls[:sign]
    end
    assert_empty server.sent("POST", "/vault/v1/movements/mv_3/sign/aggregate")
  end

  def test_sign_begin_without_disclosure_is_refused
    begin_body = response_of("sign_begin")[1].reject { |k, _| k == "messages" }
    w, = wallet(swap_routes(begin_body, response_of("sign_aggregate")), share: full_share)
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
      assert_match(/refusing to blind-sign/, err.message)
      assert_equal 0, calls[:sign]
    end
  end

  def test_sign_begin_package_count_must_match_sources
    begin_body = response_of("sign_begin")[1]
    begin_body = begin_body.merge("signing_packages" => begin_body["signing_packages"] * 2,
                                  "messages" => begin_body["messages"] * 2)
    w, = wallet(swap_routes(begin_body, response_of("sign_aggregate")), share: full_share)
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
      assert_match(/expected 1 signing packages, got 2/, err.message)
      assert_equal 0, calls[:sign]
    end
  end

  # The recorded sign/begin shape with a disclosure that is internally consistent — a single
  # transfer from this vault, bound by digest to its package — so the flow reaches round two.
  # The send asset's raw id — sha256 of it is the USDC@base fingerprint the assets fixture publishes.
  SEND_TOKEN = "usdc-base"

  def consistent_begin(amount: "5000000", signer: SIGNER, amounts: [amount], token: SEND_TOKEN)
    body = response_of("sign_begin")[1]
    disc = body["messages"][0]
    nonce = "00" * 32
    messages = []
    packages = []
    amounts.each do |a|
      message = JSON.generate({ "signer_id" => signer,
                                "intents" => [{ "intent" => "transfer", "receiver_id" => "r.example",
                                                "tokens" => { token => a } }] })
      messages << disc.merge("message" => message, "nonce" => nonce)
      packages << body["signing_packages"][0].merge(
        "message" => Paymos::Digest.payload_digest_hex(message, [nonce].pack("H*"), disc["recipient"])
      )
    end
    body.merge("messages" => messages, "signing_packages" => packages)
  end

  # Every source must move the SEND asset: a token key hashing to another asset's fingerprint —
  # here USDT@base's, against a debit approved in USDC@base — is refused before any share.
  def test_the_guard_refuses_a_transfer_of_another_asset
    w, server = wallet(swap_routes(consistent_begin(token: "usdt-base"), response_of("sign_aggregate")),
                       share: full_share)
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
      assert_match(/co-sign refused: source 0 transfers a token other than USDC@base/, err.message)
      assert_equal 0, calls[:sign]
    end
    assert_empty server.sent("POST", "/vault/v1/movements/mv_3/sign/aggregate")
  end

  def sha(s)
    ::Digest::SHA256.hexdigest(s)
  end

  # Drives a swap of the recorded quote, disclosing a transfer of +token+, against the given
  # catalog and pins. Returns [error or nil, sign calls, server].
  def swap_disclosing(token, catalog_body: nil, pins: nil)
    routes = swap_routes(consistent_begin(token: token), response_of("sign_aggregate"))
    routes = routes.merge("GET /vault/v1/assets" => [200, catalog_body]) if catalog_body
    server = FakeServer.new(routes)
    w = Paymos::Wallet.new(Paymos::VaultSecret.pack("vk_live_test", 7, full_share),
                           base_url: "https://example.test", transport: server,
                           pinned_fingerprints: pins)
    with_native_stubbed do |calls|
      err = begin
        w.swap(send: "USDC@base", receive: "USDT@base", amount: "5")
        nil
      rescue Paymos::PaymosError => e
        e
      end
      [err, calls[:sign], server]
    end
  end

  # One label, two contracts: /assets lists USDC@base twice with different fingerprints. A token
  # matching either one is that coin and signs; a token matching neither is refused.
  def test_a_label_listed_twice_accepts_either_fingerprint
    _, assets = response_of("assets")
    second = assets[0].merge("fingerprint" => sha("usdc-base-v2"))
    twice = [assets[0], second, assets[1]]
    %w[usdc-base usdc-base-v2].each do |token|
      err, signs, server = swap_disclosing(token, catalog_body: twice)
      assert_nil err, "#{token}: #{err&.message}"
      assert_equal 1, signs, token
      assert_equal 1, server.sent("POST", "/vault/v1/movements/mv_3/sign/aggregate").length, token
    end
    err, signs, = swap_disclosing("usdt-base", catalog_body: twice)
    assert_match(/transfers a token other than USDC@base/, err&.message.to_s)
    assert_equal 0, signs
  end

  # One label listed twice with DIFFERENT decimals: the debit is in the first entry's units, so the
  # second entry's token — whose raw units are worth 10^Δ more or less — is refused before any share.
  def test_a_label_listed_twice_with_other_decimals_refuses_the_second_token
    _, assets = response_of("assets")
    second = assets[0].merge("fingerprint" => sha("usdc-base-v2"), "decimals" => 18)
    twice = [assets[0], second, assets[1]]
    err, signs, server = swap_disclosing("usdc-base-v2", catalog_body: twice)
    assert_match(/co-sign refused: source 0 transfers a token other than USDC@base/, err&.message.to_s)
    assert_equal 0, signs
    assert_empty server.sent("POST", "/vault/v1/movements/mv_3/sign/aggregate")

    # The first entry's token still signs.
    err, signs, = swap_disclosing("usdc-base", catalog_body: twice)
    assert_nil err, err&.message
    assert_equal 1, signs
  end

  # A pinned label is checked against the pin alone, whatever /assets says (compared lowercase).
  def test_a_pinned_fingerprint_matching_the_token_signs
    err, signs, = swap_disclosing("usdc-base-pinned", pins: { "USDC@base" => sha("usdc-base-pinned").upcase })
    assert_nil err, err&.message
    assert_equal 1, signs

    err, signs, = swap_disclosing("usdc-base", pins: { "USDC@base" => ["0" * 64, sha("usdc-base")] })
    assert_nil err, err&.message
    assert_equal 1, signs
  end

  # The server publishes one fingerprint, the caller pinned another: the pin wins and the
  # server-published token is refused.
  def test_a_published_fingerprint_that_differs_from_the_pin_is_refused
    err, signs, server = swap_disclosing("usdc-base", pins: { "USDC@base" => sha("usdc-base-pinned") })
    assert_match(/co-sign refused: source 0 transfers a token other than USDC@base/, err&.message.to_s)
    assert_equal 0, signs
    assert_empty server.sent("POST", "/vault/v1/movements/mv_3/sign/aggregate")
  end

  # One label listed twice with different decimals: the server scales by the FIRST entry, and so
  # must the SDK — local validation and the echo check both.
  def test_a_label_listed_twice_uses_the_first_entrys_decimals
    _, assets = response_of("assets")
    twice = [assets[0], assets[0].merge("decimals" => 18), assets[1]]

    w, = wallet({ "GET /vault/v1/assets" => [200, twice] }.merge(route_of("quote_withdraw_dry")))
    assert_raises(Paymos::PaymosError) do
      w.quote_withdraw(asset: "USDC@base", amount: "10.1234567", to: "0xabc0000000000000000000000000000000000000")
    end

    routes = { "GET /vault/v1/assets" => [200, twice] }.merge(route_of("quote_withdraw")).merge(begin_refused("mv_1"))
    w, server = wallet(routes, share: full_share)
    with_native_stubbed do
      err = assert_raises(Paymos::PaymosError) do
        w.withdraw(asset: "USDC@base", amount: "10", to: "0xabc0000000000000000000000000000000000000")
      end
      # Past the echo (10 at 6 decimals = the quote's 10000000), stopped at round one.
      assert_equal "commitments are required", err.message
    end
    assert_equal 1, server.sent("POST", "/vault/v1/movements/mv_1/sign/begin").length
  end

  def test_malformed_pins_are_rejected_up_front
    [{ "USDC@base" => 5 }, { "USDC@base" => [] }, "USDC@base"].each do |pins|
      assert_raises(Paymos::PaymosError, pins.inspect) do
        Paymos::Wallet.new(Paymos::VaultSecret.pack("vk_live_test", 7, nil), pinned_fingerprints: pins)
      end
    end
  end

  # An older server publishes no fingerprint: reads keep working, a co-sign refuses — the check is
  # never skipped.
  def test_a_missing_fingerprint_refuses_the_cosign_but_not_the_reads
    status, assets = response_of("assets")
    bare = assets.map { |a| a.reject { |k, _| k == "fingerprint" } }
    routes = swap_routes(consistent_begin, response_of("sign_aggregate"))
             .merge("GET /vault/v1/assets" => [status, bare])
    w, server = wallet(routes, share: full_share)
    assert_nil w.assets[0].fingerprint
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
      assert_match(/did not publish an asset fingerprint.*update the server/, err.message)
      assert_equal 0, calls[:sign]
    end
    assert_empty server.sent("POST", "/vault/v1/movements/mv_3/sign/aggregate")
  end

  # A key package without its verifying key leaves no signer to compare against: refuse, never skip.
  def test_a_key_package_without_verifying_key_refuses_the_cosign
    w, server = wallet(swap_routes(consistent_begin, response_of("sign_aggregate")),
                       share: JSON.generate({ "identifier" => "01" }))
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
      assert_match(/co-sign refused: the key package carries no verifying_key/, err.message)
      assert_equal 0, calls[:sign]
    end
    assert_empty server.sent("POST", "/vault/v1/movements/mv_3/sign/aggregate")
  end

  # A per-source amount that is not a positive run of ASCII digits is refused before any share:
  # Integer() would accept a sign, and a negative source can offset an inflated one.
  def test_the_guard_refuses_a_non_positive_or_signed_amount
    ["-900", "-1", "+5", "", "0", "00", "1_000", " 5", "5.0", 5].each do |bad|
      w, server = wallet(swap_routes(consistent_begin(amount: bad), response_of("sign_aggregate")),
                         share: full_share)
      with_native_stubbed do |calls|
        err = assert_raises(Paymos::PaymosError, bad.inspect) do
          w.swap(send: "USDC@base", receive: "USDT@base", amount: "5")
        end
        assert_match(/co-sign refused: bad transfer amount/, err.message, bad.inspect)
        assert_equal 0, calls[:sign], bad.inspect
      end
      assert_empty server.sent("POST", "/vault/v1/movements/mv_3/sign/aggregate"), bad.inspect
    end
  end

  # Two sources, the approved debit D = 5000000: A = 2D and B = -D total D, which the debit
  # check alone would pass while A by itself moves 2D.
  def test_the_guard_refuses_a_negative_source_offsetting_an_inflated_one
    status, quote = response_of("quote_swap")
    routes = swap_routes(consistent_begin(amounts: %w[10000000 -5000000]), response_of("sign_aggregate"))
             .merge("POST /vault/v1/quote/swap" => [status, quote.merge("sources" => 2)])
    w, server = wallet(routes, share: full_share)
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
      assert_match(/co-sign refused: bad transfer amount for source 1/, err.message)
      assert_equal 2, calls[:commit]
      assert_equal 0, calls[:sign]
    end
    assert_empty server.sent("POST", "/vault/v1/movements/mv_3/sign/aggregate")
  end

  def test_sign_aggregate_ok_completes_the_swap
    w, server = wallet(swap_routes(consistent_begin, response_of("sign_aggregate")), share: full_share)
    mv = with_native_stubbed do |calls|
      m = w.swap(send: "USDC@base", receive: "USDT@base", amount: "5")
      assert_equal 1, calls[:sign]
      m
    end
    assert_equal "mv_3", mv.id
    assert_sent_matches(server, "sign_aggregate")
  end

  def test_sign_aggregate_error_is_typed
    w, = wallet(swap_routes(consistent_begin, response_of("sign_aggregate_error")), share: full_share)
    err = with_native_stubbed do
      assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
    end
    assert_instance_of Paymos::PaymosError, err
    assert_equal 400, err.status
    assert_equal "token and shares are required", err.message
  end

  def test_sign_aggregate_ok_false_on_a_2xx_is_still_a_failure
    agg = [200, { "ok" => false, "status" => "failed", "error" => "relay rejected" }]
    w, = wallet(swap_routes(consistent_begin, agg), share: full_share)
    err = with_native_stubbed do
      assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
    end
    assert_equal "relay rejected", err.message
  end

  def test_the_guard_refuses_another_vaults_transfer
    w, = wallet(swap_routes(consistent_begin(signer: "someone.else"), response_of("sign_aggregate")),
                share: full_share)
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
      assert_match(/different vault/, err.message)
      assert_equal 0, calls[:sign]
    end
  end

  # The recorded sign/begin shape, disclosing +message+ verbatim and binding its package to it —
  # for bytes JSON.generate would never write.
  def raw_begin(message)
    body = response_of("sign_begin")[1]
    disc = body["messages"][0]
    nonce = "00" * 32
    body.merge("messages" => [disc.merge("message" => message, "nonce" => nonce)],
               "signing_packages" => [body["signing_packages"][0].merge(
                 "message" => Paymos::Digest.payload_digest_hex(message, [nonce].pack("H*"), disc["recipient"])
               )])
  end

  def refused_with(message, pattern)
    w, server = wallet(swap_routes(raw_begin(message), response_of("sign_aggregate")), share: full_share)
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
      assert_match(pattern, err.message)
      assert_equal 0, calls[:sign]
    end
    assert_empty server.sent("POST", "/vault/v1/movements/mv_3/sign/aggregate")
  end

  # The verifier on chain re-parses the signed bytes and rejects a repeated key; JSON.parse keeps
  # the last. Read last-wins, each of these is one transfer inside the debit — it is refused.
  def test_the_guard_refuses_a_message_that_repeats_a_key
    real = '{"intent":"transfer","tokens":{"usdc-base":"5000000000"}}'
    decoy = '{"intent":"transfer","tokens":{"usdc-base":"5000000"}}'
    [
      %({"signer_id":"#{SIGNER}","intents":[#{real}],"intents":[#{decoy}]}),
      %({"signer_id":"#{SIGNER}","intents":[#{real}],"\\u0069ntents":[#{decoy}]}),
      %({"signer_id":"someone.else","intents":[#{decoy}],"signer_id":"#{SIGNER}"}),
      %({"signer_id":"#{SIGNER}","intents":[{"intent":"transfer","tokens":{"usdc-base":"5000000000","usdc-base":"5000000"}}]})
    ].each do |message|
      # Read last-wins: what json < 3 does by default (json 3 refuses a repeat unless allowed).
      assert_equal 1, JSON.parse(message, allow_duplicate_key: true)["intents"].length
      refused_with(message, /co-sign refused: unreadable message for source 0: duplicate key/)
    end
    # "Intents" is another key to JSON.parse and to the verifier alike: the guard reads "intents".
    refused_with(%({"signer_id":"#{SIGNER}","intents":[#{real}],"Intents":[#{decoy}]}), /above the approved debit/)
  end

  # JSON.parse stops at max_nesting (100): a deep message is the guard's refusal, typed.
  def test_the_guard_refuses_a_message_nested_too_deep
    intents = '"intents":[{"intent":"transfer","tokens":{"usdc-base":"5000000"}}]'
    refused_with(%({"signer_id":"#{SIGNER}",#{intents},"memo":#{'[' * 100_000}#{']' * 100_000}}),
                 /co-sign refused: unreadable message for source 0: nesting of \d+ is too deep/)
  end

  def test_the_guard_refuses_an_inflated_transfer
    w, = wallet(swap_routes(consistent_begin(amount: "5000001"), response_of("sign_aggregate")),
                share: full_share)
    with_native_stubbed do |calls|
      err = assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
      assert_match(/above the approved debit/, err.message)
      assert_equal 0, calls[:sign]
    end
  end

  # A retry under the same key that finds round one refused converges only when the movement
  # already progressed; a pending one re-raises (begin_refused serves a pending movement).
  def test_a_refused_round_one_converges_only_on_a_progressed_movement
    fx_mv = response_of("movement")[1]
    PY_PROGRESSED.each do |status|
      routes = catalog.merge(route_of("quote_swap"))
                      .merge("POST /vault/v1/movements/mv_3/sign/begin" => response_of("sign_begin_error"),
                             "GET /vault/v1/movements/mv_3" => [200, fx_mv.merge("status" => status)])
      w, = wallet(routes, share: full_share)
      mv = with_native_stubbed { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
      assert_equal status, mv.status
    end
    (fx("vocabulary")["movement_statuses"] - PY_PROGRESSED).each do |status|
      routes = catalog.merge(route_of("quote_swap"))
                      .merge("POST /vault/v1/movements/mv_3/sign/begin" => response_of("sign_begin_error"),
                             "GET /vault/v1/movements/mv_3" => [200, fx_mv.merge("status" => status)])
      w, = wallet(routes, share: full_share)
      err = with_native_stubbed do
        assert_raises(Paymos::PaymosError) { w.swap(send: "USDC@base", receive: "USDT@base", amount: "5") }
      end
      assert_equal "commitments are required", err.message, status
    end
  end

  # ── status vocabulary ─────────────────────────────────────────────────────

  def test_every_status_is_classified_like_python
    vocab = fx("vocabulary")
    all = (vocab["movement_statuses"] + vocab["sign_statuses"]).uniq
    all.each do |s|
      assert_equal PY_TERMINAL.include?(s), Paymos::Wallet::TERMINAL.include?(s), "terminal? #{s}"
      assert_equal PY_PROGRESSED.include?(s), Paymos::Wallet::PROGRESSED.include?(s), "progressed? #{s}"
    end
    # No internal word the server never sends.
    assert_empty Paymos::Wallet::TERMINAL - vocab["movement_statuses"]
    assert_empty Paymos::Wallet::PROGRESSED - vocab["movement_statuses"]
  end

  # ── errors ────────────────────────────────────────────────────────────────

  ERROR_TYPES = {
    "error_400" => Paymos::PaymosError,
    "error_400_body" => Paymos::PaymosError,
    "error_401" => Paymos::AuthError,
    "error_403" => Paymos::Forbidden,
    "error_404_movement" => Paymos::PaymosError,
    "error_404_path" => Paymos::PaymosError,
    "error_409_idempotency" => Paymos::Conflict
  }.freeze

  def test_every_error_fixture_is_covered
    names = Dir[File.join(ContractFixtures.dir, "error_*.json")].map { |f| File.basename(f, ".json") }
    assert_equal ERROR_TYPES.keys.sort, names.sort
  end

  # Drive the SDK call each fixture was recorded from, where the SDK can make it.
  def drive(w, req)
    path = req["path"]
    body = req["body"].is_a?(Hash) ? req["body"] : {}
    case path
    when "/vault/v1/balances" then w.balances
    when %r{\A/vault/v1/movements/([^/]+)\z} then w.movement(Regexp.last_match(1))
    when "/vault/v1/quote/withdraw"
      w.quote_withdraw(asset: body["asset"] || "USDC@base", amount: body["amount"] || "10",
                       to: body["to"] || "0xabc", mode: body["mode"] || "exact_out")
    else w.instance_variable_get(:@http).get(path)
    end
  end

  def test_every_error_fixture_maps_to_its_type_and_message
    ERROR_TYPES.each do |name, klass|
      f = fx(name)
      w, = wallet(catalog.merge("#{f['request']['method']} #{f['request']['path']}" => response_of(name)))
      err = assert_raises(Paymos::PaymosError, name) { drive(w, f["request"]) }
      assert_instance_of klass, err, name
      assert_equal f["response"]["status"], err.status, name
      assert_equal f["response"]["body"]["error"], err.message, name
    end
  end

  def test_an_html_404_from_a_proxy_is_a_typed_error
    html = "<!DOCTYPE html>\n<html><head><title>404</title></head><body>Not Found</body></html>"
    w, = wallet({ "GET /vault/v1/assets" => [404, html] })
    err = assert_raises(Paymos::PaymosError) { w.assets }
    assert_instance_of Paymos::PaymosError, err
    assert_equal 404, err.status
    assert_match(/status 404/, err.message)
    assert_match(/HTML/, err.message)
  end

  def test_an_html_200_where_json_belongs_is_a_typed_error
    w, = wallet({ "GET /vault/v1/balances" => [200, "<html><body>the public site</body></html>"] })
    err = assert_raises(Paymos::PaymosError) { w.balances }
    assert_equal 200, err.status
    assert_match(/expected JSON/, err.message)
  end
end
