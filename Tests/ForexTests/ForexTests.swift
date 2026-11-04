import XCTest
@testable import Forex

final class ForexTests: XCTestCase {

    // MARK: - Decoding (hermetic)

    func testRatesDecoding() throws {
        let json = """
        { "date": "2024-03-06", "eur": { "usd": 1.08, "gbp": 0.85 } }
        """.data(using: .utf8)!

        let rates = try Rates.rates(from: json)

        XCTAssertEqual(rates.code, "EUR")
        XCTAssertEqual(rates.pairs.count, 2)
        XCTAssertEqual(rates.pairs.first(where: { $0.code == "USD" })?.rate, 1.08)
        XCTAssertEqual(rates.pairs.first(where: { $0.code == "GBP" })?.rate, 0.85)
        XCTAssertEqual(Rates.dateFormatter.string(from: rates.date), "2024-03-06")
    }

    func testCurrenciesDecoding() throws {
        let json = """
        { "usd": "US Dollar", "eur": "Euro" }
        """.data(using: .utf8)!

        let currencies = try Currency.currencies(from: json)

        XCTAssertEqual(currencies.count, 2)
        XCTAssertEqual(currencies.map(\.code), ["eur", "usd"]) // sorted by code
        XCTAssertEqual(currencies.first(where: { $0.code == "usd" })?.name, "US Dollar")
    }

    func testRatesSurviveARoundTripThroughTheirCoding() throws {
        let rates = Rates(date: Date(timeIntervalSince1970: 1_700_000_000), code: "EUR", pairs: [
            Rates.Pair(code: "USD", rate: 1.08)
        ])

        let decoded = try JSONDecoder().decode(Rates.self, from: JSONEncoder().encode(rates))

        XCTAssertEqual(decoded.date, rates.date)
        XCTAssertEqual(decoded.code, "EUR")
        XCTAssertEqual(decoded.pairs, rates.pairs)
    }

    func testRatesDecodingFailureThrowsParsingError() {
        let json = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try Rates.rates(from: json)) { error in
            guard case ForexError.dataParsingError = error else {
                return XCTFail("Expected dataParsingError, got \(error)")
            }
        }
    }

    // MARK: - Degraded payloads (regression for review findings 1 & 2)

    func testRatesDecodingMissingBaseObjectThrows() {
        // Valid JSON and HTTP 200, but the base-currency object is absent: must throw,
        // not decode to an empty table that then gets cached as fresh for the full TTL.
        let json = #"{ "date": "2024-03-06" }"#.data(using: .utf8)!
        XCTAssertThrowsError(try Rates.rates(from: json)) { error in
            guard case ForexError.dataParsingError = error else {
                return XCTFail("Expected dataParsingError, got \(error)")
            }
        }
    }

    func testRatesDecodingEmptyTableThrows() {
        let json = #"{ "date": "2024-03-06", "eur": {} }"#.data(using: .utf8)!
        XCTAssertThrowsError(try Rates.rates(from: json)) { error in
            guard case ForexError.dataParsingError = error else {
                return XCTFail("Expected dataParsingError, got \(error)")
            }
        }
    }

    func testRatesDecodingMultipleBasesThrows() {
        let json = #"{ "date": "2024-03-06", "eur": { "usd": 1.08 }, "gbp": { "usd": 1.27 } }"#.data(using: .utf8)!
        XCTAssertThrowsError(try Rates.rates(from: json)) { error in
            guard case ForexError.dataParsingError = error else {
                return XCTFail("Expected dataParsingError, got \(error)")
            }
        }
    }

    // MARK: - Date formatting

    func testDateFormatterUsesCalendarYearNotWeekYear() {
        // 2024-12-30 falls in ISO week-year 2025; a `YYYY` pattern would render "2025".
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")! // match the formatter's zone
        var components = DateComponents()
        components.year = 2024
        components.month = 12
        components.day = 30
        let date = calendar.date(from: components)!

        XCTAssertEqual(Rates.dateFormatter.string(from: date), "2024-12-30")
    }

    // MARK: - Integration (exercises the live API; only with FOREX_LIVE_TESTS=1)

    func testFetchCurrencies_live() async throws {
        let currencies = try await liveFetch { try await $0.fetchCurrencies() }
        XCTAssertFalse(currencies.isEmpty, "Currencies should not be empty")
    }

    func testFetchRates_live() async throws {
        let rates = try await liveFetch { try await $0.fetchRates(for: "usd") }
        XCTAssertFalse(rates.pairs.isEmpty, "Rates should not be empty")
    }

    /// Runs `fetch` with a default client against the live API, or skips the test so a default
    /// run stays off the network. A run that sets the variable asked for the live API, so
    /// without a connection these tests fail rather than skip: the default session has no URL
    /// cache to answer from, doesn't wait for connectivity, and gives up after 30 seconds.
    private func liveFetch<T>(_ fetch: (ForexClient) async throws -> T) async throws -> T {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FOREX_LIVE_TESTS"] == "1",
            "Live API test: run with FOREX_LIVE_TESTS=1 swift test"
        )
        return try await fetch(ForexClient())
    }
}
