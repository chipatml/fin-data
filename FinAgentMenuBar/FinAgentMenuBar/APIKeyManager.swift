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

    /// Plaid host used by the next request. Saved in UserDefaults (not a secret).
    /// Changing it does not move credentials between environments.
    @Published var plaidEnvironment: PlaidEnvironment = .production {
        didSet {
            UserDefaults.standard.set(plaidEnvironment.rawValue, forKey: Self.plaidEnvironmentKey)
        }
    }

    private let enclaveLabel = "com.mlaid.finagent.apikey.enclave.master"
    // Keychain account for the biometry-gated Secure Enclave key's wrapped blob.
    private let enclaveKeyAccount = "com.mlaid.finagent.apikey.enclave.key.v2"

    // Credentials saved before environments were split. The app always posted
    // these to production.plaid.com. They are not copied into Sandbox: the
    // last value written here may be a sandbox secret.
    private let legacyClientIdAccount = "com.mlaid.finagent.plaid.client_id"
    private let legacySecretAccount = "com.mlaid.finagent.plaid.secret"
    private static let plaidEnvironmentKey = "com.mlaid.finagent.plaid.environment"
    /// Generic-password items are unique on service + account. Omitting the
    /// service makes a query treat service as a wildcard.
    private static let keychainService = "com.mlaid.FinAgentMenuBar"

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

    private func clientIdAccount(for environment: PlaidEnvironment) -> String {
        "com.mlaid.finagent.plaid.client_id.\(environment.rawValue)"
    }

    private func secretAccount(for environment: PlaidEnvironment) -> String {
        "com.mlaid.finagent.plaid.secret.\(environment.rawValue)"
    }

    init() {
        tokenEntries = loadTokenEntries()
        if let raw = UserDefaults.standard.string(forKey: Self.plaidEnvironmentKey),
           let stored = PlaidEnvironment(rawValue: raw),
           PlaidEnvironment.settingsChoices.contains(stored) {
            plaidEnvironment = stored
        }
    }

    // MARK: - Shared Credentials (client_id + secret)
    /// Encrypts and stores Plaid credentials for `environment`. On first setup
    /// this creates the biometric Enclave key (one Touch ID prompt) and caches the
    /// derived symmetric key for the session. The next request uses `environment`
    /// without an app restart.
    func storeSharedCredentials(clientId: String, secret: String, environment: PlaidEnvironment) async {
        let trimmedClientId = Self.trimmedCredential(clientId)
        let trimmedSecret = Self.trimmedCredential(secret)
        guard !trimmedClientId.isEmpty, !trimmedSecret.isEmpty else {
            errorMessage = "Enter a \(environment.displayName) client_id and secret."
            statusMessage = "Failed to store credentials"
            return
        }
        // Ensure the biometric key exists and the symmetric key is in memory.
        guard await authenticate(reason: "Set up FinAgent secure storage") else {
            return // errorMessage already set by authenticate()
        }
        do {
            let symmetricKey = try currentSymmetricKey()
            try encryptAndStore(trimmedClientId, using: symmetricKey, account: clientIdAccount(for: environment))
            try encryptAndStore(trimmedSecret, using: symmetricKey, account: secretAccount(for: environment))
            try requireRoundTrip(clientId: trimmedClientId, secret: trimmedSecret, environment: environment, using: symmetricKey)
            plaidEnvironment = environment

            statusMessage = "Credentials saved for \(environment.displayName). \(Self.savedCredentialLabel(clientId: trimmedClientId, secret: trimmedSecret))"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Failed to store credentials"
        }
    }

    /// Writes trimmed client_id/secret for `environment` and selects that host
    /// for the next request. A blank field keeps the value already stored for
    /// that same environment. A blank secret does not keep the unlabeled secret
    /// from before environments were split, and it does not copy another
    /// environment's secret. Access tokens are left untouched.
    func updateSharedCredentials(clientId: String?, secret: String?, environment: PlaidEnvironment) async {
        let trimmedClientId = Self.trimmedCredential(clientId ?? "")
        let trimmedSecret = Self.trimmedCredential(secret ?? "")
        // A blank field keeps the value already stored for this environment.
        // The unlabeled client_id/secret are not copied in: that pair was not
        // tagged with an environment, and sending it with a new secret is what
        // Plaid reports as INVALID_API_KEYS. Re-normalize a kept value so a
        // smart dash stored earlier is replaced with the ASCII Plaid issued.
        let resolvedClientId = trimmedClientId.isEmpty
            ? currentClientId(for: environment).map(Self.trimmedCredential)
            : trimmedClientId
        guard let resolvedClientId, !resolvedClientId.isEmpty else {
            errorMessage = "Enter the \(environment.displayName) client_id. An older unlabeled client_id is not copied in."
            statusMessage = "Update failed"
            return
        }
        guard !trimmedSecret.isEmpty || hasStoredSecret(for: environment) else {
            errorMessage = "Enter the \(environment.displayName) secret. A blank field only keeps a secret already saved for \(environment.displayName)."
            statusMessage = "Update failed"
            return
        }
        do {
            let symmetricKey = try currentSymmetricKey()
            try encryptAndStore(resolvedClientId, using: symmetricKey, account: clientIdAccount(for: environment))
            let expectedSecret: String
            if !trimmedSecret.isEmpty {
                try encryptAndStore(trimmedSecret, using: symmetricKey, account: secretAccount(for: environment))
                expectedSecret = trimmedSecret
            } else if let kept = try trimmedStored(account: secretAccount(for: environment), using: symmetricKey) {
                let healed = Self.trimmedCredential(kept)
                if healed != kept {
                    try encryptAndStore(healed, using: symmetricKey, account: secretAccount(for: environment))
                }
                expectedSecret = healed
            } else {
                throw KeychainError.readBackMismatch(environment: environment)
            }
            try requireRoundTrip(clientId: resolvedClientId, secret: expectedSecret, environment: environment, using: symmetricKey)
            plaidEnvironment = environment
            statusMessage = "Credentials updated for \(environment.displayName). Next pull uses \(environment.hostDescription). \(Self.savedCredentialLabel(clientId: resolvedClientId, secret: expectedSecret))"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Update failed"
        }
    }

    /// client_id saved for `environment` only. The unlabeled client_id is not
    /// returned here, so the form cannot silently save it into Sandbox.
    func currentClientId(for environment: PlaidEnvironment) -> String? {
        guard let symmetricKey = try? currentSymmetricKey() else { return nil }
        return storedCredential(account: clientIdAccount(for: environment), using: symmetricKey)
    }

    /// Prefix and length of the pre-environment client_id, for the hint under
    /// the field. Nil if that item is absent. This value is not sent.
    func legacyClientIdLabel() -> String? {
        guard let symmetricKey = try? currentSymmetricKey() else { return nil }
        guard let value = storedCredential(account: legacyClientIdAccount, using: symmetricKey) else { return nil }
        return PlaidCredentialText.clientIdLabel(PlaidCredentialText.normalized(value))
    }

    /// Hash and code points of the pair a pull would send. No secret text.
    func storedCredentialFingerprint(for environment: PlaidEnvironment) -> String? {
        guard let symmetricKey = try? currentSymmetricKey() else { return nil }
        guard let clientId = storedCredential(account: clientIdAccount(for: environment), using: symmetricKey),
              let secret = storedCredential(account: secretAccount(for: environment), using: symmetricKey) else {
            return nil
        }
        let sentId = Self.trimmedCredential(clientId)
        let sentSecret = Self.trimmedCredential(secret)
        var line = "Saved \(PlaidCredentialText.fingerprintLine(sentId, label: "client_id", revealPrefix: true)); \(PlaidCredentialText.fingerprintLine(sentSecret, label: "secret", revealPrefix: false))"
        if clientId != sentId {
            line += ". Before normalize, client_id \(PlaidCredentialText.anomalySummary(clientId))"
        }
        if secret != sentSecret {
            line += ". Before normalize, secret \(PlaidCredentialText.anomalySummary(secret))"
        }
        return line
    }

    /// True when this environment has its own secret in the keychain.
    /// The unlabeled legacy secret does not count.
    func hasStoredSecret(for environment: PlaidEnvironment) -> Bool {
        keychainItemExists(account: secretAccount(for: environment))
    }

    /// True when this environment has its own client_id. The unlabeled item does not count.
    func hasStoredClientId(for environment: PlaidEnvironment) -> Bool {
        keychainItemExists(account: clientIdAccount(for: environment))
    }

    /// True when a complete client_id + secret pair is stored for `environment`.
    func hasEnvironmentCredentials(_ environment: PlaidEnvironment) -> Bool {
        keychainItemExists(account: clientIdAccount(for: environment))
            && keychainItemExists(account: secretAccount(for: environment))
    }

    /// True when the only saved pair is the pre-environment slot, which this
    /// app used to send to Production.
    var usesUnlabeledLegacySecret: Bool {
        hasLegacyCredentials() && !PlaidEnvironment.settingsChoices.contains(where: { self.hasEnvironmentCredentials($0) })
    }

    // MARK: - Access Tokens (multiple, each labeled)
    /// Institution names can repeat. The stored label stays unique without adding account numbers.
    func uniqueTokenLabel(_ base: String) -> String {
        let existing = Set(tokenEntries.map(\.label))
        if !existing.contains(base) { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// Adds a labeled access token, returning its generated id.
    /// `environment` tags the token so later pulls use that host and its client_id/secret.
    @discardableResult
    func addAccessToken(label: String, token: String, environment: PlaidEnvironment? = nil) async -> String? {
        do {
            let symmetricKey = try currentSymmetricKey()
            let entry = PlaidTokenEntry(label: label, environment: environment)
            let trimmedToken = Self.trimmedCredential(token)
            guard !trimmedToken.isEmpty else {
                errorMessage = "Enter an access token."
                statusMessage = "Failed to add token"
                return nil
            }
            try encryptAndStore(trimmedToken, using: symmetricKey, account: accessTokenAccount(for: entry.id))

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
        let trimmedToken = Self.trimmedCredential(token)
        guard !trimmedToken.isEmpty else { throw KeychainError.keyNotFound }
        let symmetricKey = try currentSymmetricKey()
        try encryptAndStore(trimmedToken, using: symmetricKey, account: accessTokenAccount(for: id))
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
    /// New items are stored with `keychainService`. Items saved before that
    /// (empty service) are still found, so the enclave key and existing
    /// secrets keep decrypting.
    private func readKeychainData(account: String) -> Data? {
        if let data = copyKeychainData(account: account, service: Self.keychainService) {
            return data
        }
        return copyKeychainData(account: account, service: nil)
    }

    private func copyKeychainData(account: String, service: String?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let service {
            query[kSecAttrService as String] = service
        }
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
        // Delete only the item we are about to replace. Including kSecValueData
        // in the delete query looks for an item whose ciphertext already equals
        // the new value, finds nothing, and the add then fails with
        // errSecDuplicateItem. The first secret stayed in the Keychain and every
        // later "update" was dropped.
        deleteKeychainItem(account: account, service: Self.keychainService)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToSave(status)
        }
        // The pre-service item, if any, is left in place. Deleting with an empty
        // service can be treated as a wildcard and would remove the item just
        // added. Reads try `keychainService` first, so the new value wins.
    }

    /// Wipes the shared credentials and every stored access token.
    public func deleteKeys() async {
        var accounts = [legacyClientIdAccount, legacySecretAccount]
        for environment in PlaidEnvironment.settingsChoices {
            accounts.append(clientIdAccount(for: environment))
            accounts.append(secretAccount(for: environment))
        }
        accounts.append(contentsOf: tokenEntries.map { accessTokenAccount(for: $0.id) })

        for account in accounts {
            deleteKeychainItem(account: account)
        }

        tokenEntries.removeAll()
        saveTokenEntries()
        plaidEnvironment = .production
        isUnlocked = false
        statusMessage = "Credentials deleted"
    }

    /// `service == nil` deletes every generic password with this account.
    /// A non-nil service, including "", deletes only that service.
    private func deleteKeychainItem(account: String, service: String? = nil) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        if let service {
            query[kSecAttrService as String] = service
        }
        SecItemDelete(query as CFDictionary)
    }

    /// True when some Plaid client_id + secret pair is present, including the
    /// unlabeled pair saved before credentials were split by environment.
    func hasSharedCredentials() -> Bool {
        hasLegacyCredentials() || PlaidEnvironment.settingsChoices.contains(where: { self.hasEnvironmentCredentials($0) })
    }

    private func hasLegacyCredentials() -> Bool {
        keychainItemExists(account: legacyClientIdAccount)
            && keychainItemExists(account: legacySecretAccount)
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
    // — for the Cloud Storage service-account JSON. Requires an unlocked
    // session, like everything else here. The service-account key is never
    // written to UserDefaults.

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

    /// Host for this token. Untagged tokens still use the environment selected in the menu.
    func environment(forTokenId id: String) -> PlaidEnvironment {
        tokenEntries.first { $0.id == id }?.plaidEnvironment ?? plaidEnvironment
    }

    /// Stable Plaid `user.client_user_id` for this Mac. Not a secret and not PII.
    func plaidClientUserId() -> String {
        let key = "com.mlaid.finagent.plaid.client_user_id"
        if let existing = UserDefaults.standard.string(forKey: key),
           existing.count >= 8,
           existing.count <= 128,
           existing.unicodeScalars.allSatisfy({ scalar in
               scalar.value < 128 && !CharacterSet.whitespacesAndNewlines.contains(scalar)
           }) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    /// client_id and secret for `environment`, with no access token. Used by Hosted Link.
    func linkCredentials(for environment: PlaidEnvironment) throws -> PlaidCredentials {
        let symmetricKey = try currentSymmetricKey()
        let pair = try credentialPair(for: environment, using: symmetricKey)
        return PlaidCredentials(
            clientId: pair.clientId,
            secret: pair.secret,
            accessToken: "",
            source: pair.source
        )
    }

    /// Decrypts the credentials for the token's environment plus the token for `id`.
    /// Read on every request, so an update applies without restarting the app.
    func credentials(forTokenId id: String) throws -> PlaidCredentials {
        let symmetricKey = try currentSymmetricKey()
        let pair = try credentialPair(for: environment(forTokenId: id), using: symmetricKey)
        let accessToken = Self.trimmedCredential(
            try decrypt(account: accessTokenAccount(for: id), using: symmetricKey)
        )
        guard !accessToken.isEmpty else { throw KeychainError.keyNotFound }
        return PlaidCredentials(
            clientId: pair.clientId,
            secret: pair.secret,
            accessToken: accessToken,
            source: pair.source
        )
    }

    /// Per-environment pair. Production may still read the unlabeled pair, but
    /// only while neither Sandbox nor Production has its own pair — that is the
    /// install that has not re-saved since environments were split. After a
    /// Sandbox (or Production) pair is saved, the unlabeled secret is not sent.
    private func credentialPair(for environment: PlaidEnvironment, using symmetricKey: SymmetricKey) throws -> (clientId: String, secret: String, source: String) {
        if let clientId = try trimmedStored(account: clientIdAccount(for: environment), using: symmetricKey),
           let secret = try trimmedStored(account: secretAccount(for: environment), using: symmetricKey) {
            return (clientId, secret, environment.rawValue)
        }
        let anyLabeledPair = PlaidEnvironment.settingsChoices.contains { hasEnvironmentCredentials($0) }
        if environment == .production, !anyLabeledPair,
           let clientId = try trimmedStored(account: legacyClientIdAccount, using: symmetricKey),
           let secret = try trimmedStored(account: legacySecretAccount, using: symmetricKey) {
            return (clientId, secret, "legacy")
        }
        throw KeychainError.missingCredentials(environment: environment)
    }

    /// Decrypts what was just written and refuses to switch environments when
    /// the Keychain returns a different client_id or secret.
    private func requireRoundTrip(clientId: String, secret: String, environment: PlaidEnvironment, using symmetricKey: SymmetricKey) throws {
        let storedId = try trimmedStored(account: clientIdAccount(for: environment), using: symmetricKey)
        let storedSecret = try trimmedStored(account: secretAccount(for: environment), using: symmetricKey)
        guard storedId == clientId, storedSecret == secret else {
            throw KeychainError.readBackMismatch(environment: environment)
        }
    }

    private static func savedCredentialLabel(clientId: String, secret: String) -> String {
        "\(PlaidCredentialText.fingerprintLine(clientId, label: "client_id", revealPrefix: true)); \(PlaidCredentialText.fingerprintLine(secret, label: "secret", revealPrefix: false))"
    }

    /// Nil when the account is absent or the stored value is only whitespace.
    /// Returns the stored bytes, not the normalized form, so a pull can report
    /// smart punctuation that is folded only at send time.
    private func trimmedStored(account: String, using symmetricKey: SymmetricKey) throws -> String? {
        do {
            let raw = try decrypt(account: account, using: symmetricKey)
            guard !Self.trimmedCredential(raw).isEmpty else { return nil }
            return raw
        } catch KeychainError.keyNotFound {
            return nil
        }
    }

    private static func trimmedCredential(_ value: String) -> String {
        PlaidCredentialText.normalized(value)
    }

    /// Form prefill helper. Missing and unreadable values are both nil.
    private func storedCredential(account: String, using symmetricKey: SymmetricKey) -> String? {
        do {
            return try trimmedStored(account: account, using: symmetricKey)
        } catch {
            return nil
        }
    }

    private func decrypt(account: String, using symmetricKey: SymmetricKey) throws -> String {
        guard let combined = readKeychainData(account: account) else {
            throw KeychainError.keyNotFound
        }

        let sealedBox = try ChaChaPoly.SealedBox(combined: combined)
        let decrypted = try ChaChaPoly.open(sealedBox, using: symmetricKey)
        guard let text = String(data: decrypted, encoding: .utf8) else {
            throw KeychainError.keyNotFound
        }
        return text
    }
}

enum KeychainError: Error, LocalizedError {
    case unableToCreateKey(OSStatus)
    case unableToSave(OSStatus)
    case keyNotFound
    case unableToDeleteKey(OSStatus)
    case secureEnclaveUnavailable
    case locked
    case missingCredentials(environment: PlaidEnvironment)
    case readBackMismatch(environment: PlaidEnvironment)
    var errorDescription: String? {
        switch self {
        case .unableToCreateKey(let status): return "Failed to create Secure Enclave key (\(status))"
        case .unableToSave(let status):      return "Failed to save to Keychain (\(status))"
        case .keyNotFound:                   return "API key not found"
        case .unableToDeleteKey(let status): return "Failed to delete Secure Enclave key (\(status))"
        case .secureEnclaveUnavailable:      return "Secure Enclave is not available on this device"
        case .locked:                        return "Locked — authenticate with Touch ID first"
        case .missingCredentials(let environment):
            return "\(environment.displayName): no client_id and secret are saved for this environment. Open Update client_id / secret, choose \(environment.displayName), and save them."
        case .readBackMismatch(let environment):
            return "\(environment.displayName): the Keychain did not return the client_id and secret just saved. The previous values are unchanged."
        }
    }
}
