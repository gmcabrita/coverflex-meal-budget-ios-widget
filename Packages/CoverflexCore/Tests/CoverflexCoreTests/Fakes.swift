import Foundation
@testable import CoverflexCore

/// Thread safe box for test state.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}

struct FakeResponse {
    var status: Int
    var json: String
}

/// Answers requests by "METHOD path". Records every request.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    let routes: Locked<[String: [FakeResponse]]>
    let requests = Locked<[URLRequest]>([])
    var offline = false

    init(_ routes: [String: [FakeResponse]]) {
        self.routes = Locked(routes)
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.update { $0.append(request) }
        if offline { throw URLError(.notConnectedToInternet) }

        let key = "\(request.httpMethod ?? "GET") \(request.url!.path())"
        var response: FakeResponse?
        routes.update { routes in
            guard var queue = routes[key], !queue.isEmpty else { return }
            // The last response repeats.
            response = queue.count > 1 ? queue.removeFirst() : queue[0]
            routes[key] = queue
        }
        guard let response else { fatalError("No fake response for \(key)") }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
        return (Data(response.json.utf8), http)
    }

    func paths() -> [String] {
        requests.get().map { "\($0.httpMethod ?? "GET") \($0.url!.path())" }
    }
}

final class MemoryStore<Value: Sendable>: SecureStore, @unchecked Sendable {
    let value: Locked<Value?>
    init(_ value: Value?) { self.value = Locked(value) }
    func load() -> Value? { value.get() }
    func save(_ value: Value) { self.value.set(value) }
    func clear() { value.set(nil) }
}

final class MemorySnapshotStore: SnapshotStore, @unchecked Sendable {
    let snapshot: Locked<BudgetSnapshot>
    init(_ snapshot: BudgetSnapshot = BudgetSnapshot()) { self.snapshot = Locked(snapshot) }
    func load() -> BudgetSnapshot { snapshot.get() }
    func save(_ snapshot: BudgetSnapshot) { self.snapshot.set(snapshot) }
}

/// Builds an unsigned JWT with the given expiry.
func makeJWT(exp: Date) -> String {
    func encode(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(encode(#"{"alg":"none"}"#)).\(encode("{\"exp\":\(Int(exp.timeIntervalSince1970))}")).sig"
}

/// Holds requests until the test calls `releaseAll()`, so tests can act while a request is in flight.
/// After the first release, later requests pass without waiting, so a test cannot hang.
final class GatedTransport: HTTPTransport, @unchecked Sendable {
    let inner: FakeTransport
    /// Yields once per request that reached the transport.
    let arrivals: AsyncStream<Void>
    private let arrivalsContinuation: AsyncStream<Void>.Continuation
    private let releases: Locked<[CheckedContinuation<Void, Never>]> = Locked([])
    private let isOpen = Locked(false)

    init(_ inner: FakeTransport) {
        self.inner = inner
        (arrivals, arrivalsContinuation) = AsyncStream.makeStream()
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if !isOpen.get() {
            await withCheckedContinuation { continuation in
                releases.update { $0.append(continuation) }
                arrivalsContinuation.yield()
            }
        }
        return try await inner.send(request)
    }

    func releaseAll() {
        isOpen.set(true)
        var pending: [CheckedContinuation<Void, Never>] = []
        releases.update { pending = $0; $0 = [] }
        pending.forEach { $0.resume() }
    }
}
