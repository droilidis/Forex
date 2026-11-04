import Foundation

/// Fetches exchange-rate tables and the list of currencies from the free API at
/// https://github.com/fawazahmed0/exchange-api (served via the jsDelivr CDN).
///
/// A client keeps nothing: every call is a request, through the session it was given. The
/// ``Forex`` actor adds a cache on top of it.
public struct ForexClient: Sendable {
    /// The session a client uses unless it's given another.
    ///
    /// It doesn't wait for connectivity, so with no network or an unreachable CDN a request
    /// fails instead of waiting. It has no URL cache, as the CDN's `max-age` of a week would
    /// otherwise serve a stored response without reaching the network. A request gives up
    /// after 30 seconds.
    public static let defaultSession = URLSession(configuration: defaultConfiguration())

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    private static let baseURLString = "https://cdn.jsdelivr.net/npm/@fawazahmed0/"

    let session: URLSession

    public init(session: URLSession = ForexClient.defaultSession) {
        self.session = session
    }

    /// Fetches the list of supported currencies (code and display name).
    /// - Parameter date: a historical date, or `nil` for the latest list.
    public func fetchCurrencies(for date: Date? = nil) async throws -> [Currency] {
        let url = try Self.versionedBaseURL(date: date).appending(path: "currencies.json")
        return try Currency.currencies(from: try await data(from: url))
    }

    /// Fetches the exchange-rate table for a single base currency.
    /// - Parameters:
    ///   - currency: the ISO base-currency code (case-insensitive).
    ///   - date: a historical date, or `nil` for the latest rates.
    /// - Throws: ``ForexError/dataParsingError(_:)`` too when the table is for another base
    ///   currency, as its rates would convert to the wrong currency without an error.
    public func fetchRates(for currency: String, date: Date? = nil) async throws -> Rates {
        let url = try Self.versionedBaseURL(date: date)
            .appending(path: "currencies")
            .appending(path: "\(currency.lowercased()).json")
        let rates = try Rates.rates(from: try await data(from: url))
        guard rates.code == currency.uppercased() else {
            throw ForexError.dataParsingError("Expected the table for \(currency.uppercased()), got \(rates.code).")
        }
        return rates
    }

    private static func versionedBaseURL(date: Date?) throws -> URL {
        let dateParameter = date.map { Rates.dateFormatter.string(from: $0) } ?? "latest"
        guard let url = URL(string: baseURLString)?
            .appending(path: "currency-api@\(dateParameter)")
            .appending(path: "v1")
        else {
            throw ForexError.invalidURL
        }
        return url
    }

    private func data(from url: URL) async throws -> Data {
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
