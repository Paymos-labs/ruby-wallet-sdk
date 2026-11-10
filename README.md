# paymos-wallet — Ruby SDK

Send, swap and bridge **USDT, USDC, BTC, ETH** and the rest of the wallet's catalogue from
Ruby — no browser, no wallet extension, and no seed phrase anywhere in your environment. It is
built for the services that pay people out: marketplaces, exchanges, payroll and treasury jobs.

Your process holds **one half** of the signing key; the Paymos server holds the other.
**Neither side alone can move funds** — every swap and withdrawal is co-signed, and your half
never reaches the server.

- **Non-custodial** — a leaked API key can't sign; your co-signing share stays in your process.
- **Fee-transparent** — every quote is a dry preview with a full `platform / network / route`
  fee breakdown you see *before* signing anything.
- **Human amounts, no floats** — you pass decimal strings like `"100"` / `"0.5"`; responses come
  back as raw integer strings.
- **Zero dependencies** — fiddle, net/http, json and digest are all stdlib. The native co-signing
  core is loaded at runtime.

The SDK talks in plain asset terms (`USDC@base`, `ETH@arb`) and hides the routing and the
2-of-2 signing behind a small, safe surface.

## Install

```bash
gem install paymos-wallet
```

Requires **Ruby ≥ 3.0**.

The native co-signing core is **not** inside the gem. On first use the SDK downloads the
platform-matching build of the core version it is pinned to from the `paymos-wallet-core` releases,
verifies it, and caches it per user. When this SDK build carries a compiled-in SHA-256 for your
platform, that hash is the only one accepted — for the download and, re-checked on every load, for
the cached file. When it carries none, the download is checked against the `.sha256` published in
the same release, which catches a corrupted download but not a replaced release.

A prebuilt core exists for **Linux x86-64**, **Linux arm64** and **Windows x64**. The SDK also
recognises macOS on both architectures, but no macOS build is published yet — there is no Mac to
produce one on, and cross-compiling an Apple dylib elsewhere is not the same thing. On any platform
without a prebuilt core, build the crate yourself and set `PAYMOS_NATIVE_LIB` to the resulting
`libwallet_mpc.so` / `.dylib` / `wallet_mpc.dll`. The same variable skips the download when you want
it skipped: an offline host, or a corporate proxy that will not reach GitHub.

## Get access & your API key

The SDK controls a **Paymos vault**, which you own from the **Paymos wallet** — a Telegram-only
Mini App. Open **@Ox0000000000000000000Bot**, tap **Open Wallet**, then **Settings → Vault API**
and mint a key:

| Key | Can do | Carries |
|---|---|---|
| **read** | `assets`, `balances`, `quote_swap`, `quote_withdraw`, `movement`, `movements` | API key only |
| **full** | everything a read key does, **plus** `swap` and `withdraw` | API key **+** your co-signing share |

The key is a `vs_live_…` string. A full key's co-signing share is decrypted on your device and
**never leaves your process**. Treat a full secret like a private key.

```bash
export PAYMOS_VAULT_SECRET="vs_live_…"
# optional — defaults to https://wallet.paymos.io
# export PAYMOS_BASE_URL="https://wallet.paymos.io"
```

## Quickstart

```ruby
require "paymos"

w = Paymos::Wallet.from_env               # reads PAYMOS_VAULT_SECRET

# Balances: per-asset, raw amount strings + a nullable USD value.
w.balances.each { |b| puts "#{b.asset} #{b.amount_raw} #{b.usd}" }

# Preview a withdraw — a dry, money-safe quote. Headline is the fee breakdown.
q = w.quote_withdraw(asset: "USDC@base", amount: "25", to: "0xRecipient…")
puts "#{q.fees.platform} #{q.fees.network} #{q.fees.total}"

# Move money (full key only). Amounts are human decimal strings.
mv = w.swap(send: "USDC@base", receive: "ETH@arb", amount: "100")
settled = w.wait(mv.id)                   # poll to a terminal status
puts settled.status
```

## Core concepts

**Amounts: human in, raw out.** Every amount you pass — the `amount:` of `quote_swap`,
`quote_withdraw`, `swap` and `withdraw`, and `min_receive:` / `max_debit:` — is a human decimal
string (`"100"`, `"0.5"`); the server owns each asset's decimals and scales it to raw. Every amount
in a response is a raw integer string (`"10000"` is 0.01 of a 6-decimal USDC). Never a float, in
either direction. `Paymos::Amounts.format_units` turns a raw response amount into a human one for
display; `Paymos::Amounts.parse_units` turns a human figure into raw units to **compare** with a
response amount. It is never for building an argument:
`wallet.withdraw(asset: "USDC@base", amount: Paymos::Amounts.parse_units("0.01", 6), to: …)` sends
`"10000"` and pays out **10 000 USDC** — and since the SDK and the server agree on that number, no
check anywhere can tell it from an intended one.

**Moving money.** `swap` and `withdraw` (full key only) create a real movement and drive the
2-of-2 co-sign. Before any signature the SDK re-checks that the server's quote echoes exactly
the assets and amount you approved — a decimals bug, contract drift, or a server that changes those
numbers raises and **signs nothing**. The echo covers assets and amounts, not where the route sends
the funds (see [Security](#security)).

```ruby
mv = w.swap(send: "USDC@base", receive: "ETH@arb", amount: "100", min_receive: "0.03")
wd = w.withdraw(asset: "USDC@base", amount: "25", to: "0xRecipient…", max_debit: "26")
```

**Safety caps.** `min_receive` floors the guaranteed receive (`SlippageExceeded` below it,
nothing signed); `max_debit` ceilings the total vault debit — strongly recommended for
unattended `exact_out` payouts; `idempotency_key` makes a retry after an ambiguous failure
replay the same movement instead of paying twice.

**Withdraw modes.** `"exact_out"` (default) — the recipient gets exactly `amount`, the debit is
server-computed. `"total_in"` — `amount` is the total debited; the recipient gets it minus fees.

**Waiting.** `wait(id)` polls to a terminal status — `completed | failed | refunded | expired |
cancelled` — and raises on timeout.

## Errors

Every call raises a subclass of `Paymos::PaymosError`, which carries `message` and `status` (the
HTTP status, or nil for a transport-level failure). Branch on the class instead of
string-matching a message.

| Exception | When |
|---|---|
| `Paymos::AuthError` | `401` — API key missing, malformed, or unrecognized |
| `Paymos::Forbidden` | `403` — the key is valid but lacks the scope this call needs |
| `Paymos::InsufficientFunds` | `400` — the vault balance can't cover the amount (plus fees) |
| `Paymos::QuoteExpired` | `400` — the referenced quote expired; fetch a fresh one |
| `Paymos::SlippageExceeded` | `400` or local — delivered / guaranteed amount fell below your floor |
| `Paymos::CrossAssetWithdrawNotAllowed` | `400` — a withdraw changed the asset (that's a swap) |
| `Paymos::RouteUnavailable` | `400` — no route could be quoted right now; retry shortly |
| `Paymos::RateLimited` | `429` — carries `retry_after` (seconds, or nil) |
| `Paymos::Conflict` | `409` — idempotency key reused with a different request |
| `Paymos::PaymosError` | base — `404`, any other 4xx/5xx, local refusals, transport errors |

```ruby
begin
  mv = w.swap(send: "USDC@base", receive: "ETH@arb", amount: "100", min_receive: "0.03")
rescue Paymos::SlippageExceeded
  # guaranteed receive below your floor — nothing signed
rescue Paymos::InsufficientFunds
  # not enough balance for amount + fees
rescue Paymos::RateLimited => e
  sleep(e.retry_after || 1)
rescue Paymos::PaymosError => e
  warn "#{e.status} #{e.message}"
end
```

Calling `swap` / `withdraw` with a **read-only** key raises *before* any movement is created — a
read key can never sign.

## Security

- A leaked **API key alone cannot move funds** — no share, no signature (and the key can be
  revoked).
- A leaked **share alone cannot move funds** — no server co-sign.
- Both are required, on purpose. Before co-signing, the SDK checks that the quote echoes the
  assets and amount you approved, and that every message it signs is a single transfer from your
  vault, of the send asset, moving in total no more than the approved debit.
- What it does **not** check: the recipient. The route's deposit address is chosen by the server
  and is not verified by the SDK. And for `exact_out` the approved debit is itself computed by the
  server — pass `max_debit` to put your own ceiling on it; for unattended payouts, always do.
- The token check binds to the fingerprint the server publishes in `/assets`, unless you pin it
  (`pinned_fingerprints`, below).

Treat a full `vs_live_…` secret like a private key, and back up the share — losing it means
losing your ability to co-sign.

## License

MIT for this wrapper — see `LICENSE`. The co-signing core it downloads is proprietary; its
binary distribution grants no rights to its source.

---

## FAQ

### How do I send USDT (TRC20) from code?

Install the SDK, point it at your vault, and ask for a withdrawal with the asset written the way the
wallet writes it — `USDT@tron`. The same call sends USDT on BNB Chain (`USDT@bsc`), Ethereum
(`USDT@eth`), Polygon, Solana, Arbitrum, Avalanche or TON: the asset string is the only difference.

```
gem install paymos-wallet
```

### Is this custodial? Who can move the money?

Nobody alone. The vault is **2-of-2**: your process holds one signing share, the server holds the
other, and a transfer needs both. A stolen API key cannot sign, and the server cannot sign without
you. Your share never leaves your process.

### What is the difference between a quote and a transfer?

A quote is a dry run. It prices the route, separates platform, network and route fees, and reserves
nothing — ask for as many as you like. A transfer is the same numbers, signed. Nothing moves until
your half of the signature exists.

### Does it blind-sign whatever the server asks for?

No, and this is the part worth reading twice. The server discloses the exact message it wants
signed; the SDK recomputes the digest itself and refuses unless the package binds to that message,
the message is a single transfer from your vault, and the transfers together move no more than the
approved debit. Two limits: the recipient is chosen by the server and is not checked, and for
`exact_out` the approved debit is server-computed unless you cap it with `max_debit` — which you
should for unattended payouts.

Each transfer is also bound to its token: the token id must hash to the fingerprint `/assets`
publishes for the send asset. That fingerprint comes from the same server, so the check catches a
server bug or a compromised signing path, not a server compromised end to end. For a trust anchor
that does not depend on the server, pin the fingerprints yourself:
`Paymos::Wallet.new(secret, pinned_fingerprints: { "USDC@base" => "<sha256 hex>" })` (a list is
accepted too). A pinned asset is checked against your values only.

### Which networks and assets are supported?

USDT moves on nine chains — Tron, Ethereum, BNB Chain, Polygon, Solana, Arbitrum, Optimism,
Avalanche and TON — and USDC on eight: that same list without Tron and TON, with Base instead. Add
the native coin of each of those chains, and BTC, LTC, DOGE, XRP, BCH, DASH, ZEC and ADA, and the
catalogue is 21 assets across 18 chains. It is also the authority: an asset it does not list cannot
be quoted or sent, in any SDK.

### How are fees reported?

Every quote breaks the cost into platform, network and route, and amounts come back as raw integer
strings rather than floats: money that has been through a float is money with a rounding error in
it. You pass human amounts in (`"100"`, `"0.5"`) and read exact integers back.

### Can I use it for automated payouts?

That is what it is for: headless, no browser, no wallet extension, no seed phrase in the environment.
A worker holding one share can pay out continuously, and losing that machine costs the ability to
sign — not the funds.

### What happens if a transfer is interrupted?

Every money-moving call is sent under an idempotency key, and repeating a call with the **same** key
returns the original operation instead of starting a second one. That holds only if your retry
carries the same key: pass your own durable one (`idempotency_key:`, e.g. your payout id) and retry
with it, and a retry after a timeout cannot pay twice. Leave it out and the SDK generates a fresh key
per call — a retry is then a second payment. An empty key is refused rather than sent.

## The same wallet, in eight languages

Every SDK here speaks to the same vault API and enforces the same rules; pick the one your service is
written in. The signing core is shared, so a fix there reaches all of them.

| Language | Package | Repository |
|---|---|---|
| Python | `pip install paymos-wallet` | [python-wallet-sdk](https://github.com/paymos-labs/python-wallet-sdk) |
| TypeScript / Node.js | `npm install @paymos/wallet` | [typescript-wallet-sdk](https://github.com/paymos-labs/typescript-wallet-sdk) |
| Go | `go get github.com/paymos-labs/go-wallet-sdk` | [go-wallet-sdk](https://github.com/paymos-labs/go-wallet-sdk) |
| Rust | `cargo add paymos-wallet` | [rust-wallet-sdk](https://github.com/paymos-labs/rust-wallet-sdk) |
| C# / .NET | `dotnet add package Paymos.Wallet` | [csharp-wallet-sdk](https://github.com/paymos-labs/csharp-wallet-sdk) |
| Java | `io.paymos:wallet` | [java-wallet-sdk](https://github.com/paymos-labs/java-wallet-sdk) |
| Ruby *(this one)* | `gem install paymos-wallet` | [ruby-wallet-sdk](https://github.com/paymos-labs/ruby-wallet-sdk) |
| PHP | `composer require paymos/wallet` | [php-wallet-sdk](https://github.com/paymos-labs/php-wallet-sdk) |
| Signing core | `paymos-wallet-core` | [paymos-wallet-core](https://github.com/paymos-labs/paymos-wallet-core) |

## Documentation

- [wallet.paymos.io](https://wallet.paymos.io) — the product, the supported networks, and guides for
  the routes people ask about most: USDT BEP20 to TRC20, USDC between chains, and the rest.
- [Networks and assets](https://wallet.paymos.io/networks) — every chain and token the wallet
  carries, with the standard each one is named by.
- [USDT BEP20 → TRC20](https://wallet.paymos.io/guides/usdt-bep20-to-trc20) — a worked route, priced
  live; the other pairs are linked from it.
