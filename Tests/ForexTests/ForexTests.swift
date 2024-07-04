import XCTest
@testable import Forex

final class ForexTests: XCTestCase {
    func testExample() throws {
        // XCTest Documentation
        // https://developer.apple.com/documentation/xctest

        // Defining Test Cases and Test Methods
        // https://developer.apple.com/documentation/xctest/defining_test_cases_and_test_methods
    }

    func testFetchCurrencies() async {
        do {
            let currencies = try await Forex.fetchCurrencies()
            XCTAssertFalse(currencies.isEmpty, "Currencies should not be empty")
            print("Fetched currencies: \(currencies)")
        } catch {
            XCTFail("Error fetching currencies: \(error.localizedDescription)")
        }
    }

    func testFetchRates() async {
        do {
            let currencies = try await Forex.fetchCurrencies()
            XCTAssertFalse(currencies.isEmpty, "Currencies should not be empty")
            let rates = try await Forex.fetchRates(currency: currencies.randomElement()!.code)
            XCTAssertFalse(rates.pairs.isEmpty, "Rates should not be empty")
            print("Fetched rates: \(rates)")
        } catch {
            XCTFail("Error fetching rates: \(error.localizedDescription)")
        }
    }

    static var allTests = [
        ("testFetchCurrencies", testFetchCurrencies),
        ("testFetchRates", testFetchRates),
    ]
}
