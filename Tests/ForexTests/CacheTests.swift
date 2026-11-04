import XCTest
@testable import Forex

/// The `Forex` actor over a stubbed session.
final class CacheTests: XCTestCase {
    private static let hour: TimeInterval = 60 * 60
    private static let day: TimeInterval = 24 * hour

    /// The payload for USD with 1 USD = `rate` EUR.
    private func reply(eur rate: Double) -> StubServer.Reply {
        .rates(base: "usd", ["eur": rate])
    }

    /// A stored table for USD, with 1 USD = `rate` EUR, fetched `age` seconds ago.
    private func table(eur rate: Double = 0.5, age: TimeInterval) -> StoredRates {
        StoredRates(
            rates: Rates(date: Date(), code: "USD", pairs: [Rates.Pair(code: "EUR", rate: rate)]),
            fetchedAt: Date(timeIntervalSinceNow: -age)
        )
    }

    private func convert(_ forex: Forex) async throws -> Double {
        try await forex.convert(value: 10, from: "EUR", to: "USD")
    }

    private func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    // MARK: - Conversion through the cache

    func testConvertUsesTheFetchedTable() async throws {
        let server = StubServer(reply: reply(eur: 0.5))
        let forex = Forex(client: server.client)

        let value = try await forex.convert(value: 10, from: "eur", to: "usd")

        XCTAssertEqual(value, 20, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testConvertingACurrencyToItselfMakesNoRequest() async throws {
        let server = StubServer(reply: .offline)
        let forex = Forex(client: server.client)

        let value = try await forex.convert(value: 42, from: "USD", to: "usd")

        XCTAssertEqual(value, 42, accuracy: 0.0001)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testConvertThrowsWhenTheTableHasNoRateForTheSource() async throws {
        let server = StubServer(reply: reply(eur: 0.5))
        let forex = Forex(client: server.client)

        await assertThrows(try await forex.convert(value: 10, from: "JPY", to: "USD")) { error in
            guard case let ForexError.rateUnavailable(source, destination) = error else {
                return XCTFail("Expected rateUnavailable, got \(error)")
            }
            XCTAssertEqual(source, "JPY")
            XCTAssertEqual(destination, "USD")
        }
    }

    func testPrefetchMakesLaterConversionsRequestNothing() async throws {
        let server = StubServer(reply: reply(eur: 0.5))
        let forex = Forex(client: server.client)

        await forex.prefetchRates(for: "usd")
        XCTAssertEqual(server.requests.count, 1)
        let value = try await convert(forex)

        XCTAssertEqual(value, 20, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testPrefetchIgnoresAFailure() async {
        let server = StubServer(reply: .offline)
        let forex = Forex(client: server.client)

        await forex.prefetchRates(for: "USD")

        XCTAssertEqual(server.requests.count, 1)
    }

    // MARK: - Freshness

    func testATableStaysFreshForADayByDefault() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        let forex = Forex(client: server.client, store: InMemoryRatesStore([table(age: Self.day - Self.hour)]))

        let value = try await convert(forex)

        XCTAssertEqual(value, 20, accuracy: 0.0001)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAnOlderTableIsNotFreshByDefault() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        let forex = Forex(client: server.client, store: InMemoryRatesStore([table(age: Self.day + Self.hour)]))

        let value = try await convert(forex)

        XCTAssertEqual(value, 40, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testTheCallerChoosesHowLongATableStaysFresh() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        let store = InMemoryRatesStore([table(age: 2 * Self.hour)])
        let shortLived = Forex(client: server.client, store: store, freshness: Self.hour)
        let longLived = Forex(client: server.client, store: InMemoryRatesStore([table(age: 2 * Self.day)]), freshness: 3 * Self.day)

        let refreshed = try await convert(shortLived)
        let kept = try await convert(longLived)

        XCTAssertEqual(refreshed, 40, accuracy: 0.0001)
        XCTAssertEqual(kept, 20, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testATableFetchedInTheFutureIsNotFresh() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        let forex = Forex(client: server.client, store: InMemoryRatesStore([table(age: -Self.hour)]))

        let value = try await convert(forex)

        XCTAssertEqual(value, 40, accuracy: 0.0001)
    }

    // MARK: - Fetch first

    func testFetchFirstReplacesAnOlderTable() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        let store = InMemoryRatesStore([table(age: 2 * Self.day)])
        let forex = Forex(client: server.client, store: store)

        let first = try await convert(forex)
        let second = try await convert(forex)
        let stored = await store.load(currency: "USD")

        XCTAssertEqual(first, 40, accuracy: 0.0001)
        XCTAssertEqual(second, 40, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(stored?.rates.pairs, [Rates.Pair(code: "EUR", rate: 0.25)])
        XCTAssertEqual(stored?.fetchedAt.timeIntervalSinceNow ?? -.infinity, 0, accuracy: 60)
    }

    func testFetchFirstFallsBackToTheTableAndKeepsItWhenTheFetchFails() async throws {
        let server = StubServer(reply: .offline)
        let old = table(age: 2 * Self.day)
        let store = InMemoryRatesStore([old])
        let forex = Forex(client: server.client, store: store)

        let value = try await convert(forex)
        let stored = await store.load(currency: "USD")

        XCTAssertEqual(value, 20, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(stored?.fetchedAt, old.fetchedAt)
    }

    func testAFailedRefreshFallsBackToTheTableItFetchedEarlier() async throws {
        let server = StubServer(reply: reply(eur: 0.5))
        let forex = Forex(client: server.client, freshness: 0)
        _ = try await convert(forex)

        server.setReply(.offline)
        let value = try await convert(forex)

        XCTAssertEqual(value, 20, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testAFailedFetchThrowsWithNoTable() async {
        let server = StubServer(reply: .offline)
        let forex = Forex(client: server.client)

        await assertThrows(try await convert(forex)) { error in
            guard case ForexError.networkError = error else {
                return XCTFail("Expected networkError, got \(error)")
            }
        }
    }

    // MARK: - Refresh in the background

    func testRefreshInBackgroundReturnsAtOnceThenStoresAndYieldsTheNewTable() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        server.hold()
        let store = InMemoryRatesStore([table(age: 30 * Self.day)])
        let forex = Forex(client: server.client, store: store, stalePolicy: .refreshInBackground())
        let updates = await forex.updates()

        // The request stays unanswered, so this can only return the stored table.
        let atOnce = try await convert(forex)
        XCTAssertEqual(atOnce, 20, accuracy: 0.0001)

        try await server.waitForRequests(1)
        server.release()
        let code = try await nextCode(of: updates)
        let stored = await store.load(currency: "USD")
        let afterwards = try await convert(forex)

        XCTAssertEqual(code, "USD")
        XCTAssertEqual(stored?.rates.pairs, [Rates.Pair(code: "EUR", rate: 0.25)])
        XCTAssertEqual(afterwards, 40, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testRefreshInBackgroundLeavesAFreshTableAlone() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        let store = InMemoryRatesStore([table(age: Self.hour)])
        let forex = Forex(client: server.client, store: store, stalePolicy: .refreshInBackground())

        let value = try await convert(forex)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(value, 20, accuracy: 0.0001)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testRefreshInBackgroundMakesOneRequestForManyCalls() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        server.hold()
        let store = InMemoryRatesStore([table(age: 2 * Self.day)])
        let forex = Forex(client: server.client, store: store, stalePolicy: .refreshInBackground())

        for _ in 0..<5 {
            _ = try await convert(forex)
        }
        try await server.waitForRequests(1)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(server.requests.count, 1)
        server.release()
    }

    func testRefreshInBackgroundUpToAMaximumAgeReturnsAYoungerTableAtOnce() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        server.hold()
        let store = InMemoryRatesStore([table(age: 2 * Self.day)])
        let forex = Forex(client: server.client, store: store, stalePolicy: .refreshInBackground(maximumAge: 3 * Self.day))

        let value = try await convert(forex)

        XCTAssertEqual(value, 20, accuracy: 0.0001)
        try await server.waitForRequests(1)
        server.release()
    }

    func testRefreshInBackgroundPastTheMaximumAgeFetchesFirst() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        let store = InMemoryRatesStore([table(age: 4 * Self.day)])
        let forex = Forex(client: server.client, store: store, stalePolicy: .refreshInBackground(maximumAge: 3 * Self.day))

        let value = try await convert(forex)

        XCTAssertEqual(value, 40, accuracy: 0.0001)
    }

    func testRefreshInBackgroundPastTheMaximumAgeFallsBackWhenTheFetchFails() async throws {
        let server = StubServer(reply: .offline)
        let store = InMemoryRatesStore([table(age: 4 * Self.day)])
        let forex = Forex(client: server.client, store: store, stalePolicy: .refreshInBackground(maximumAge: 3 * Self.day))

        let value = try await convert(forex)

        XCTAssertEqual(value, 20, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testRefreshInBackgroundFetchesFirstWithNoTable() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        let forex = Forex(client: server.client, stalePolicy: .refreshInBackground())

        let value = try await convert(forex)

        XCTAssertEqual(value, 40, accuracy: 0.0001)
    }

    func testAFailedBackgroundRefreshKeepsTheTable() async throws {
        let server = StubServer(reply: .offline)
        let old = table(age: 2 * Self.day)
        let store = InMemoryRatesStore([old])
        let forex = Forex(client: server.client, store: store, stalePolicy: .refreshInBackground())

        _ = try await convert(forex)
        try await server.waitForRequests(1)
        let value = try await convert(forex)
        let stored = await store.load(currency: "USD")

        XCTAssertEqual(value, 20, accuracy: 0.0001)
        XCTAssertEqual(stored?.fetchedAt, old.fetchedAt)
    }

    // MARK: - After a relaunch

    func testRefreshInBackgroundReturnsAtOnceAfterARelaunchWithTheFileStore() async throws {
        let folder = temporaryFolder()
        let server = StubServer(reply: reply(eur: 0.5))

        // The first launch fetches and saves.
        let firstLaunch = try await convert(Forex(client: server.client, store: FileRatesStore(directory: folder)))
        XCTAssertEqual(firstLaunch, 20, accuracy: 0.0001)

        // The relaunch has nothing in memory, and finds the table too old to be fresh.
        server.setReply(reply(eur: 0.25))
        server.hold()
        let relaunched = Forex(client: server.client, store: FileRatesStore(directory: folder), freshness: 0, stalePolicy: .refreshInBackground())
        let updates = await relaunched.updates()

        let atOnce = try await convert(relaunched)
        XCTAssertEqual(atOnce, 20, accuracy: 0.0001)

        try await server.waitForRequests(2)
        server.release()
        let code = try await nextCode(of: updates)
        let saved = try await FileRatesStore(directory: folder).load(currency: "USD")

        XCTAssertEqual(code, "USD")
        XCTAssertEqual(saved?.rates.pairs, [Rates.Pair(code: "EUR", rate: 0.25)])
    }

    func testAFreshTableIsUsedAfterARelaunchWithoutARequest() async throws {
        let folder = temporaryFolder()
        try await FileRatesStore(directory: folder).save(table(age: Self.hour))
        let server = StubServer(reply: reply(eur: 0.25))

        let value = try await convert(Forex(client: server.client, store: FileRatesStore(directory: folder)))

        XCTAssertEqual(value, 20, accuracy: 0.0001)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testADamagedFileCountsAsNoTableAndTheFetchReplacesIt() async throws {
        let folder = temporaryFolder()
        let store = FileRatesStore(directory: folder)
        try await store.save(table(age: Self.hour))
        try Data("damaged".utf8).write(to: folder.appending(path: "USD.json"))
        let server = StubServer(reply: reply(eur: 0.25))

        let value = try await convert(Forex(client: server.client, store: store))
        let saved = try await store.load(currency: "USD")

        XCTAssertEqual(value, 40, accuracy: 0.0001)
        XCTAssertEqual(saved?.rates.pairs, [Rates.Pair(code: "EUR", rate: 0.25)])
    }

    // MARK: - The failure window

    func testCallsInTheFailureWindowFailAtOnceWithoutARequest() async throws {
        let server = StubServer(reply: .offline)
        let forex = Forex(client: server.client)

        for _ in 0..<5 {
            await assertThrows(try await convert(forex)) { error in
                guard case ForexError.networkError = error else {
                    return XCTFail("Expected the fetch's error, got \(error)")
                }
            }
        }

        XCTAssertEqual(server.requests.count, 1)
    }

    func testCallsInTheFailureWindowUseTheStoredTableWithoutARequest() async throws {
        let server = StubServer(reply: .offline)
        let store = InMemoryRatesStore([table(age: 2 * Self.day)])
        let forex = Forex(client: server.client, store: store)

        for _ in 0..<5 {
            let value = try await convert(forex)
            XCTAssertEqual(value, 20, accuracy: 0.0001)
        }

        XCTAssertEqual(server.requests.count, 1)
    }

    func testTheFailureWindowHoldsBackBackgroundRefreshes() async throws {
        let server = StubServer(reply: .offline)
        let store = InMemoryRatesStore([table(age: 2 * Self.day)])
        let forex = Forex(client: server.client, store: store, stalePolicy: .refreshInBackground())

        // The first refresh, given time to fail.
        _ = try await convert(forex)
        try await server.waitForRequests(1)
        try await Task.sleep(for: .milliseconds(100))

        for _ in 0..<5 {
            _ = try await convert(forex)
        }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(server.requests.count, 1)
    }

    func testAfterTheFailureWindowACallFetchesAgain() async throws {
        let server = StubServer(reply: .offline)
        let forex = Forex(client: server.client, failureWindow: .zero)

        await assertThrows(try await convert(forex))
        server.setReply(reply(eur: 0.5))
        let value = try await convert(forex)

        XCTAssertEqual(value, 20, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testTheCallerChoosesTheFailureWindow() async throws {
        let server = StubServer(reply: .offline)
        let forex = Forex(client: server.client, failureWindow: .milliseconds(50))

        await assertThrows(try await convert(forex))
        try await Task.sleep(for: .milliseconds(100))
        await assertThrows(try await convert(forex))

        XCTAssertEqual(server.requests.count, 2)
    }

    func testTheFailureWindowIsPerCurrency() async throws {
        let server = StubServer(reply: .offline)
        let forex = Forex(client: server.client)
        await assertThrows(try await convert(forex))

        server.setReply(.rates(base: "gbp", ["eur": 0.5]))
        let gbp = try await forex.convert(value: 10, from: "EUR", to: "GBP")
        await assertThrows(try await convert(forex))

        XCTAssertEqual(gbp, 20, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 2)
    }

    // MARK: - A payload for another base

    func testAPayloadForAnotherBaseIsAFailedFetch() async throws {
        let server = StubServer(reply: .rates(base: "eur", ["usd": 2, "gbp": 0.8]))
        let old = table(age: 2 * Self.day)
        let store = InMemoryRatesStore([old])
        let forex = Forex(client: server.client, store: store)

        let value = try await convert(forex)
        let usd = await store.load(currency: "USD")
        let eur = await store.load(currency: "EUR")

        XCTAssertEqual(value, 20, accuracy: 0.0001)
        XCTAssertEqual(usd?.fetchedAt, old.fetchedAt)
        XCTAssertNil(eur)
    }

    // MARK: - One fetch per currency

    func testConcurrentCallersShareOneFetch() async throws {
        let server = StubServer(reply: reply(eur: 0.5))
        server.hold()
        let forex = Forex(client: server.client)

        let values = try await withThrowingTaskGroup(of: Double.self) { group in
            for _ in 0..<20 {
                group.addTask { try await forex.convert(value: 10, from: "EUR", to: "USD") }
            }
            try await server.waitForRequests(1)
            try await Task.sleep(for: .milliseconds(100))
            server.release()
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(values, Array(repeating: 20, count: 20))
        XCTAssertEqual(server.requests.count, 1)
    }

    func testConcurrentCallersShareOneFailedFetch() async throws {
        let server = StubServer(reply: .offline)
        server.hold()
        let forex = Forex(client: server.client)

        let failures = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask { (try? await forex.convert(value: 10, from: "EUR", to: "USD")) == nil }
            }
            try await server.waitForRequests(1)
            try await Task.sleep(for: .milliseconds(100))
            server.release()
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(failures, Array(repeating: true, count: 20))
        XCTAssertEqual(server.requests.count, 1)
    }

    func testDifferentCurrenciesFetchSeparately() async throws {
        let server = StubServer(reply: .rates(base: "usd", ["eur": 0.5]))
        let forex = Forex(client: server.client)

        _ = try await forex.convert(value: 10, from: "EUR", to: "USD")
        server.setReply(.rates(base: "gbp", ["eur": 0.25]))
        let gbp = try await forex.convert(value: 10, from: "EUR", to: "GBP")

        XCTAssertEqual(gbp, 40, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 2)
    }

    // MARK: - The store

    func testConcurrentCallersReadTheStoreOnce() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        let store = ProbeStore(table(age: Self.hour))
        let forex = Forex(client: server.client, store: store)

        let values = try await withThrowingTaskGroup(of: Double.self) { group in
            for _ in 0..<20 {
                group.addTask { try await forex.convert(value: 10, from: "EUR", to: "USD") }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        _ = try await convert(forex)
        let loads = await store.loads

        XCTAssertEqual(values, Array(repeating: 20, count: 20))
        XCTAssertEqual(loads, ["USD"])
    }

    func testAFailedLoadIsReadAgainByTheNextCall() async throws {
        let server = StubServer(reply: .offline)
        let store = ProbeStore(table(age: Self.hour), failingLoads: 1)
        let forex = Forex(client: server.client, store: store)

        await assertThrows(try await convert(forex))
        let second = try await convert(forex)
        let third = try await convert(forex)
        let loads = await store.loads

        XCTAssertEqual(second, 20, accuracy: 0.0001)
        XCTAssertEqual(third, 20, accuracy: 0.0001)
        XCTAssertEqual(loads, ["USD", "USD"])
        XCTAssertEqual(server.requests.count, 1)
    }

    func testATableFetchedAfterAFailedLoadIsUsedWithoutReadingTheStore() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        let store = ProbeStore(table(age: Self.hour), failingLoads: 1)
        let forex = Forex(client: server.client, store: store)

        let first = try await convert(forex)
        let second = try await convert(forex)
        let loads = await store.loads

        XCTAssertEqual(first, 40, accuracy: 0.0001)
        XCTAssertEqual(second, 40, accuracy: 0.0001)
        XCTAssertEqual(loads, ["USD"])
    }

    func testALateLoadDoesNotReplaceAFetchedTable() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        server.hold()
        let store = ProbeStore(table(age: Self.hour), failingLoads: 1, heldLoad: 2)
        let forex = Forex(client: server.client, store: store)

        // The first call's load fails, so it fetches, and the fetch waits.
        let fetching = Task { try await forex.convert(value: 10, from: "EUR", to: "USD") }
        try await server.waitForRequests(1)

        // The next call's load waits until the fetch has stored its table.
        let loading = Task { try await forex.convert(value: 10, from: "EUR", to: "USD") }
        try await store.waitForLoads(2)
        server.release()
        let fetched = try await fetching.value
        await store.releaseLoad()
        let loaded = try await loading.value

        XCTAssertEqual(fetched, 40, accuracy: 0.0001)
        XCTAssertEqual(loaded, 40, accuracy: 0.0001)
    }

    func testAFailedLoadCountsAsNoTable() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        let forex = Forex(client: server.client, store: ProbeStore(failing: true))

        let value = try await convert(forex)

        XCTAssertEqual(value, 40, accuracy: 0.0001)
    }

    func testAFailedSaveKeepsTheTableInMemoryAndYieldsIt() async throws {
        let server = StubServer(reply: reply(eur: 0.25))
        let forex = Forex(client: server.client, store: ProbeStore(failing: true))
        let updates = await forex.updates()

        _ = try await convert(forex)
        let code = try await nextCode(of: updates)
        let value = try await convert(forex)

        XCTAssertEqual(code, "USD")
        XCTAssertEqual(value, 40, accuracy: 0.0001)
        XCTAssertEqual(server.requests.count, 1)
    }

    // MARK: - The stream

    func testTheStreamYieldsTheUppercasedCodeOfAFetchedTable() async throws {
        let server = StubServer(reply: reply(eur: 0.5))
        let forex = Forex(client: server.client)
        let updates = await forex.updates()

        _ = try await forex.convert(value: 10, from: "eur", to: "usd")
        let code = try await nextCode(of: updates)

        XCTAssertEqual(code, "USD")
    }

    func testEachStreamYieldsEveryCode() async throws {
        let server = StubServer(reply: reply(eur: 0.5))
        let forex = Forex(client: server.client)
        let first = await forex.updates()
        let second = await forex.updates()

        _ = try await convert(forex)
        let firstCode = try await nextCode(of: first)
        let secondCode = try await nextCode(of: second)

        XCTAssertEqual(firstCode, "USD")
        XCTAssertEqual(secondCode, "USD")
    }

    func testTheStreamYieldsNothingForAFailedFetchOrAStoredTable() async throws {
        let server = StubServer(reply: .offline)
        let store = InMemoryRatesStore([table(age: Self.hour)])
        let forex = Forex(client: server.client, store: store)
        let updates = await forex.updates()

        // A table from the store, then a failed fetch, and then the first table fetched,
        // which must be the first element.
        _ = try await convert(forex)
        await assertThrows(try await forex.convert(value: 10, from: "EUR", to: "CHF"))
        server.setReply(.rates(base: "gbp", ["eur": 0.5]))
        _ = try await forex.convert(value: 10, from: "EUR", to: "GBP")
        let code = try await nextCode(of: updates)

        XCTAssertEqual(code, "GBP")
    }

    func testAStreamFinishesWhenItsForexGoesAway() async throws {
        var forex: Forex? = Forex(client: StubServer(reply: .offline).client)
        let updates = try await XCTUnwrapAsync(await forex?.updates())

        forex = nil
        let code = try await nextCode(of: updates)

        XCTAssertNil(code)
    }

    private func XCTUnwrapAsync<T>(_ value: @autoclosure () async -> T?) async throws -> T {
        let value = await value()
        return try XCTUnwrap(value)
    }
}

/// A store that records its reads, and can fail or hold one.
private actor ProbeStore: RatesStore {
    private struct Failure: Error {}

    private(set) var loads: [String] = []
    private let table: StoredRates?
    private let failing: Bool
    private let failingLoads: Int
    private let heldLoad: Int?
    private var waitingLoad: CheckedContinuation<Void, Never>?

    /// - Parameters:
    ///   - failing: every load and save throws.
    ///   - failingLoads: how many of the first loads throw.
    ///   - heldLoad: which load, counting from 1, waits for `releaseLoad()`.
    init(_ table: StoredRates? = nil, failing: Bool = false, failingLoads: Int = 0, heldLoad: Int? = nil) {
        self.table = table
        self.failing = failing
        self.failingLoads = failingLoads
        self.heldLoad = heldLoad
    }

    func load(currency: String) async throws -> StoredRates? {
        loads.append(currency)
        let number = loads.count
        if number == heldLoad {
            await withCheckedContinuation { waitingLoad = $0 }
        }
        try await Task.sleep(for: .milliseconds(10))
        if failing || number <= failingLoads { throw Failure() }
        return table
    }

    func releaseLoad() {
        waitingLoad?.resume()
        waitingLoad = nil
    }

    /// Waits for the store to have received `count` loads.
    func waitForLoads(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 where loads.count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(loads.count, count, "Loads that never came", file: file, line: line)
    }

    func save(_ table: StoredRates) throws {
        if failing { throw Failure() }
    }
}
