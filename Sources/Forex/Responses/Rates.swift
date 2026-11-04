import Foundation

public struct Rates: Codable, Sendable {
    public let date: Date
    public let code: String
    public let pairs: [Pair]

    public struct Pair: Sendable, Hashable {
        public let code: String
        public let rate: Double

        public init(code: String, rate: Double) {
            self.code = code.uppercased()
            self.rate = rate
        }
    }

    public init(date: Date, code: String, pairs: [Pair]) {
        self.date = date
        self.code = code.uppercased()
        self.pairs = pairs
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case date, code, pairs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.date = try container.decode(Date.self, forKey: .date)

        // The payload shape is `{ "date": ..., "<base>": { "<code>": rate, ... } }`:
        // exactly one dynamic key (the base currency) sits alongside the static `date`
        // key. Require it explicitly so a degraded-but-valid-JSON 200 response (missing
        // or duplicated base object, or an empty table) fails to decode instead of
        // silently yielding an empty `Rates` that would then be cached as "fresh".
        let dynamicContainer = try decoder.container(keyedBy: DynamicKey.self)
        let baseKeys = dynamicContainer.allKeys.filter { CodingKeys(rawValue: $0.stringValue) == nil }

        guard baseKeys.count == 1, let baseKey = baseKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: dynamicContainer.codingPath,
                debugDescription: "Expected exactly one base-currency object, found \(baseKeys.count)."
            ))
        }

        let pairsMap = try dynamicContainer.decode([String: Double].self, forKey: baseKey)
        guard !pairsMap.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: dynamicContainer.codingPath,
                debugDescription: "Rate table for '\(baseKey.stringValue)' is empty."
            ))
        }

        self.code = baseKey.stringValue.uppercased()
        self.pairs = pairsMap.map { Pair(code: $0.key, rate: $0.value) }
    }

    /// Writes the payload's shape, the one `init(from:)` reads, so a table survives a round
    /// trip through any coder with the same date strategy on both sides.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(date, forKey: DynamicKey(CodingKeys.date.rawValue))
        let pairsMap = Dictionary(pairs.map { ($0.code, $0.rate) }, uniquingKeysWith: { first, _ in first })
        try container.encode(pairsMap, forKey: DynamicKey(code))
    }
}

public extension Rates {
    /// `value` in the currency `sourceCurrencyCode`, expressed in this table's currency.
    ///
    /// A table is for its *destination* currency: `pair.rate` is "source per 1 destination",
    /// so the result is `value / pair.rate`. The code is case-insensitive, and the table's
    /// own currency returns `value` unchanged.
    ///
    /// - Throws: ``ForexError/rateUnavailable(source:destination:)`` when the source currency
    ///   isn't in the table, or its rate is zero, negative or non-finite.
    func convert(value: Double, from sourceCurrencyCode: String) throws -> Double {
        let source = sourceCurrencyCode.uppercased()

        guard source != code else { return value }

        // Reject zero, negative, and non-finite (inf/NaN) rates: a degraded payload must
        // surface as a thrown error, not as garbage output (negative amounts, or
        // `value / .infinity == 0`).
        guard let pair = pairs.first(where: { $0.code == source }),
              pair.rate.isFinite, pair.rate > 0 else {
            throw ForexError.rateUnavailable(source: source, destination: code)
        }

        return value / pair.rate
    }
}

public extension Rates {
    static func rates(from data: Data) throws -> Rates {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(dateFormatter)
        do {
            return try decoder.decode(Rates.self, from: data)
        } catch {
            throw ForexError.dataParsingError(String(describing: error))
        }
    }
}

extension Rates {
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
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    var intValue: Int?
    init?(intValue: Int) {
        return nil
    }
}
