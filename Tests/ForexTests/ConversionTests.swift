import XCTest
@testable import Forex

/// The conversion on `Rates`, which needs neither the network nor the cache.
final class ConversionTests: XCTestCase {
    /// The table for USD: 1 USD = 0.5 EUR, so 1 EUR = 2 USD.
    private func table(eur rate: Double = 0.5) -> Rates {
        Rates(date: Date(), code: "USD", pairs: [Rates.Pair(code: "EUR", rate: rate)])
    }

    private func assertRateUnavailable(
        _ table: Rates,
        from source: String = "EUR",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try table.convert(value: 10, from: source), file: file, line: line) { error in
            guard case let ForexError.rateUnavailable(thrownSource, destination) = error else {
                return XCTFail("Expected rateUnavailable, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(thrownSource, source, file: file, line: line)
            XCTAssertEqual(destination, "USD", file: file, line: line)
        }
    }

    func testConvertTheTablesOwnCurrencyReturnsValueUnchanged() throws {
        XCTAssertEqual(try table().convert(value: 42, from: "usd"), 42, accuracy: 0.0001)
    }

    func testConvertDividesValueBySourcePerDestinationRate() throws {
        XCTAssertEqual(try table().convert(value: 10, from: "EUR"), 20, accuracy: 0.0001)
    }

    func testConvertIsCaseInsensitive() throws {
        XCTAssertEqual(try table().convert(value: 10, from: "eur"), 20, accuracy: 0.0001)

        let lowercased = Rates(date: Date(), code: "usd", pairs: [Rates.Pair(code: "eur", rate: 0.5)])
        XCTAssertEqual(try lowercased.convert(value: 10, from: "EUR"), 20, accuracy: 0.0001)
        XCTAssertEqual(try lowercased.convert(value: 10, from: "USD"), 10, accuracy: 0.0001)
    }

    func testConvertWorksOnADecodedTable() throws {
        let json = #"{ "date": "2024-03-06", "usd": { "eur": 0.5 } }"#.data(using: .utf8)!

        XCTAssertEqual(try Rates.rates(from: json).convert(value: 10, from: "eur"), 20, accuracy: 0.0001)
    }

    func testConvertThrowsWhenSourceRateMissing() {
        assertRateUnavailable(table(), from: "JPY")
    }

    func testConvertThrowsOnNonPositiveRate() {
        assertRateUnavailable(table(eur: -0.5))
        assertRateUnavailable(table(eur: 0))
    }

    func testConvertThrowsOnNonFiniteRate() {
        assertRateUnavailable(table(eur: .infinity))
        assertRateUnavailable(table(eur: .nan))
    }
}
