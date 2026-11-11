import Foundation

/// Tokens returned by `POST /employee/sessions` and `POST /employee/sessions/renew`.
/// `token` is the short-lived access token. `refreshToken` renews it.
public struct AuthTokens: Codable, Equatable, Sendable {
    public var token: String
    public var refreshToken: String

    public init(token: String, refreshToken: String) {
        self.token = token
        self.refreshToken = refreshToken
    }

    enum CodingKeys: String, CodingKey {
        case token
        case refreshToken = "refresh_token"
    }
}

/// What the app needs to log in again without an OTP code, as `run-gmc/src/coverflex/util` does.
/// `userAgentToken` comes from `POST /employee/sessions/trust-user-agent` after an OTP sign-in.
/// Coverflex skips the OTP for logins that include it.
public struct Credentials: Codable, Equatable, Sendable {
    public var email: String
    public var password: String
    public var userAgentToken: String

    public init(email: String, password: String, userAgentToken: String) {
        self.email = email
        self.password = password
        self.userAgentToken = userAgentToken
    }
}

/// Everything the app keeps in the Keychain for one signed-in account. One record, so the app and
/// the widget never see credentials of one account with tokens of another.
public struct StoredSession: Codable, Equatable, Sendable {
    /// New for each sign-in. A refresh saves its result only while this ID is still the stored one,
    /// so a refresh in the widget process cannot undo a sign-out or a new sign-in in the app.
    public var id: UUID
    public var credentials: Credentials
    public var tokens: AuthTokens

    public init(id: UUID = UUID(), credentials: Credentials, tokens: AuthTokens) {
        self.id = id
        self.credentials = credentials
        self.tokens = tokens
    }
}

/// The last known meal budget, shared between the app and the widget through the App Group.
public struct BudgetSnapshot: Codable, Equatable, Sendable {
    /// Meal pocket balance in cents. Nil until the first successful fetch.
    public var balanceCents: Int?
    /// Time of the last successful fetch.
    public var fetchedAt: Date?
    /// Set when the last refresh failed. A failure keeps the last known balance.
    public var problem: BudgetProblem?

    public init(balanceCents: Int? = nil, fetchedAt: Date? = nil, problem: BudgetProblem? = nil) {
        self.balanceCents = balanceCents
        self.fetchedAt = fetchedAt
        self.problem = problem
    }

    /// True when the user must sign in again in this app before a refresh can work.
    public var needsSignIn: Bool {
        if case .signInRequired = problem { return true }
        return false
    }
}

public enum BudgetProblem: Error, Codable, Equatable, Sendable {
    /// No refresh token, or Coverflex rejected it. The text says why, for display in the app.
    case signInRequired(String)
    /// Network error, server error, or an unexpected response.
    case fetchFailed(String)
}

/// Response of `GET /employee/pockets`. Only the fields the app uses.
struct PocketsResponse: Decodable {
    struct Pocket: Decodable {
        struct Balance: Decodable {
            /// Amount in cents. Decoded as Double because the API schema only says "number".
            let amount: Double
        }

        let type: String
        let balance: Balance
    }

    let pockets: [Pocket]

    /// Balance of the "meals" pocket in cents.
    func mealBalanceCents() throws(CoverflexError) -> Int {
        guard let pocket = pockets.first(where: { $0.type == "meals" }) else {
            throw .unexpectedResponse("Meals pocket not found")
        }
        return Int(pocket.balance.amount.rounded())
    }
}
