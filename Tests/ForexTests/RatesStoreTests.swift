import XCTest
@testable import Forex

final class RatesStoreTests: XCTestCase {
    private func table(_ code: String = "USD", eur rate: Double = 0.5) -> StoredRates {
        StoredRates(
            rates: Rates(date: Date(timeIntervalSince1970: 1_700_000_000), code: code, pairs: [Rates.Pair(code: "EUR", rate: rate)]),
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_123.456)
        )
    }

    /// A folder for the test, inside one that doesn't exist yet.
    private func temporaryFolder() -> URL {
        let parent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return parent.appending(path: "Rates")
    }

    private func assertSame(_ table: StoredRates?, _ expected: StoredRates, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(table?.fetchedAt, expected.fetchedAt, file: file, line: line)
        XCTAssertEqual(table?.rates.date, expected.rates.date, file: file, line: line)
        XCTAssertEqual(table?.rates.code, expected.rates.code, file: file, line: line)
        XCTAssertEqual(table?.rates.pairs, expected.rates.pairs, file: file, line: line)
    }

    // MARK: - In memory

    func testInMemoryStoreRoundTrip() async {
        let store = InMemoryRatesStore()
        let empty = await store.load(currency: "USD")
        XCTAssertNil(empty)

        await store.save(table())

        assertSame(await store.load(currency: "USD"), table())
    }

    func testInMemoryStoreStartsWithItsTables() async {
        let store = InMemoryRatesStore([table()])

        assertSame(await store.load(currency: "USD"), table())
    }

    // MARK: - File

    func testFileStoreRoundTrip() async throws {
        let directory = temporaryFolder()
        try await FileRatesStore(directory: directory).save(table())

        // A new store, as after a relaunch.
        let loaded = try await FileRatesStore(directory: directory).load(currency: "USD")

        assertSame(loaded, table())
    }

    func testFileStoreKeepsATableOfManyRates() async throws {
        let store = FileRatesStore(directory: temporaryFolder())
        let pairs = [("EUR", 0.9234567891234), ("BTC", 0.0000091234), ("VND", 25_432.5)].map(Rates.Pair.init)
        let table = StoredRates(rates: Rates(date: Date(), code: "USD", pairs: pairs), fetchedAt: Date())

        try await store.save(table)
        let loaded = try await store.load(currency: "USD")

        XCTAssertEqual(Set(try XCTUnwrap(loaded).rates.pairs), Set(pairs))
    }

    func testFileStoreHasNothingBeforeTheFirstSave() async throws {
        let table = try await FileRatesStore(directory: temporaryFolder()).load(currency: "USD")

        XCTAssertNil(table)
    }

    func testFileStoreKeepsOneTablePerCurrency() async throws {
        let store = FileRatesStore(directory: temporaryFolder())
        try await store.save(table("USD", eur: 0.5))
        try await store.save(table("GBP", eur: 1.2))

        let usd = try await store.load(currency: "USD")
        let gbp = try await store.load(currency: "GBP")

        assertSame(usd, table("USD", eur: 0.5))
        assertSame(gbp, table("GBP", eur: 1.2))
    }

    func testFileStoreReplacesACurrencysTable() async throws {
        let store = FileRatesStore(directory: temporaryFolder())
        try await store.save(table(eur: 0.5))
        try await store.save(table(eur: 0.25))

        let loaded = try await store.load(currency: "USD")

        assertSame(loaded, table(eur: 0.25))
    }

    func testFileStoreThrowsOnADamagedFile() async throws {
        let directory = temporaryFolder()
        let store = FileRatesStore(directory: directory)
        try await store.save(table())
        try Data("damaged".utf8).write(to: directory.appending(path: "USD.json"))

        await assertThrows(try await store.load(currency: "USD"))
    }

    func testFileStoreKeepsACodeWithAPathInItsFolder() async throws {
        let directory = temporaryFolder()
        let store = FileRatesStore(directory: directory)

        try await store.save(table("../USD"))
        let loaded = try await store.load(currency: "../USD")

        assertSame(loaded, table("../USD"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.deletingLastPathComponent().path), ["Rates"])
    }
}
