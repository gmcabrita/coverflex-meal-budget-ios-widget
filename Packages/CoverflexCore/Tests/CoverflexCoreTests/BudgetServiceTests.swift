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
/// The renew endpoint wraps the tokens in `data` and names the access token `access_token`.
private let renewJSON = "{\"data\":{\"access_token\":\"\(newAccess)\",\"refresh_token\":\"\(newRefresh)\"}}"
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
    snapshot: BudgetSnapshot = BudgetSnapshot(),
    renewIssues: MemoryRenewIssueStore = MemoryRenewIssueStore()
) -> (BudgetService, MemoryStore<StoredSession>, MemorySnapshotStore) {
    let sessions = MemoryStore<StoredSession>(session)
    let snapshots = MemorySnapshotStore(snapshot)
    let service = BudgetService(
        api: CoverflexAPI(transport: transport),
        sessions: sessions,
        snapshots: snapshots,
        renewIssues: renewIssues,
        now: { now }
    )
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

/// Answers every request with 200 and `response`, after it runs `hook`.
private final class HookTransport: HTTPTransport, @unchecked Sendable {
    let response: String
    let hook: @Sendable () async -> Void

    init(response: String, hook: @escaping @Sendable () async -> Void) {
        self.response = response
        self.hook = hook
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        await hook()
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(response.utf8), http)
    }
}

@Suite struct RefreshTests {
    @Test func usesCachedAccessTokenWhenValid() async {
        let transport = FakeTransport([pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)]])
        let (service, _, _) = makeService(transport, session: makeSession())

        let snapshot = await service.refresh(trigger: .app)

        #expect(snapshot == BudgetSnapshot(balanceCents: 325, fetchedAt: now, problem: nil))
        #expect(transport.paths() == [pocketsPath])
        #expect(transport.requests.get()[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(validAccess)")
    }

    @Test func renewsExpiredAccessTokenAndKeepsSessionID() async {
        let transport = FakeTransport([
            renewPath: [FakeResponse(status: 200, json: renewJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let session = makeSession(access: expiredAccess)
        let (service, sessions, _) = makeService(transport, session: session)

        #expect(await service.refresh(trigger: .app).balanceCents == 325)
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

        let snapshot = await service.refresh(trigger: .app)

        #expect(snapshot.balanceCents == 325)
        #expect(snapshot.problem == nil)
        #expect(transport.paths() == [renewPath, loginPath, pocketsPath])
        let body = try JSONDecoder().decode([String: String].self, from: transport.requests.get()[1].httpBody!)
        #expect(body == ["email": "e@x.pt", "password": "pw", "user_agent_token": "uat"])
        #expect(sessions.value.get()?.tokens == newTokens)
    }

    @Test func unreadableRenewResponseLogsInWithSavedCredentials() async throws {
        let transport = FakeTransport([
            renewPath: [FakeResponse(status: 200, json: #"{"data":{}}"#)],
            loginPath: [FakeResponse(status: 200, json: tokensJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let renewIssues = MemoryRenewIssueStore()
        let (service, sessions, _) = makeService(transport, session: makeSession(access: expiredAccess), renewIssues: renewIssues)

        let snapshot = await service.refresh(trigger: .widgetButton)

        #expect(snapshot.balanceCents == 325)
        #expect(snapshot.problem == nil)
        #expect(transport.paths() == [renewPath, loginPath, pocketsPath])
        #expect(sessions.value.get()?.tokens == newTokens)
        let issue = try #require(renewIssues.load())
        #expect(issue.date == now)
        #expect(issue.trigger == .widgetButton)
        #expect(issue.refreshTokenChangedDuringRequest == false)
        #expect(issue.nextStep == "Logged in with the saved credentials.")
        #expect(issue.error.contains("Response keys: [data]. data keys: []."))
    }

    @Test(arguments: [
        FakeResponse(status: 401, json: "{}"),
        FakeResponse(status: 200, json: #"{"otp_required":true}"#),
        FakeResponse(status: 503, json: "{}"),
    ])
    func renewIssueRecordsFailedLoginFallback(login: FakeResponse) async throws {
        let transport = FakeTransport([
            renewPath: [FakeResponse(status: 401, json: "{}")],
            loginPath: [login],
        ])
        let renewIssues = MemoryRenewIssueStore()
        let (service, _, _) = makeService(transport, session: makeSession(access: expiredAccess), renewIssues: renewIssues)

        #expect(await service.refresh(trigger: .app).problem != nil)
        let issue = try #require(renewIssues.load())
        #expect(issue.nextStep.hasPrefix("Login with the saved credentials failed: "))
    }

    @Test func temporaryRenewFailureRecordsIssue() async throws {
        let transport = FakeTransport([renewPath: [FakeResponse(status: 500, json: "{}")]])
        let renewIssues = MemoryRenewIssueStore()
        let (service, _, _) = makeService(transport, session: makeSession(access: expiredAccess), renewIssues: renewIssues)

        await service.refresh(trigger: .shortcut)

        let issue = try #require(renewIssues.load())
        #expect(issue.trigger == .shortcut)
        #expect(issue.nextStep == "Kept the session for a later retry.")
        #expect(issue.error == "Coverflex returned HTTP 500. Response keys: [].")
    }

    @Test func renewIssueRecordsTokensSavedByOtherProcess() async throws {
        let sessions = MemoryStore<StoredSession>(makeSession(access: expiredAccess))
        let renewIssues = MemoryRenewIssueStore()
        let service = BudgetService(
            api: CoverflexAPI(transport: RenewRaceTransport(sessions: sessions)),
            sessions: sessions,
            snapshots: MemorySnapshotStore(),
            renewIssues: renewIssues,
            now: { now }
        )

        #expect(await service.refresh(trigger: .app).balanceCents == 325)
        let issue = try #require(renewIssues.load())
        #expect(issue.refreshTokenChangedDuringRequest == true)
        #expect(issue.nextStep == "Used the tokens that another process saved.")
    }

    @Test func newerStoredRenewIssueIsKept() async {
        let newer = RenewIssue(date: now.addingTimeInterval(5), trigger: .widgetButton, error: "x", refreshTokenChangedDuringRequest: nil, nextStep: "y")
        let renewIssues = MemoryRenewIssueStore(newer)
        let transport = FakeTransport([renewPath: [FakeResponse(status: 500, json: "{}")]])
        let (service, _, _) = makeService(transport, session: makeSession(access: expiredAccess), renewIssues: renewIssues)

        await service.refresh(trigger: .app)

        #expect(renewIssues.load() == newer)
    }

    /// The widget process records a renew issue while the app process waits for its own fetch.
    /// The app then saves the snapshot it loaded before the issue. The issue must stay.
    @Test func otherProcessRefreshDoesNotEraseRenewIssue() async throws {
        let snapshots = MemorySnapshotStore()
        let renewIssues = MemoryRenewIssueStore()
        let widget = BudgetService(
            api: CoverflexAPI(transport: FakeTransport([
                renewPath: [FakeResponse(status: 200, json: "{}")],
                loginPath: [FakeResponse(status: 200, json: tokensJSON)],
                pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
            ])),
            sessions: MemoryStore(makeSession(access: expiredAccess)),
            snapshots: snapshots,
            renewIssues: renewIssues,
            now: { now }
        )
        let app = BudgetService(
            api: CoverflexAPI(transport: HookTransport(response: pocketsJSON) { await widget.refresh(trigger: .widgetButton) }),
            sessions: MemoryStore(makeSession()),
            snapshots: snapshots,
            renewIssues: renewIssues,
            now: { now }
        )

        #expect(await app.refresh(trigger: .app).balanceCents == 325)

        #expect(try #require(renewIssues.load()).trigger == .widgetButton)
        #expect(await app.lastRenewIssue?.trigger == .widgetButton)
    }

    @Test func renewErrorBodyStaysOutOfDiagnostics() async throws {
        let secretBody = #"{"error":"bad","refresh_token":"SECRET-TOKEN","email":"SECRET@x.pt"}"#
        let transport = FakeTransport([
            renewPath: [FakeResponse(status: 401, json: secretBody)],
            loginPath: [FakeResponse(status: 401, json: secretBody)],
        ])
        let renewIssues = MemoryRenewIssueStore()
        let (service, _, _) = makeService(transport, session: makeSession(access: expiredAccess), renewIssues: renewIssues)

        let snapshot = await service.refresh(trigger: .app)
        let issue = try #require(renewIssues.load())
        let report = DebugReport.text(
            snapshot: snapshot,
            lastRenewIssue: issue,
            hasSession: false,
            accessTokenExpiry: nil,
            refreshTokenExpiry: nil,
            environment: DebugReport.Environment(appVersion: "1", systemVersion: "iOS", generatedAt: now)
        )

        #expect(report.contains(#"Coverflex returned HTTP 401. Response keys: [email, error, refresh_token]. error: "bad""#))
        #expect(!report.contains("SECRET"))
    }

    @Test func errorFieldValuesAreShownWithSecretsRedacted() {
        let body = #"{"errors":{"detail":"Unauthorized","refresh_token":"SECRET","fields":[{"password":"SECRET"}]},"message":"Try again","token":"SECRET"}"#

        let text = CoverflexAPI.describeResponse(Data(body.utf8))

        #expect(text == #"Response keys: [errors, message, token]. errors: {"detail":"Unauthorized","fields":[{"password":"<redacted>"}],"refresh_token":"<redacted>"} message: "Try again""#)
    }

    @Test func unreadableLoginBodyStaysOutOfError() async {
        let transport = FakeTransport([loginPath: [FakeResponse(status: 200, json: "SECRET-TOKEN")]])

        await #expect(throws: CoverflexError.unexpectedResponse("Response is not a JSON object (12 bytes).")) {
            try await CoverflexAPI(transport: transport).logIn(credentials)
        }
    }

    @Test func decodeErrorListsResponseKeysWithoutValues() async {
        let transport = FakeTransport([renewPath: [FakeResponse(status: 200, json: #"{"secret":"abc","access_token":"xyz"}"#)]])
        let api = CoverflexAPI(transport: transport)

        do {
            _ = try await api.renew(refreshToken: validRefresh)
            Issue.record("Expected an error")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Response keys: [access_token, secret]."))
            #expect(!message.contains("xyz"))
        }
    }

    @Test func expiredRefreshTokenLogsInWithoutRenewRequest() async {
        let transport = FakeTransport([
            loginPath: [FakeResponse(status: 200, json: tokensJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let (service, _, _) = makeService(transport, session: makeSession(access: expiredAccess, refresh: expiredRefresh))

        #expect(await service.refresh(trigger: .app).balanceCents == 325)
        #expect(transport.paths() == [loginPath, pocketsPath])
    }

    @Test func refreshTokenWithoutReadableExpiryIsSentToServer() async {
        let transport = FakeTransport([
            renewPath: [FakeResponse(status: 200, json: renewJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let (service, _, _) = makeService(transport, session: makeSession(access: "opaque-access", refresh: "opaque-refresh"))

        #expect(await service.refresh(trigger: .app).balanceCents == 325)
        #expect(transport.requests.get()[0].value(forHTTPHeaderField: "Authorization") == "Bearer opaque-refresh")
    }

    @Test(arguments: [429, 404, 500])
    func temporaryRenewFailureKeepsSessionWithoutLogin(status: Int) async {
        let transport = FakeTransport([renewPath: [FakeResponse(status: status, json: "{}")]])
        let session = makeSession(access: expiredAccess)
        let (service, sessions, _) = makeService(transport, session: session)

        expectFetchFailed(await service.refresh(trigger: .app))
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

        let snapshot = await service.refresh(trigger: .app)

        #expect(snapshot.needsSignIn)
        #expect(snapshot.balanceCents == 1000)
        #expect(snapshot.fetchedAt == previous.fetchedAt)
        #expect(sessions.value.get() == nil)
        #expect(AppLink.widgetTap(for: snapshot) == .signIn)
    }

    @Test func loginAskingForOTPRequiresSignIn() async {
        let transport = FakeTransport([loginPath: [FakeResponse(status: 200, json: #"{"otp_required":true}"#)]])
        let (service, sessions, _) = makeService(transport, session: makeSession(access: expiredAccess, refresh: expiredRefresh))

        #expect(await service.refresh(trigger: .app).needsSignIn)
        #expect(sessions.value.get() == nil)
    }

    @Test func unreadableLoginResponseKeepsSession() async {
        let transport = FakeTransport([loginPath: [FakeResponse(status: 200, json: "<html>maintenance</html>")]])
        let session = makeSession(access: expiredAccess, refresh: expiredRefresh)
        let (service, sessions, _) = makeService(transport, session: session)

        expectFetchFailed(await service.refresh(trigger: .app))
        #expect(sessions.value.get() == session)
    }

    @Test func rateLimitedLoginKeepsSession() async {
        let transport = FakeTransport([loginPath: [FakeResponse(status: 429, json: "{}")]])
        let session = makeSession(access: expiredAccess, refresh: expiredRefresh)
        let (service, sessions, _) = makeService(transport, session: session)

        expectFetchFailed(await service.refresh(trigger: .app))
        #expect(sessions.value.get() == session)
    }

    @Test func rejectedRefreshTokenUsesTokensRenewedByOtherProcess() async {
        let sessions = MemoryStore<StoredSession>(makeSession(access: expiredAccess))
        let service = BudgetService(
            api: CoverflexAPI(transport: RenewRaceTransport(sessions: sessions)),
            sessions: sessions,
            snapshots: MemorySnapshotStore(),
            renewIssues: MemoryRenewIssueStore(),
            now: { now }
        )

        let snapshot = await service.refresh(trigger: .app)

        #expect(snapshot.balanceCents == 325)
        #expect(snapshot.problem == nil)
        #expect(sessions.value.get()?.tokens == newTokens)
    }

    @Test func missingSessionRequiresSignIn() async {
        let (service, _, _) = makeService(FakeTransport([:]), session: nil)
        #expect(await service.refresh(trigger: .app).needsSignIn)
    }

    @Test func unreadableSessionKeepsBalanceAndSession() async {
        let transport = FakeTransport([:])
        let session = makeSession()
        let (service, sessions, _) = makeService(transport, session: session, snapshot: BudgetSnapshot(balanceCents: 500, fetchedAt: now))
        sessions.readError.set(KeychainError(status: errSecInteractionNotAllowed))

        let snapshot = await service.refresh(trigger: .app)

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

        let snapshot = await service.refresh(trigger: .app)

        #expect(snapshot.balanceCents == 500)
        expectFetchFailed(snapshot)
        #expect(sessions.value.get() == session)
        #expect(AppLink.widgetTap(for: snapshot) == .openCoverflex)
    }

    @Test func revokedAccessTokenRenewsOnceAndRetries() async {
        let transport = FakeTransport([
            pocketsPath: [FakeResponse(status: 401, json: "{}"), FakeResponse(status: 200, json: pocketsJSON)],
            renewPath: [FakeResponse(status: 200, json: renewJSON)],
        ])
        let (service, _, _) = makeService(transport, session: makeSession())

        #expect(await service.refresh(trigger: .app).balanceCents == 325)
        #expect(transport.paths() == [pocketsPath, renewPath, pocketsPath])
    }

    @Test func refreshIfOlderSkipsFetchForRecentSnapshot() async {
        let transport = FakeTransport([:])
        let recent = BudgetSnapshot(balanceCents: 700, fetchedAt: now.addingTimeInterval(-60))
        let (service, _, _) = makeService(transport, session: makeSession(), snapshot: recent)

        #expect(await service.refreshIfOlder(than: 300, trigger: .app) == recent)
        #expect(transport.paths().isEmpty)
    }

    @Test func missingMealsPocketIsFetchFailure() async {
        let transport = FakeTransport([pocketsPath: [FakeResponse(status: 200, json: #"{"pockets":[]}"#)]])
        let (service, _, _) = makeService(transport, session: makeSession())

        expectFetchFailed(await service.refresh(trigger: .app))
    }
}

@Suite struct SessionRaceTests {
    @Test func concurrentRefreshesShareOneRenewal() async {
        let fake = FakeTransport([
            renewPath: [FakeResponse(status: 200, json: renewJSON), FakeResponse(status: 401, json: "{}")],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let transport = GatedTransport(fake)
        let (service, sessions, _) = makeService(transport, session: makeSession(access: expiredAccess))
        let (joinStream, joinContinuation) = AsyncStream<Void>.makeStream()
        await service.observeJoins { joinContinuation.yield() }
        var joins = joinStream.makeAsyncIterator()

        async let first = service.refresh(trigger: .app)
        var arrivals = transport.arrivals.makeAsyncIterator()
        _ = await arrivals.next()
        async let second = service.refresh(trigger: .app)
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
            renewPath: [FakeResponse(status: 200, json: renewJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let transport = GatedTransport(fake)
        let (service, sessions, snapshots) = makeService(transport, session: makeSession(access: expiredAccess))

        async let pending = service.refresh(trigger: .app)
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
            renewPath: [FakeResponse(status: 200, json: renewJSON)],
            pocketsPath: [FakeResponse(status: 200, json: pocketsJSON)],
        ])
        let transport = GatedTransport(fake)
        let (widgetService, sessions, snapshots) = makeService(transport, session: makeSession(access: expiredAccess))

        async let pending = widgetService.refresh(trigger: .app)
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

        async let pending = widgetService.refresh(trigger: .app)
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
