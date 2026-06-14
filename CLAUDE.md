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
- Tests are XCTest. Most are **hermetic** (no network) via the `#if DEBUG` `preload(_:)` seam.
  Two `*_live` integration tests hit the real CDN and **auto-skip when offline**
  (`XCTSkipIf(isOffline)`), so `swift test` stays green without a connection.

## Public API (`Sources/Forex/`)

- `Forex` — an **actor** (`Forex.shared`). Isolated rate cache, **24 h TTL**, **single-flight**
  dedup (concurrent fetches for one currency share a single request), and **stale-fallback**
  (a failed refresh reuses the last known rates).
  - `convert(value:from:to:) async throws -> Double`
  - `prefetchRates(for:) async` — best-effort cache warm.
  - static `fetchCurrencies(for:)`, `fetchRates(for:date:)` — lower-level fetches.
- `Responses/Currency.swift`, `Responses/Rates.swift` (with `Rates.Pair`) — decoded models.
- `ForexError` — typed, conforms to `LocalizedError`.

## Conversion correctness (don't break these — all regression-tested)

- Rates are fetched for the **destination** currency; `pair.rate` is *source per 1
  destination*, so `result = value / pair.rate`.
- Identical source/destination returns the value unchanged. Codes are case-insensitive
  (uppercased internally).
- Zero, negative, and non-finite rates are **rejected** (`rateUnavailable`) — a degraded
  payload must throw, never produce garbage (e.g. `value / .infinity == 0`).
- Decoding also rejects degraded payloads: a missing base object, an empty table, or multiple
  base currencies each throw `dataParsingError`.
- Dates use `yyyy-MM-dd` (calendar year — **not** `YYYY` week-year, a new-year off-by-one),
  with a POSIX locale and UTC zone.
