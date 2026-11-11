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
    public var needsSignIn: Bool { problem == .signInRequired }
}

public enum BudgetProblem: Error, Codable, Equatable, Sendable {
    /// No refresh token, or Coverflex rejected it.
    case signInRequired
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
