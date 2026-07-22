// JWT.swift
//
// Unverified JWT payload inspection for expiry and claims (matches Rust
// `jsonwebtoken::dangerous::insecure_decode` usage).

import Foundation

/// Parse JWT `exp` claim without signature validation. Returns nil for non-JWTs.
public func parseJWTExpiration(_ token: String) -> Date? {
    guard let payload = decodeJWTPayload(token),
          let exp = payload["exp"] as? NSNumber
            ?? (payload["exp"] as? Int).map({ NSNumber(value: $0) })
            ?? (payload["exp"] as? Double).map({ NSNumber(value: $0) })
            ?? (payload["exp"] as? Int64).map({ NSNumber(value: $0) })
    else {
        return nil
    }
    return Date(timeIntervalSince1970: exp.doubleValue)
}

/// True when JWT is expired or will expire within `threshold`.
public func isJWTExpiredOrNear(
    _ token: String,
    threshold: TimeInterval,
    now: Date = Date()
) -> Bool {
    guard let exp = parseJWTExpiration(token) else { return false }
    return exp <= now.addingTimeInterval(threshold)
}

/// Decode JWT payload JSON (no signature check).
public func decodeJWTPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
          !parts[0].isEmpty,
          !parts[1].isEmpty,
          !parts[2].isEmpty,
          let data = AuthCrypto.base64URLDecode(String(parts[1])),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return obj
}

/// Peek principal claims from an access token JWT.
public func peekAccessTokenPrincipal(
    _ accessToken: String
) -> (principalType: String, principalID: String, teamID: String?)? {
    guard let payload = decodeJWTPayload(accessToken) else { return nil }
    let pt = (payload["principal_type"] as? String)
        ?? (payload["principalType"] as? String)
    let pid = (payload["principal_id"] as? String)
        ?? (payload["principalId"] as? String)
    guard let pt, let pid, !pt.isEmpty, !pid.isEmpty else { return nil }
    let tid = (payload["team_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return (pt, pid, tid)
}

public func peekAccessTokenPrincipalID(_ accessToken: String) -> String? {
    guard let payload = decodeJWTPayload(accessToken) else { return nil }
    let pid = (payload["principal_id"] as? String)
        ?? (payload["principalId"] as? String)
    return pid.flatMap { $0.isEmpty ? nil : $0 }
}

/// Build an unsigned test JWT with the given payload JSON object.
public func buildTestJWT(payload: [String: Any]) -> String {
    let header = AuthCrypto.base64URLEncode(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
    let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    let body = AuthCrypto.base64URLEncode(payloadData)
    return "\(header).\(body).fake-signature"
}
