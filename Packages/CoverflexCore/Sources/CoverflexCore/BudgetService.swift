import Foundation
import os

/// Signs in, fetches the meal budget, keeps the Coverflex session alive, and records the result
/// in the snapshot store.
///
/// Access token order, as `getAuthenticationToken` in run-gmc
/// (https://github.com/gmcabrita/run-gmc/tree/49b8808/src/coverflex/util):
/// 1. Stored access token, while it is valid.
/// 2. Renew with the stored refresh token.
/// 3. When Coverflex rejects the refresh token (or it expired), log in with the stored email,
///    password, and user agent token. This needs no OTP code.
/// Only when step 3 is rejected does the user have to sign in again in the app.
/// Temporary failures (network, 5xx, 429, ...) keep everything for the next attempt.
///
/// The app, the widget timeline, and the refresh App Intent all go through this type.
/// Concurrent `refresh()` calls in one process share one fetch, so they do not both spend
/// the same refresh token. The app and the widget extension are separate processes:
/// writes check `StoredSession.id`, so a refresh never undoes a sign-out or a new sign-in.
public actor BudgetService {
    /// Instance used by the app and the widget extension.
    public static let shared = BudgetService()

    /// Renew failures go to Console.app under this subsystem and category.
    private static let logger = Logger(subsystem: "com.gmcabrita.CoverflexBudget", category: "renew")

    /// Renew the access token when it expires within this many seconds.
    static let accessTokenExpiryMargin: TimeInterval = 60

    private let api: CoverflexAPI
    private let sessions: any SecureStore<StoredSession>
    private let snapshots: any SnapshotStore
    private let renewIssues: any RenewIssueStore
    private let now: @Sendable () -> Date

    /// The refresh in progress. Later callers wait for it.
    private var inFlight: Task<BudgetSnapshot, Never>?

    /// Test hook: runs each time a `refresh()` call waits for the refresh in progress.
    private var onJoinInFlight: (@Sendable () -> Void)?

    public init(
        api: CoverflexAPI = CoverflexAPI(),
        sessions: any SecureStore<StoredSession> = KeychainStore.session,
        snapshots: any SnapshotStore = AppGroupSnapshotStore(),
        renewIssues: any RenewIssueStore = AppGroupRenewIssueStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.sessions = sessions
        self.snapshots = snapshots
        self.renewIssues = renewIssues
        self.now = now
    }

    public var snapshot: BudgetSnapshot { snapshots.load() }

    /// The last failed renew request, for the app's diagnostics. Kept after sign-out.
    public var lastRenewIssue: RenewIssue? { renewIssues.load() }

    /// True when a refresh can run without user input.
    /// A read error does not prove that the session is missing, so it counts as a session.
    public var hasSession: Bool {
        do { return try sessions.load() != nil } catch { return true }
    }

    /// Expiry dates read from the stored tokens, for display in the app. Nil when unknown.
    public var tokenExpiry: (access: Date?, refresh: Date?) {
        guard let tokens = currentSession()?.tokens else { return (nil, nil) }
        return (JWT.expirationDate(of: tokens.token), JWT.expirationDate(of: tokens.refreshToken))
    }

    // MARK: - Sign-in

    /// First sign-in step. Returns false when Coverflex sent an OTP code; continue with `finishSignIn`.
    /// Returns true when the stored user agent token for this email let Coverflex skip the OTP.
    public func startSignIn(email: String, password: String) async throws -> Bool {
        let trustedToken = currentSession().flatMap { $0.credentials.email == email ? $0.credentials.userAgentToken : nil }
        switch try await api.signIn(email: email, password: password, userAgentToken: trustedToken) {
        case let .signedIn(tokens):
            let userAgentToken: String
            if let trustedToken {
                userAgentToken = trustedToken
            } else {
                userAgentToken = try await api.trustUserAgent(accessToken: tokens.token)
            }
            try await store(Credentials(email: email, password: password, userAgentToken: userAgentToken), tokens)
            return true
        case .otpRequired:
            return false
        }
    }

    /// Second sign-in step: sends the OTP code, then trusts this client so later logins need no code.
    public func finishSignIn(email: String, password: String, otp: String) async throws {
        let tokens = try await api.signIn(email: email, password: password, otp: otp)
        let userAgentToken = try await api.trustUserAgent(accessToken: tokens.token)
        try await store(Credentials(email: email, password: password, userAgentToken: userAgentToken), tokens)
    }

    private func store(_ credentials: Credentials, _ tokens: AuthTokens) async throws {
        inFlight = nil
        try sessions.save(StoredSession(credentials: credentials, tokens: tokens))
        await refresh(trigger: .signIn)
    }

    /// Removes the session and the cached budget.
    public func signOut() {
        inFlight = nil
        sessions.clear()
        snapshots.save(BudgetSnapshot(problem: .signInRequired("Signed out.")))
    }

    // MARK: - Refresh

    /// Lets tests know when a second `refresh()` call joined the refresh in progress.
    func observeJoins(_ observer: @escaping @Sendable () -> Void) {
        onJoinInFlight = observer
    }

    /// Returns the stored snapshot when it is newer than `maxAge`. Otherwise refreshes.
    /// The widget timeline uses this to skip a second fetch right after the refresh button ran.
    public func refreshIfOlder(than maxAge: TimeInterval, trigger: RefreshTrigger) async -> BudgetSnapshot {
        let current = snapshots.load()
        if current.problem == nil, let fetchedAt = current.fetchedAt, now().timeIntervalSince(fetchedAt) < maxAge {
            return current
        }
        return await refresh(trigger: trigger)
    }

    /// Fetches the meal budget and stores the result.
    /// A failure keeps the last known balance and records the problem.
    /// A caller that joins a refresh in progress gets its result; that refresh keeps its own trigger.
    @discardableResult
    public func refresh(trigger: RefreshTrigger) async -> BudgetSnapshot {
        if let inFlight {
            onJoinInFlight?()
            return await inFlight.value
        }

        let task = Task { await self.performRefresh(trigger: trigger) }
        inFlight = task
        let result = await task.value
        if inFlight == task { inFlight = nil }
        return result
    }

    private func performRefresh(trigger: RefreshTrigger) async -> BudgetSnapshot {
        var snapshot = snapshots.load()
        let session: StoredSession
        do {
            guard let stored = try sessions.load() else {
                snapshot.problem = .signInRequired("No saved Coverflex session.")
                snapshots.save(snapshot)
                return snapshot
            }
            session = stored
        } catch {
            // The session is probably still there (for example, the device was not unlocked
            // since a restart). Keep it and try again on the next refresh.
            snapshot.problem = .fetchFailed("Could not read the saved Coverflex session: \(error.localizedDescription)")
            snapshots.save(snapshot)
            return snapshot
        }

        do {
            snapshot.balanceCents = try await fetchBalanceCents(session, trigger: trigger)
            snapshot.fetchedAt = now()
            snapshot.problem = nil
        } catch let problem {
            snapshot.problem = problem
        }
        // A sign-out or a new sign-in (in any process) replaced the session: drop this result.
        // `.signInRequired` here means this refresh removed its own rejected session, so it is saved.
        guard currentSession()?.id == session.id || snapshot.needsSignIn else { return snapshots.load() }
        snapshots.save(snapshot)
        return snapshot
    }

    private func fetchBalanceCents(_ session: StoredSession, trigger: RefreshTrigger) async throws(BudgetProblem) -> Int {
        if !JWT.isExpired(session.tokens.token, now: now(), margin: Self.accessTokenExpiryMargin) {
            do {
                return try await api.mealBalanceCents(accessToken: session.tokens.token)
            } catch let error where error.isUnauthorized {
                // Coverflex revoked the access token before its expiry. Get a new one and retry.
            } catch {
                throw .fetchFailed(error.localizedDescription)
            }
        }

        let accessToken = try await freshAccessToken(session, trigger: trigger)
        do {
            return try await api.mealBalanceCents(accessToken: accessToken)
        } catch {
            throw .fetchFailed(error.localizedDescription)
        }
    }

    /// Renews with the refresh token. Logs in with the credentials only when the refresh token is dead.
    /// Records a `RenewIssue` when the renew request fails.
    private func freshAccessToken(_ session: StoredSession, trigger: RefreshTrigger) async throws(BudgetProblem) -> String {
        let refreshToken = session.tokens.refreshToken
        let renewFailure: String
        // Set when the renew request failed and the login fallback runs. Recorded with the login result.
        var failedRenew: (error: CoverflexError, current: StoredSession?)?

        // Skip the request only when the expiry is known. An unreadable refresh token goes to the server.
        if let expiry = JWT.expirationDate(of: refreshToken), expiry <= now() {
            renewFailure = "The refresh token expired at \(expiry.formatted(date: .abbreviated, time: .shortened))."
        } else {
            do {
                let renewed = try await api.renew(refreshToken: refreshToken)
                try saveTokens(renewed, for: session)
                return renewed.token
            } catch let error as CoverflexError {
                let current = currentSession().flatMap { $0.id == session.id ? $0 : nil }
                // The other process may have renewed first and spent this refresh token.
                if let current, current.tokens != session.tokens,
                   !JWT.isExpired(current.tokens.token, now: now(), margin: Self.accessTokenExpiryMargin) {
                    recordRenewIssue(error, trigger: trigger, current: current, refreshToken: refreshToken,
                                     nextStep: "Used the tokens that another process saved.")
                    return current.tokens.token
                }
                // A 2xx body without tokens: the cause is not known yet. Login still works.
                guard error.isRejection || error.isUnexpectedResponse else {
                    recordRenewIssue(error, trigger: trigger, current: current, refreshToken: refreshToken,
                                     nextStep: "Kept the session for a later retry.")
                    throw .fetchFailed(error.localizedDescription)
                }
                failedRenew = (error, current)
                renewFailure = "Renew failed: \(error.localizedDescription)"
            } catch let problem as BudgetProblem {
                throw problem
            } catch {
                throw .fetchFailed(error.localizedDescription)
            }
        }

        do {
            let accessToken = try await logInWithCredentials(session, renewFailure: renewFailure)
            if let failedRenew {
                recordRenewIssue(failedRenew.error, trigger: trigger, current: failedRenew.current, refreshToken: refreshToken,
                                 nextStep: "Logged in with the saved credentials.")
            }
            return accessToken
        } catch {
            if let failedRenew {
                recordRenewIssue(failedRenew.error, trigger: trigger, current: failedRenew.current, refreshToken: refreshToken,
                                 nextStep: "Login with the saved credentials failed: \(error.message)")
            }
            throw error
        }
    }

    /// Logs in with the saved email, password, and user agent token. Removes the session when
    /// Coverflex rejects the login or asks for an OTP code.
    private func logInWithCredentials(_ session: StoredSession, renewFailure: String) async throws(BudgetProblem) -> String {
        let result: SignInResult
        do {
            result = try await api.logIn(session.credentials)
        } catch where error.isRejection {
            // Wrong password or revoked user agent token. Stop retrying: repeated failed
            // logins can lock the account. Only a new sign-in fixes this.
            throw clear(session, reason: "\(renewFailure) Login failed: \(error.localizedDescription)")
        } catch {
            throw .fetchFailed(error.localizedDescription)
        }

        switch result {
        case let .signedIn(tokens):
            try saveTokens(tokens, for: session)
            return tokens.token
        case .otpRequired:
            // Each retry could send another OTP code. Only a new sign-in fixes this.
            throw clear(session, reason: "\(renewFailure) Coverflex asked for a new verification code.")
        }
    }

    /// Writes the renew diagnostic to the system log and to `renewIssues`.
    /// `current` is the stored session after the request, or nil when it was replaced or unreadable.
    private func recordRenewIssue(
        _ error: CoverflexError,
        trigger: RefreshTrigger,
        current: StoredSession?,
        refreshToken: String,
        nextStep: String
    ) {
        let issue = RenewIssue(
            date: now(),
            trigger: trigger,
            error: error.localizedDescription,
            refreshTokenChangedDuringRequest: current.map { $0.tokens.refreshToken != refreshToken },
            nextStep: nextStep
        )
        let changed = issue.refreshTokenChangedDuringRequest.map(String.init) ?? "unknown"
        // `CoverflexError` messages hold no response values, so they are safe to log as public.
        Self.logger.error(
            "Renew failed. Trigger: \(issue.trigger.rawValue, privacy: .public). Process: \(ProcessInfo.processInfo.processName, privacy: .public). Refresh token changed: \(changed, privacy: .public). Next step: \(nextStep, privacy: .public). Error: \(issue.error, privacy: .public)"
        )
        // Keep the newest issue. Another process can save one while this refresh waits for the login.
        // The load and the save are not atomic across processes; a lost write here loses only a diagnostic.
        if let stored = renewIssues.load(), stored.date > issue.date { return }
        renewIssues.save(issue)
    }

    /// Saves new tokens into the session unless a sign-out or a new sign-in replaced it during the request.
    private func saveTokens(_ tokens: AuthTokens, for session: StoredSession) throws(BudgetProblem) {
        guard var current = currentSession(), current.id == session.id else {
            throw .fetchFailed("The Coverflex session changed during the refresh.")
        }
        current.tokens = tokens
        do {
            try sessions.save(current)
        } catch {
            throw .fetchFailed("Could not save the Coverflex session: \(error.localizedDescription)")
        }
    }

    /// The stored session, or nil when none is stored or the Keychain cannot read it now.
    /// The checks for a changed session use it: a read error counts as "changed", so a refresh
    /// never writes over or removes a session that it cannot see.
    private func currentSession() -> StoredSession? {
        try? sessions.load()
    }

    /// Removes the rejected session and returns `.signInRequired`. When a sign-out or a new sign-in
    /// replaced the session during the request, leaves the store alone and returns `.fetchFailed`.
    private func clear(_ session: StoredSession, reason: String) -> BudgetProblem {
        guard currentSession()?.id == session.id else { return .fetchFailed("The Coverflex session changed during the refresh.") }
        sessions.clear()
        return .signInRequired(reason)
    }
}
