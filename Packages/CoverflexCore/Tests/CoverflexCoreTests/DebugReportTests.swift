import Foundation
import Testing
@testable import CoverflexCore

@Suite struct DebugReportTests {
    private let environment = DebugReport.Environment(
        appVersion: "1.2 (3)",
        systemVersion: "iOS 26.0",
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    @Test func listsProblemAndRenewIssue() {
        let snapshot = BudgetSnapshot(
            balanceCents: 325,
            fetchedAt: Date(timeIntervalSince1970: 1_799_999_000),
            problem: .fetchFailed("Coverflex returned HTTP 500.")
        )
        let issue = RenewIssue(
                date: Date(timeIntervalSince1970: 1_799_999_500),
                trigger: .widgetButton,
                error: "Unexpected Coverflex response: keyNotFound Response keys: [data].",
                refreshTokenChangedDuringRequest: true,
                nextStep: "Logged in with the saved credentials."
        )

        let text = DebugReport.text(
            snapshot: snapshot,
            lastRenewIssue: issue,
            hasSession: true,
            accessTokenExpiry: Date(timeIntervalSince1970: 1_800_001_800),
            refreshTokenExpiry: nil,
            environment: environment
        )

        #expect(text == """
        Coverflex Budget debug info
        Generated: 2027-01-15T08:00:00Z
        App version: 1.2 (3)
        System: iOS 26.0

        Session saved: Yes
        Access token expires: 2027-01-15T08:30:00Z
        Refresh token expires: Unknown

        Balance fetched: Yes
        Last successful fetch: 2027-01-15T07:43:20Z
        Last refresh problem: Fetch failed: Coverflex returned HTTP 500.

        Last renew issue:
          Time: 2027-01-15T07:51:40Z
          Started by: widgetButton
          Refresh token changed: Yes
          Next step: Logged in with the saved credentials.
          Error: Unexpected Coverflex response: keyNotFound Response keys: [data].
        """)
    }

    @Test func reportsMissingRenewIssue() {
        let text = DebugReport.text(
            snapshot: BudgetSnapshot(),
            lastRenewIssue: nil,
            hasSession: false,
            accessTokenExpiry: nil,
            refreshTokenExpiry: nil,
            environment: environment
        )

        #expect(text.hasSuffix("Last refresh problem: None\n\nLast renew issue: None"))
        #expect(text.contains("Session saved: No"))
    }
}
