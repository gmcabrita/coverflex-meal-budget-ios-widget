import Foundation

/// Signs in, fetches the meal budget, keeps the Coverflex session alive, and records the result
/// in the snapshot store.
///
/// Access token order, as `getAuthenticationToken` in `run-gmc/src/coverflex/util`:
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

    /// Renew the access token when it expires within this many seconds.
    static let accessTokenExpiryMargin: TimeInterval = 60

    private let api: CoverflexAPI
    private let sessions: any SecureStore<StoredSession>
    private let snapshots: any SnapshotStore
    private let now: @Sendable () -> Date

    /// The refresh in progress. Later callers wait for it.
    private var inFlight: Task<BudgetSnapshot, Never>?

    public init(
        api: CoverflexAPI = CoverflexAPI(),
        sessions: any SecureStore<StoredSession> = KeychainStore.session,
        snapshots: any SnapshotStore = AppGroupSnapshotStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.sessions = sessions
        self.snapshots = snapshots
        self.now = now
    }

    public var snapshot: BudgetSnapshot { snapshots.load() }

    /// True when a refresh can run without user input.
    public var hasSession: Bool { sessions.load() != nil }

    /// Expiry dates read from the stored tokens, for display in the app. Nil when unknown.
    public var tokenExpiry: (access: Date?, refresh: Date?) {
        guard let tokens = sessions.load()?.tokens else { return (nil, nil) }
        return (JWT.expirationDate(of: tokens.token), JWT.expirationDate(of: tokens.refreshToken))
    }

    // MARK: - Sign-in

    /// First sign-in step. Returns false when Coverflex sent an OTP code; continue with `finishSignIn`.
    /// Returns true when the stored user agent token for this email let Coverflex skip the OTP.
    public func startSignIn(email: String, password: String) async throws -> Bool {
        let trustedToken = sessions.load().flatMap { $0.credentials.email == email ? $0.credentials.userAgentToken : nil }
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
        await refresh()
    }

    /// Removes the session and the cached budget.
    public func signOut() {
        inFlight = nil
        sessions.clear()
        snapshots.save(BudgetSnapshot(problem: .signInRequired("Signed out.")))
    }

    // MARK: - Refresh

    /// Returns the stored snapshot when it is newer than `maxAge`. Otherwise refreshes.
    /// The widget timeline uses this to skip a second fetch right after the refresh button ran.
    public func refreshIfOlder(than maxAge: TimeInterval) async -> BudgetSnapshot {
        let current = snapshots.load()
        if current.problem == nil, let fetchedAt = current.fetchedAt, now().timeIntervalSince(fetchedAt) < maxAge {
            return current
        }
        return await refresh()
    }

    /// Fetches the meal budget and stores the result.
    /// A failure keeps the last known balance and records the problem.
    @discardableResult
    public func refresh() async -> BudgetSnapshot {
        if let inFlight { return await inFlight.value }

        let task = Task { await self.performRefresh() }
        inFlight = task
        let result = await task.value
        if inFlight == task { inFlight = nil }
        return result
    }

    private func performRefresh() async -> BudgetSnapshot {
        guard let session = sessions.load() else {
            var snapshot = snapshots.load()
            snapshot.problem = .signInRequired("No saved Coverflex session.")
            snapshots.save(snapshot)
            return snapshot
        }

        var snapshot = snapshots.load()
        do {
            snapshot.balanceCents = try await fetchBalanceCents(session)
            snapshot.fetchedAt = now()
            snapshot.problem = nil
        } catch let problem {
            snapshot.problem = problem
        }
        // A sign-out or a new sign-in (in any process) replaced the session: drop this result.
        // `.signInRequired` here means this refresh removed its own rejected session, so it is saved.
        guard sessions.load()?.id == session.id || snapshot.needsSignIn else { return snapshots.load() }
        snapshots.save(snapshot)
        return snapshot
    }

    private func fetchBalanceCents(_ session: StoredSession) async throws(BudgetProblem) -> Int {
        if !JWT.isExpired(session.tokens.token, now: now(), margin: Self.accessTokenExpiryMargin) {
            do {
                return try await api.mealBalanceCents(accessToken: session.tokens.token)
            } catch let error where error.isUnauthorized {
                // Coverflex revoked the access token before its expiry. Get a new one and retry.
            } catch {
                throw .fetchFailed(error.localizedDescription)
            }
        }

        let accessToken = try await freshAccessToken(session)
        do {
            return try await api.mealBalanceCents(accessToken: accessToken)
        } catch {
            throw .fetchFailed(error.localizedDescription)
        }
    }

    /// Renews with the refresh token. Logs in with the credentials only when the refresh token is dead.
    private func freshAccessToken(_ session: StoredSession) async throws(BudgetProblem) -> String {
        let refreshToken = session.tokens.refreshToken
        var renewFailure: String

        // Skip the request only when the expiry is known. An unreadable refresh token goes to the server.
        if let expiry = JWT.expirationDate(of: refreshToken), expiry <= now() {
            renewFailure = "The refresh token expired at \(expiry.formatted(date: .abbreviated, time: .shortened))."
        } else {
            do {
                let renewed = try await api.renew(refreshToken: refreshToken)
                try saveTokens(renewed, for: session)
                return renewed.token
            } catch let error as CoverflexError {
                // The other process may have renewed first and spent this refresh token.
                if let current = sessions.load(), current.id == session.id, current.tokens != session.tokens,
                   !JWT.isExpired(current.tokens.token, now: now(), margin: Self.accessTokenExpiryMargin) {
                    return current.tokens.token
                }
                guard error.isRejection else { throw .fetchFailed(error.localizedDescription) }
                renewFailure = "Renew failed: \(error.localizedDescription)"
            } catch let problem as BudgetProblem {
                throw problem
            } catch {
                throw .fetchFailed(error.localizedDescription)
            }
        }

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

    /// Saves new tokens into the session unless a sign-out or a new sign-in replaced it during the request.
    private func saveTokens(_ tokens: AuthTokens, for session: StoredSession) throws(BudgetProblem) {
        guard var current = sessions.load(), current.id == session.id else {
            throw .fetchFailed("The Coverflex session changed during the refresh.")
        }
        current.tokens = tokens
        do {
            try sessions.save(current)
        } catch {
            throw .fetchFailed("Could not save the Coverflex session: \(error.localizedDescription)")
        }
    }

    /// Removes the rejected session and returns `.signInRequired`. When a sign-out or a new sign-in
    /// replaced the session during the request, leaves the store alone and returns `.fetchFailed`.
    private func clear(_ session: StoredSession, reason: String) -> BudgetProblem {
        guard sessions.load()?.id == session.id else { return .fetchFailed("The Coverflex session changed during the refresh.") }
        sessions.clear()
        return .signInRequired(reason)
    }
}
