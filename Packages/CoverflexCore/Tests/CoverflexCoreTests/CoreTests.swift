import Foundation
import Testing
@testable import CoverflexCore

@Suite struct SignInTests {
    private let tokensJSON = #"{"token":"a","refresh_token":"r"}"#

    @Test func firstStepWithoutTokensAsksForOTP() async throws {
        let transport = FakeTransport(["POST /api/employee/sessions": [FakeResponse(status: 422, json: #"{"error":"otp"}"#)]])
        let result = try await CoverflexAPI(transport: transport).signIn(email: "e@x.pt", password: "pw", userAgentToken: nil)

        #expect(result == .otpRequired)
        let body = try JSONDecoder().decode([String: String].self, from: transport.requests.get()[0].httpBody!)
        #expect(body == ["email": "e@x.pt", "password": "pw"])
    }

    @Test func firstStepWithTokensSignsIn() async throws {
        let transport = FakeTransport(["POST /api/employee/sessions": [FakeResponse(status: 200, json: tokensJSON)]])
        let result = try await CoverflexAPI(transport: transport).signIn(email: "e", password: "p", userAgentToken: nil)
        #expect(result == .signedIn(AuthTokens(token: "a", refreshToken: "r")))
    }

    @Test func firstStepNetworkErrorThrows() async {
        let transport = FakeTransport([:])
        transport.offline = true
        await #expect(throws: CoverflexError.self) {
            try await CoverflexAPI(transport: transport).signIn(email: "e", password: "p", userAgentToken: nil)
        }
    }

    @Test func otpStepSendsCodeAndReturnsTokens() async throws {
        let transport = FakeTransport(["POST /api/employee/sessions": [FakeResponse(status: 200, json: tokensJSON)]])
        let tokens = try await CoverflexAPI(transport: transport).signIn(email: "e", password: "p", otp: "123456")

        #expect(tokens == AuthTokens(token: "a", refreshToken: "r"))
        let body = try JSONDecoder().decode([String: String].self, from: transport.requests.get()[0].httpBody!)
        #expect(body["otp"] == "123456")
    }

    @Test func otpStepRejectionThrowsHTTPError() async {
        let transport = FakeTransport(["POST /api/employee/sessions": [FakeResponse(status: 401, json: "bad otp")]])
        await #expect(throws: CoverflexError.http(status: 401, body: "bad otp")) {
            try await CoverflexAPI(transport: transport).signIn(email: "e", password: "p", otp: "000000")
        }
    }
}

@Suite struct JWTTests {
    @Test func readsExpiry() {
        let exp = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(JWT.expirationDate(of: makeJWT(exp: exp)) == exp)
    }

    @Test func malformedTokenCountsAsExpired() {
        #expect(JWT.expirationDate(of: "not-a-jwt") == nil)
        #expect(JWT.isExpired("not-a-jwt", now: .now, margin: 0))
    }
}

@Suite struct FormattingTests {
    @Test func portugueseLocale() {
        let amount = BudgetFormatting.format(cents: 12482, locale: Locale(identifier: "pt_PT"))
        #expect(amount.whole == "124")
        #expect(amount.rest.hasPrefix(",82"))
        #expect(amount.rest.hasSuffix("€"))
    }

    @Test func englishLocale() {
        let amount = BudgetFormatting.format(cents: 325, locale: Locale(identifier: "en_US"))
        #expect(amount == FormattedAmount(whole: "€3", rest: ".25"))
    }

    @Test func zeroAndNegative() {
        #expect(BudgetFormatting.format(cents: 0, locale: Locale(identifier: "en_US")).full == "€0.00")
        #expect(BudgetFormatting.format(cents: -150, locale: Locale(identifier: "en_US")).full == "-€1.50")
    }
}

@Suite struct AppLinkTests {
    @Test func roundTrip() {
        for link in AppLink.allCases {
            #expect(AppLink(url: link.url) == link)
        }
        #expect(AppLink(url: URL(string: "https://example.com/open-coverflex")!) == nil)
    }

    @Test func widgetTapWithoutBalanceOpensThisApp() {
        #expect(AppLink.widgetTap(for: BudgetSnapshot()) == .signIn)
        #expect(AppLink.widgetTap(for: BudgetSnapshot(balanceCents: 1, fetchedAt: .now)) == .openCoverflex)
        // Signed in, but the first fetch failed: no auth error, so the tap opens Coverflex.
        #expect(AppLink.widgetTap(for: BudgetSnapshot(problem: .fetchFailed("offline"))) == .openCoverflex)
    }
}

@Suite struct AppGroupTests {
    @Test func usesDeclaredGroupWithoutAltStore() {
        #expect(AppGroup.resolve(altStoreAppGroups: nil) == "group.com.gmcabrita.CoverflexBudget")
    }

    @Test func usesGroupRenamedByAltStore() {
        let groups = ["group.com.rileytestut.AltStore.ABCDE12345", "group.com.gmcabrita.CoverflexBudget.ABCDE12345"]
        #expect(AppGroup.resolve(altStoreAppGroups: groups) == "group.com.gmcabrita.CoverflexBudget.ABCDE12345")
    }
}
