import Foundation

enum ForexError: Error {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case dataParsingError(Error)
}

public actor Forex {
    public static let shared: Forex = Forex()
    private init() {}

    private static let baseURLString = "https://cdn.jsdelivr.net/npm/@fawazahmed0/"

    private var allCachedRates: [String: Rates] = [:]

    private func cachedRates(for currencyCode: String) -> Rates? {
        allCachedRates[currencyCode]
    }

    private func cacheRates(_ rates: Rates?) {
        guard let rates else { return }
        allCachedRates[rates.code] = rates
    }

    public func cacheRates(for currencyCode: String) async {
        let rates = try? await Self.fetchRates(currency: currencyCode)
        cacheRates(rates)
    }

    public func convert(value: Double, from sourceCurrencyCode: String, to destinationCurrencyCode: String) async -> Double {
        guard sourceCurrencyCode != destinationCurrencyCode else {
            return value
        }

        var rates = cachedRates(for: destinationCurrencyCode)
        if rates == nil {
            rates = try? await Self.fetchRates(currency: destinationCurrencyCode)
            cacheRates(rates)
        }
        guard let rates else { return 0.0 }

        guard let pair = rates.pairs.first(where: { $0.code == sourceCurrencyCode }) else {
            return 0.0
        }

        return  value / pair.rate
    }
}


// MARK: - API

extension Forex {
    static var dateFormatter: DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "YYYY-MM-dd"
        return dateFormatter
    }
}

public extension Forex {
    static func fetchCurrencies(for date: Date = .now) async throws -> [Currency] {
        guard let url = URL(string: baseURLString)?
            .appending(path: "currency-api@\(Forex.dateFormatter.string(from: date))")
            .appending(path: "v1")
            .appending(path: "currencies.json")
        else {
            throw ForexError.invalidURL
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try Currency.currencies(from: data)
        } catch {
            throw ForexError.networkError(error)
        }
    }

    static func fetchRates(for date: Date = .now, currency: String) async throws -> Rates {
        guard let url = URL(string: baseURLString)?
            .appending(path: "currency-api@\(dateFormatter.string(from: date))")
            .appending(path: "v1").appending(path: "currencies")
            .appending(path: "\(currency.lowercased()).json")
        else {
            throw ForexError.invalidURL
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try Rates.rates(from: data)
        } catch {
            throw ForexError.networkError(error)
        }
    }
}
