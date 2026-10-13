//
//  APIKeyManager.swift
//  FinAgentMenuBar
//
//  Created by Chirag Patel on 7/16/26.
//

import SwiftUI
import CryptoKit
import Security
import LocalAuthentication
import Combine
@MainActor
class APIKeyManager: ObservableObject {
    static let shared = APIKeyManager()
    
    @Published var isUnlocked = false
    @Published var statusMessage = "Locked"
    @Published var errorMessage: String?

    /// Labels + ids for every stored access token. Persisted in UserDefaults;
    /// the tokens themselves are encrypted in the keychain, keyed by id.
    @Published var tokenEntries: [PlaidTokenEntry] = []

    private let enclaveLabel = "com.mlaid.finagent.apikey.enclave.master"
    // Keychain account for the biometry-gated Secure Enclave key's wrapped blob.
    private let enclaveKeyAccount = "com.mlaid.finagent.apikey.enclave.key.v2"

    // Shared app-level Plaid credentials, each its own encrypted keychain item.
    private let plaidClientIdAccount = "com.mlaid.finagent.plaid.client_id"
    private let plaidSecretAccount = "com.mlaid.finagent.plaid.secret"

    // Per-token keychain accounts share this prefix; UserDefaults holds the metadata.
    private let accessTokenAccountPrefix = "com.mlaid.finagent.plaid.access_token."
    private let tokenEntriesKey = "com.mlaid.finagent.plaid.token_entries"

    // Symmetric key derived once (behind Touch ID) at unlock and held in memory
    // for the session. Encrypts/decrypts everything, including background pulls.
    // Cleared on lock() and never persisted.
    private var cachedSymmetricKey: SymmetricKey?

    private func accessTokenAccount(for id: String) -> String {
        accessTokenAccountPrefix + id
    }

    init() {
        tokenEntries = loadTokenEntries()
    }

    // MARK: - Shared Credentials (client_id + secret)
    /// Encrypts and stores the shared app-level Plaid credentials. On first setup
    /// this creates the biometric Enclave key (one Touch ID prompt) and caches the
    /// derived symmetric key for the session.
    func storeSharedCredentials(clientId: String, secret: String) async {
        // Ensure the biometric key exists and the symmetric key is in memory.
        guard await authenticate(reason: "Set up FinAgent secure storage") else {
            return // errorMessage already set by authenticate()
        }
        do {
            let symmetricKey = try currentSymmetricKey()
            try encryptAndStore(clientId, using: symmetricKey, account: plaidClientIdAccount)
            try encryptAndStore(secret, using: symmetricKey, account: plaidSecretAccount)

            statusMessage = "Credentials saved"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Failed to store credentials"
        }
    }

    /// Updates the shared credentials in place, overwriting only the fields
    /// provided (blank = keep existing). Access tokens are left untouched — use
    /// this to apply a secret rotated in the Plaid Dashboard.
    func updateSharedCredentials(clientId: String?, secret: String?) async {
        do {
            let symmetricKey = try currentSymmetricKey()
            if let clientId, !clientId.isEmpty {
                try encryptAndStore(clientId, using: symmetricKey, account: plaidClientIdAccount)
            }
            if let secret, !secret.isEmpty {
                try encryptAndStore(secret, using: symmetricKey, account: plaidSecretAccount)
            }
            statusMessage = "Credentials updated"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Update failed"
        }
    }

    /// Current stored client_id, for pre-filling the update form. Nil if unavailable.
    func currentClientId() -> String? {
        guard let symmetricKey = try? currentSymmetricKey() else { return nil }
        return try? decrypt(account: plaidClientIdAccount, using: symmetricKey)
    }

    // MARK: - Access Tokens (multiple, each labeled)
    /// Adds a labeled access token, returning its generated id.
    @discardableResult
    func addAccessToken(label: String, token: String) async -> String? {
        do {
            let symmetricKey = try currentSymmetricKey()
            let entry = PlaidTokenEntry(label: label)
            try encryptAndStore(token, using: symmetricKey, account: accessTokenAccount(for: entry.id))

            tokenEntries.append(entry)
            saveTokenEntries()
            statusMessage = "Added \(label)"
            errorMessage = nil
            return entry.id

        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Failed to add token"
            return nil
        }
    }

    /// Overwrites the stored token for an existing entry, keeping its id + label.
    /// Used by token rotation.
    func updateAccessToken(id: String, token: String) throws {
        let symmetricKey = try currentSymmetricKey()
        try encryptAndStore(token, using: symmetricKey, account: accessTokenAccount(for: id))
    }

    /// Removes the access token with the given id (keychain + metadata).
    func removeAccessToken(id: String) {
        deleteKeychainItem(account: accessTokenAccount(for: id))
        tokenEntries.removeAll { $0.id == id }
        saveTokenEntries()
    }

    // MARK: - Token entry persistence
    private func loadTokenEntries() -> [PlaidTokenEntry] {
        guard let data = UserDefaults.standard.data(forKey: tokenEntriesKey),
              let entries = try? JSONDecoder().decode([PlaidTokenEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func saveTokenEntries() {
        if let data = try? JSONEncoder().encode(tokenEntries) {
            UserDefaults.standard.set(data, forKey: tokenEntriesKey)
        }
    }
    /// Unlocks the session: presents Touch ID (with passcode fallback) once, then
    /// derives the symmetric key into memory. All later encrypt/decrypt — including
    /// background pulls — reuse the in-memory key with no further prompts until the
    /// app restarts or lock() is called. Returns true if unlocked.
    @discardableResult
    func authenticate(reason: String = "Unlock FinAgent to access your Plaid data") async -> Bool {
        // Already unlocked this session — nothing to prompt.
        if cachedSymmetricKey != nil {
            isUnlocked = true
            return true
        }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        // Reuse this authentication for the immediate key-agreement operation.
        context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration
        let policy: LAPolicy = .deviceOwnerAuthentication // biometrics + passcode fallback

        var canEvalError: NSError?
        guard context.canEvaluatePolicy(policy, error: &canEvalError) else {
            errorMessage = "Touch ID / passcode is not available on this Mac"
            statusMessage = "Locked"
            isUnlocked = false
            return false
        }

        let authed: Bool = await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
        guard authed else {
            isUnlocked = false
            statusMessage = "Locked"
            errorMessage = "Authentication failed or cancelled"
            return false
        }

        do {
            // Derive the symmetric key using the authenticated context; cache it.
            let enclaveKey = try getOrCreateBiometricEnclaveKey(context: context)
            let symmetricKey = try deriveSymmetricKey(using: enclaveKey)
            cachedSymmetricKey = symmetricKey

            isUnlocked = true
            statusMessage = "Unlocked"
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Unlock failed"
            isUnlocked = false
            return false
        }
    }

    /// Locks the session: clears the in-memory key so decryption needs Touch ID
    /// again. Does not stop background scheduling (it just can't decrypt until
    /// the next unlock).
    func lock() {
        cachedSymmetricKey = nil
        isUnlocked = false
        statusMessage = "Locked"
    }
    // MARK: - Secure Enclave Asymmetric Key
    //
    // A Secure Enclave private key is NOT exportable. We persist the key's opaque
    // `dataRepresentation` blob (wrapped by the Enclave, safe to store) in the
    // keychain and reconstruct it. The key is created with a biometry/user-presence
    // access control, so it can only be *used* after a live Touch ID (or passcode)
    // — enforced by passing an authenticated LAContext.
    private func getOrCreateBiometricEnclaveKey(context: LAContext) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let blob = readKeychainData(account: enclaveKeyAccount) {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: blob, authenticationContext: context)
        }

        guard SecureEnclave.isAvailable else {
            throw KeychainError.secureEnclaveUnavailable
        }

        let accessControl = try makeBiometricAccessControl()
        let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            accessControl: accessControl, authenticationContext: context)
        try storeSealedData(privateKey.dataRepresentation, account: enclaveKeyAccount)
        return privateKey
    }

    /// Access control requiring the private key be usable only after user presence
    /// (Touch ID, with device-passcode fallback), while the device is unlocked.
    private func makeBiometricAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &error
        ) else {
            throw error!.takeRetainedValue()
        }
        return accessControl
    }

    /// Reads raw data for a keychain generic-password item, or nil if absent.
    private func readKeychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    
    // MARK: - Improved deriveSymmetricKey using Key Agreement
    private func deriveSymmetricKey(using enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey) throws -> SymmetricKey {
        let publicKey = enclaveKey.publicKey
        
        // Perform ECDH Key Agreement between private key and its own public key
        let sharedSecret = try enclaveKey.sharedSecretFromKeyAgreement(with: publicKey)
        
        // Derive final symmetric key using HKDF
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: "com.mlaid.finagentmenubar.apikey.v1".data(using: .utf8)!,
            sharedInfo: "com.mlaid.finagentmenubar.apikey.encryption.v1".data(using: .utf8)!,
            outputByteCount: 32
        )
    }
    /// Encrypt `value` under `symmetricKey` and persist it for `account`.
    private func encryptAndStore(_ value: String, using symmetricKey: SymmetricKey, account: String) throws {
        let sealedBox = try ChaChaPoly.seal(Data(value.utf8), using: symmetricKey)
        try storeSealedData(sealedBox.combined, account: account)
    }

    private func storeSealedData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToSave(status)
        }
    }

    /// Wipes the shared credentials and every stored access token.
    public func deleteKeys() async {
        var accounts = [plaidClientIdAccount, plaidSecretAccount]
        accounts.append(contentsOf: tokenEntries.map { accessTokenAccount(for: $0.id) })

        for account in accounts {
            deleteKeychainItem(account: account)
        }

        tokenEntries.removeAll()
        saveTokenEntries()
        isUnlocked = false
        statusMessage = "Credentials deleted"
    }

    private func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// True when the shared client_id + secret are present.
    func hasSharedCredentials() -> Bool {
        keychainItemExists(account: plaidClientIdAccount)
            && keychainItemExists(account: plaidSecretAccount)
    }

    private func keychainItemExists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Generic encrypted secrets
    //
    // Same envelope as the Plaid credentials — ChaChaPoly under the session key
    // — for secrets owned by other subsystems (e.g. the Google Drive refresh
    // token). Requires an unlocked session, like everything else here.

    /// Encrypt and persist `value` for `account`.
    func storeSecret(_ value: String, account: String) throws {
        try encryptAndStore(value, using: currentSymmetricKey(), account: account)
    }

    /// Decrypt the secret stored for `account`. Throws when locked or absent.
    func readSecret(account: String) throws -> String {
        try decrypt(account: account, using: currentSymmetricKey())
    }

    /// True when a secret is present, without needing an unlocked session.
    func hasSecret(account: String) -> Bool {
        keychainItemExists(account: account)
    }

    func deleteSecret(account: String) {
        deleteKeychainItem(account: account)
    }

    // MARK: - Get Plaid Credentials
    /// The in-memory symmetric key derived at unlock. Throws if the session is
    /// locked (call authenticate() first).
    private func currentSymmetricKey() throws -> SymmetricKey {
        guard let key = cachedSymmetricKey else { throw KeychainError.locked }
        return key
    }

    /// Decrypts the shared credentials combined with the token for `id`.
    func credentials(forTokenId id: String) throws -> PlaidCredentials {
        let symmetricKey = try currentSymmetricKey()
        return PlaidCredentials(
            clientId: try decrypt(account: plaidClientIdAccount, using: symmetricKey),
            secret: try decrypt(account: plaidSecretAccount, using: symmetricKey),
            accessToken: try decrypt(account: accessTokenAccount(for: id), using: symmetricKey)
        )
    }

    private func decrypt(account: String, using symmetricKey: SymmetricKey) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let combined = item as? Data else {
            throw KeychainError.keyNotFound
        }

        let sealedBox = try ChaChaPoly.SealedBox(combined: combined)
        let decrypted = try ChaChaPoly.open(sealedBox, using: symmetricKey)
        return String(data: decrypted, encoding: .utf8) ?? ""
    }
}

enum KeychainError: Error, LocalizedError {
    case unableToCreateKey(OSStatus)
    case unableToSave(OSStatus)
    case keyNotFound
    case unableToDeleteKey(OSStatus)
    case secureEnclaveUnavailable
    case locked
    var errorDescription: String? {
        switch self {
        case .unableToCreateKey(let status): return "Failed to create Secure Enclave key (\(status))"
        case .unableToSave(let status):      return "Failed to save to Keychain (\(status))"
        case .keyNotFound:                   return "API key not found"
        case .unableToDeleteKey(let status): return "Failed to delete Secure Enclave key (\(status))"
        case .secureEnclaveUnavailable:      return "Secure Enclave is not available on this device"
        case .locked:                        return "Locked — authenticate with Touch ID first"
        }
    }
}
