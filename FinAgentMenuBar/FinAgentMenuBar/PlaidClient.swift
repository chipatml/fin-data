//
//  PlaidClient.swift
//  FinAgentMenuBar
//
//  Thin async client over the Plaid REST API. Credentials (client_id,
//  secret, access_token) are supplied by the caller — see APIKeyManager —
//  and sent in the JSON body of every request, as Plaid expects.
//

import Foundation

// MARK: - Credentials & Environment

struct PlaidCredentials {
    let clientId: String
    let secret: String
    let accessToken: String
}

/// Metadata for one stored access token. The token itself lives in the
/// keychain, keyed by `id`; only the non-secret label + id are persisted here.
struct PlaidTokenEntry: Codable, Identifiable, Hashable {
    let id: String
    var label: String

    init(id: String = UUID().uuidString, label: String) {
        self.id = id
        self.label = label
    }
}

enum PlaidEnvironment {
    case sandbox
    case development
    case production

    var baseURL: URL {
        switch self {
        case .sandbox:     return URL(string: "https://sandbox.plaid.com")!
        case .development: return URL(string: "https://development.plaid.com")!
        case .production:  return URL(string: "https://production.plaid.com")!
        }
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

    var errorDescription: String? {
        displayMessage ?? errorMessage ?? errorCode ?? "Unknown Plaid error"
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
    case invalidResponse
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Plaid"
        case .http(let status, let body):
            return "Plaid HTTP \(status): \(body)"
        }
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

    init(credentials: PlaidCredentials,
         environment: PlaidEnvironment = .production,
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

    /// Rotate this Item's access token. Invalidates the current token
    /// immediately and returns a new one for the same Item.
    func rotateAccessToken() async throws -> String {
        let response: RotateAccessTokenResponse = try await post("/item/access_token/invalidate", body: [:])
        return response.newAccessToken
    }

    // MARK: Request plumbing

    /// POST `body` (with credentials injected) to `path` and decode the reply.
    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var payload = body
        payload["client_id"] = credentials.clientId
        payload["secret"] = credentials.secret
        payload["access_token"] = credentials.accessToken

        var request = URLRequest(url: environment.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw PlaidClientError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            // Plaid returns a structured error envelope on failure.
            if let apiError = try? decoder.decode(PlaidAPIError.self, from: data) {
                throw apiError
            }
            let bodyText = String(data: data, encoding: .utf8) ?? "<no body>"
            throw PlaidClientError.http(status: http.statusCode, body: bodyText)
        }

        return try decoder.decode(T.self, from: data)
    }
}
