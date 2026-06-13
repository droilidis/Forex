import XCTest
@testable import Forex

final class ForexTests: XCTestCase {

    // MARK: - Conversion (hermetic, no network)

    func testConvertSameCurrencyReturnsValueUnchanged() async throws {
        let forex = Forex()
        let value = try await forex.convert(value: 42, from: "USD", to: "usd")
        XCTAssertEqual(value, 42, accuracy: 0.0001)
    }

    func testConvertDividesValueBySourcePerDestinationRate() async throws {
        let forex = Forex()
        // Rate table for the destination (USD): 1 USD = 0.5 EUR  ⇒  1 EUR = 2 USD.
        await forex.preload(Rates(date: Date(), code: "USD", pairs: [
            Rates.Pair(code: "EUR", rate: 0.5)
        ]))

        let usd = try await forex.convert(value: 10, from: "EUR", to: "USD")
        XCTAssertEqual(usd, 20, accuracy: 0.0001)
    }

    func testConvertIsCaseInsensitive() async throws {
        let forex = Forex()
        await forex.preload(Rates(date: Date(), code: "USD", pairs: [
            Rates.Pair(code: "EUR", rate: 0.5)
        ]))

        let usd = try await forex.convert(value: 10, from: "eur", to: "usd")
        XCTAssertEqual(usd, 20, accuracy: 0.0001)
    }

    func testConvertThrowsWhenSourceRateMissing() async {
        let forex = Forex()
        await forex.preload(Rates(date: Date(), code: "USD", pairs: [
            Rates.Pair(code: "EUR", rate: 0.5)
        ]))

        do {
            _ = try await forex.convert(value: 10, from: "JPY", to: "USD")
            XCTFail("Expected rateUnavailable to be thrown")
        } catch let ForexError.rateUnavailable(source, destination) {
            XCTAssertEqual(source, "JPY")
            XCTAssertEqual(destination, "USD")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

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
        XCTAssertEqual(Forex.dateFormatter.string(from: rates.date), "2024-03-06")
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

    func testRatesDecodingFailureThrowsParsingError() {
        let json = "not json".data(using: .utf8)!
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

        XCTAssertEqual(Forex.dateFormatter.string(from: date), "2024-12-30")
    }

    // MARK: - Integration (requires network; exercises the live API)

    func testFetchCurrencies_live() async throws {
        try XCTSkipIf(isOffline, "Requires network access")
        let currencies = try await Forex.fetchCurrencies()
        XCTAssertFalse(currencies.isEmpty, "Currencies should not be empty")
    }

    func testFetchRates_live() async throws {
        try XCTSkipIf(isOffline, "Requires network access")
        let rates = try await Forex.fetchRates(for: "usd")
        XCTAssertFalse(rates.pairs.isEmpty, "Rates should not be empty")
    }

    /// Crude offline check so the live tests skip instead of failing without a connection.
    private var isOffline: Bool {
        (try? Data(contentsOf: URL(string: "https://cdn.jsdelivr.net")!)) == nil
    }
}
