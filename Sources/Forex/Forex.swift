import Foundation

// MARK: - Errors

public enum ForexError: Error, Sendable {
    case invalidURL
    case networkError(String)
    case invalidResponse
    case dataParsingError(String)
    case rateUnavailable(source: String, destination: String)
}

extension ForexError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The exchange-rate request URL could not be constructed."
        case .networkError(let message):
            return "A network error occurred: \(message)"
        case .invalidResponse:
            return "The exchange-rate server returned an invalid response."
        case .dataParsingError(let message):
            return "The exchange-rate data could not be parsed: \(message)"
        case .rateUnavailable(let source, let destination):
            return "No exchange rate is available from \(source) to \(destination)."
        }
    }
}

// MARK: - Forex

/// Currency conversion backed by the free exchange-rate API at
/// https://github.com/fawazahmed0/exchange-api (served via the jsDelivr CDN).
///
/// `Forex` is an `actor`, so its rate cache is isolated and concurrent callers are
/// data-race free. Concurrent requests for the same currency are additionally
/// de-duplicated ("single-flight"): a burst of conversions triggers at most one
/// network request per currency, rather than one request per caller.
public actor Forex {
    public static let shared = Forex()

    private static let baseURLString = "https://cdn.jsdelivr.net/npm/@fawazahmed0/"

    /// How long fetched rates stay fresh before a re-fetch is attempted. The upstream
    /// API publishes new rates roughly once per day.
    private let cacheTTL: TimeInterval

    /// - Parameter cacheTTL: freshness window for cached rates (default 24 hours).
    public init(cacheTTL: TimeInterval = 24 * 60 * 60) {
        self.cacheTTL = cacheTTL
    }

    // MARK: Cache state (actor-isolated)

    private struct CacheEntry {
        let rates: Rates
        let fetchedAt: Date
    }

    /// Most recently fetched rates, keyed by uppercased base-currency code.
    private var cache: [String: CacheEntry] = [:]

    /// In-flight fetches, keyed by uppercased base-currency code, so concurrent
    /// callers for the same currency share a single network request.
    private var inFlight: [String: Task<Rates, Error>] = [:]

    // MARK: Public API

    /// Converts `value` from one ISO currency code to another.
    ///
    /// Rates are fetched for the *destination* currency and cached, so a list of
    /// conversions into the same destination (the common case — a single preferred
    /// currency) shares one network request and one cache entry.
    ///
    /// - Returns: `value` expressed in `destinationCurrencyCode`.
    /// - Throws: ``ForexError`` if rates cannot be fetched and none are cached, or
    ///   ``ForexError/rateUnavailable(source:destination:)`` if the source currency
    ///   is absent from the destination's rate table.
    public func convert(value: Double, from sourceCurrencyCode: String, to destinationCurrencyCode: String) async throws -> Double {
        let source = sourceCurrencyCode.uppercased()
        let destination = destinationCurrencyCode.uppercased()

        guard source != destination else { return value }

        let rates = try await rates(for: destination)

        // Reject zero, negative, and non-finite (inf/NaN) rates: a degraded payload must
        // surface as a thrown error, not as garbage output (negative amounts, or
        // `value / .infinity == 0`).
        guard let pair = rates.pairs.first(where: { $0.code == source }),
              pair.rate.isFinite, pair.rate > 0 else {
            throw ForexError.rateUnavailable(source: source, destination: destination)
        }

        // `rates` is the table for `destination`, so `pair.rate` is "source per 1
        // destination"; dividing `value` (in source) by it yields the destination amount.
        return value / pair.rate
    }

    /// Warms the cache for a currency (e.g. the user's preferred currency) so later
    /// conversions are instant. Best-effort: network errors are ignored.
    public func prefetchRates(for currencyCode: String) async {
        _ = try? await rates(for: currencyCode)
    }

    // MARK: Single-flight cache

    /// Returns rates for `code`: a fresh cache hit, a joined in-flight request, or a
    /// newly started one. On fetch failure it falls back to stale cached rates if any
    /// exist (so a transient outage keeps using the last known rates); otherwise it rethrows.
    private func rates(for code: String) async throws -> Rates {
        let key = code.uppercased()

        if let entry = cache[key], Date().timeIntervalSince(entry.fetchedAt) < cacheTTL {
            return entry.rates
        }

        // Join an existing in-flight fetch for this currency rather than starting another.
        if let existing = inFlight[key] {
            do {
                return try await existing.value
            } catch {
                if let stale = cache[key]?.rates { return stale }
                throw error
            }
        }

        // Own a new fetch. Register it *before* the first suspension point so that
        // concurrent callers entering this method find it and join (single-flight).
        // Only one owner can exist per key, so this owner clears exactly its own task.
        let task = Task { try await Self.fetchRates(for: key) }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let rates = try await task.value
            cache[key] = CacheEntry(rates: rates, fetchedAt: Date())
            return rates
        } catch {
            if let stale = cache[key]?.rates { return stale }
            throw error
        }
    }
}

// MARK: - Networking

extension Forex {
    /// A `DateFormatter` is costly to create and is thread-safe for read-only
    /// formatting/parsing once configured, so it is built once. Uses `yyyy` (calendar
    /// year) — not `YYYY` (week-of-year year, a classic off-by-a-year bug around the
    /// new year) — with a fixed POSIX locale and UTC zone for stable parsing.
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    private static func versionedBaseURL(date: Date?) throws -> URL {
        let dateParameter = date.map { dateFormatter.string(from: $0) } ?? "latest"
        guard let url = URL(string: baseURLString)?
            .appending(path: "currency-api@\(dateParameter)")
            .appending(path: "v1")
        else {
            throw ForexError.invalidURL
        }
        return url
    }

    private static func data(from url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ForexError.invalidResponse
            }
            return data
        } catch let error as ForexError {
            throw error
        } catch {
            throw ForexError.networkError(error.localizedDescription)
        }
    }
}

#if DEBUG
extension Forex {
    /// Test seam: preload the cache with known rates so the conversion and
    /// single-flight logic can be exercised without network access. Debug-only.
    func preload(_ rates: Rates, fetchedAt: Date = Date()) {
        cache[rates.code.uppercased()] = CacheEntry(rates: rates, fetchedAt: fetchedAt)
    }
}
#endif

public extension Forex {
    /// Fetches the list of supported currencies (code and display name).
    /// - Parameter date: a historical date, or `nil` for the latest rates.
    static func fetchCurrencies(for date: Date? = nil) async throws -> [Currency] {
        let url = try versionedBaseURL(date: date).appending(path: "currencies.json")
        let data = try await data(from: url)
        return try Currency.currencies(from: data)
    }

    /// Fetches the exchange-rate table for a single base currency.
    /// - Parameters:
    ///   - currency: the ISO base-currency code (case-insensitive).
    ///   - date: a historical date, or `nil` for the latest rates.
    static func fetchRates(for currency: String, date: Date? = nil) async throws -> Rates {
        let url = try versionedBaseURL(date: date)
            .appending(path: "currencies")
            .appending(path: "\(currency.lowercased()).json")
        let data = try await data(from: url)
        return try Rates.rates(from: data)
    }
}
