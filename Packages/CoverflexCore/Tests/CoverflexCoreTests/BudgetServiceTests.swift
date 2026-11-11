import Foundation
import Testing
@testable import CoverflexCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let validAccess = makeJWT(exp: now.addingTimeInterval(3600))
private let expiredAccess = makeJWT(exp: now.addingTimeInterval(-10))
private let validRefresh = makeJWT(exp: now.addingTimeInterval(86400 * 30))
private let newAccess = makeJWT(exp: now.addingTimeInterval(7200))
private let newRefresh = makeJWT(exp: now.addingTimeInterval(86400 * 60))

private let pocketsJSON = #"{"pockets":[{"type":"benefits","balance":{"amount":5000}},{"type":"meals","balance":{"amount":325}}]}"#
private let renewJSON = "{\"token\":\"\(newAccess)\",\"refresh_token\":\"\(newRefresh)\"}"

private func makeService(
    _ transport: FakeTransport,
    tokens: AuthTokens?,
    snapshot: BudgetSnapshot = BudgetSnapshot()
) -> (BudgetService, MemoryTokenStore, MemorySnapshotStore) {
    let tokenStore = MemoryTokenStore(tokens)
    let snapshotStore = MemorySnapshotStore(snapshot)
    let service = BudgetService(
        api: CoverflexAPI(transport: transport),
        tokens: tokenStore,
        snapshots: snapshotStore,
        now: { now }
    )
    return (service, tokenStore, snapshotStore)
}

/// Simulates another process that renews first: while the renew request is in flight,
/// the store receives new tokens and the server rejects the spent refresh token.
private final class RenewRaceTransport: HTTPTransport, @unchecked Sendable {
    let tokenStore: MemoryTokenStore
    let otherProcessTokens: AuthTokens

    init(tokenStore: MemoryTokenStore, otherProcessTokens: AuthTokens) {
        self.tokenStore = tokenStore
        self.otherProcessTokens = otherProcessTokens
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let isRenew = request.url!.path().hasSuffix("/renew")
        if isRenew { tokenStore.save(otherProcessTokens) }
        let status = isRenew ? 401 : 200
        let body = isRenew ? "{}" : pocketsJSON
        if !isRenew {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(otherProcessTokens.token)")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@Suite struct BudgetServiceTests {
    @Test func usesCachedAccessTokenWhenValid() async {
        let transport = FakeTransport(["GET /api/employee/pockets": [FakeResponse(status: 200, json: pocketsJSON)]])
        let (service, _, _) = makeService(transport, tokens: AuthTokens(token: validAccess, refreshToken: validRefresh))

        let snapshot = await service.refresh()

        #expect(snapshot == BudgetSnapshot(balanceCents: 325, fetchedAt: now, problem: nil))
        #expect(transport.paths() == ["GET /api/employee/pockets"])
        #expect(transport.requests.get()[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(validAccess)")
    }

    @Test func renewsExpiredAccessTokenAndStoresNewTokens() async {
        let transport = FakeTransport([
            "POST /api/employee/sessions/renew": [FakeResponse(status: 200, json: renewJSON)],
            "GET /api/employee/pockets": [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let (service, tokens, _) = makeService(transport, tokens: AuthTokens(token: expiredAccess, refreshToken: validRefresh))

        let snapshot = await service.refresh()

        #expect(snapshot.balanceCents == 325)
        #expect(transport.paths() == ["POST /api/employee/sessions/renew", "GET /api/employee/pockets"])
        #expect(transport.requests.get()[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(validRefresh)")
        #expect(tokens.load() == AuthTokens(token: newAccess, refreshToken: newRefresh))
    }

    @Test func rejectedRefreshTokenRequiresSignInAndKeepsLastBalance() async {
        let transport = FakeTransport(["POST /api/employee/sessions/renew": [FakeResponse(status: 401, json: "{}")]])
        let previous = BudgetSnapshot(balanceCents: 1000, fetchedAt: now.addingTimeInterval(-3600))
        let (service, tokens, _) = makeService(
            transport,
            tokens: AuthTokens(token: expiredAccess, refreshToken: validRefresh),
            snapshot: previous
        )

        let snapshot = await service.refresh()

        #expect(snapshot == BudgetSnapshot(balanceCents: 1000, fetchedAt: previous.fetchedAt, problem: .signInRequired))
        #expect(tokens.load() == nil)
        #expect(AppLink.widgetTap(for: snapshot) == .signIn)
    }

    @Test func rejectedRefreshTokenUsesTokensRenewedByOtherProcess() async {
        let stored = AuthTokens(token: expiredAccess, refreshToken: validRefresh)
        let otherProcessTokens = AuthTokens(token: newAccess, refreshToken: newRefresh)
        let tokenStore = MemoryTokenStore(stored)
        let transport = RenewRaceTransport(tokenStore: tokenStore, otherProcessTokens: otherProcessTokens)
        let service = BudgetService(
            api: CoverflexAPI(transport: transport),
            tokens: tokenStore,
            snapshots: MemorySnapshotStore(),
            now: { now }
        )

        let snapshot = await service.refresh()

        #expect(snapshot.balanceCents == 325)
        #expect(snapshot.problem == nil)
        #expect(tokenStore.load() == otherProcessTokens)
    }

    @Test func concurrentRefreshesShareOneRenewal() async {
        let fake = FakeTransport([
            "POST /api/employee/sessions/renew": [FakeResponse(status: 200, json: renewJSON), FakeResponse(status: 401, json: "{}")],
            "GET /api/employee/pockets": [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let transport = GatedTransport(fake)
        let tokens = MemoryTokenStore(AuthTokens(token: expiredAccess, refreshToken: validRefresh))
        let service = BudgetService(api: CoverflexAPI(transport: transport), tokens: tokens, snapshots: MemorySnapshotStore(), now: { now })

        async let first = service.refresh()
        var arrivals = transport.arrivals.makeAsyncIterator()
        _ = await arrivals.next()
        async let second = service.refresh()
        try? await Task.sleep(for: .milliseconds(20))
        transport.releaseAll()
        _ = await arrivals.next()
        transport.releaseAll()

        let results = await [first, second]
        #expect(results.allSatisfy { $0.balanceCents == 325 && $0.problem == nil })
        #expect(fake.paths() == ["POST /api/employee/sessions/renew", "GET /api/employee/pockets"])
        #expect(tokens.load() == AuthTokens(token: newAccess, refreshToken: newRefresh))
    }

    @Test func signOutDuringRenewalDoesNotRestoreSession() async {
        let fake = FakeTransport([
            "POST /api/employee/sessions/renew": [FakeResponse(status: 200, json: renewJSON)],
            "GET /api/employee/pockets": [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let transport = GatedTransport(fake)
        let tokens = MemoryTokenStore(AuthTokens(token: expiredAccess, refreshToken: validRefresh))
        let snapshots = MemorySnapshotStore()
        let service = BudgetService(api: CoverflexAPI(transport: transport), tokens: tokens, snapshots: snapshots, now: { now })

        async let pending = service.refresh()
        var arrivals = transport.arrivals.makeAsyncIterator()
        _ = await arrivals.next()
        await service.signOut()
        transport.releaseAll()
        _ = await pending

        #expect(tokens.load() == nil)
        #expect(snapshots.load() == BudgetSnapshot(problem: .signInRequired))
    }

    @Test func rateLimitedRenewalKeepsTokens() async {
        let transport = FakeTransport(["POST /api/employee/sessions/renew": [FakeResponse(status: 429, json: "{}")]])
        let stored = AuthTokens(token: expiredAccess, refreshToken: validRefresh)
        let (service, tokens, _) = makeService(transport, tokens: stored)

        let snapshot = await service.refresh()

        guard case .fetchFailed = snapshot.problem else {
            Issue.record("Expected fetchFailed, got \(String(describing: snapshot.problem))")
            return
        }
        #expect(tokens.load() == stored)
    }

    @Test func expiredRefreshTokenRequiresSignInWithoutNetwork() async {
        let transport = FakeTransport([:])
        let expiredRefresh = makeJWT(exp: now.addingTimeInterval(-1))
        let (service, _, _) = makeService(transport, tokens: AuthTokens(token: expiredAccess, refreshToken: expiredRefresh))

        let snapshot = await service.refresh()

        #expect(snapshot.problem == .signInRequired)
        #expect(transport.paths().isEmpty)
    }

    @Test func missingTokensRequireSignIn() async {
        let (service, _, _) = makeService(FakeTransport([:]), tokens: nil)
        #expect(await service.refresh().problem == .signInRequired)
    }

    @Test func networkFailureKeepsBalanceAndTokens() async {
        let transport = FakeTransport([:])
        transport.offline = true
        let stored = AuthTokens(token: validAccess, refreshToken: validRefresh)
        let (service, tokens, _) = makeService(transport, tokens: stored, snapshot: BudgetSnapshot(balanceCents: 500, fetchedAt: now))

        let snapshot = await service.refresh()

        #expect(snapshot.balanceCents == 500)
        guard case .fetchFailed = snapshot.problem else {
            Issue.record("Expected fetchFailed, got \(String(describing: snapshot.problem))")
            return
        }
        #expect(tokens.load() == stored)
        #expect(AppLink.widgetTap(for: snapshot) == .openCoverflex)
    }

    @Test func revokedAccessTokenRenewsOnceAndRetries() async {
        let transport = FakeTransport([
            "GET /api/employee/pockets": [FakeResponse(status: 401, json: "{}"), FakeResponse(status: 200, json: pocketsJSON)],
            "POST /api/employee/sessions/renew": [FakeResponse(status: 200, json: renewJSON)],
        ])
        let (service, _, _) = makeService(transport, tokens: AuthTokens(token: validAccess, refreshToken: validRefresh))

        let snapshot = await service.refresh()

        #expect(snapshot.balanceCents == 325)
        #expect(transport.paths() == [
            "GET /api/employee/pockets", "POST /api/employee/sessions/renew", "GET /api/employee/pockets",
        ])
    }

    @Test func refreshIfOlderSkipsFetchForRecentSnapshot() async {
        let transport = FakeTransport([:])
        let recent = BudgetSnapshot(balanceCents: 700, fetchedAt: now.addingTimeInterval(-60))
        let (service, _, _) = makeService(transport, tokens: AuthTokens(token: validAccess, refreshToken: validRefresh), snapshot: recent)

        #expect(await service.refreshIfOlder(than: 300) == recent)
        #expect(transport.paths().isEmpty)
    }

    @Test func missingMealsPocketIsFetchFailure() async {
        let transport = FakeTransport(["GET /api/employee/pockets": [FakeResponse(status: 200, json: #"{"pockets":[]}"#)]])
        let (service, _, _) = makeService(transport, tokens: AuthTokens(token: validAccess, refreshToken: validRefresh))

        guard case .fetchFailed = await service.refresh().problem else {
            Issue.record("Expected fetchFailed")
            return
        }
    }
}
