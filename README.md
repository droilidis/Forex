# Forex

A small Swift package for currency conversion, backed by the free exchange-rate API
at https://github.com/fawazahmed0/exchange-api (served via the jsDelivr CDN).

## Usage

Forex has three layers, each usable on its own: a client that fetches, a conversion on a
rate table, and a cache that keeps tables by the caller's policy.

### Cache

`Forex` is an `actor` that fetches tables, keeps them and converts with them. There is no
shared instance: each caller creates its own.

```swift
import Forex

let forex = Forex()

// Convert between currencies. Rates are fetched once per destination currency and
// kept; concurrent conversions to the same destination share a single request.
let amount = try await forex.convert(value: 100, from: "EUR", to: "USD")

// Ready the table ahead of time (best-effort), e.g. for the user's preferred currency.
await forex.prefetchRates(for: "USD")
```

`convert` throws `ForexError` when no rate is available, so callers can distinguish a
genuine value from a failed conversion.

A bare `Forex()` keeps tables in memory, treats them as fresh for 24 hours (the upstream API
updates roughly daily), falls back to the last table when a refresh fails, and never waits
for a connection. The caller can choose otherwise:

```swift
let forex = Forex(
    client: ForexClient(session: session),
    store: FileRatesStore(directory: folder),
    freshness: 12 * 60 * 60,
    stalePolicy: .refreshInBackground(maximumAge: 30 * 24 * 60 * 60),
    failureWindow: .seconds(60)
)

for await code in await forex.updates() {
    // A new table for `code` is stored: convert again.
}
```

- `store`: where tables are kept, as a `RatesStore`, which loads and saves a table with its
  fetch date. `InMemoryRatesStore` is the default. `FileRatesStore` writes to a folder the
  caller picks, so tables outlive the process. A failed load counts as an empty store for that
  call, and the next call reads again. A failed save leaves the table in memory only. `load` and
  `save` must finish in bounded time, as the calls for a currency wait for them.
- `freshness`: how long a table stays fresh. A fresh table is used without a request.
- `stalePolicy`: what to do with an older table. `.fetchFirst`, the default, fetches first and
  falls back to the table when the fetch fails. `.refreshInBackground()` returns the table at
  once and refreshes it in the background, at any age; with a `maximumAge`, a table older than
  that is handled as in `.fetchFirst`.
- `failureWindow`: how long a failed fetch makes further calls for that currency fail at once
  without a request (default 10 seconds), so converting many prices one by one makes one
  request. A call in the window uses the last table if there is one, and otherwise throws the
  fetch's error.

`updates()` returns an `AsyncStream` of the uppercased codes of the tables stored from then on,
one element for each table fetched. Each call returns a stream of its own.

### Conversion

A function on `Rates` converts a value from a currency to the table's currency, for a caller
that holds a table. It throws `ForexError.rateUnavailable` when the table has no usable rate.

```swift
let rates: Rates = …  // the table for USD
let amount = try rates.convert(value: 100, from: "EUR")
```

### Client

`ForexClient` fetches a table, or the list of currencies, and keeps nothing.

```swift
let client = ForexClient()
let currencies = try await client.fetchCurrencies()
let rates = try await client.fetchRates(for: "usd")
```

It takes any `URLSession`. Its default, `ForexClient.defaultSession`, doesn't wait for
connectivity, has no URL cache, and gives up after 30 seconds.

## Testing

```
swift test                     # no network: the two live API tests are skipped
FOREX_LIVE_TESTS=1 swift test  # also runs the live API tests against the CDN
```
