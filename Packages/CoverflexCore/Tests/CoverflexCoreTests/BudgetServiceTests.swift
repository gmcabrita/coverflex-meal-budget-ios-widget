import Foundation
import Security
import Testing
@testable import CoverflexCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let validAccess = makeJWT(exp: now.addingTimeInterval(3600))
private let expiredAccess = makeJWT(exp: now.addingTimeInterval(-10))
private let validRefresh = makeJWT(exp: now.addingTimeInterval(86400 * 30))
private let expiredRefresh = makeJWT(exp: now.addingTimeInterval(-1))
private let newAccess = makeJWT(exp: now.addingTimeInterval(7200))
private let newRefresh = makeJWT(exp: now.addingTimeInterval(86400 * 60))

private let pocketsJSON = #"{"pockets":[{"type":"benefits","balance":{"amount":5000}},{"type":"meals","balance":{"amount":325}}]}"#
private let tokensJSON = "{\"token\":\"\(newAccess)\",\"refresh_token\":\"\(newRefresh)\"}"
private let newTokens = AuthTokens(token: newAccess, refreshToken: newRefresh)

private let renewPath = "POST /api/employee/sessions/renew"
private let loginPath = "POST /api/employee/sessions"
private let trustPath = "POST /api/employee/sessions/trust-user-agent"
private let pocketsPath = "GET /api/employee/pockets"

private let credentials = Credentials(email: "e@x.pt", password: "pw", userAgentToken: "uat")

private func makeSession(access: String = validAccess, refresh: String = validRefresh) -> StoredSession {
    StoredSession(credentials: credentials, tokens: AuthTokens(token: access, refreshToken: refresh))
}

private func makeService(
    _ transport: some HTTPTransport,
    session: StoredSession?,
    snapshot: BudgetSnapshot = BudgetSnapshot()
) -> (BudgetService, MemoryStore<StoredSession>, MemorySnapshotStore) {
    let sessions = MemoryStore<StoredSession>(session)
    let snapshots = MemorySnapshotStore(snapshot)
    let service = BudgetService(api: CoverflexAPI(transport: transport), sessions: sessions, snapshots: snapshots, now: { now })
    return (service, sessions, snapshots)
}

private func expectFetchFailed(_ snapshot: BudgetSnapshot, sourceLocation: SourceLocation = #_sourceLocation) {
    guard case .fetchFailed = snapshot.problem else {
        Issue.record("Expected fetchFailed, got \(String(describing: snapshot.problem))", sourceLocation: sourceLocation)
        return
    }
}

/// Simulates the other process renewing first: while this renew request is in flight,
/// the store receives new tokens and the server rejects the spent refresh token.
private final class RenewRaceTransport: HTTPTransport, @unchecked Sendable {
    let sessions: MemoryStore<StoredSession>

    init(sessions: MemoryStore<StoredSession>) { self.sessions = sessions }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let isRenew = request.url!.path().hasSuffix("/renew")
        if isRenew {
            sessions.value.update { $0?.tokens = newTokens }
        } else {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(newAccess)")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: isRenew ? 401 : 200, httpVersion: nil, headerFields: nil)!
        return (Data((isRenew ? "{}" : pocketsJSON).utf8), response)
    }
}

@Suite struct RefreshTests {
    @Test func usesCachedAccessTokenWhenValid() async {
        let transport = FakeTransport([pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)]])
        let (service, _, _) = makeService(transport, session: makeSession())

        let snapshot = await service.refresh()

        #expect(snapshot == BudgetSnapshot(balanceCents: 325, fetchedAt: now, problem: nil))
        #expect(transport.paths() == [pocketsPath])
        #expect(transport.requests.get()[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(validAccess)")
    }

    @Test func renewsExpiredAccessTokenAndKeepsSessionID() async {
        let transport = FakeTransport([
            renewPath: [FakeResponse(status: 200, json: tokensJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let session = makeSession(access: expiredAccess)
        let (service, sessions, _) = makeService(transport, session: session)

        #expect(await service.refresh().balanceCents == 325)
        #expect(transport.paths() == [renewPath, pocketsPath])
        let renew = transport.requests.get()[0]
        #expect(renew.value(forHTTPHeaderField: "Authorization") == "Bearer \(validRefresh)")
        #expect(renew.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sessions.value.get() == StoredSession(id: session.id, credentials: credentials, tokens: newTokens))
    }

    @Test func rejectedRefreshTokenLogsInWithSavedCredentials() async throws {
        let transport = FakeTransport([
            renewPath: [FakeResponse(status: 401, json: "{}")],
            loginPath: [FakeResponse(status: 200, json: tokensJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let (service, sessions, _) = makeService(transport, session: makeSession(access: expiredAccess))

        let snapshot = await service.refresh()

        #expect(snapshot.balanceCents == 325)
        #expect(snapshot.problem == nil)
        #expect(transport.paths() == [renewPath, loginPath, pocketsPath])
        let body = try JSONDecoder().decode([String: String].self, from: transport.requests.get()[1].httpBody!)
        #expect(body == ["email": "e@x.pt", "password": "pw", "user_agent_token": "uat"])
        #expect(sessions.value.get()?.tokens == newTokens)
    }

    @Test func expiredRefreshTokenLogsInWithoutRenewRequest() async {
        let transport = FakeTransport([
            loginPath: [FakeResponse(status: 200, json: tokensJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let (service, _, _) = makeService(transport, session: makeSession(access: expiredAccess, refresh: expiredRefresh))

        #expect(await service.refresh().balanceCents == 325)
        #expect(transport.paths() == [loginPath, pocketsPath])
    }

    @Test func refreshTokenWithoutReadableExpiryIsSentToServer() async {
        let transport = FakeTransport([
            renewPath: [FakeResponse(status: 200, json: tokensJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let (service, _, _) = makeService(transport, session: makeSession(access: "opaque-access", refresh: "opaque-refresh"))

        #expect(await service.refresh().balanceCents == 325)
        #expect(transport.requests.get()[0].value(forHTTPHeaderField: "Authorization") == "Bearer opaque-refresh")
    }

    @Test(arguments: [429, 404, 500])
    func temporaryRenewFailureKeepsSessionWithoutLogin(status: Int) async {
        let transport = FakeTransport([renewPath: [FakeResponse(status: status, json: "{}")]])
        let session = makeSession(access: expiredAccess)
        let (service, sessions, _) = makeService(transport, session: session)

        expectFetchFailed(await service.refresh())
        #expect(transport.paths() == [renewPath])
        #expect(sessions.value.get() == session)
    }

    @Test func rejectedLoginRequiresSignInAndKeepsLastBalance() async {
        let transport = FakeTransport([
            renewPath: [FakeResponse(status: 401, json: "{}")],
            loginPath: [FakeResponse(status: 401, json: "bad password")],
        ])
        let previous = BudgetSnapshot(balanceCents: 1000, fetchedAt: now.addingTimeInterval(-3600))
        let (service, sessions, _) = makeService(transport, session: makeSession(access: expiredAccess), snapshot: previous)

        let snapshot = await service.refresh()

        #expect(snapshot.needsSignIn)
        #expect(snapshot.balanceCents == 1000)
        #expect(snapshot.fetchedAt == previous.fetchedAt)
        #expect(sessions.value.get() == nil)
        #expect(AppLink.widgetTap(for: snapshot) == .signIn)
    }

    @Test func loginAskingForOTPRequiresSignIn() async {
        let transport = FakeTransport([loginPath: [FakeResponse(status: 200, json: #"{"otp_required":true}"#)]])
        let (service, sessions, _) = makeService(transport, session: makeSession(access: expiredAccess, refresh: expiredRefresh))

        #expect(await service.refresh().needsSignIn)
        #expect(sessions.value.get() == nil)
    }

    @Test func unreadableLoginResponseKeepsSession() async {
        let transport = FakeTransport([loginPath: [FakeResponse(status: 200, json: "<html>maintenance</html>")]])
        let session = makeSession(access: expiredAccess, refresh: expiredRefresh)
        let (service, sessions, _) = makeService(transport, session: session)

        expectFetchFailed(await service.refresh())
        #expect(sessions.value.get() == session)
    }

    @Test func rateLimitedLoginKeepsSession() async {
        let transport = FakeTransport([loginPath: [FakeResponse(status: 429, json: "{}")]])
        let session = makeSession(access: expiredAccess, refresh: expiredRefresh)
        let (service, sessions, _) = makeService(transport, session: session)

        expectFetchFailed(await service.refresh())
        #expect(sessions.value.get() == session)
    }

    @Test func rejectedRefreshTokenUsesTokensRenewedByOtherProcess() async {
        let sessions = MemoryStore<StoredSession>(makeSession(access: expiredAccess))
        let service = BudgetService(
            api: CoverflexAPI(transport: RenewRaceTransport(sessions: sessions)),
            sessions: sessions,
            snapshots: MemorySnapshotStore(),
            now: { now }
        )

        let snapshot = await service.refresh()

        #expect(snapshot.balanceCents == 325)
        #expect(snapshot.problem == nil)
        #expect(sessions.value.get()?.tokens == newTokens)
    }

    @Test func missingSessionRequiresSignIn() async {
        let (service, _, _) = makeService(FakeTransport([:]), session: nil)
        #expect(await service.refresh().needsSignIn)
    }

    @Test func unreadableSessionKeepsBalanceAndSession() async {
        let transport = FakeTransport([:])
        let session = makeSession()
        let (service, sessions, _) = makeService(transport, session: session, snapshot: BudgetSnapshot(balanceCents: 500, fetchedAt: now))
        sessions.readError.set(KeychainError(status: errSecInteractionNotAllowed))

        let snapshot = await service.refresh()

        #expect(snapshot.balanceCents == 500)
        expectFetchFailed(snapshot)
        #expect(transport.paths().isEmpty)
        #expect(sessions.value.get() == session)
        #expect(await service.hasSession)
    }

    @Test func networkFailureKeepsBalanceAndSession() async {
        let transport = FakeTransport([:])
        transport.offline = true
        let session = makeSession()
        let (service, sessions, _) = makeService(transport, session: session, snapshot: BudgetSnapshot(balanceCents: 500, fetchedAt: now))

        let snapshot = await service.refresh()

        #expect(snapshot.balanceCents == 500)
        expectFetchFailed(snapshot)
        #expect(sessions.value.get() == session)
        #expect(AppLink.widgetTap(for: snapshot) == .openCoverflex)
    }

    @Test func revokedAccessTokenRenewsOnceAndRetries() async {
        let transport = FakeTransport([
            pocketsPath: [FakeResponse(status: 401, json: "{}"), FakeResponse(status: 200, json: pocketsJSON)],
            renewPath: [FakeResponse(status: 200, json: tokensJSON)],
        ])
        let (service, _, _) = makeService(transport, session: makeSession())

        #expect(await service.refresh().balanceCents == 325)
        #expect(transport.paths() == [pocketsPath, renewPath, pocketsPath])
    }

    @Test func refreshIfOlderSkipsFetchForRecentSnapshot() async {
        let transport = FakeTransport([:])
        let recent = BudgetSnapshot(balanceCents: 700, fetchedAt: now.addingTimeInterval(-60))
        let (service, _, _) = makeService(transport, session: makeSession(), snapshot: recent)

        #expect(await service.refreshIfOlder(than: 300) == recent)
        #expect(transport.paths().isEmpty)
    }

    @Test func missingMealsPocketIsFetchFailure() async {
        let transport = FakeTransport([pocketsPath: [FakeResponse(status: 200, json: #"{"pockets":[]}"#)]])
        let (service, _, _) = makeService(transport, session: makeSession())

        expectFetchFailed(await service.refresh())
    }
}

@Suite struct SessionRaceTests {
    @Test func concurrentRefreshesShareOneRenewal() async {
        let fake = FakeTransport([
            renewPath: [FakeResponse(status: 200, json: tokensJSON), FakeResponse(status: 401, json: "{}")],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let transport = GatedTransport(fake)
        let (service, sessions, _) = makeService(transport, session: makeSession(access: expiredAccess))
        let (joinStream, joinContinuation) = AsyncStream<Void>.makeStream()
        await service.observeJoins { joinContinuation.yield() }
        var joins = joinStream.makeAsyncIterator()

        async let first = service.refresh()
        var arrivals = transport.arrivals.makeAsyncIterator()
        _ = await arrivals.next()
        async let second = service.refresh()
        // Release the renew request only after the second call waits for the first refresh.
        // Earlier, the second call could start its own refresh.
        _ = await joins.next()
        transport.releaseAll()

        let results = await [first, second]
        #expect(results.allSatisfy { $0.balanceCents == 325 && $0.problem == nil })
        #expect(fake.paths() == [renewPath, pocketsPath])
        #expect(sessions.value.get()?.tokens == newTokens)
    }

    @Test func signOutDuringRenewalDoesNotRestoreSession() async {
        let fake = FakeTransport([
            renewPath: [FakeResponse(status: 200, json: tokensJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let transport = GatedTransport(fake)
        let (service, sessions, snapshots) = makeService(transport, session: makeSession(access: expiredAccess))

        async let pending = service.refresh()
        var arrivals = transport.arrivals.makeAsyncIterator()
        _ = await arrivals.next()
        await service.signOut()
        transport.releaseAll()
        _ = await pending

        #expect(sessions.value.get() == nil)
        #expect(snapshots.load() == BudgetSnapshot(problem: .signInRequired("Signed out.")))
    }

    /// The app signs out while the widget process renews. The widget's service never sees `signOut()`.
    @Test func otherProcessSignOutDuringRenewalDoesNotRestoreSession() async {
        let fake = FakeTransport([
            renewPath: [FakeResponse(status: 200, json: tokensJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let transport = GatedTransport(fake)
        let (widgetService, sessions, snapshots) = makeService(transport, session: makeSession(access: expiredAccess))

        async let pending = widgetService.refresh()
        var arrivals = transport.arrivals.makeAsyncIterator()
        _ = await arrivals.next()
        sessions.clear()
        snapshots.save(BudgetSnapshot(problem: .signInRequired("Signed out.")))
        transport.releaseAll()
        _ = await pending

        #expect(sessions.value.get() == nil)
        #expect(snapshots.load() == BudgetSnapshot(problem: .signInRequired("Signed out.")))
    }

    /// The widget's login fails while the app stores a new session. The new session stays.
    @Test func failedLoginDoesNotRemoveNewerSession() async {
        let fake = FakeTransport([loginPath: [FakeResponse(status: 401, json: "{}")]])
        let transport = GatedTransport(fake)
        let (widgetService, sessions, snapshots) = makeService(
            transport,
            session: makeSession(access: expiredAccess, refresh: expiredRefresh)
        )
        let newer = StoredSession(credentials: credentials, tokens: newTokens)

        async let pending = widgetService.refresh()
        var arrivals = transport.arrivals.makeAsyncIterator()
        _ = await arrivals.next()
        sessions.save(newer)
        transport.releaseAll()
        _ = await pending

        #expect(sessions.value.get() == newer)
        #expect(!snapshots.load().needsSignIn)
    }
}

@Suite struct SignInFlowTests {
    @Test func otpSignInTrustsDeviceAndStoresSession() async throws {
        let transport = FakeTransport([
            loginPath: [FakeResponse(status: 422, json: "otp sent"), FakeResponse(status: 200, json: tokensJSON)],
            trustPath: [FakeResponse(status: 200, json: #"{"user_agent_token":"new-uat"}"#)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let (service, sessions, snapshots) = makeService(transport, session: nil)

        #expect(try await service.startSignIn(email: "e@x.pt", password: "pw") == false)
        try await service.finishSignIn(email: "e@x.pt", password: "pw", otp: "123456")

        #expect(transport.paths() == [loginPath, loginPath, trustPath, pocketsPath])
        let trust = transport.requests.get()[2]
        #expect(trust.value(forHTTPHeaderField: "Authorization") == "Bearer \(newAccess)")
        #expect(trust.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(sessions.value.get()?.credentials == Credentials(email: "e@x.pt", password: "pw", userAgentToken: "new-uat"))
        #expect(sessions.value.get()?.tokens == newTokens)
        #expect(snapshots.load().balanceCents == 325)
    }

    @Test func signInWithSavedUserAgentTokenSkipsOTP() async throws {
        let transport = FakeTransport([
            loginPath: [FakeResponse(status: 200, json: tokensJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let old = makeSession()
        let (service, sessions, _) = makeService(transport, session: old)

        #expect(try await service.startSignIn(email: "e@x.pt", password: "new-pw"))

        let body = try JSONDecoder().decode([String: String].self, from: transport.requests.get()[0].httpBody!)
        #expect(body["user_agent_token"] == "uat")
        #expect(sessions.value.get()?.credentials == Credentials(email: "e@x.pt", password: "new-pw", userAgentToken: "uat"))
        #expect(sessions.value.get()?.id != old.id)
        #expect(transport.paths() == [loginPath, pocketsPath])
    }
}
