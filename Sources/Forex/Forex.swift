import Foundation

/// A cache of exchange-rate tables over a ``ForexClient``, and conversion with them.
///
/// Each caller creates its own instance and chooses the policy: a bare `Forex()` keeps tables
/// in memory, treats them as fresh for 24 hours, falls back to the last table when a refresh
/// fails, and never waits for a connection.
///
/// `Forex` is an `actor`, so its state is isolated and concurrent callers are data-race free.
/// Concurrent requests for the same currency are de-duplicated ("single-flight"): a burst of
/// conversions triggers at most one network request per currency, rather than one per caller.
public actor Forex {
    /// What to do with a table older than `freshness`.
    public enum StalePolicy: Sendable {
        /// Fetch first, and fall back to the table when the fetch fails.
        case fetchFirst

        /// Return the table at once and refresh it in the background. A table older than
        /// `maximumAge` (`nil`: no limit) is handled as in ``fetchFirst``.
        case refreshInBackground(maximumAge: TimeInterval? = nil)
    }

    private let client: ForexClient
    private let store: any RatesStore
    private let freshness: TimeInterval
    private let stalePolicy: StalePolicy
    private let failureWindow: Duration

    /// - Parameters:
    ///   - client: fetches the tables.
    ///   - store: where tables are kept (default: in memory).
    ///   - freshness: how long a table stays fresh (default 24 hours, as the upstream API
    ///     publishes new rates roughly once a day).
    ///   - stalePolicy: what to do with an older table (default ``StalePolicy/fetchFirst``).
    ///   - failureWindow: how long a failed fetch makes further calls for that currency fail
    ///     at once without a request (default 10 seconds), so converting many prices one by
    ///     one makes one request. A call in the window uses the last table if there is one,
    ///     and otherwise throws the fetch's error.
    public init(
        client: ForexClient = ForexClient(),
        store: any RatesStore = InMemoryRatesStore(),
        freshness: TimeInterval = 24 * 60 * 60,
        stalePolicy: StalePolicy = .fetchFirst,
        failureWindow: Duration = .seconds(10)
    ) {
        self.client = client
        self.store = store
        self.freshness = freshness
        self.stalePolicy = stalePolicy
        self.failureWindow = failureWindow
    }

    deinit {
        for subscriber in subscribers.values {
            subscriber.finish()
        }
    }

    // MARK: State (actor-isolated, keyed by uppercased currency code)

    private struct Failure {
        let error: Error

        /// On a monotonic clock, as a wall clock set back would hold the window open for as
        /// long as it moved.
        let until: ContinuousClock.Instant
    }

    /// The latest table of each currency, so a conversion doesn't read the store.
    private var tables: [String: StoredRates] = [:]

    /// The reads from the store, one per currency, shared by concurrent callers. A read that
    /// succeeded stays, so a currency is read only once. A failed one goes, so that the next
    /// call reads again.
    private var loads: [String: Task<Void, Never>] = [:]

    /// In-flight fetches, so concurrent callers for a currency share a single request.
    private var inFlight: [String: Task<Rates, Error>] = [:]

    /// The last failed fetch of each currency, which holds back requests until `until`.
    private var failures: [String: Failure] = [:]

    private var subscribers: [UUID: AsyncStream<String>.Continuation] = [:]

    // MARK: Public API

    /// Converts `value` from one ISO currency code to another.
    ///
    /// Rates are fetched for the *destination* currency and cached, so a list of
    /// conversions into the same destination (the common case — a single preferred
    /// currency) shares one network request and one table.
    ///
    /// - Returns: `value` expressed in `destinationCurrencyCode`.
    /// - Throws: ``ForexError`` if rates cannot be fetched and no table is stored, or
    ///   ``ForexError/rateUnavailable(source:destination:)`` if the table has no usable rate
    ///   for the source currency.
    public func convert(value: Double, from sourceCurrencyCode: String, to destinationCurrencyCode: String) async throws -> Double {
        guard sourceCurrencyCode.uppercased() != destinationCurrencyCode.uppercased() else { return value }

        return try await rates(for: destinationCurrencyCode).convert(value: value, from: sourceCurrencyCode)
    }

    /// Readies the table for a currency (e.g. the user's preferred currency) so later
    /// conversions are instant. Best-effort: network errors are ignored.
    public func prefetchRates(for currencyCode: String) async {
        _ = try? await rates(for: currencyCode)
    }

    /// The uppercased code of each currency whose table is stored from now on: one element
    /// per table fetched, even when its rates are the same as the last one's, and even when
    /// the store failed to save it, as conversions use it from then on.
    ///
    /// Each call returns a stream of its own. A stream finishes when this instance goes away.
    public func updates() -> AsyncStream<String> {
        let id = UUID()
        let (stream, subscriber) = AsyncStream.makeStream(of: String.self)
        subscriber.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        subscribers[id] = subscriber
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    // MARK: Cache

    /// Returns the table for `code` as the policy says. When a fetch fails, it falls back to
    /// the last table if there is one, so a transient outage keeps using the last known
    /// rates; otherwise it rethrows.
    private func rates(for code: String) async throws -> Rates {
        let key = code.uppercased()

        if let table = await storedTable(for: key) {
            // A fetch date in the future means the clock moved: the age says nothing.
            let age = Date().timeIntervalSince(table.fetchedAt)
            if age >= 0, age < freshness {
                return table.rates
            }
            if case .refreshInBackground(let maximumAge) = stalePolicy, age < maximumAge ?? .infinity {
                _ = try? sharedFetch(for: key)
                return table.rates
            }
        }

        do {
            return try await sharedFetch(for: key).value
        } catch {
            if let table = tables[key] { return table.rates }
            throw error
        }
    }

    /// The latest table for `key`, from the store until there's one in memory.
    private func storedTable(for key: String) async -> StoredRates? {
        if let table = tables[key] { return table }

        let load = loads[key] ?? Task {
            do {
                let stored = try await store.load(currency: key)
                // After a failed read, a fetch may have stored a newer table in the meantime.
                tables[key] = tables[key] ?? stored
            } catch {
                loads[key] = nil
            }
        }
        loads[key] = load
        await load.value
        return tables[key]
    }

    /// The fetch in flight for `key`, or a new one. The fetch stores its table itself, as a
    /// background refresh has no caller waiting for it.
    ///
    /// - Throws: the last failure's error, inside the failure window.
    private func sharedFetch(for key: String) throws -> Task<Rates, Error> {
        if let task = inFlight[key] { return task }

        if let failure = failures[key], ContinuousClock.Instant.now < failure.until {
            throw failure.error
        }

        // Registered before the task can run, as the task runs on this actor: concurrent
        // callers entering this method find it and join (single-flight).
        let task = Task<Rates, Error> {
            defer { inFlight[key] = nil }
            do {
                let rates = try await client.fetchRates(for: key)
                let table = StoredRates(rates: rates, fetchedAt: Date())
                tables[key] = table
                try? await store.save(table)
                for subscriber in subscribers.values {
                    subscriber.yield(key)
                }
                return rates
            } catch {
                failures[key] = Failure(error: error, until: .now + failureWindow)
                throw error
            }
        }
        inFlight[key] = task
        return task
    }
}
