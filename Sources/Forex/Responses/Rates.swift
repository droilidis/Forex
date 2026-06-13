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

        // The payload shape is `{ "date": ..., "<base>": { "<code>": rate, ... } }`,
        // so the base currency appears as a dynamic key alongside the static `date` key.
        var codeString = ""
        var pairsMap = [String: Double]()
        let dynamicContainer = try decoder.container(keyedBy: DynamicKey.self)
        for key in dynamicContainer.allKeys where CodingKeys(rawValue: key.stringValue) == nil {
            codeString = key.stringValue
            pairsMap = try dynamicContainer.decode([String: Double].self, forKey: key)
        }
        self.code = codeString.uppercased()

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
