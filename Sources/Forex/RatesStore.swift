import Foundation

/// A rate table with the date it was fetched, which is what a table's age is measured from.
/// `rates.date` is the day the API published it.
public struct StoredRates: Codable, Sendable {
    public let rates: Rates
    public let fetchedAt: Date

    public init(rates: Rates, fetchedAt: Date) {
        self.rates = rates
        self.fetchedAt = fetchedAt
    }
}

/// Where the ``Forex`` actor keeps its tables, one per currency. It reads a currency's table
/// from the store on the first call that needs it, and saves every table it fetches.
///
/// A failed load counts as an empty store for that call, and the next call reads again. A
/// failed save leaves the table in the actor's memory only. Neither fails a conversion.
///
/// `load` and `save` must finish in bounded time: the calls for a currency wait for its load,
/// and a fetch isn't over until its save is, so its callers, the stream and later fetches for
/// the currency all wait for the save.
public protocol RatesStore: Sendable {
    /// The table for an uppercased currency code, or `nil` when none is stored.
    func load(currency: String) async throws -> StoredRates?

    /// Stores `table` under its `rates.code`, replacing the table stored for that currency.
    func save(_ table: StoredRates) async throws
}

/// Keeps tables in memory, for as long as the store exists. The default store of ``Forex``.
public actor InMemoryRatesStore: RatesStore {
    private var tables: [String: StoredRates] = [:]

    /// - Parameter tables: the tables to start with.
    public init(_ tables: [StoredRates] = []) {
        for table in tables {
            self.tables[table.rates.code] = table
        }
    }

    public func load(currency: String) -> StoredRates? {
        tables[currency.uppercased()]
    }

    public func save(_ table: StoredRates) {
        tables[table.rates.code] = table
    }
}

/// Keeps each table in a JSON file of its own in a folder the caller picks, so tables outlive
/// the process. The folder is created when the first table is saved.
public struct FileRatesStore: RatesStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// - Throws: an error when the file exists but can't be read or decoded.
    public func load(currency: String) async throws -> StoredRates? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(for: currency))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(StoredRates.self, from: data)
    }

    public func save(_ table: StoredRates) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(table).write(to: fileURL(for: table.rates.code), options: .atomic)
    }

    /// The code is percent-encoded, as it comes from a caller or the server and a `/` or `..`
    /// in it must not lead out of the folder.
    private func fileURL(for currency: String) -> URL {
        let name = currency.uppercased().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return directory.appending(path: "\(name).json", directoryHint: .notDirectory)
    }
}
