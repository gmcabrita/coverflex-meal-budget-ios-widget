import Foundation

/// Plain text report that the user can share from the app to help diagnose refresh problems.
/// It holds no tokens, email, or password: only dates, states, and error texts.
public enum DebugReport {
    /// Values that come from the device and the bundle, not from `BudgetService`.
    public struct Environment: Sendable {
        public var appVersion: String
        public var systemVersion: String
        public var generatedAt: Date

        public init(appVersion: String, systemVersion: String, generatedAt: Date) {
            self.appVersion = appVersion
            self.systemVersion = systemVersion
            self.generatedAt = generatedAt
        }
    }

    public static func text(
        snapshot: BudgetSnapshot,
        lastRenewIssue: RenewIssue?,
        hasSession: Bool,
        accessTokenExpiry: Date?,
        refreshTokenExpiry: Date?,
        environment: Environment
    ) -> String {
        var lines = [
            "Coverflex Budget debug info",
            "Generated: \(date(environment.generatedAt))",
            "App version: \(environment.appVersion)",
            "System: \(environment.systemVersion)",
            "",
            "Session saved: \(hasSession ? "Yes" : "No")",
            "Access token expires: \(date(accessTokenExpiry))",
            "Refresh token expires: \(date(refreshTokenExpiry))",
            "",
            "Balance fetched: \(snapshot.balanceCents == nil ? "No" : "Yes")",
            "Last successful fetch: \(date(snapshot.fetchedAt))",
            "Last refresh problem: \(problem(snapshot.problem))",
            "",
        ]
        if let issue = lastRenewIssue {
            lines += [
                "Last renew issue:",
                "  Time: \(date(issue.date))",
                "  Started by: \(issue.trigger.rawValue)",
                "  Refresh token changed: \(issue.refreshTokenChangedDuringRequest.map { $0 ? "Yes" : "No" } ?? "Unknown")",
                "  Next step: \(issue.nextStep)",
                "  Error: \(issue.error)",
            ]
        } else {
            lines.append("Last renew issue: None")
        }
        return lines.joined(separator: "\n")
    }

    /// ISO 8601 in UTC, so the times compare with the expiry in the JWTs and with other devices.
    private static func date(_ date: Date?) -> String {
        date?.ISO8601Format() ?? "Unknown"
    }

    private static func problem(_ problem: BudgetProblem?) -> String {
        switch problem {
        case nil: "None"
        case let .signInRequired(reason): "Sign-in required: \(reason)"
        case let .fetchFailed(message): "Fetch failed: \(message)"
        }
    }
}
