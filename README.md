# Forex

A small Swift package for currency conversion, backed by the free exchange-rate API
at https://github.com/fawazahmed0/exchange-api (served via the jsDelivr CDN).

## Usage

```swift
import Forex

// Convert between currencies. Rates are fetched once per destination currency and
// cached; concurrent conversions to the same destination share a single request.
let amount = try await Forex.shared.convert(value: 100, from: "EUR", to: "USD")

// Warm the cache ahead of time (best-effort), e.g. for the user's preferred currency.
await Forex.shared.prefetchRates(for: "USD")

// Lower-level API.
let currencies = try await Forex.fetchCurrencies()
let rates = try await Forex.fetchRates(for: "usd")
```

`Forex` is an `actor`: the rate cache is isolated (data-race free) and concurrent
requests for the same currency are de-duplicated. Cached rates are considered fresh
for 24 hours (the upstream API updates roughly daily); if a refresh fails, the last
known rates are used until one succeeds.

`convert` throws `ForexError` when no rate is available, so callers can distinguish a
genuine value from a failed conversion.
