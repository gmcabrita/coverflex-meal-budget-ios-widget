import Foundation

/// Fetches the meal budget, renews tokens when needed, and records the result in the snapshot store.
///
/// The app, the widget timeline, and the refresh App Intent all go through this type.
/// Concurrent `refresh()` calls in one process share one fetch, so they do not both
/// spend the same refresh token. The app and the widget extension are separate processes;
/// `renew` handles the case where the other process renewed first.
public actor BudgetService {
    /// Instance used by the app and the widget extension.
    public static let shared = BudgetService()

    /// Renew the access token when it expires within this many seconds.
    static let accessTokenExpiryMargin: TimeInterval = 60

    private let api: CoverflexAPI
    private let tokens: any TokenStore
    private let snapshots: any SnapshotStore
    private let now: @Sendable () -> Date

    /// The refresh in progress. Later callers wait for it.
    private var inFlight: Task<BudgetSnapshot, Never>?
    /// Changes on sign-in and sign-out. A refresh started in an earlier session does not save its result.
    private var session = 0

    public init(
        api: CoverflexAPI = CoverflexAPI(),
        tokens: any TokenStore = KeychainTokenStore(),
        snapshots: any SnapshotStore = AppGroupSnapshotStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.tokens = tokens
        self.snapshots = snapshots
        self.now = now
    }

    public var snapshot: BudgetSnapshot { snapshots.load() }

    public var hasTokens: Bool { tokens.load() != nil }

    /// Stores the tokens from a completed sign-in and fetches the budget.
    /// Throws when the Keychain does not accept the tokens.
    @discardableResult
    public func completeSignIn(with newTokens: AuthTokens) async throws -> BudgetSnapshot {
        startNewSession()
        try tokens.save(newTokens)
        return await refresh()
    }

    /// Removes the tokens and the cached budget.
    public func signOut() {
        startNewSession()
        tokens.clear()
        snapshots.save(BudgetSnapshot(problem: .signInRequired))
    }

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

        let session = self.session
        let task = Task { await self.performRefresh(in: session) }
        inFlight = task
        let result = await task.value
        if inFlight == task { inFlight = nil }
        return result
    }

    private func startNewSession() {
        session += 1
        inFlight = nil
    }

    private func performRefresh(in session: Int) async -> BudgetSnapshot {
        var snapshot = snapshots.load()
        do {
            snapshot.balanceCents = try await fetchBalanceCents(in: session)
            snapshot.fetchedAt = now()
            snapshot.problem = nil
        } catch let problem {
            snapshot.problem = problem
        }
        guard session == self.session else { return snapshots.load() }
        snapshots.save(snapshot)
        return snapshot
    }

    private func fetchBalanceCents(in session: Int) async throws(BudgetProblem) -> Int {
        guard let stored = tokens.load() else { throw .signInRequired }

        let tokenWasCached = !JWT.isExpired(stored.token, now: now(), margin: Self.accessTokenExpiryMargin)
        let accessToken = tokenWasCached ? stored.token : try await renew(stored, in: session)

        do {
            return try await api.mealBalanceCents(accessToken: accessToken)
        } catch let error where error.isUnauthorized && tokenWasCached {
            // The cached access token was revoked before its expiry. Renew once and retry.
            let renewed = try await renew(stored, in: session)
            do {
                return try await api.mealBalanceCents(accessToken: renewed)
            } catch {
                throw Self.problem(for: error)
            }
        } catch {
            throw Self.problem(for: error)
        }
    }

    private func renew(_ stored: AuthTokens, in session: Int) async throws(BudgetProblem) -> String {
        if JWT.isExpired(stored.refreshToken, now: now(), margin: 0) {
            clearTokens(ifStill: stored)
            throw .signInRequired
        }
        let renewed: AuthTokens
        do {
            renewed = try await api.renew(refreshToken: stored.refreshToken)
        } catch {
            guard session == self.session else { throw .fetchFailed("Signed out during refresh") }
            if error.isUnauthorized {
                // The other process may have renewed first and spent this refresh token.
                // Use its tokens when that happened.
                if let current = tokens.load(), current != stored,
                   !JWT.isExpired(current.token, now: now(), margin: Self.accessTokenExpiryMargin) {
                    return current.token
                }
                // Coverflex rejected the refresh token. Only a new sign-in can fix this.
                clearTokens(ifStill: stored)
                throw .signInRequired
            }
            // Rate limits, server errors, and network errors keep the tokens for the next attempt.
            throw Self.problem(for: error)
        }

        // A sign-in or sign-out during the request replaced the session. Do not restore old tokens.
        guard session == self.session else { throw .fetchFailed("Signed out during refresh") }
        do {
            try tokens.save(renewed)
        } catch {
            // Coverflex already spent the old refresh token, so the next refresh will likely need a sign-in.
            throw .fetchFailed("Could not save the renewed Coverflex session: \(error.localizedDescription)")
        }
        return renewed.token
    }

    /// Clears the tokens unless another process stored new ones (for example, a sign-in in the app).
    private func clearTokens(ifStill expected: AuthTokens) {
        if tokens.load() == expected { tokens.clear() }
    }

    private static func problem(for error: CoverflexError) -> BudgetProblem {
        error.isUnauthorized ? .signInRequired : .fetchFailed(error.localizedDescription)
    }
}
