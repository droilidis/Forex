import Foundation

public struct Currency {
    let code: String
    let name: String
}

public extension Currency {
    static func currencies(from data: Data) throws -> [Currency] {
        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode([String: String].self, from: data)
            return response.map({ Currency(code: $0.key, name: $0.value) })
        } catch {
            throw ForexError.dataParsingError(error)
        }
    }
}
