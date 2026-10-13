//
//  GoogleOAuthConfig.swift
//  FinAgentMenuBar
//
//  The Google OAuth client (id + secret) identifying this app to Google. Stored
//  the same way as the Plaid client_id/secret: encrypted under the session key
//  derived from the Secure Enclave, in the keychain. Nothing about the Google
//  client lives in UserDefaults or on disk in the clear.
//
//  You create the client once — console.cloud.google.com, enable the Drive API,
//  then Credentials → Create credentials → OAuth client ID → "Desktop app" —
//  and paste it into the Google Drive panel. Google has no anonymous entry
//  point: the client id is what names this app on the consent screen, so it has
//  to exist before a login can be offered.
//
//  Reading either value needs an unlocked session, so `isConfigured` deliberately
//  tests for presence only — the UI has to render correctly while locked.
//

import Foundation

@MainActor
enum GoogleOAuthConfig {
    struct Credentials {
        let clientId: String
        let clientSecret: String
    }

    // Siblings of the Plaid entries in APIKeyManager, same encryption envelope.
    private static let clientIdAccount = "com.mlaid.finagent.gdrive.client_id"
    private static let clientSecretAccount = "com.mlaid.finagent.gdrive.client_secret"

    private static var keys: APIKeyManager { .shared }

    /// True when both halves are stored. Presence check only — no decryption,
    /// so this is safe to call while the session is locked.
    static var isConfigured: Bool {
        keys.hasSecret(account: clientIdAccount) && keys.hasSecret(account: clientSecretAccount)
    }

    /// Validate and store the OAuth client. Throws if the id isn't a Google
    /// client id, or if the session is locked.
    static func save(clientId: String, clientSecret: String) throws {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        guard GoogleDriveAuth.redirectScheme(clientId: id) != nil else {
            throw GoogleDriveError.invalidClientId
        }
        guard !secret.isEmpty else {
            throw GoogleDriveError.notConfigured
        }

        // Store the secret first: a half-written config that still fails
        // `isConfigured` is recoverable, one that passes it is not.
        try keys.storeSecret(secret, account: clientSecretAccount)
        try keys.storeSecret(id, account: clientIdAccount)
    }

    /// Decrypt both halves. Throws when locked or not yet configured.
    static func credentials() throws -> Credentials {
        guard isConfigured else { throw GoogleDriveError.notConfigured }
        return Credentials(clientId: try keys.readSecret(account: clientIdAccount),
                           clientSecret: try keys.readSecret(account: clientSecretAccount))
    }

    /// The client id alone, for display. Nil while locked — callers show a
    /// placeholder rather than prompting for Touch ID just to draw a label.
    static var displayClientId: String? {
        try? keys.readSecret(account: clientIdAccount)
    }

    static func clear() {
        keys.deleteSecret(account: clientIdAccount)
        keys.deleteSecret(account: clientSecretAccount)
    }
}
