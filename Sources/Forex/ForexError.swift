import Foundation

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
