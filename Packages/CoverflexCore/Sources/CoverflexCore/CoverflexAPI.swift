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
/// Endpoints and headers mirror the web app, as in `run-gmc/src/coverflex`.
public struct CoverflexAPI: Sendable {
    public static let baseURL = URL(string: "https://menhir-api.coverflex.com/api")!

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    /// First sign-in step. Without a trusted device, Coverflex sends an OTP and does not return tokens.
    public func signIn(email: String, password: String) async throws(CoverflexError) -> SignInResult {
        let request = makeRequest("employee/sessions", method: "POST", body: ["email": email, "password": password])
        do {
            return .signedIn(try await decode(AuthTokens.self, from: request))
        } catch .network(let message) {
            throw .network(message)
        } catch {
            // Same behavior as bin/coverflex-uat.ts: any other failure means "now ask for the OTP".
            return .otpRequired
        }
    }

    /// Second sign-in step with the OTP code the user received.
    public func signIn(email: String, password: String, otp: String) async throws(CoverflexError) -> AuthTokens {
        let body = ["email": email, "password": password, "otp": otp]
        return try await decode(AuthTokens.self, from: makeRequest("employee/sessions", method: "POST", body: body))
    }

    /// Exchanges a refresh token for a new access token and a new refresh token.
    public func renew(refreshToken: String) async throws(CoverflexError) -> AuthTokens {
        let request = makeRequest("employee/sessions/renew", method: "POST", bearer: refreshToken)
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
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .unexpectedResponse(String(describing: error))
        }
    }
}
