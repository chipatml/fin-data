//
//  GoogleDriveAuth.swift
//  FinAgentMenuBar
//
//  OAuth 2.0 against Google using the installed-app (PKCE) flow, so no local
//  redirect listener is needed — ASWebAuthenticationSession intercepts the
//  custom-scheme callback itself, which a sandboxed app is allowed to do.
//
//  The refresh token and client secret are encrypted with the same Secure
//  Enclave-derived key as the Plaid credentials (see APIKeyManager). The access
//  token is held in memory only and re-minted from the refresh token on demand.
//

import Foundation
import AuthenticationServices
import CryptoKit
import AppKit
import Combine

// MARK: - Errors

enum GoogleDriveError: Error, LocalizedError {
    case notConfigured
    case notConnected
    case invalidClientId
    case cancelled
    case oauth(String)
    case http(status: Int, body: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add a Google OAuth client ID and secret first"
        case .notConnected:
            return "Google Drive is not connected"
        case .invalidClientId:
            return "Client ID must end in .apps.googleusercontent.com"
        case .cancelled:
            return "Google sign-in was cancelled"
        case .oauth(let message):
            return "Google sign-in failed: \(message)"
        case .http(let status, let body):
            return "Google Drive HTTP \(status): \(body)"
        case .invalidResponse:
            return "Unexpected response from Google"
        }
    }

    /// True for the "this resource is gone" case, so callers can drop a stale
    /// cached folder/file id and re-resolve instead of failing the whole sync.
    var isNotFound: Bool {
        if case .http(let status, _) = self { return status == 404 }
        return false
    }

    /// True when the access token was rejected — worth one forced refresh.
    var isUnauthorized: Bool {
        if case .http(let status, _) = self { return status == 401 }
        return false
    }
}

// MARK: - Auth manager

@MainActor
final class GoogleDriveAuth: NSObject, ObservableObject {
    static let shared = GoogleDriveAuth()

    /// The narrowest scope that still works: the app can only see and manage
    /// files it created itself, never the rest of the user's Drive.
    static let scope = "https://www.googleapis.com/auth/drive.file"

    private static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published var statusMessage = "Not connected"
    @Published var errorMessage: String?
    /// The Google account the refresh token belongs to, for display only.
    @Published private(set) var connectedEmail: String?

    private let keys = APIKeyManager.shared

    // The OAuth client itself lives in GoogleOAuthConfig (keychain). Only the
    // refresh token is owned here; the account email is a display label.
    private let connectedEmailKey = "com.mlaid.finagent.gdrive.account_email"
    private let refreshTokenAccount = "com.mlaid.finagent.gdrive.refresh_token"

    // In-memory access token; never persisted.
    private var accessToken: String?
    private var accessTokenExpiry: Date?

    private var session: ASWebAuthenticationSession?

    private override init() {
        super.init()
        isConnected = keys.hasSecret(account: refreshTokenAccount)
        connectedEmail = UserDefaults.standard.string(forKey: connectedEmailKey)
        statusMessage = isConnected ? "Connected" : (isConfigured ? "Not connected" : "No OAuth client")
    }

    // MARK: - Configuration

    /// True when an OAuth client id + secret have been stored.
    var isConfigured: Bool { GoogleOAuthConfig.isConfigured }

    /// Save the OAuth client credentials from the Google Cloud console, both
    /// encrypted in the keychain (see GoogleOAuthConfig).
    func configure(clientId: String, clientSecret: String) {
        do {
            try GoogleOAuthConfig.save(clientId: clientId, clientSecret: clientSecret)
            errorMessage = nil
            statusMessage = "OAuth client saved — sign in next"
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Connect / disconnect

    /// Run the browser consent flow and persist the resulting refresh token.
    func connect() async {
        guard !isConnecting else { return }
        guard isConfigured else {
            errorMessage = GoogleDriveError.notConfigured.errorDescription
            return
        }
        isConnecting = true
        statusMessage = "Waiting for Google…"
        errorMessage = nil
        defer { isConnecting = false }

        do {
            // Decrypted once for the whole flow — both the authorize request
            // and the token exchange need them.
            let client = try GoogleOAuthConfig.credentials()
            guard let scheme = Self.redirectScheme(clientId: client.clientId) else {
                throw GoogleDriveError.invalidClientId
            }
            let redirectURI = scheme + ":/oauth2redirect"

            let verifier = Self.randomURLSafeString()
            let challenge = Self.codeChallenge(for: verifier)
            let state = Self.randomURLSafeString(byteCount: 16)

            var components = URLComponents(url: Self.authEndpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: client.clientId),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: Self.scope),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
                // offline + consent guarantee a refresh token is issued even on
                // a re-authorisation of an already-granted client.
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ]

            let callback = try await presentConsent(url: components.url!, scheme: scheme)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let error = items.first(where: { $0.name == "error" })?.value {
                throw GoogleDriveError.oauth(error)
            }
            guard items.first(where: { $0.name == "state" })?.value == state else {
                throw GoogleDriveError.oauth("state mismatch")
            }
            guard let code = items.first(where: { $0.name == "code" })?.value else {
                throw GoogleDriveError.oauth("no authorization code returned")
            }

            let token = try await exchange(form: [
                "code": code,
                "client_id": client.clientId,
                "client_secret": client.clientSecret,
                "code_verifier": verifier,
                "redirect_uri": redirectURI,
                "grant_type": "authorization_code",
            ])

            guard let refresh = token.refreshToken else {
                throw GoogleDriveError.oauth("Google did not return a refresh token")
            }
            try keys.storeSecret(refresh, account: refreshTokenAccount)
            apply(token)

            isConnected = true
            connectedEmail = await fetchAccountEmail()
            UserDefaults.standard.set(connectedEmail, forKey: connectedEmailKey)
            statusMessage = connectedEmail.map { "Connected as \($0)" } ?? "Connected"
        } catch {
            isConnected = keys.hasSecret(account: refreshTokenAccount)
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusMessage = "Not connected"
        }
    }

    /// Revoke the grant at Google (best effort) and drop every stored token.
    func disconnect() async {
        if let refresh = try? keys.readSecret(account: refreshTokenAccount) {
            var request = URLRequest(url: Self.revokeEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody(["token": refresh])
            _ = try? await URLSession.shared.data(for: request)
        }
        forgetTokens()
        statusMessage = "Disconnected"
        errorMessage = nil
    }

    /// Drop local tokens without contacting Google. Used by the full reset.
    func forgetTokens() {
        keys.deleteSecret(account: refreshTokenAccount)
        UserDefaults.standard.removeObject(forKey: connectedEmailKey)
        accessToken = nil
        accessTokenExpiry = nil
        connectedEmail = nil
        isConnected = false
    }

    /// Forget the tokens *and* the OAuth client, leaving nothing behind.
    func reset() async {
        await disconnect()
        GoogleOAuthConfig.clear()
        statusMessage = "No OAuth client"
    }

    // MARK: - Access tokens

    /// A usable access token, minting a new one from the refresh token when the
    /// cached one is missing or about to expire. `forceRefresh` bypasses the
    /// cache after the API rejects a token as unauthorized.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh,
           let token = accessToken,
           let expiry = accessTokenExpiry,
           expiry > Date().addingTimeInterval(60) {
            return token
        }
        return try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws -> String {
        guard let refresh = try? keys.readSecret(account: refreshTokenAccount) else {
            throw GoogleDriveError.notConnected
        }
        let client = try GoogleOAuthConfig.credentials()
        do {
            let token = try await exchange(form: [
                "refresh_token": refresh,
                "client_id": client.clientId,
                "client_secret": client.clientSecret,
                "grant_type": "refresh_token",
            ])
            apply(token)
            return token.accessToken
        } catch let error as GoogleDriveError {
            // A revoked or expired grant can never recover on its own — clear it
            // so the UI prompts for a fresh consent instead of retrying forever.
            if case .http(let status, _) = error, status == 400 || status == 401 {
                forgetTokens()
                statusMessage = "Google access revoked — reconnect"
            }
            throw error
        }
    }

    private func apply(_ token: TokenResponse) {
        accessToken = token.accessToken
        accessTokenExpiry = Date().addingTimeInterval(token.expiresIn ?? 3600)
    }

    /// The signed-in account's email, purely for display. Failure is non-fatal.
    private func fetchAccountEmail() async -> String? {
        guard let token = try? await validAccessToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let about = try? JSONDecoder().decode(AboutResponse.self, from: data) else {
            return nil
        }
        return about.user?.emailAddress
    }

    // MARK: - Browser consent

    private func presentConsent(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: GoogleDriveError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? GoogleDriveError.invalidResponse)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: GoogleDriveError.oauth("could not open the sign-in window"))
            }
        }
    }

    // MARK: - Token endpoint

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval?
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private struct AboutResponse: Decodable {
        struct User: Decodable { let emailAddress: String? }
        let user: User?
    }

    private func exchange(form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(form)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleDriveError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw GoogleDriveError.http(status: http.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "<no body>")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// `application/x-www-form-urlencoded` body. Encoded by hand rather than via
    /// URLComponents, which leaves `+`, `&` and `=` intact inside values — all
    /// three of which would corrupt a form body carrying an OAuth token.
    private static func formBody(_ fields: [String: String]) -> Data {
        // Unreserved characters per RFC 3986; everything else is escaped.
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    // MARK: - PKCE helpers

    /// Google's installed-app redirect scheme is the client id in reverse-DNS
    /// form: `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`.
    /// ASWebAuthenticationSession claims it for the duration of the flow, so it
    /// needs no Info.plist registration.
    static func redirectScheme(clientId: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientId.hasSuffix(suffix) else { return nil }
        let prefix = String(clientId.dropLast(suffix.count))
        guard !prefix.isEmpty else { return nil }
        return "com.googleusercontent.apps." + prefix
    }

    private static func randomURLSafeString(byteCount: Int = 48) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255) }
        }
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Presentation anchor

extension GoogleDriveAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Menu-bar app: the popover's window is the only one on screen.
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first { $0.isVisible }
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
    }
}
