import Foundation

enum JWT {
    /// Reads the `exp` claim of a JWT without verifying the signature.
    /// Returns nil when the token is malformed or has no `exp` claim.
    static func expirationDate(of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = base64URLDecode(String(parts[1])) else { return nil }

        struct Claims: Decodable { let exp: Double }
        guard let claims = try? JSONDecoder().decode(Claims.self, from: payload) else { return nil }
        return Date(timeIntervalSince1970: claims.exp)
    }

    /// True when the token expires within `margin` seconds of `now`, or has no readable expiry.
    static func isExpired(_ token: String, now: Date, margin: TimeInterval) -> Bool {
        guard let expiry = expirationDate(of: token) else { return true }
        return expiry.timeIntervalSince(now) <= margin
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        return Data(base64Encoded: base64)
    }
}
