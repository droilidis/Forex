import Foundation

public struct Rates: Codable {
    let date: Date
    let code: String
    let pairs: [Pair]

    struct Pair: Codable {
        let code: String
        let rate: Double
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case date, code, pairs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.date = try container.decode(Date.self, forKey: .date)

        var codeString = ""
        var pairsMap = [String: Double]()
        let dynamicContainer = try decoder.container(keyedBy: DynamicKey.self)
        try dynamicContainer.allKeys.forEach { key in
            guard CodingKeys(rawValue: key.stringValue) == nil else { return }
            codeString = key.stringValue
            pairsMap = try dynamicContainer.decode([String: Double].self, forKey: key)
        }
        self.code = codeString.uppercased()

        self.pairs = pairsMap.map({ Pair(code: $0.key.uppercased(), rate: $0.value) })
    }
}

public extension Rates {
    static func rates(from data: Data) throws -> Rates {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(Forex.dateFormatter)
        do {
            let response = try decoder.decode(Rates.self, from: data)
            return response
        } catch {
            throw ForexError.dataParsingError(error)
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
