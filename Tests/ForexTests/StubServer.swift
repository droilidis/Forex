import Foundation
import XCTest
import os
@testable import Forex

/// Answers a session's requests in the test process, through `StubURLProtocol`, so a test
/// exercises the real client and session without reaching the network.
final class StubServer: Sendable {
    enum Reply: Sendable {
        case body(String, status: Int = 200, headers: [String: String] = [:])
        case failure(URLError.Code)

        /// The API's payload for a rate table.
        static func rates(base: String, _ rates: [String: Double]) -> Reply {
            let pairs = rates.map { #""\#($0.key)": \#($0.value)"# }.joined(separator: ", ")
            return .body(#"{ "date": "2026-11-01", "\#(base)": { \#(pairs) } }"#)
        }

        /// The failure a request gets with no network.
        static let offline = Reply.failure(.notConnectedToInternet)
    }

    private struct State {
        var reply: Reply
        var requests: [URL] = []
        var isHolding = false
        var held: [StubURLProtocol] = []
    }

    private static let servers = OSAllocatedUnfairLock<[String: StubServer]>(initialState: [:])
    private static let idHeader = "X-Stub-Server"

    private let state: OSAllocatedUnfairLock<State>
    let session: URLSession

    /// - Parameter configuration: the session's configuration, to which the stub is added.
    init(reply: Reply, configuration: URLSessionConfiguration = .ephemeral) {
        let id = UUID().uuidString
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [Self.idHeader: id]
        state = OSAllocatedUnfairLock(initialState: State(reply: reply))
        session = URLSession(configuration: configuration)
        Self.servers.withLock { $0[id] = self }
    }

    var client: ForexClient { ForexClient(session: session) }

    /// The reply to the requests from now on, and to those being held.
    func setReply(_ reply: Reply) {
        state.withLock { $0.reply = reply }
    }

    /// The URLs of the requests received so far.
    var requests: [URL] {
        state.withLock { $0.requests }
    }

    /// Leaves requests unanswered until `release()`, or for 5 seconds, so that code waiting for
    /// a held request fails its test instead of never ending.
    func hold() {
        state.withLock { $0.isHolding = true }
        Task {
            try? await Task.sleep(for: .seconds(5))
            release()
        }
    }

    func release() {
        let (held, reply) = state.withLock { state in
            defer {
                state.isHolding = false
                state.held = []
            }
            return (state.held, state.reply)
        }
        for request in held {
            request.answer(with: reply)
        }
    }

    /// Waits for the server to have received `count` requests.
    func waitForRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 where requests.count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(requests.count, count, "Requests that never came", file: file, line: line)
    }

    fileprivate static func server(for request: URLRequest) -> StubServer? {
        guard let id = request.value(forHTTPHeaderField: idHeader) else { return nil }
        return servers.withLock { $0[id] }
    }

    fileprivate func receive(_ request: StubURLProtocol, url: URL) {
        let reply: Reply? = state.withLock { state in
            state.requests.append(url)
            if state.isHolding {
                state.held.append(request)
                return nil
            }
            return state.reply
        }
        if let reply {
            request.answer(with: reply)
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = StubServer.server(for: request), let url = request.url else {
            return client?.urlProtocol(self, didFailWithError: URLError(.unknown)) ?? ()
        }
        server.receive(self, url: url)
    }

    override func stopLoading() {}

    fileprivate func answer(with reply: StubServer.Reply) {
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .body(let body, let status, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

/// Runs `operation`, or throws after `seconds`, so a test that would otherwise wait forever
/// fails instead.
func withTimeLimit<T: Sendable>(
    seconds: Int = 5,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        defer { group.cancelAll() }
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ForexError.networkError("Nothing within \(seconds) seconds")
        }
        return try await group.next()!
    }
}

/// The next element of a stream of currency codes.
func nextCode(of stream: AsyncStream<String>) async throws -> String? {
    try await withTimeLimit { await stream.first { _ in true } }
}
