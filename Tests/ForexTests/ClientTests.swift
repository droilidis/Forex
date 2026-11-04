import XCTest
@testable import Forex

final class ClientTests: XCTestCase {

    // MARK: - Requests

    func testFetchRatesAsksForTheLatestTableOfTheLowercasedCode() async throws {
        let server = StubServer(reply: .rates(base: "usd", ["eur": 0.5]))

        let rates = try await server.client.fetchRates(for: "USD")

        XCTAssertEqual(rates.code, "USD")
        XCTAssertEqual(rates.pairs, [Rates.Pair(code: "EUR", rate: 0.5)])
        XCTAssertEqual(server.requests.map(\.path), ["/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.json"])
    }

    func testFetchRatesForADateAsksForThatDay() async throws {
        let server = StubServer(reply: .rates(base: "usd", ["eur": 0.5]))
        let date = try XCTUnwrap(Rates.dateFormatter.date(from: "2024-03-06"))

        _ = try await server.client.fetchRates(for: "usd", date: date)

        XCTAssertEqual(server.requests.map(\.path), ["/npm/@fawazahmed0/currency-api@2024-03-06/v1/currencies/usd.json"])
    }

    func testFetchCurrenciesReturnsTheList() async throws {
        let server = StubServer(reply: .body(#"{ "usd": "US Dollar", "eur": "Euro" }"#))

        let currencies = try await server.client.fetchCurrencies()

        XCTAssertEqual(currencies.map(\.code), ["eur", "usd"])
        XCTAssertEqual(server.requests.map(\.path), ["/npm/@fawazahmed0/currency-api@latest/v1/currencies.json"])
    }

    // MARK: - Failures

    func testAnHTTPErrorThrowsInvalidResponse() async {
        let server = StubServer(reply: .body("Not found", status: 404))

        await assertThrows(try await server.client.fetchRates(for: "usd")) { error in
            guard case ForexError.invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }

    func testATransportErrorThrowsNetworkError() async {
        let server = StubServer(reply: .offline)

        await assertThrows(try await server.client.fetchCurrencies()) { error in
            guard case ForexError.networkError = error else {
                return XCTFail("Expected networkError, got \(error)")
            }
        }
    }

    func testADegradedPayloadThrowsParsingError() async {
        let server = StubServer(reply: .body(#"{ "date": "2026-11-01" }"#))

        await assertThrows(try await server.client.fetchRates(for: "usd")) { error in
            guard case ForexError.dataParsingError = error else {
                return XCTFail("Expected dataParsingError, got \(error)")
            }
        }
    }

    func testAPayloadForAnotherBaseThrowsParsingError() async {
        let server = StubServer(reply: .rates(base: "eur", ["usd": 2, "gbp": 0.8]))

        await assertThrows(try await server.client.fetchRates(for: "USD")) { error in
            guard case ForexError.dataParsingError = error else {
                return XCTFail("Expected dataParsingError, got \(error)")
            }
        }
    }

    // MARK: - The default session

    func testAClientUsesTheDefaultSessionUnlessGivenAnother() {
        let session = URLSession(configuration: .ephemeral)

        XCTAssertIdentical(ForexClient().session, ForexClient.defaultSession)
        XCTAssertIdentical(ForexClient(session: session).session, session)
    }

    func testTheDefaultSessionGivesUpAfterThirtySeconds() {
        let configuration = ForexClient.defaultSession.configuration

        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
    }

    /// Nothing listens on port 1 of the loopback interface, so this is a refused connection,
    /// which a session that waits for connectivity keeps waiting on. No request leaves the Mac.
    func testTheDefaultSessionFailsOnARefusedConnectionInsteadOfWaiting() async throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1/usd.json"))

        try await withTimeLimit(seconds: 25) {
            await assertThrows(try await ForexClient.defaultSession.data(from: url))
        }
    }

    func testTheDefaultSessionKeepsNothingInAURLCache() async throws {
        let body = #"{ "date": "2026-11-01", "usd": { "eur": 0.5 } }"#
        let server = StubServer(
            reply: .body(body, headers: ["Cache-Control": "public, max-age=604800"]),
            configuration: ForexClient.defaultConfiguration()
        )

        XCTAssertNil(server.session.configuration.urlCache)
        _ = try await server.client.fetchRates(for: "usd")
        _ = try await server.client.fetchRates(for: "usd")

        XCTAssertEqual(server.requests.count, 2, "The second fetch came from a cache")
    }
}

/// Fails unless `expression` throws, and hands the error to `check`.
func assertThrows<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ check: (Error) -> Void = { _ in }
) async {
    do {
        let value = try await expression()
        XCTFail("Expected an error, got \(value)", file: file, line: line)
    } catch {
        check(error)
    }
}
