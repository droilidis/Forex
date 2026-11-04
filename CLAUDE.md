# Forex

A small, standalone, dependency-free Swift package for currency conversion, backed by the
free exchange-rate API at github.com/fawazahmed0/exchange-api (served via the jsDelivr CDN).
Consumed by the Wishes app via a remote SwiftPM reference pinned to `main` — push changes
before the app can pick them up.

## Build & test

```
swift build
swift test
```

- `swift-tools-version: 6.0`; platforms iOS 16 / macOS 13.
- **Swift 6 strict concurrency is in force.** Treat data-race / `Sendable` / actor-isolation
  diagnostics as hard errors. After non-trivial changes, run an independent review focused on
  concurrency and conversion correctness.
- Tests are XCTest. Most are **hermetic** (no network): `StubServer` answers a session's
  requests through a `URLProtocol`, and a store passed to `Forex` holds a table of any age.
  Two `*_live` integration tests hit the real CDN and run **only when asked**: `swift test`
  skips them and makes no network request, and `FOREX_LIVE_TESTS=1 swift test` runs them. With
  the variable set and no network they fail, as the run asked for them.

## Public API (`Sources/Forex/`)

Three layers, each usable on its own. Forex is public: the library provides the mechanism, and
the caller chooses the policy (storage, staleness). There is no shared instance.

- **Client:** `ForexClient`, a `Sendable` struct over a `URLSession` the caller may pass; it
  keeps nothing.
  - `fetchCurrencies(for:)`, `fetchRates(for:date:)`.
  - `defaultSession` doesn't wait for connectivity, has no URL cache and gives up after 30 s.
    Don't set `waitsForConnectivity`: a request would wait through a refused connection, past
    the request timeout, and every caller with it. Don't give it a URL cache: the CDN's
    `max-age` of a week would serve a stored response, whatever `freshness` says.
- **Conversion:** `Rates.convert(value:from:)` converts to the table's currency, with the
  checks below.
- **Cache:** `Forex`, an **actor** created by the caller with a client, a store, `freshness`
  (24 h), a `StalePolicy` (`.fetchFirst`, or `.refreshInBackground(maximumAge:)`) and a
  `failureWindow` (10 s, a `Duration` on `ContinuousClock`, so moving the wall clock back
  can't hold it open).
  - `convert(value:from:to:) async throws -> Double`
  - `prefetchRates(for:) async` — best-effort.
  - `updates() -> AsyncStream<String>` — the code of each table stored; a stream per call.
  - **Single-flight:** concurrent callers for one currency share a fetch, and one read of the
    store. The fetch's task stores its own result, as a background refresh has no caller.
  - **Stale-fallback:** a failed fetch keeps the last table and uses it. In the failure window
    no request is made: a call uses the last table, or throws the failed fetch's error.
- **Stores:** `RatesStore` loads and saves a `StoredRates` (a table with its fetch date).
  `InMemoryRatesStore` is the default, and `FileRatesStore` writes a JSON file per currency to
  a folder the caller picks. `Forex` reads a currency from the store until a read succeeds,
  and keeps the table in memory. `load` and `save` must finish in bounded time.
- `Responses/Currency.swift`, `Responses/Rates.swift` (with `Rates.Pair`) — decoded models.
  `Rates` encodes to the API's payload shape, the one it decodes.
- `ForexError` — typed, conforms to `LocalizedError`.

## Conversion correctness (don't break these — all regression-tested)

- Rates are fetched for the **destination** currency; `pair.rate` is *source per 1
  destination*, so `result = value / pair.rate`.
- Identical source/destination returns the value unchanged (in `Forex.convert`, without a
  fetch). Codes are case-insensitive (`Rates` and `Rates.Pair` hold them uppercased).
- Zero, negative, and non-finite rates are **rejected** (`rateUnavailable`) — a degraded
  payload must throw, never produce garbage (e.g. `value / .infinity == 0`).
- Decoding also rejects degraded payloads: a missing base object, an empty table, or multiple
  base currencies each throw `dataParsingError`, and so does a table for another base than the
  one `fetchRates` asked for.
- Dates use `yyyy-MM-dd` (calendar year — **not** `YYYY` week-year, a new-year off-by-one),
  with a POSIX locale and UTC zone.
