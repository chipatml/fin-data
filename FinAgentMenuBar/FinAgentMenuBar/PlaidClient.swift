//
//  PlaidClient.swift
//  FinAgentMenuBar
//
//  Thin async client over the Plaid REST API. Credentials (client_id,
//  secret, access_token) are supplied by the caller — see APIKeyManager —
//  and sent in the JSON body of every request, as Plaid expects.
//

import CryptoKit
import Foundation
import os

/// Normalizes and describes Plaid credential text without exposing secrets.
enum PlaidCredentialText {
    private static var loggedNormalizations: Set<String> = []

    /// Folds smart punctuation to ASCII, then drops whitespace, control
    /// characters, and invisible characters anywhere in the string. macOS text
    /// fields turn a hyphen or quote into a lookalike (en dash, curly quote)
    /// that keeps the same character count and changes the UTF-8 Plaid checks.
    static func normalized(_ value: String) -> String {
        let folded = foldSmartPunctuation(value)
        let filtered = folded.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
                && !scalar.properties.isDefaultIgnorableCodePoint
        }
        let result = String(String.UnicodeScalarView(filtered))
        logNormalizationIfNeeded(raw: value, sent: result)
        return result
    }

    /// First 8 hex digits of SHA-256 over the UTF-8 bytes. Compare with
    /// `printf %s 'SECRET' | shasum -a 256` (not `echo`, which adds a newline).
    static func sha256Prefix(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(4).reduce(into: "") { partial, byte in
            partial += String(format: "%02x", byte)
        }
    }

    /// Counts, hash, and code points. Never includes the credential text.
    /// `revealPrefix` is only for a client_id, whose first four characters are
    /// already shown in the UI.
    static func fingerprintLine(_ value: String, label: String, revealPrefix: Bool) -> String {
        let prefix: String
        if revealPrefix, !value.isEmpty {
            prefix = " \(value.prefix(4))…"
        } else {
            prefix = ""
        }
        return "\(label)\(prefix) \(anomalySummary(value)) sha256:\(sha256Prefix(value))"
    }

    /// Character count, UTF-8 byte count, and non-ASCII / other-ASCII scalars
    /// as `index:U+XXXX`. The character itself is not included.
    static func anomalySummary(_ value: String) -> String {
        let scalars = value.unicodeScalars.count
        let chars = value.count
        let charText = chars == scalars ? "chars \(chars)" : "chars \(chars) scalars \(scalars)"
        return "\(charText) utf8 \(value.utf8.count) nonascii \(codePointList(value, where: { $0.value > 127 })) other-ascii \(codePointList(value, where: isOtherASCII))"
    }

    /// First four characters and the length. Never the full client_id.
    static func clientIdLabel(_ clientId: String) -> String {
        guard !clientId.isEmpty else { return "empty" }
        return "\(clientId.prefix(4))… len \(clientId.count)"
    }

    /// `index:U+XXXX` for scalars matching `include`, capped so a long secret
    /// cannot flood the log. Empty means `none`.
    static func codePointList(_ value: String, where include: (Unicode.Scalar) -> Bool) -> String {
        var notes: [String] = []
        var extra = 0
        for (index, scalar) in value.unicodeScalars.enumerated() where include(scalar) {
            if notes.count < 8 {
                notes.append("\(index):U+\(String(format: "%04X", scalar.value))")
            } else {
                extra += 1
            }
        }
        guard !notes.isEmpty else { return "none" }
        if extra > 0 {
            return notes.joined(separator: ",") + " +\(extra)"
        }
        return notes.joined(separator: ",")
    }

    private static func isOtherASCII(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        guard value < 128 else { return false }
        let isDigit = value >= 0x30 && value <= 0x39
        let isUpper = value >= 0x41 && value <= 0x5A
        let isLower = value >= 0x61 && value <= 0x7A
        return !(isDigit || isUpper || isLower)
    }

    /// Maps dash and quote lookalikes, and fullwidth ASCII, onto the characters
    /// Plaid issued. ASCII hyphens and quotes are left alone.
    private static func foldSmartPunctuation(_ value: String) -> String {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            scalars.append(foldedScalar(scalar))
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func foldedScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D:
            return Unicode.Scalar(0x2D)!
        case 0x2018, 0x2019, 0x201A, 0x201B:
            return Unicode.Scalar(0x27)!
        case 0x201C, 0x201D, 0x201E, 0x201F:
            return Unicode.Scalar(0x22)!
        case 0xFF01...0xFF5E:
            return Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar
        default:
            return scalar
        }
    }

    /// One console line per distinct normalization. The line is counts and code
    /// points only, so a secret never appears in the log.
    private static func logNormalizationIfNeeded(raw: String, sent: String) {
        guard raw != sent else { return }
        let line = "PlaidCredentialText normalized before use; sent sha256:\(sha256Prefix(sent)) raw \(anomalySummary(raw)); sent \(anomalySummary(sent))"
        guard loggedNormalizations.insert(line).inserted else { return }
        if loggedNormalizations.count > 32 {
            loggedNormalizations.removeAll()
            loggedNormalizations.insert(line)
        }
        print(line)
    }

    /// The fixed environment tag of a Plaid access token, not its unique id.
    static func accessTokenKind(_ token: String) -> String {
        for kind in ["access-sandbox", "access-production", "access-development"] {
            if token.hasPrefix(kind + "-") { return kind }
        }
        return "unrecognized"
    }
}

// MARK: - Credentials & Environment

struct PlaidCredentials {
    let clientId: String
    let secret: String
    let accessToken: String
    /// Keychain slot the client_id and secret were read from: sandbox, production, or legacy.
    let source: String

    /// Safe to log and show in the UI. Includes no secret and no access-token id.
    func debugSummary(
        environment: PlaidEnvironment,
        url: URL,
        sendsAccessToken: Bool,
        bodyKeys: [String] = [],
        normalizationNotes: [String] = []
    ) -> String {
        let token: String
        if sendsAccessToken {
            token = "\(PlaidCredentialText.anomalySummary(accessToken)), kind \(PlaidCredentialText.accessTokenKind(accessToken))"
        } else {
            token = "not sent"
        }
        var parts = [
            "slot \(source)",
            PlaidCredentialText.fingerprintLine(clientId, label: "client_id", revealPrefix: true),
            PlaidCredentialText.fingerprintLine(secret, label: "secret", revealPrefix: false),
            "access token \(token)",
            url.absoluteString,
            "app header Content-Type application/json",
            "no PLAID-CLIENT-ID",
            "no PLAID-SECRET",
            "no Plaid-Version"
        ]
        if !bodyKeys.isEmpty {
            parts.append("body keys \(bodyKeys.joined(separator: ","))")
        }
        parts.append(contentsOf: normalizationNotes)
        return parts.joined(separator: ", ")
    }
}

/// Metadata for one stored access token. The token itself lives in the
/// keychain, keyed by `id`; only the non-secret label + id are persisted here.
struct PlaidTokenEntry: Codable, Identifiable, Hashable {
    let id: String
    var label: String
    /// `sandbox` or `production` for tokens saved with a known host.
    /// Nil on tokens added before environments were stored; those follow the
    /// environment currently selected in the menu.
    var environment: String?

    init(id: String = UUID().uuidString, label: String, environment: PlaidEnvironment? = nil) {
        self.id = id
        self.label = label
        self.environment = environment?.rawValue
    }

    var plaidEnvironment: PlaidEnvironment? {
        guard let environment, let parsed = PlaidEnvironment(rawValue: environment),
              PlaidEnvironment.settingsChoices.contains(parsed) else {
            return nil
        }
        return parsed
    }
}

enum PlaidEnvironment: String, CaseIterable, Identifiable {
    case sandbox
    case development
    case production

    var id: String { rawValue }

    /// Environments the credential UI offers. Development remains only so older
    /// hosts still have a URL if a caller names that case.
    static let settingsChoices: [PlaidEnvironment] = [.sandbox, .production]

    var displayName: String {
        switch self {
        case .sandbox: return "Sandbox"
        case .development: return "Development"
        case .production: return "Production"
        }
    }

    var baseURL: URL {
        switch self {
        case .sandbox:     return URL(string: "https://sandbox.plaid.com")!
        case .development: return URL(string: "https://development.plaid.com")!
        case .production:  return URL(string: "https://production.plaid.com")!
        }
    }

    var hostDescription: String {
        baseURL.host ?? displayName
    }
}

// MARK: - Errors

/// Mirrors the standard Plaid error envelope returned on non-2xx responses.
struct PlaidAPIError: Codable, Error, LocalizedError {
    let errorType: String?
    let errorCode: String?
    let errorMessage: String?
    let displayMessage: String?
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case errorType = "error_type"
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case displayMessage = "display_message"
        case requestId = "request_id"
    }

    /// Host the failing request was sent to. Not part of Plaid's JSON envelope.
    var environment: PlaidEnvironment? = nil
    /// Lengths and a client_id prefix. Never a secret. Not part of Plaid's JSON.
    var debugSummary: String? = nil

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errorType = try container.decodeIfPresent(String.self, forKey: .errorType)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        displayMessage = try container.decodeIfPresent(String.self, forKey: .displayMessage)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        environment = nil
        debugSummary = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(errorType, forKey: .errorType)
        try container.encodeIfPresent(errorCode, forKey: .errorCode)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(displayMessage, forKey: .displayMessage)
        try container.encodeIfPresent(requestId, forKey: .requestId)
    }

    var errorDescription: String? {
        let code = errorCode ?? "UNKNOWN"
        let message = errorMessage ?? displayMessage ?? "Unknown Plaid error"
        var text = "\(code) — \(message)"
        if let displayMessage, !displayMessage.isEmpty, displayMessage != message {
            text += " — \(displayMessage)"
        }
        if let environment {
            text = "\(environment.displayName): \(text)"
        }
        if let debugSummary {
            text += ". \(debugSummary)"
        }
        return text
    }

    /// True when the error means this product simply isn't available for the
    /// item or client — e.g. the institution/integration doesn't support it,
    /// or the client isn't authorized for it — rather than a genuine failure.
    /// These are safe to skip so other products still load.
    var isProductUnavailable: Bool {
        let unavailableCodes: Set<String> = [
            "INVALID_PRODUCT",           // client not authorized for the product
            "PRODUCTS_NOT_SUPPORTED",    // institution doesn't support it
            "PRODUCT_NOT_READY",         // data not yet available for this item
            "NO_ACCOUNTS",               // no accounts of the required type
            "ADDITIONAL_CONSENT_REQUIRED"
        ]
        if let code = errorCode, unavailableCodes.contains(code) { return true }
        let text = (errorMessage ?? displayMessage ?? "").lowercased()
        return text.contains("does not have access")
            || text.contains("not authorized to access")
            || text.contains("not supported")
    }
}

enum PlaidClientError: Error, LocalizedError {
    case invalidResponse(environment: PlaidEnvironment)
    case http(status: Int, body: String, environment: PlaidEnvironment)
    case credentialEncodingMismatch(environment: PlaidEnvironment, summary: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let environment):
            return "\(environment.displayName): Invalid response from Plaid"
        case .http(let status, let body, let environment):
            return "\(environment.displayName): Plaid HTTP \(status): \(body)"
        case .credentialEncodingMismatch(let environment, let summary):
            return "\(environment.displayName): JSON encoding changed client_id or secret, so the request was not sent. \(summary)"
        }
    }
}

/// Placeholder curl for the credential probe. The command never contains a
/// real client_id or secret; the owner pastes those locally and compares hashes.
enum PlaidProbeCurl {
    static func placeholderCommand(for environment: PlaidEnvironment) -> String {
        let url = environment.baseURL.appendingPathComponent("institutions/get").absoluteString
        return """
        curl -sS -X POST '\(url)' \\
          -H 'Content-Type: application/json' \\
          -d '{"client_id":"CLIENT_ID","secret":"SECRET","count":1,"offset":0,"country_codes":["US"]}'
        # Compare the app secret sha256 (first 8 hex) with:
        # printf %s 'SECRET' | shasum -a 256
        # Do not use echo; it adds a newline and changes the hash.
        """
    }
}

// MARK: - Shared response models

struct PlaidBalances: Codable {
    let available: Double?
    let current: Double?
    let limit: Double?
    let isoCurrencyCode: String?

    enum CodingKeys: String, CodingKey {
        case available, current, limit
        case isoCurrencyCode = "iso_currency_code"
    }
}

struct PlaidAccount: Codable, Identifiable {
    let accountId: String
    let name: String?
    let officialName: String?
    let mask: String?
    let type: String?
    let subtype: String?
    let balances: PlaidBalances?

    var id: String { accountId }

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case name
        case officialName = "official_name"
        case mask, type, subtype, balances
    }
}

struct PlaidSecurity: Codable, Identifiable {
    let securityId: String
    let name: String?
    let tickerSymbol: String?
    let type: String?
    let closePrice: Double?
    let isoCurrencyCode: String?

    var id: String { securityId }

    enum CodingKeys: String, CodingKey {
        case securityId = "security_id"
        case name
        case tickerSymbol = "ticker_symbol"
        case type
        case closePrice = "close_price"
        case isoCurrencyCode = "iso_currency_code"
    }
}

// MARK: - Transactions

struct PlaidPersonalFinanceCategory: Codable {
    let primary: String?
    let detailed: String?
}

struct PlaidTransaction: Codable, Identifiable {
    let transactionId: String
    let accountId: String
    let amount: Double
    let isoCurrencyCode: String?
    let date: String
    let name: String?
    let merchantName: String?
    let pending: Bool?
    let category: [String]?
    let personalFinanceCategory: PlaidPersonalFinanceCategory?

    var id: String { transactionId }

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case accountId = "account_id"
        case amount
        case isoCurrencyCode = "iso_currency_code"
        case date, name
        case merchantName = "merchant_name"
        case pending, category
        case personalFinanceCategory = "personal_finance_category"
    }
}

struct PlaidRemovedTransaction: Codable {
    let transactionId: String
    enum CodingKeys: String, CodingKey { case transactionId = "transaction_id" }
}

private struct TransactionsSyncResponse: Codable {
    let added: [PlaidTransaction]
    let modified: [PlaidTransaction]
    let removed: [PlaidRemovedTransaction]
    let nextCursor: String
    let hasMore: Bool
    let accounts: [PlaidAccount]?

    enum CodingKeys: String, CodingKey {
        case added, modified, removed
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
        case accounts
    }
}

/// Aggregated result of walking every page of `/transactions/sync`.
struct PlaidTransactionsResult: Encodable {
    var added: [PlaidTransaction] = []
    var modified: [PlaidTransaction] = []
    var removed: [String] = []
    var cursor: String = ""
    var accounts: [PlaidAccount] = []
}

// MARK: - Statements

struct PlaidStatement: Codable, Identifiable {
    let statementId: String
    let month: Int?
    let year: Int?

    var id: String { statementId }

    enum CodingKeys: String, CodingKey {
        case statementId = "statement_id"
        case month, year
    }
}

struct PlaidStatementAccount: Codable, Identifiable {
    let accountId: String
    let accountName: String?
    let accountMask: String?
    let statements: [PlaidStatement]

    var id: String { accountId }

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case accountName = "account_name"
        case accountMask = "account_mask"
        case statements
    }
}

struct PlaidStatementsResult: Codable {
    let accounts: [PlaidStatementAccount]
    let institutionName: String?

    enum CodingKeys: String, CodingKey {
        case accounts
        case institutionName = "institution_name"
    }
}

// MARK: - Investments

struct PlaidHolding: Codable {
    let accountId: String
    let securityId: String
    let quantity: Double?
    let institutionPrice: Double?
    let institutionValue: Double?
    let costBasis: Double?
    let isoCurrencyCode: String?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case securityId = "security_id"
        case quantity
        case institutionPrice = "institution_price"
        case institutionValue = "institution_value"
        case costBasis = "cost_basis"
        case isoCurrencyCode = "iso_currency_code"
    }
}

struct PlaidInvestmentHoldings: Codable {
    let accounts: [PlaidAccount]
    let holdings: [PlaidHolding]
    let securities: [PlaidSecurity]
}

struct PlaidInvestmentTransaction: Codable, Identifiable {
    let investmentTransactionId: String
    let accountId: String
    let securityId: String?
    let date: String
    let name: String?
    let quantity: Double?
    let amount: Double?
    let price: Double?
    let fees: Double?
    let type: String?
    let subtype: String?
    let isoCurrencyCode: String?

    var id: String { investmentTransactionId }

    enum CodingKeys: String, CodingKey {
        case investmentTransactionId = "investment_transaction_id"
        case accountId = "account_id"
        case securityId = "security_id"
        case date, name, quantity, amount, price, fees, type, subtype
        case isoCurrencyCode = "iso_currency_code"
    }
}

private struct InvestmentsTransactionsResponse: Codable {
    let accounts: [PlaidAccount]
    let securities: [PlaidSecurity]
    let investmentTransactions: [PlaidInvestmentTransaction]
    let totalInvestmentTransactions: Int

    enum CodingKeys: String, CodingKey {
        case accounts, securities
        case investmentTransactions = "investment_transactions"
        case totalInvestmentTransactions = "total_investment_transactions"
    }
}

struct PlaidInvestmentTransactionsResult: Encodable {
    var accounts: [PlaidAccount] = []
    var securities: [PlaidSecurity] = []
    var transactions: [PlaidInvestmentTransaction] = []
}

// MARK: - Liabilities

struct PlaidCreditLiability: Codable {
    let accountId: String?
    let lastStatementBalance: Double?
    let lastStatementIssueDate: String?
    let minimumPaymentAmount: Double?
    let nextPaymentDueDate: String?
    let isOverdue: Bool?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case lastStatementBalance = "last_statement_balance"
        case lastStatementIssueDate = "last_statement_issue_date"
        case minimumPaymentAmount = "minimum_payment_amount"
        case nextPaymentDueDate = "next_payment_due_date"
        case isOverdue = "is_overdue"
    }
}

struct PlaidMortgageLiability: Codable {
    let accountId: String?
    let outstandingPrincipalBalance: Double?
    let nextMonthlyPayment: Double?
    let nextPaymentDueDate: String?
    let interestRatePercentage: Double?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case outstandingPrincipalBalance = "outstanding_principal_balance"
        case nextMonthlyPayment = "next_monthly_payment"
        case nextPaymentDueDate = "next_payment_due_date"
        case interestRatePercentage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId)
        outstandingPrincipalBalance = try c.decodeIfPresent(Double.self, forKey: .outstandingPrincipalBalance)
        nextMonthlyPayment = try c.decodeIfPresent(Double.self, forKey: .nextMonthlyPayment)
        nextPaymentDueDate = try c.decodeIfPresent(String.self, forKey: .nextPaymentDueDate)
        // interest_rate is a nested object { percentage, type }; pull just the percentage.
        if let rate = try? c.nestedContainer(keyedBy: InterestRateKeys.self, forKey: .interestRatePercentage) {
            interestRatePercentage = try rate.decodeIfPresent(Double.self, forKey: .percentage)
        } else {
            interestRatePercentage = nil
        }
    }

    private enum InterestRateKeys: String, CodingKey {
        case percentage
    }
}

struct PlaidStudentLiability: Codable {
    let accountId: String?
    let outstandingInterestAmount: Double?
    let minimumPaymentAmount: Double?
    let nextPaymentDueDate: String?
    let interestRatePercentage: Double?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case outstandingInterestAmount = "outstanding_interest_amount"
        case minimumPaymentAmount = "minimum_payment_amount"
        case nextPaymentDueDate = "next_payment_due_date"
        case interestRatePercentage = "interest_rate_percentage"
    }
}

struct PlaidLiabilities: Codable {
    let credit: [PlaidCreditLiability]?
    let mortgage: [PlaidMortgageLiability]?
    let student: [PlaidStudentLiability]?
}

struct PlaidLiabilitiesResult: Codable {
    let accounts: [PlaidAccount]
    let liabilities: PlaidLiabilities
}

// MARK: - Rotate access token

private struct RotateAccessTokenResponse: Codable {
    let newAccessToken: String
    enum CodingKeys: String, CodingKey { case newAccessToken = "new_access_token" }
}

// MARK: - Client

struct PlaidClient {
    let credentials: PlaidCredentials
    let environment: PlaidEnvironment
    private let session: URLSession
    private let decoder: JSONDecoder
    private let log = Logger(subsystem: "com.mlaid.FinAgentMenuBar", category: "Plaid")

    init(credentials: PlaidCredentials,
         environment: PlaidEnvironment,
         session: URLSession = .shared) {
        self.credentials = credentials
        self.environment = environment
        self.session = session
        self.decoder = JSONDecoder()
    }

    // MARK: Public API

    /// Incrementally fetch transactions. Pass the cursor persisted from a
    /// previous call to receive only new/updated/removed transactions;
    /// pass `nil` (or "") for a full initial sync. Walks every page.
    func fetchTransactions(startingCursor: String? = nil) async throws -> PlaidTransactionsResult {
        var result = PlaidTransactionsResult()
        var cursor = startingCursor ?? ""
        var hasMore = true

        while hasMore {
            var body: [String: Any] = ["count": 500]
            if !cursor.isEmpty { body["cursor"] = cursor }

            let page: TransactionsSyncResponse = try await post("/transactions/sync", body: body)
            result.added.append(contentsOf: page.added)
            result.modified.append(contentsOf: page.modified)
            result.removed.append(contentsOf: page.removed.map { $0.transactionId })
            if let accounts = page.accounts { result.accounts = accounts }

            cursor = page.nextCursor
            hasMore = page.hasMore
        }

        result.cursor = cursor
        return result
    }

    /// List available statements grouped by account.
    func fetchStatements() async throws -> PlaidStatementsResult {
        try await post("/statements/list", body: [:])
    }

    /// Current investment holdings + the securities they reference.
    func fetchInvestmentHoldings() async throws -> PlaidInvestmentHoldings {
        try await post("/investments/holdings/get", body: [:])
    }

    /// Investment transactions in a date range (YYYY-MM-DD). Walks every page.
    func fetchInvestmentTransactions(startDate: String, endDate: String) async throws -> PlaidInvestmentTransactionsResult {
        var result = PlaidInvestmentTransactionsResult()
        var offset = 0
        let pageSize = 500

        while true {
            let body: [String: Any] = [
                "start_date": startDate,
                "end_date": endDate,
                "options": ["count": pageSize, "offset": offset]
            ]
            let page: InvestmentsTransactionsResponse = try await post("/investments/transactions/get", body: body)

            if offset == 0 {
                result.accounts = page.accounts
                result.securities = page.securities
            }
            result.transactions.append(contentsOf: page.investmentTransactions)

            offset += page.investmentTransactions.count
            if offset >= page.totalInvestmentTransactions || page.investmentTransactions.isEmpty {
                break
            }
        }
        return result
    }

    /// Liabilities (credit cards, mortgages, student loans).
    func fetchLiabilities() async throws -> PlaidLiabilitiesResult {
        try await post("/liabilities/get", body: [:])
    }

    /// Starts a Hosted Link session for this client's environment. The returned
    /// link token and URL are credentials for that session; callers must not log them.
    func createHostedLink(clientUserId: String, includeOptionalProducts: Bool = true) async throws -> HostedLinkSession {
        let end = Date()
        let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -730, to: end) ?? end
        var body: [String: Any] = [
            "client_name": "FinAgent",
            "language": "en",
            "country_codes": ["US"],
            "user": ["client_user_id": clientUserId],
            "products": ["transactions"],
            "transactions": ["days_requested": 730],
            "hosted_link": [String: String]()
        ]
        if includeOptionalProducts {
            body["optional_products"] = ["investments", "liabilities", "statements"]
            body["statements"] = [
                "start_date": Self.plaidDay(start),
                "end_date": Self.plaidDay(end)
            ]
        }
        let response: LinkTokenCreateResponse = try await post(
            "/link/token/create",
            body: body,
            sendsAccessToken: false,
            omitsResponseBody: true
        )
        guard let rawURL = response.hostedLinkURL, let url = URL(string: rawURL), Self.isPlaidHostedLinkURL(url) else {
            throw HostedLinkError.missingURL(environment: environment)
        }
        guard !response.linkToken.isEmpty else {
            throw HostedLinkError.missingURL(environment: environment)
        }
        return HostedLinkSession(
            url: url,
            linkToken: response.linkToken,
            expiration: Self.parsePlaidDate(response.expiration)
        )
    }

    /// One poll of `/link/token/get`. Public tokens stay inside the returned
    /// items and are not logged.
    func hostedLinkStatus(linkToken: String) async throws -> HostedLinkPoll {
        let response: LinkTokenGetResponse = try await post(
            "/link/token/get",
            body: ["link_token": linkToken],
            sendsAccessToken: false,
            logsRequest: false,
            omitsResponseBody: true
        )
        return HostedLinkPoll.parse(response)
    }

    /// Exchanges one public token. The access token in the result must not be logged.
    func exchangePublicToken(_ publicToken: String) async throws -> String {
        let response: PublicTokenExchangeResponse = try await post(
            "/item/public_token/exchange",
            body: ["public_token": publicToken],
            sendsAccessToken: false,
            logsRequest: false,
            omitsResponseBody: true
        )
        let accessToken = PlaidCredentialText.normalized(response.accessToken)
        guard !accessToken.isEmpty else {
            throw HostedLinkError.exchangeEmpty(environment: environment)
        }
        return accessToken
    }

    private static func isPlaidHostedLinkURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "plaid.com" || host.hasSuffix(".plaid.com")
    }

    private static func plaidDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func parsePlaidDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    /// Confirms client_id and secret with Plaid before any access token is sent.
    /// `/institutions/get` checks the key pair and does not take an access token,
    /// so a failure here is INVALID_API_KEYS rather than a bad token.
    func verifyClientCredentials() async throws {
        let body: [String: Any] = [
            "count": 1,
            "offset": 0,
            "country_codes": ["US"]
        ]
        let _: EmptyJSONObject = try await post("/institutions/get", body: body, sendsAccessToken: false)
    }

    /// Rotate this Item's access token. Invalidates the current token
    /// immediately and returns a new one for the same Item.
    func rotateAccessToken() async throws -> String {
        let response: RotateAccessTokenResponse = try await post("/item/access_token/invalidate", body: [:])
        return response.newAccessToken
    }

    // MARK: Request plumbing

    /// POST `body` (with credentials injected) to `path` and decode the reply.
    /// Credentials go in the JSON body (`client_id`, `secret`), which is what
    /// `https://sandbox.plaid.com/institutions/get` accepts. `PLAID-CLIENT-ID`,
    /// `PLAID-SECRET`, and `Plaid-Version` are not set; a working curl does not
    /// send them either.
    private func post<T: Decodable>(
        _ path: String,
        body: [String: Any],
        sendsAccessToken: Bool = true,
        logsRequest: Bool = true,
        omitsResponseBody: Bool = false
    ) async throws -> T {
        guard let url = endpointURL(path) else {
            throw PlaidClientError.invalidResponse(environment: environment)
        }
        let rawClientId = credentials.clientId
        let rawSecret = credentials.secret
        let clientId = PlaidCredentialText.normalized(rawClientId)
        let secret = PlaidCredentialText.normalized(rawSecret)
        let accessToken = PlaidCredentialText.normalized(credentials.accessToken)
        var notes: [String] = []
        if rawClientId != clientId {
            notes.append("client_id normalized before send; raw \(PlaidCredentialText.anomalySummary(rawClientId))")
        }
        if rawSecret != secret {
            notes.append("secret normalized before send; raw \(PlaidCredentialText.anomalySummary(rawSecret))")
        }

        var payload = body
        payload["client_id"] = clientId
        payload["secret"] = secret
        if sendsAccessToken {
            payload["access_token"] = accessToken
        } else {
            payload.removeValue(forKey: "access_token")
        }
        let bodyKeys = payload.keys.map { String(describing: $0) }.sorted()
        let summary = PlaidCredentials(
            clientId: clientId,
            secret: secret,
            accessToken: accessToken,
            source: credentials.source
        ).debugSummary(
            environment: environment,
            url: url,
            sendsAccessToken: sendsAccessToken,
            bodyKeys: bodyKeys,
            normalizationNotes: notes
        )
        // Safe fields only: hashes, lengths, and code points. Never the secret or token id.
        // Link polling skips this line so a 30-minute wait does not reprint credentials.
        if logsRequest {
            let line = "Plaid \(environment.rawValue) POST \(summary)"
            print(line)
            log.info("\(line, privacy: .public)")
            let nonASCII = "Plaid non-ASCII detection client_id \(PlaidCredentialText.codePointList(clientId, where: { $0.value > 127 })) secret \(PlaidCredentialText.codePointList(secret, where: { $0.value > 127 }))"
            print(nonASCII)
            log.info("\(nonASCII, privacy: .public)")
        }

        let encoded = try jsonBody(payload, clientId: clientId, secret: secret, accessToken: sendsAccessToken ? accessToken : nil, summary: summary)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(nil, forHTTPHeaderField: "PLAID-CLIENT-ID")
        request.setValue(nil, forHTTPHeaderField: "PLAID-SECRET")
        request.setValue(nil, forHTTPHeaderField: "Plaid-Version")
        request.setValue(nil, forHTTPHeaderField: "PLAID-VERSION")
        request.httpBody = encoded

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw PlaidClientError.invalidResponse(environment: environment)
        }

        guard (200...299).contains(http.statusCode) else {
            // Plaid returns a structured error envelope on failure.
            if var apiError = try? decoder.decode(PlaidAPIError.self, from: data) {
                apiError.environment = environment
                apiError.debugSummary = summary
                let failure = "Plaid error \(apiError.errorCode ?? "?") \(apiError.errorMessage ?? "") \(summary)"
                print(failure)
                log.error("\(failure, privacy: .public)")
                throw apiError
            }
            let bodyText = omitsResponseBody ? "response omitted" : (String(data: data, encoding: .utf8) ?? "<no body>")
            throw PlaidClientError.http(status: http.statusCode, body: bodyText, environment: environment)
        }

        return try decoder.decode(T.self, from: data)
    }

    /// Encodes `payload` and refuses to send if `client_id` or `secret` is not
    /// the same string after a JSON parse. Slashes stay as `/`, matching curl.
    private func jsonBody(
        _ payload: [String: Any],
        clientId: String,
        secret: String,
        accessToken: String?,
        summary: String
    ) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let object = parsed as? [String: Any],
              (object["client_id"] as? String) == clientId,
              (object["secret"] as? String) == secret,
              accessToken == nil || (object["access_token"] as? String) == accessToken else {
            throw PlaidClientError.credentialEncodingMismatch(environment: environment, summary: summary)
        }
        return data
    }

    /// Path join that keeps `/transactions/sync` as a real path. `appendingPathComponent`
    /// percent-encodes `?` and can treat a leading slash as one component.
    private func endpointURL(_ path: String) -> URL? {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(url: environment.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.path
        if basePath.isEmpty || basePath == "/" {
            components.path = "/" + relative
        } else {
            components.path = (basePath.hasSuffix("/") ? basePath : basePath + "/") + relative
        }
        return components.url
    }
}

/// Decodes a JSON object while ignoring its keys. Used for the credential probe.
private struct EmptyJSONObject: Decodable {}

/// A Hosted Link session. `linkToken` and `url` grant access to that session
/// for its lifetime. Do not log, persist, or put them in UI text.
struct HostedLinkSession {
    let url: URL
    let linkToken: String
    let expiration: Date?
}

/// One bank the user added. `publicToken` is exchanged immediately and never logged.
struct HostedLinkAddedItem {
    let institutionName: String
    let publicToken: String
}

struct HostedLinkPoll {
    let finished: Bool
    let items: [HostedLinkAddedItem]

    fileprivate static func parse(_ response: LinkTokenGetResponse) -> HostedLinkPoll {
        let sessions = response.linkSessions ?? []
        let finished = !sessions.isEmpty && sessions.allSatisfy { session in
            let stamp = session.finishedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !stamp.isEmpty
        }
        var items: [HostedLinkAddedItem] = []
        var seen: Set<String> = []
        for session in sessions {
            let added = session.results?.itemAddResults ?? []
            if !added.isEmpty {
                for result in added {
                    appendItem(
                        publicToken: result.publicToken,
                        institutionName: result.institution?.name,
                        into: &items,
                        seen: &seen
                    )
                }
            } else {
                appendItem(
                    publicToken: session.onSuccess?.publicToken,
                    institutionName: session.onSuccess?.metadata?.institution?.name,
                    into: &items,
                    seen: &seen
                )
            }
        }
        return HostedLinkPoll(finished: finished, items: items)
    }

    private static func appendItem(
        publicToken: String?,
        institutionName: String?,
        into items: inout [HostedLinkAddedItem],
        seen: inout Set<String>
    ) {
        let token = PlaidCredentialText.normalized(publicToken ?? "")
        guard !token.isEmpty, seen.insert(token).inserted else { return }
        items.append(HostedLinkAddedItem(institutionName: institutionLabel(institutionName), publicToken: token))
    }

    private static func institutionLabel(_ raw: String?) -> String {
        let flattened = (raw ?? "").replacingOccurrences(of: "\n", with: " ")
        let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Linked bank" }
        if trimmed.count > 80 { return String(trimmed.prefix(80)) }
        return trimmed
    }
}

enum HostedLinkError: Error, LocalizedError {
    case missingURL(environment: PlaidEnvironment)
    case exchangeEmpty(environment: PlaidEnvironment)
    case endedWithoutBank(environment: PlaidEnvironment)
    case timedOut(environment: PlaidEnvironment)
    case browserFailed(environment: PlaidEnvironment)

    var errorDescription: String? {
        switch self {
        case .missingURL(let environment):
            return "\(environment.displayName): Plaid did not return a hosted_link_url. Hosted Link was not started for this session."
        case .exchangeEmpty(let environment):
            return "\(environment.displayName): Plaid did not return an access token from public_token exchange."
        case .endedWithoutBank(let environment):
            return "\(environment.displayName): the link ended without a connected bank."
        case .timedOut(let environment):
            return "\(environment.displayName): the link timed out after 30 minutes. No bank was saved. Start Link a bank again."
        case .browserFailed(let environment):
            return "\(environment.displayName): the bank link could not be opened in the browser."
        }
    }
}

private struct LinkTokenCreateResponse: Decodable {
    let hostedLinkURL: String?
    let linkToken: String
    let expiration: String?

    enum CodingKeys: String, CodingKey {
        case hostedLinkURL = "hosted_link_url"
        case linkToken = "link_token"
        case expiration
    }
}

private struct LinkTokenGetResponse: Decodable {
    let linkSessions: [LinkTokenSession]?

    enum CodingKeys: String, CodingKey {
        case linkSessions = "link_sessions"
    }
}

private struct LinkTokenSession: Decodable {
    let finishedAt: String?
    let results: LinkTokenSessionResults?
    let onSuccess: LinkTokenOnSuccess?

    enum CodingKeys: String, CodingKey {
        case finishedAt = "finished_at"
        case results
        case onSuccess = "on_success"
    }
}

private struct LinkTokenSessionResults: Decodable {
    let itemAddResults: [LinkTokenItemAdd]?

    enum CodingKeys: String, CodingKey {
        case itemAddResults = "item_add_results"
    }
}

private struct LinkTokenItemAdd: Decodable {
    let publicToken: String?
    let institution: LinkTokenInstitution?

    enum CodingKeys: String, CodingKey {
        case publicToken = "public_token"
        case institution
    }
}

private struct LinkTokenOnSuccess: Decodable {
    let publicToken: String?
    let metadata: LinkTokenSuccessMetadata?

    enum CodingKeys: String, CodingKey {
        case publicToken = "public_token"
        case metadata
    }
}

private struct LinkTokenSuccessMetadata: Decodable {
    let institution: LinkTokenInstitution?
}

private struct LinkTokenInstitution: Decodable {
    let name: String?
}

private struct PublicTokenExchangeResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}
