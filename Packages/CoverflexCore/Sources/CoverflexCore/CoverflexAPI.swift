import Foundation

public enum CoverflexError: Error, Equatable, Sendable, LocalizedError {
    /// Coverflex answered with a non-2xx status code.
    case http(status: Int, body: String)
    /// The request did not complete (offline, timeout, TLS, ...).
    case network(String)
    /// Coverflex answered 2xx with a body the app cannot read.
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .http(status, body):
            body.isEmpty ? "Coverflex returned HTTP \(status)." : "Coverflex returned HTTP \(status): \(body)"
        case let .network(message):
            message
        case let .unexpectedResponse(message):
            "Unexpected Coverflex response: \(message)"
        }
    }

    /// True when Coverflex refused the token or the credentials. Other 4xx codes (404, 408, 429, ...)
    /// do not prove that, so the app keeps the session and tries again later.
    var isRejection: Bool {
        if case let .http(status, _) = self { return [400, 401, 403, 422].contains(status) }
        return false
    }

    /// True when the request failed for a reason that a later retry can fix: network, 429, or 5xx.
    /// Coverflex did not check the credentials, so it did not send an OTP code.
    var isTemporary: Bool {
        switch self {
        case .network: true
        case let .http(status, _): status == 429 || (500..<600).contains(status)
        case .unexpectedResponse: false
        }
    }

    /// True when the server rejected the credentials or token.
    var isUnauthorized: Bool {
        if case let .http(status, _) = self { return status == 401 || status == 403 }
        return false
    }
}

/// Sends HTTP requests. `URLSession` in the app, a fake in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// Result of the first sign-in step.
public enum SignInResult: Equatable, Sendable {
    case signedIn(AuthTokens)
    /// Coverflex did not return tokens. It usually sends an OTP code by email or SMS at this point.
    case otpRequired
}

/// Client for the Coverflex employee API used by https://my.coverflex.com.
/// Endpoints and headers mirror the web app, as in run-gmc:
/// https://github.com/gmcabrita/run-gmc/tree/49b8808/src/coverflex
public struct CoverflexAPI: Sendable {
    public static let baseURL = URL(string: "https://menhir-api.coverflex.com/api")!

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    /// First sign-in step. With a trusted `userAgentToken`, Coverflex returns tokens at once.
    /// Without one, Coverflex sends an OTP and does not return tokens.
    public func signIn(email: String, password: String, userAgentToken: String?) async throws(CoverflexError) -> SignInResult {
        var body = ["email": email, "password": password]
        body["user_agent_token"] = userAgentToken
        do {
            return .signedIn(try await decode(AuthTokens.self, from: makeRequest("employee/sessions", method: "POST", body: body)))
        } catch let error where error.isTemporary {
            throw error
        } catch {
            // Same behavior as run-gmc `bin/coverflex-uat.ts`: any other failure means "now ask for the OTP".
            // The status Coverflex uses when it sends the code is not known, so this includes 4xx codes.
            return .otpRequired
        }
    }

    /// Second sign-in step with the OTP code the user received.
    public func signIn(email: String, password: String, otp: String) async throws(CoverflexError) -> AuthTokens {
        let body = ["email": email, "password": password, "otp": otp]
        return try await decode(AuthTokens.self, from: makeRequest("employee/sessions", method: "POST", body: body))
    }

    /// Login without OTP, as `loginWithCredentials` in run-gmc:
    /// https://github.com/gmcabrita/run-gmc/tree/49b8808/src/coverflex/util
    /// Returns `.otpRequired` when Coverflex answers 2xx with a JSON object without tokens:
    /// it no longer trusts the user agent token and wants an OTP code.
    public func logIn(_ credentials: Credentials) async throws(CoverflexError) -> SignInResult {
        let body = [
            "email": credentials.email,
            "password": credentials.password,
            "user_agent_token": credentials.userAgentToken,
        ]
        let data = try await send(makeRequest("employee/sessions", method: "POST", body: body))
        if let tokens = try? JSONDecoder().decode(AuthTokens.self, from: data) { return .signedIn(tokens) }
        if (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return .otpRequired }
        throw .unexpectedResponse(String(decoding: data.prefix(200), as: UTF8.self))
    }

    /// Marks this client as trusted and returns the token that lets later logins skip the OTP.
    public func trustUserAgent(accessToken: String) async throws(CoverflexError) -> String {
        struct Response: Decodable {
            let userAgentToken: String
            enum CodingKeys: String, CodingKey { case userAgentToken = "user_agent_token" }
        }
        var request = makeRequest("employee/sessions/trust-user-agent", method: "POST", bearer: accessToken)
        // Same header as run-gmc, without a body: https://github.com/gmcabrita/run-gmc/blob/49b8808/bin/coverflex-uat.ts
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try await decode(Response.self, from: request).userAgentToken
    }

    /// Exchanges a refresh token for a new access token and a new refresh token.
    public func renew(refreshToken: String) async throws(CoverflexError) -> AuthTokens {
        var request = makeRequest("employee/sessions/renew", method: "POST", bearer: refreshToken)
        // The web app sends this header without a body. Same as run-gmc: https://github.com/gmcabrita/run-gmc/tree/49b8808/src/coverflex/util
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await decode(AuthTokens.self, from: request)
    }

    /// Balance of the meal pocket in cents.
    public func mealBalanceCents(accessToken: String) async throws(CoverflexError) -> Int {
        let request = makeRequest("employee/pockets", method: "GET", bearer: accessToken)
        return try await decode(PocketsResponse.self, from: request).mealBalanceCents()
    }

    // MARK: - Plumbing

    private func makeRequest(
        _ path: String,
        method: String,
        bearer: String? = nil,
        body: [String: String]? = nil
    ) -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9,pt-PT;q=0.8,pt;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://my.coverflex.com/", forHTTPHeaderField: "Referer")
        request.setValue("web", forHTTPHeaderField: "x-coverflex-channel")
        request.setValue("en-GB", forHTTPHeaderField: "x-coverflex-language")
        request.setValue("1.218.3", forHTTPHeaderField: "x-coverflex-version")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(body)
        }
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws(CoverflexError) -> T {
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .unexpectedResponse(String(describing: error))
        }
    }

    /// Sends the request and returns the body of a 2xx response.
    private func send(_ request: URLRequest) async throws(CoverflexError) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw .network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw .unexpectedResponse("Not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(500), as: UTF8.self)
            throw .http(status: http.statusCode, body: body)
        }
        return data
    }
}
