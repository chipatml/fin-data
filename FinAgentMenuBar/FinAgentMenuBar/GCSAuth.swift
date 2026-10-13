//
//  GCSAuth.swift
//  FinAgentMenuBar
//
//  A GCP service-account JSON key lives only in the Keychain, encrypted with
//  the same session key APIKeyManager uses for Plaid secrets. The bucket name
//  and the service-account email (a label, not a secret) live in UserDefaults.
//  Nothing in this file is a credential.
//

import Foundation
import Combine
import Security

enum GCSError: Error, LocalizedError {
    case invalidKey(String)
    case notConfigured
    case missingBucket
    case invalidBucket(String)
    case permissionDenied
    case bucketNotFound(String)
    case notFound
    case unauthorized
    case http(status: Int, detail: String)
    case signingFailed(String)

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidKey(let reason):
            return "Invalid service account key. \(reason)"
        case .notConfigured:
            return "No Cloud Storage service account key is saved"
        case .missingBucket:
            return "Enter a bucket name"
        case .invalidBucket(let name):
            return "Bucket name “\(name)” is not valid. Use the lowercase name from Cloud Storage."
        case .permissionDenied:
            return "Permission denied. Grant this service account Storage Object Admin (roles/storage.objectAdmin) on the bucket."
        case .bucketNotFound(let name):
            return "Bucket “\(name)” was not found. Check the name and the project that owns it."
        case .notFound:
            return "Object not found"
        case .unauthorized:
            return "Cloud Storage rejected the access token"
        case .http(let status, let detail):
            return "Cloud Storage HTTP \(status): \(detail)"
        case .signingFailed(let reason):
            return "Could not sign the service-account token. \(reason)"
        }
    }
}

struct ServiceAccountKey {
    let clientEmail: String
    let privateKeyPEM: String
    let tokenURI: String

    static func parse(_ raw: String) throws -> ServiceAccountKey {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GCSError.invalidKey("Paste the JSON key file, or import it.")
        }
        guard trimmed.count < 100_000 else {
            throw GCSError.invalidKey("That text is too large to be a service account key.")
        }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GCSError.invalidKey("The text is not a JSON object.")
        }
        let type = json["type"] as? String
        guard type == "service_account" else {
            throw GCSError.invalidKey("Expected a Google service account key (\"type\": \"service_account\").")
        }
        guard let email = json["client_email"] as? String, email.contains("@") else {
            throw GCSError.invalidKey("The key has no client_email.")
        }
        guard let pem = json["private_key"] as? String, pem.contains("PRIVATE KEY") else {
            throw GCSError.invalidKey("The key has no private_key PEM block.")
        }
        let tokenURI: String
        if let rawURI = json["token_uri"] as? String, URL(string: rawURI) != nil {
            tokenURI = rawURI
        } else {
            tokenURI = "https://oauth2.googleapis.com/token"
        }
        return ServiceAccountKey(clientEmail: email, privateKeyPEM: pem, tokenURI: tokenURI)
    }
}

@MainActor
final class GCSAuth: ObservableObject {
    static let shared = GCSAuth()

    /// Keychain account for the encrypted service-account JSON. The private key
    /// never goes to UserDefaults or disk in the clear.
    static let keyAccount = "com.mlaid.finagent.gcs.service_account"
    private static let emailKey = "com.mlaid.finagent.gcs.client_email"
    static let scope = "https://www.googleapis.com/auth/devstorage.read_write"

    @Published private(set) var isConfigured = false
    @Published private(set) var clientEmail: String?
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast
    private let session: URLSession = .shared

    private init() {
        isConfigured = APIKeyManager.shared.hasSecret(account: Self.keyAccount)
        clientEmail = UserDefaults.standard.string(forKey: Self.emailKey)
        statusMessage = isConfigured ? "Service account saved" : "No service account"
    }

    /// Validate `json` and store it in the Keychain. Requires an unlocked session.
    func save(json: String) async -> Bool {
        let parsed: ServiceAccountKey
        do {
            parsed = try ServiceAccountKey.parse(json)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusMessage = "Key rejected"
            return false
        }

        guard await APIKeyManager.shared.authenticate(reason: "Save the Cloud Storage service account key") else {
            errorMessage = APIKeyManager.shared.errorMessage ?? GCSError.notConfigured.errorDescription
            return false
        }

        do {
            let stored = json.trimmingCharacters(in: .whitespacesAndNewlines)
            try APIKeyManager.shared.storeSecret(stored, account: Self.keyAccount)
            clientEmail = parsed.clientEmail
            UserDefaults.standard.set(parsed.clientEmail, forKey: Self.emailKey)
            cachedToken = nil
            tokenExpiry = .distantPast
            isConfigured = true
            // Prove the key can mint a token before calling the save a success.
            // A rejected key is removed so it is not left behind as configured.
            do {
                _ = try await accessToken(forceRefresh: true)
            } catch let urlError as URLError {
                statusMessage = "Service account saved"
                errorMessage = "Saved the key, but could not reach Google to verify it (\(urlError.localizedDescription))."
                return true
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                clear()
                errorMessage = message
                statusMessage = "Key rejected"
                return false
            }
            statusMessage = "Service account saved"
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusMessage = "Could not save the key"
            return false
        }
    }

    /// Drop the key. Does not need an unlocked session.
    func clear() {
        APIKeyManager.shared.deleteSecret(account: Self.keyAccount)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        clientEmail = nil
        cachedToken = nil
        tokenExpiry = .distantPast
        isConfigured = false
        statusMessage = "Service account removed"
        errorMessage = nil
    }

    /// Bearer token for the JSON API. Cached until shortly before `expires_in`.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cachedToken, tokenExpiry > Date().addingTimeInterval(60) {
            return cachedToken
        }
        guard isConfigured else { throw GCSError.notConfigured }
        guard await APIKeyManager.shared.authenticate(reason: "Unlock FinAgent to upload to Cloud Storage") else {
            throw KeychainError.locked
        }
        let raw = try APIKeyManager.shared.readSecret(account: Self.keyAccount)
        let key = try ServiceAccountKey.parse(raw)
        let assertion = try ServiceAccountJWT.sign(key: key)
        let token = try await exchange(assertion: assertion, tokenURI: key.tokenURI)
        cachedToken = token.value
        tokenExpiry = Date().addingTimeInterval(token.expiresIn)
        return token.value
    }

    private struct MintedToken {
        let value: String
        let expiresIn: TimeInterval
    }

    private func exchange(assertion: String, tokenURI: String) async throws -> MintedToken {
        guard let url = URL(string: tokenURI) else {
            throw GCSError.invalidKey("token_uri is not a URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GCSError.http(status: -1, detail: "No HTTP response from the token endpoint")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = Self.tokenErrorDetail(data) ?? "the token endpoint rejected the service account key"
            if http.statusCode == 400 || http.statusCode == 401 {
                throw GCSError.invalidKey(detail)
            }
            throw GCSError.http(status: http.statusCode, detail: detail)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw GCSError.invalidKey("The token endpoint did not return an access_token.")
        }
        let expires = json["expires_in"] as? TimeInterval ?? 3600
        return MintedToken(value: access, expiresIn: expires)
    }

    private static func tokenErrorDetail(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let description = json["error_description"] as? String
        let error = json["error"] as? String
        let joined = [error, description].compactMap { $0 }.joined(separator: ": ")
        return joined.isEmpty ? nil : joined
    }

    private func formBody(_ fields: [String: String]) -> Data {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}

enum ServiceAccountJWT {
    static func sign(key: ServiceAccountKey) throws -> String {
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8)
        let now = Int(Date().timeIntervalSince1970)
        let claims: [String: Any] = [
            "iss": key.clientEmail,
            "scope": GCSAuth.scope,
            "aud": key.tokenURI,
            "iat": now,
            "exp": now + 3600,
        ]
        let claimsData = try JSONSerialization.data(withJSONObject: claims)
        let signingInput = "\(base64url(header)).\(base64url(claimsData))"
        let privateKey = try PKCS8.secKey(pem: key.privateKeyPEM)
        let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
            throw GCSError.signingFailed("This Mac cannot sign with the key algorithm.")
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            algorithm,
            Data(signingInput.utf8) as CFData,
            &error
        ) else {
            let detail = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
            throw GCSError.signingFailed(detail)
        }
        return "\(signingInput).\(base64url(signature as Data))"
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum PKCS8 {
    /// RSA private key in PKCS#1 DER, which `SecKeyCreateWithData` accepts.
    static func secKey(pem: String) throws -> SecKey {
        let pkcs1 = try pkcs1DER(pem: pem)
        var lastDetail = "unrecognized RSA key"
        for bits in [2048, 4096, 1024] {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits: bits,
            ]
            var error: Unmanaged<CFError>?
            if let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) {
                return key
            }
            if let error {
                lastDetail = String(describing: error.takeRetainedValue())
            }
        }
        throw GCSError.signingFailed(lastDetail)
    }

    static func pkcs1DER(pem: String) throws -> Data {
        let body = pem
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let der = Data(base64Encoded: body) else {
            throw GCSError.invalidKey("private_key is not valid base64.")
        }
        if pem.contains("BEGIN RSA PRIVATE KEY") {
            return der
        }
        guard pem.contains("BEGIN PRIVATE KEY") else {
            throw GCSError.invalidKey("private_key must be a PEM PRIVATE KEY block.")
        }
        return try unwrapPKCS8(der)
    }

    /// PrivateKeyInfo ::= SEQUENCE { version, algorithm, privateKey OCTET STRING }
    private static func unwrapPKCS8(_ der: Data) throws -> Data {
        var offset = 0
        let outer = try readTLV(der, offset: &offset)
        guard outer.tag == 0x30 else {
            throw GCSError.invalidKey("private_key is not a PKCS#8 sequence.")
        }
        var inner = 0
        _ = try readTLV(outer.value, offset: &inner)
        _ = try readTLV(outer.value, offset: &inner)
        let key = try readTLV(outer.value, offset: &inner)
        guard key.tag == 0x04, !key.value.isEmpty else {
            throw GCSError.invalidKey("private_key is missing the RSA key.")
        }
        return key.value
    }

    private struct TLV {
        let tag: UInt8
        let value: Data
    }

    private static func readTLV(_ data: Data, offset: inout Int) throws -> TLV {
        guard offset < data.count else { throw GCSError.invalidKey("private_key was truncated.") }
        let tag = data[offset]
        offset += 1
        guard offset < data.count else { throw GCSError.invalidKey("private_key was truncated.") }
        let lengthByte = data[offset]
        offset += 1
        let length: Int
        if lengthByte < 0x80 {
            length = Int(lengthByte)
        } else {
            let count = Int(lengthByte & 0x7f)
            guard count > 0, count <= 3, offset + count <= data.count else {
                throw GCSError.invalidKey("private_key has a bad length.")
            }
            length = data[offset..<(offset + count)].reduce(0) { ($0 << 8) | Int($1) }
            offset += count
        }
        guard offset + length <= data.count else {
            throw GCSError.invalidKey("private_key was truncated.")
        }
        let value = data.subdata(in: offset..<(offset + length))
        offset += length
        return TLV(tag: tag, value: value)
    }
}
