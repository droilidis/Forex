import Foundation

public struct Currency: Sendable, Hashable, Codable {
    public let code: String
    public let name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

public extension Currency {
    static func currencies(from data: Data) throws -> [Currency] {
        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode([String: String].self, from: data)
            return response
                .map { Currency(code: $0.key, name: $0.value) }
                .sorted { $0.code < $1.code }
        } catch {
            throw ForexError.dataParsingError(String(describing: error))
        }
    }
}
