import Foundation

public struct Rates: Codable, Sendable {
    public let date: Date
    public let code: String
    public let pairs: [Pair]

    public struct Pair: Codable, Sendable, Hashable {
        public let code: String
        public let rate: Double

        public init(code: String, rate: Double) {
            self.code = code
            self.rate = rate
        }
    }

    public init(date: Date, code: String, pairs: [Pair]) {
        self.date = date
        self.code = code
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
        self.pairs = pairsMap.map { Pair(code: $0.key.uppercased(), rate: $0.value) }
    }
}

public extension Rates {
    static func rates(from data: Data) throws -> Rates {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(Forex.dateFormatter)
        do {
            return try decoder.decode(Rates.self, from: data)
        } catch {
            throw ForexError.dataParsingError(String(describing: error))
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    var intValue: Int?
    init?(intValue: Int) {
        return nil
    }
}
