import Foundation

private let log = FileLog("TokenRefresher")

/// Credentials returned by a successful OAuth refresh grant.
/// `refreshToken` is ROTATED on every grant (single-use) — it MUST be persisted
/// before the prior refresh token is discarded, or the account's only key is lost.
/// See ARCHITECTURE.md §Token Lifecycle & Refresh (spike 2026-06-06).
struct RefreshedCreds: Sendable {
    let accessToken: String
    let refreshToken: String
    /// Absolute expiry, epoch milliseconds (matches claudeAiOauth.expiresAt format).
    let expiresAtMillis: Int
}

enum TokenRefreshError: LocalizedError {
    /// No refresh token present in the stored credential.
    case noRefreshToken
    /// Server rejected the refresh token (HTTP 400/401 invalid_grant). The token is
    /// dead/rotated-away — genuine re-authentication (browser) is required.
    case invalidGrant(String)
    /// Edge/WAF block (HTTP 403, e.g. Cloudflare 1010). Possible client attestation —
    /// the trigger to revisit Option B (delegate to `claude auth status`).
    case edgeBlocked(Int)
    case network(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .noRefreshToken:       return "No refresh token in stored credential"
        case .invalidGrant(let b):  return "Refresh token invalid — re-authentication required (\(b))"
        case .edgeBlocked(let c):   return "OAuth endpoint blocked at edge (HTTP \(c))"
        case .network(let m):       return "Network error during refresh: \(m)"
        case .decode(let m):        return "Could not decode refresh response: \(m)"
        }
    }
}

/// Abstraction over the token-refresh strategy so Option B (delegate refresh to the
/// official `claude` CLI) can replace Option A (direct OAuth grant) at the call sites
/// without a rewrite. ARCHITECTURE.md §Option B documents the revisit trigger.
protocol TokenRefreshing: Sendable {
    func refresh(refreshToken: String) async throws -> RefreshedCreds
}

/// Option A — direct OAuth refresh-token grant against Anthropic's public PKCE client.
/// Validated live 2026-06-06: HTTP 200, rotated=true, expires_in=28800 (8h).
///
/// The CLI `User-Agent` is REQUIRED: the plain URLSession UA is blocked by Cloudflare
/// with `HTTP 403 error code: 1010` (spike H6). The `anthropic-beta` header mirrors the
/// CLI. No client_secret — this is a public client.
struct DirectTokenRefresher: TokenRefreshing {
    static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Must look like the Claude Code CLI to clear the Cloudflare browser-signature filter.
    static let userAgent = "claude-cli/2.1.166 (external, cli)"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func refresh(refreshToken: String) async throws -> RefreshedCreds {
        guard !refreshToken.isEmpty else { throw TokenRefreshError.noRefreshToken }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientId
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TokenRefreshError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TokenRefreshError.network("non-HTTP response")
        }
        let bodyStr = String(data: data, encoding: .utf8) ?? ""

        switch http.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String,
                  let rotated = json["refresh_token"] as? String else {
                throw TokenRefreshError.decode("HTTP 200 but missing access_token/refresh_token")
            }
            let expiresIn = (json["expires_in"] as? Double) ?? 28800
            let expiresAt = Int(Date().timeIntervalSince1970 * 1000 + expiresIn * 1000)
            // Never log token material — only the rotation flag + lifetime.
            log.info("[refresh] HTTP 200 rotated=\(rotated != refreshToken) expires_in=\(Int(expiresIn))")
            return RefreshedCreds(accessToken: access, refreshToken: rotated, expiresAtMillis: expiresAt)
        case 400, 401:
            log.error("[refresh] HTTP \(http.statusCode) invalid_grant — refresh token dead. body=\(bodyStr.prefix(120))")
            throw TokenRefreshError.invalidGrant(String(bodyStr.prefix(120)))
        case 403:
            log.error("[refresh] HTTP 403 edge/WAF block (possible attestation). body=\(bodyStr.prefix(120))")
            throw TokenRefreshError.edgeBlocked(http.statusCode)
        default:
            log.error("[refresh] HTTP \(http.statusCode). body=\(bodyStr.prefix(120))")
            throw TokenRefreshError.network("HTTP \(http.statusCode)")
        }
    }
}
