//
//  FinAgentDataManager.swift
//  FinAgentMenuBar
//
//  Created by Chirag Patel on 7/16/26.
//

import SwiftUI
import Combine
import AppKit

/// A per-product problem encountered while pulling one token's data.
struct ProductIssue: Identifiable, Codable {
    let id: UUID
    let product: String
    let message: String
    /// True when the product is simply unavailable for this item (soft skip),
    /// false for a genuine error worth surfacing.
    let isAvailabilityIssue: Bool

    init(product: String, message: String, isAvailabilityIssue: Bool) {
        self.id = UUID()
        self.product = product
        self.message = message
        self.isAvailabilityIssue = isAvailabilityIssue
    }

    // Persisted in the daily record and read back for merges; the generated
    // `id` is intentionally excluded so decoding a stored issue always succeeds.
    enum CodingKeys: String, CodingKey {
        case product, message, isAvailabilityIssue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.product = try c.decode(String.self, forKey: .product)
        self.message = try c.decode(String.self, forKey: .message)
        self.isAvailabilityIssue = try c.decode(Bool.self, forKey: .isAvailabilityIssue)
    }
}

/// Snapshot of everything pulled from Plaid for one access token in one refresh.
struct PlaidDataSnapshot: Encodable {
    var transactions = PlaidTransactionsResult()
    var statements: PlaidStatementsResult?
    var holdings: PlaidInvestmentHoldings?
    var investmentTransactions = PlaidInvestmentTransactionsResult()
    var liabilities: PlaidLiabilitiesResult?
    var issues: [ProductIssue] = []
    var fetchedAt: Date?

    /// Record a per-product failure, classifying Plaid "unavailable" errors as soft.
    mutating func record(_ error: Error, for product: String) {
        if let api = error as? PlaidAPIError {
            issues.append(ProductIssue(product: product,
                                       message: api.errorDescription ?? "error",
                                       isAvailabilityIssue: api.isProductUnavailable))
        } else {
            issues.append(ProductIssue(product: product,
                                       message: error.localizedDescription,
                                       isAvailabilityIssue: false))
        }
    }

    /// Genuine (non-availability) errors only.
    var hardErrors: [ProductIssue] { issues.filter { !$0.isAvailabilityIssue } }
}

/// A snapshot paired with the token (label + id) it was pulled for.
struct LabeledSnapshot: Identifiable, Encodable {
    let id: String
    let label: String
    var data = PlaidDataSnapshot()
    var errorMessage: String?
}

// MARK: - On-disk daily record

/// The point-in-time part of a day's record. Balances, holdings, liabilities and
/// statements only ever describe "now", so they're written into the run day's
/// folder only — never reconstructed for past days.
struct DailySnapshot: Codable {
    var accounts: [PlaidAccount] = []
    var statements: PlaidStatementsResult?
    var holdings: PlaidInvestmentHoldings?
    var liabilities: PlaidLiabilitiesResult?
    var issues: [ProductIssue] = []
    var fetchedAt: Date?
    var errorMessage: String?
}

/// Contents of one `<label>.json` inside a `Data/YYYY-MM-DD/` folder: the
/// transaction-type data dated to that day, plus (run day only) the snapshot.
/// Codable so an existing file can be read back and merged on the next run.
struct DailyTokenRecord: Codable {
    let id: String
    let label: String
    let date: String
    var transactions: [PlaidTransaction] = []
    var investmentTransactions: [PlaidInvestmentTransaction] = []
    var snapshot: DailySnapshot?
}

@MainActor
class FinAgentDataManager: ObservableObject {
    static let shared = FinAgentDataManager()

    private let apiManager = APIKeyManager.shared
    /// Cloud Storage mirror for the local day-file tree.
    let cloudSync = GCSSync.shared
    /// Read on every request from the environment saved with the credentials,
    /// so an update applies on the next pull without restarting the app.
    private var environment: PlaidEnvironment { apiManager.plaidEnvironment }

    @Published var lastAPICall: Date?
    @Published var errorMessage: String?
    @Published var statusMessage = "Locked"
    @Published var isRefreshing = false
    @Published var isResyncing = false
    @Published var isBackgroundActive = false
    @Published var isLinking = false
    @Published var linkStatus = ""
    @Published var linkError: String?
    private var linkTask: Task<Void, Never>?
    private var linkGeneration = 0
    /// Latest snapshot per access token, keyed/ordered by token entry.
    @Published var snapshots: [LabeledSnapshot] = []

    // Persisted transactions cursor per token, so each sync is incremental.
    private let transactionsCursorPrefix = "com.mlaid.finagent.plaid.transactions_cursor."
    private func transactionsCursor(for id: String) -> String? {
        UserDefaults.standard.string(forKey: transactionsCursorPrefix + id)
    }
    private func setTransactionsCursor(_ cursor: String?, for id: String) {
        UserDefaults.standard.set(cursor, forKey: transactionsCursorPrefix + id)
    }
    /// Drop a token's saved cursor so its next `/transactions/sync` starts from
    /// scratch — Plaid re-sends all available history, which the daily writer
    /// then buckets back into per-day folders.
    private func clearTransactionsCursor(for id: String) {
        UserDefaults.standard.removeObject(forKey: transactionsCursorPrefix + id)
    }

    // Persisted background refresh interval, in seconds.
    private let intervalKey = "com.mlaid.finagent.plaid.background_interval"
    private let backgroundEnabledKey = "com.mlaid.finagent.plaid.background_enabled"
    static let minimumInterval: TimeInterval = 60
    static let defaultBackgroundInterval: TimeInterval = 86_400 // 1 day
    /// Selectable background refresh intervals.
    @Published var backgroundInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(backgroundInterval, forKey: intervalKey)
            // Reschedule with the new interval if a schedule is running.
            if isBackgroundActive {
                startBackgroundActivity()
            }
        }
    }

    private var backgroundActivity: NSBackgroundActivityScheduler?
    // Ensures the launch auto-start of background pulls runs at most once.
    private var didResumeBackground = false

    // Auto-rotate state
    @Published var isRotating = false
    @Published var isAutoRotateActive = false
    @Published var lastRotation: Date?
    private let rotateIntervalKey = "com.mlaid.finagent.plaid.rotate_interval"
    private let lastRotationKey = "com.mlaid.finagent.plaid.last_rotation"
    private let autoRotateEnabledKey = "com.mlaid.finagent.plaid.auto_rotate_enabled"
    private let rotateAnchorKey = "com.mlaid.finagent.plaid.rotate_anchor"
    // Guards catch-up so it runs at most once per launch, not on every popover.
    private var didResumeAutoRotate = false
    static let defaultRotateInterval: TimeInterval = 2_592_000 // 30 days
    @Published var rotateInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(rotateInterval, forKey: rotateIntervalKey)
            if isAutoRotateActive { startAutoRotate() }
        }
    }
    private var rotateActivity: NSBackgroundActivityScheduler?

    private init() {
        let saved = UserDefaults.standard.double(forKey: intervalKey)
        backgroundInterval = saved >= Self.minimumInterval ? saved : Self.defaultBackgroundInterval

        let savedRotate = UserDefaults.standard.double(forKey: rotateIntervalKey)
        rotateInterval = savedRotate >= Self.minimumInterval ? savedRotate : Self.defaultRotateInterval

        let lastRotationStamp = UserDefaults.standard.double(forKey: lastRotationKey)
        lastRotation = lastRotationStamp > 0 ? Date(timeIntervalSince1970: lastRotationStamp) : nil

        // Reflect the persisted auto-rotate preference so the UI is correct at launch.
        isAutoRotateActive = UserDefaults.standard.bool(forKey: autoRotateEnabledKey)
        // Background pulls default ON — reflect the persisted preference (default true).
        isBackgroundActive = UserDefaults.standard.object(forKey: backgroundEnabledKey) as? Bool ?? true

        sweepOrphanedData()
        purgeLegacyDriveStorage()
    }

    /// Drop Google Drive Keychain items and UserDefaults left by older builds.
    /// Best-effort and silent. Runs once; deleting a missing item is success.
    private func purgeLegacyDriveStorage() {
        let doneKey = "com.mlaid.finagent.gdrive.legacy_removed"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        for account in [
            "com.mlaid.finagent.gdrive.client_id",
            "com.mlaid.finagent.gdrive.client_secret",
            "com.mlaid.finagent.gdrive.refresh_token",
        ] {
            apiManager.deleteSecret(account: account)
        }
        for key in [
            "com.mlaid.finagent.gdrive.account_email",
            "com.mlaid.finagent.gdrive.enabled",
            "com.mlaid.finagent.gdrive.folder_name",
            "com.mlaid.finagent.gdrive.pending",
            "com.mlaid.finagent.gdrive.folder_ids",
            "com.mlaid.finagent.gdrive.file_ids",
            "com.mlaid.finagent.gdrive.last_sync",
        ] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: doneKey)
    }

    /// Error code and message only. Response bodies from Link can contain tokens.
    private static func plaidErrorCode(_ error: Error) -> String {
        if let api = error as? PlaidAPIError {
            return "\(api.errorCode ?? "?") \(api.errorMessage ?? "")"
        }
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return "request failed"
    }

    /// User-facing Plaid failure text, including the host that was called.
    private func describe(_ error: Error, environment host: PlaidEnvironment? = nil) -> String {
        let text: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            text = description
        } else {
            text = "The request failed."
        }
        let prefix = "\((host ?? environment).displayName):"
        if text.hasPrefix(prefix) { return text }
        return "\(prefix) \(text)"
    }

    // MARK: - Plaid Data Pull

    // Ensures the automatic launch pull happens at most once per launch.
    private var didAutoPull = false

    /// Pull automatically on first launch of the popover, when tokens exist.
    func pullOnLaunchIfNeeded() async {
        guard !didAutoPull else { return }
        didAutoPull = true
        guard !apiManager.tokenEntries.isEmpty else { return }
        await performPeriodicAPICall()
    }

    /// Pull data for every stored access token. Each token is fetched
    /// independently so one failure doesn't abort the rest.
    func performPeriodicAPICall() async {
        guard !isRefreshing else { return }
        let entries = apiManager.tokenEntries
        guard !entries.isEmpty else {
            statusMessage = "No access tokens added"
            return
        }

        isRefreshing = true
        statusMessage = "Refreshing Plaid data..."
        errorMessage = nil
        defer { isRefreshing = false }

        // Anchor the whole refresh to one run date, and read the last fetched day
        // from the folders on disk *before* we write today's — so every token
        // buckets against the same window and the gap fill is consistent.
        let runDate = Date()
        let lastDay = lastFetchedDay()

        var results: [LabeledSnapshot] = []
        var failureCount = 0

        for entry in entries {
            var labeled = LabeledSnapshot(id: entry.id, label: entry.label)
            let host = apiManager.environment(forTokenId: entry.id)
            do {
                let credentials = try apiManager.credentials(forTokenId: entry.id)
                let client = PlaidClient(credentials: credentials, environment: host)
                // Key check does not send the access token, so INVALID_API_KEYS
                // here is the client_id/secret pair and not a bad token.
                try await client.verifyClientCredentials()
                labeled.data = await fetchAll(using: client, tokenId: entry.id, since: lastDay)
                // A token counts as failed only on a genuine (non-availability) error.
                if !labeled.data.hardErrors.isEmpty { failureCount += 1 }
            } catch {
                // Credential/decryption failure — the whole token can't be pulled.
                labeled.errorMessage = describe(error, environment: host)
                failureCount += 1
                print("Plaid refresh error [\(entry.label)]: \(Self.plaidErrorCode(error))")
            }
            results.append(labeled)
            writeDaily(for: labeled, runDate: runDate, lastFetchedDay: lastDay)
        }

        // Mirror everything this run touched (plus anything still queued from a
        // previous failed attempt) up to Cloud Storage.
        await cloudSync.flush(localRoot: dataDirectoryURL)

        snapshots = results
        lastAPICall = Date()
        if failureCount == 0 {
            statusMessage = "Updated \(results.count) account(s)"
        } else {
            statusMessage = "Updated with \(failureCount) error(s)"
            errorMessage = results.first { $0.errorMessage != nil }?.errorMessage
                ?? results.compactMap { $0.data.hardErrors.first }.first
                    .map { "\($0.product): \($0.message)" }
        }
    }

    // MARK: - Re-sync History

    /// Reset the transactions cursor for every token, then pull — so the next
    /// sync is a full re-fetch of all available history (up to what each
    /// institution exposes) and the daily writer rebuilds the per-day folders.
    /// Existing day files are merged into by id, never overwritten.
    func resyncHistory() async {
        guard !isRefreshing, !isResyncing else { return }
        let entries = apiManager.tokenEntries
        guard !entries.isEmpty else {
            statusMessage = "No access tokens to re-sync"
            return
        }
        isResyncing = true
        defer { isResyncing = false }
        for entry in entries { clearTransactionsCursor(for: entry.id) }
        statusMessage = "Re-syncing full history…"
        await performPeriodicAPICall()
    }

    /// Re-sync one token's full history. Only this token does a full sync; the
    /// others are refreshed incrementally (typically cheap) by the shared pull.
    func resyncHistory(id: String) async {
        guard !isRefreshing, !isResyncing else { return }
        guard let entry = apiManager.tokenEntries.first(where: { $0.id == id }) else { return }
        isResyncing = true
        defer { isResyncing = false }
        clearTransactionsCursor(for: id)
        statusMessage = "Re-syncing \(entry.label)…"
        await performPeriodicAPICall()
    }

    /// Pull transactions, statements, investments, and liabilities for one token.
    /// Each product is fetched independently: a product that isn't available for
    /// this item (or any other error) is recorded on the snapshot instead of
    /// aborting the remaining products.
    private func fetchAll(using client: PlaidClient, tokenId: String, since lastDay: Date?) async -> PlaidDataSnapshot {
        var snapshot = PlaidDataSnapshot()

        // Transactions — incremental via the per-token persisted cursor.
        do {
            let txResult = try await client.fetchTransactions(startingCursor: transactionsCursor(for: tokenId))
            snapshot.transactions = txResult
            setTransactionsCursor(txResult.cursor, for: tokenId)
        } catch {
            snapshot.record(error, for: "Transactions")
            logProduct(error, product: "Transactions", tokenId: tokenId)
        }

        // Statements.
        do {
            snapshot.statements = try await client.fetchStatements()
        } catch {
            snapshot.record(error, for: "Statements")
            logProduct(error, product: "Statements", tokenId: tokenId)
        }

        // Investment holdings.
        do {
            snapshot.holdings = try await client.fetchInvestmentHoldings()
        } catch {
            snapshot.record(error, for: "Investment holdings")
            logProduct(error, product: "Investment holdings", tokenId: tokenId)
        }

        // Investment transactions — from the last fetched day (minus the buffer)
        // through today, so a gap is filled and boundary items aren't missed.
        // First run (no prior day) falls back to a trailing 2-year window.
        do {
            let (start, end) = Self.investmentDateRange(since: lastDay)
            snapshot.investmentTransactions = try await client.fetchInvestmentTransactions(
                startDate: start, endDate: end)
        } catch {
            snapshot.record(error, for: "Investment transactions")
            logProduct(error, product: "Investment transactions", tokenId: tokenId)
        }

        // Liabilities.
        do {
            snapshot.liabilities = try await client.fetchLiabilities()
        } catch {
            snapshot.record(error, for: "Liabilities")
            logProduct(error, product: "Liabilities", tokenId: tokenId)
        }

        snapshot.fetchedAt = Date()
        return snapshot
    }

    private func logProduct(_ error: Error, product: String, tokenId: String) {
        if let api = error as? PlaidAPIError, api.isProductUnavailable {
            print("Skipped \(product) [\(tokenId)] — unavailable: \(api.errorCode ?? api.errorDescription ?? "")")
        } else {
            print("Error fetching \(product): \(Self.plaidErrorCode(error))")
        }
    }

    /// Overlap (in days) added ahead of the last fetched day so late-posting or
    /// day-boundary items aren't missed. Duplicates from the overlap are merged
    /// away by transaction id when writing the daily records.
    static let bufferDays = 2

    /// YYYY-MM-DD range for investment transactions: from the last fetched day
    /// minus the buffer through today. First run (no prior day) falls back to a
    /// trailing 2-year window.
    private static func investmentDateRange(since lastDay: Date?) -> (start: String, end: String) {
        let now = Date()
        let start: Date
        if let lastDay {
            start = utcCalendar.date(byAdding: .day, value: -bufferDays, to: lastDay) ?? lastDay
        } else {
            start = utcCalendar.date(byAdding: .year, value: -2, to: now) ?? now
        }
        return (dayString(start), dayString(now))
    }

    // MARK: - Day helpers

    /// UTC calendar/formatter so day boundaries match the `YYYY-MM-DD` folder
    /// names and the `date` strings Plaid returns on transactions.
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    private static func day(from string: String) -> Date? { dayFormatter.date(from: string) }

    /// Most recent `YYYY-MM-DD` folder present under the data directory, or nil
    /// if none exist yet (first run). This is the "last fetch date from files".
    private func lastFetchedDay() -> Date? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dataDirectoryURL.path) else { return nil }
        return names.compactMap { Self.day(from: $0) }.max()
    }

    /// Every calendar day in `[start+1 ... end]`, as `YYYY-MM-DD` strings, so the
    /// folder sequence stays continuous across a gap. Empty if start >= end.
    private static func continuousDays(after start: Date, through end: Date) -> [String] {
        var days: [String] = []
        var cursor = utcCalendar.date(byAdding: .day, value: 1, to: utcCalendar.startOfDay(for: start)) ?? end
        let last = utcCalendar.startOfDay(for: end)
        while cursor <= last {
            days.append(dayString(cursor))
            guard let next = utcCalendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    // MARK: - Data Export

    /// Folder where each pull's data is written as JSON.
    var dataDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("FinAgentMenuBar/Data", isDirectory: true)
    }

    /// Reveal the data folder in Finder (creating it if needed).
    func openDataFolder() {
        let url = dataDirectoryURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// JSON encoder/decoder pair for the on-disk daily records. The ISO-8601 date
    /// strategy must match on both sides so `fetchedAt` round-trips on merge.
    private static let recordEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let recordDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Bucket one token's pulled data into per-day `Data/YYYY-MM-DD/<label>.json`
    /// files, merging into any existing files so the buffer overlap and repeated
    /// runs are idempotent. Contains only pulled Plaid data — never credentials.
    private func writeDaily(for labeled: LabeledSnapshot, runDate: Date, lastFetchedDay lastDay: Date?) {
        let runDayString = Self.dayString(runDate)

        // Group transaction-type data by each item's own date.
        let txByDay = Dictionary(grouping: labeled.data.transactions.added + labeled.data.transactions.modified,
                                 by: { $0.date })
        let invByDay = Dictionary(grouping: labeled.data.investmentTransactions.transactions,
                                  by: { $0.date })

        // The set of day folders to write this run.
        var days = Set<String>()
        days.insert(runDayString)                 // run day always carries the snapshot
        days.formUnion(txByDay.keys)
        days.formUnion(invByDay.keys)
        if let lastDay {
            // Keep the folder chain continuous across a gap (empty days allowed).
            days.formUnion(Self.continuousDays(after: lastDay, through: runDate))
        }

        let snapshot = dailySnapshot(from: labeled)

        for day in days {
            let contribution = DailyTokenRecord(
                id: labeled.id,
                label: labeled.label,
                date: day,
                transactions: txByDay[day] ?? [],
                investmentTransactions: invByDay[day] ?? [],
                snapshot: day == runDayString ? snapshot : nil)
            mergeWrite(contribution)
        }

        // Removed transactions carry no date; drop them wherever they landed.
        let removed = Set(labeled.data.transactions.removed)
        if !removed.isEmpty {
            applyRemovals(removed, label: labeled.label, fallbackId: labeled.id)
        }
    }

    /// Build the run day's point-in-time snapshot from a pulled result. Accounts
    /// (with balances) are unioned across the products that return them.
    private func dailySnapshot(from labeled: LabeledSnapshot) -> DailySnapshot {
        var accountsById: [String: PlaidAccount] = [:]
        let accountSources = labeled.data.transactions.accounts
            + (labeled.data.holdings?.accounts ?? [])
            + (labeled.data.liabilities?.accounts ?? [])
            + labeled.data.investmentTransactions.accounts
        for account in accountSources where accountsById[account.accountId] == nil {
            accountsById[account.accountId] = account
        }
        return DailySnapshot(
            accounts: Array(accountsById.values),
            statements: labeled.data.statements,
            holdings: labeled.data.holdings,
            liabilities: labeled.data.liabilities,
            issues: labeled.data.issues,
            fetchedAt: labeled.data.fetchedAt ?? Date(),
            errorMessage: labeled.errorMessage)
    }

    /// Merge one contribution into its day file, deduping transaction-type data by
    /// id (incoming wins) and replacing the snapshot only when present (run day).
    private func mergeWrite(_ incoming: DailyTokenRecord) {
        let fileURL = fileURL(day: incoming.date, label: incoming.label, fallbackId: incoming.id)

        var record = readRecord(at: fileURL)
            ?? DailyTokenRecord(id: incoming.id, label: incoming.label, date: incoming.date)

        var txById = Dictionary(record.transactions.map { ($0.transactionId, $0) },
                                uniquingKeysWith: { _, new in new })
        for tx in incoming.transactions { txById[tx.transactionId] = tx }
        record.transactions = Array(txById.values)

        var invById = Dictionary(record.investmentTransactions.map { ($0.investmentTransactionId, $0) },
                                 uniquingKeysWith: { _, new in new })
        for tx in incoming.investmentTransactions { invById[tx.investmentTransactionId] = tx }
        record.investmentTransactions = Array(invById.values)

        if let snapshot = incoming.snapshot { record.snapshot = snapshot }

        write(record, to: fileURL)
    }

    /// Delete removed transaction ids from every existing day folder for a token.
    private func applyRemovals(_ removed: Set<String>, label: String, fallbackId: String) {
        let fm = FileManager.default
        guard let dayNames = try? fm.contentsOfDirectory(atPath: dataDirectoryURL.path) else { return }
        for dayName in dayNames where Self.day(from: dayName) != nil {
            let fileURL = fileURL(day: dayName, label: label, fallbackId: fallbackId)
            guard var record = readRecord(at: fileURL) else { continue }
            let kept = record.transactions.filter { !removed.contains($0.transactionId) }
            guard kept.count != record.transactions.count else { continue }
            record.transactions = kept
            write(record, to: fileURL)
        }
    }

    private func fileURL(day: String, label: String, fallbackId: String) -> URL {
        let name = Self.safeFileName(label, fallback: fallbackId)
        return dataDirectoryURL
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("\(name).json")
    }

    private func readRecord(at url: URL) -> DailyTokenRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.recordDecoder.decode(DailyTokenRecord.self, from: data)
    }

    private func write(_ record: DailyTokenRecord, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try Self.recordEncoder.encode(record)
            try data.write(to: url, options: .atomic)
            // Queue the mirror; the actual upload happens once per run in flush().
            cloudSync.markWritten(day: record.date, fileName: url.lastPathComponent)
        } catch {
            print("Daily export failed [\(record.date)/\(record.label)]: \(error)")
        }
    }

    /// Turn a token label into a filesystem-safe file name.
    private static func safeFileName(_ label: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = label.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    // MARK: - Cleanup

    /// Remove a token and purge all local data tied to it.
    func removeToken(id: String) {
        apiManager.removeAccessToken(id: id)
        purgeData(forTokenId: id)
    }

    /// Delete shared credentials + every token, then clear all local data.
    /// The Cloud Storage service-account key goes too.
    func resetAll() async {
        stopAutoRotate()
        GCSAuth.shared.clear()
        cloudSync.isEnabled = false
        await apiManager.deleteKeys()
        sweepOrphanedData() // tokenEntries is now empty, so this clears everything
        // After the sweep, so the deletions it queues don't outlive the reset.
        cloudSync.reset()
    }

    /// Delete the persisted cursor, cached snapshot, and every day file for one token.
    private func purgeData(forTokenId id: String) {
        UserDefaults.standard.removeObject(forKey: transactionsCursorPrefix + id)
        snapshots.removeAll { $0.id == id }
        removeDayFiles { $0.id == id }
    }

    /// Drop any persisted cursors / cached snapshots / day files whose token no
    /// longer exists.
    func sweepOrphanedData() {
        let validIds = Set(apiManager.tokenEntries.map { $0.id })
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(transactionsCursorPrefix) {
            let id = String(key.dropFirst(transactionsCursorPrefix.count))
            if !validIds.contains(id) {
                defaults.removeObject(forKey: key)
            }
        }
        snapshots.removeAll { !validIds.contains($0.id) }
        removeDayFiles { !validIds.contains($0.id) }
    }

    /// Walk every `Data/YYYY-MM-DD/` folder and delete token files whose record
    /// matches `shouldRemove` (matched on the id stored inside each file, so it
    /// works even after the token's label/entry is gone). Empty day folders left
    /// behind are cleaned up.
    private func removeDayFiles(_ shouldRemove: (DailyTokenRecord) -> Bool) {
        let fm = FileManager.default
        guard let dayNames = try? fm.contentsOfDirectory(atPath: dataDirectoryURL.path) else { return }
        for dayName in dayNames where Self.day(from: dayName) != nil {
            let dayDir = dataDirectoryURL.appendingPathComponent(dayName, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(atPath: dayDir.path) else { continue }
            for file in files where file.hasSuffix(".json") {
                let url = dayDir.appendingPathComponent(file)
                if let record = readRecord(at: url), shouldRemove(record) {
                    try? fm.removeItem(at: url)
                    // Propagate the deletion so Cloud Storage doesn't keep data
                    // for a token that's been removed here.
                    cloudSync.markDeleted(day: dayName, fileName: file)
                }
            }
            // Remove the day folder if it's now empty.
            if let remaining = try? fm.contentsOfDirectory(atPath: dayDir.path), remaining.isEmpty {
                try? fm.removeItem(at: dayDir)
                cloudSync.markDayRemoved(day: dayName)
            }
        }

        // Deletions are queued from synchronous call sites (init, removeToken),
        // so push them out of band rather than blocking the caller.
        let root = dataDirectoryURL
        Task { await cloudSync.flush(localRoot: root) }
    }

    // MARK: - Hosted Link

    /// Opens Plaid Hosted Link for the environment selected in the menu, then
    /// polls until the browser session finishes or 30 minutes pass.
    func startHostedLink() {
        guard !isLinking else { return }
        linkError = nil
        linkStatus = "Starting \(environment.displayName) Hosted Link…"
        isLinking = true
        linkGeneration += 1
        let generation = linkGeneration
        linkTask = Task { [weak self] in
            await self?.runHostedLink(generation: generation)
        }
    }

    func cancelHostedLink() {
        linkTask?.cancel()
    }

    private func runHostedLink(generation: Int) async {
        let host = environment
        var savedNames: [String] = []
        defer {
            // `return` cannot leave a defer. A newer link generation must keep
            // its own in-progress state when this attempt finishes.
            if linkGeneration == generation {
                isLinking = false
                linkTask = nil
            }
        }
        do {
            let credentials = try apiManager.linkCredentials(for: host)
            let client = PlaidClient(credentials: credentials, environment: host)
            linkStatus = "Creating a \(host.displayName) link…"
            let created = try await createHostedLinkSession(client: client, host: host)
            let session = created.session
            try Task.checkCancellation()
            guard NSWorkspace.shared.open(session.url) else {
                throw HostedLinkError.browserFailed(environment: host)
            }
            let deadline = hostedLinkDeadline(expiration: session.expiration)
            let productNote = created.productNote.map { " \($0)" } ?? ""
            linkStatus = "Opened \(host.displayName) in your browser. Finish signing in there.\(productNote)"
            let started = Date()
            var poll = HostedLinkPoll(finished: false, items: [])
            while Date() < deadline {
                try Task.checkCancellation()
                poll = try await client.hostedLinkStatus(linkToken: session.linkToken)
                if poll.finished { break }
                let elapsed = Int(Date().timeIntervalSince(started))
                let minutes = elapsed / 60
                let seconds = elapsed % 60
                linkStatus = "Waiting for \(host.displayName) in the browser… \(minutes):\(String(format: "%02d", seconds)).\(productNote)"
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            try Task.checkCancellation()
            if poll.finished && poll.items.isEmpty {
                throw HostedLinkError.endedWithoutBank(environment: host)
            }
            if !poll.finished && poll.items.isEmpty {
                throw HostedLinkError.timedOut(environment: host)
            }
            if !poll.finished {
                linkStatus = "\(host.displayName) link window ended. Saving banks that were already connected."
            }
            var failures: [String] = []
            for item in poll.items {
                try Task.checkCancellation()
                linkStatus = "Saving \(item.institutionName) on \(host.displayName)…"
                do {
                    let accessToken = try await client.exchangePublicToken(item.publicToken)
                    let label = apiManager.uniqueTokenLabel(item.institutionName)
                    if await apiManager.addAccessToken(label: label, token: accessToken, environment: host) != nil {
                        savedNames.append(label)
                    } else {
                        failures.append("\(item.institutionName): \(apiManager.errorMessage ?? "could not store the access token")")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let urlError as URLError where urlError.code == .cancelled {
                    throw urlError
                } catch {
                    failures.append("\(item.institutionName): \(describe(error, environment: host))")
                }
            }
            if savedNames.isEmpty {
                linkError = failures.joined(separator: "\n")
                linkStatus = "No bank was saved."
                return
            }
            linkError = failures.isEmpty ? nil : failures.joined(separator: "\n")
            let names = savedNames.joined(separator: ", ")
            linkStatus = failures.isEmpty
                ? "Saved \(names) on \(host.displayName)."
                : "Saved \(names) on \(host.displayName). \(failures.count) connection(s) failed."
            isLinking = false
            await performPeriodicAPICall()
            resumeBackgroundIfEnabled()
        } catch let urlError as URLError where urlError.code == .cancelled {
            linkError = nil
            if savedNames.isEmpty {
                linkStatus = "Link cancelled. No bank was saved."
            } else {
                linkStatus = "Link cancelled. Saved \(savedNames.joined(separator: ", ")) on \(host.displayName)."
                isLinking = false
                await performPeriodicAPICall()
                resumeBackgroundIfEnabled()
            }
        } catch is CancellationError {
            linkError = nil
            if savedNames.isEmpty {
                linkStatus = "Link cancelled. No bank was saved."
            } else {
                linkStatus = "Link cancelled. Saved \(savedNames.joined(separator: ", ")) on \(host.displayName)."
                isLinking = false
                await performPeriodicAPICall()
                resumeBackgroundIfEnabled()
            }
        } catch {
            linkError = describe(error, environment: host)
            linkStatus = "Link failed."
            print("Hosted Link failed: \(Self.plaidErrorCode(error))")
        }
    }

    /// Asks for transactions plus the other products this app fetches. If Plaid
    /// rejects an optional product the account is not enabled for, retries with
    /// transactions only so a bank can still be linked.
    private func createHostedLinkSession(client: PlaidClient, host: PlaidEnvironment) async throws -> (session: HostedLinkSession, productNote: String?) {
        do {
            let session = try await client.createHostedLink(clientUserId: apiManager.plaidClientUserId())
            return (session, nil)
        } catch let api as PlaidAPIError where api.errorCode == "INVALID_PRODUCT" || api.errorCode == "INVALID_FIELD" {
            linkStatus = "\(describe(api, environment: host)) Retrying with transactions only."
            let session = try await client.createHostedLink(
                clientUserId: apiManager.plaidClientUserId(),
                includeOptionalProducts: false
            )
            return (session, "This link requested transactions only.")
        }
    }

    /// Public tokens are valid for about 30 minutes, which is also the default
    /// Hosted Link URL lifetime when Plaid is not delivering the link.
    private func hostedLinkDeadline(expiration: Date?) -> Date {
        let halfHour = Date().addingTimeInterval(30 * 60)
        guard let expiration else { return halfHour }
        return min(expiration, halfHour)
    }

    // MARK: - Access Token Rotation

    /// Rotate one token: invalidate the old token and persist the new one for
    /// the same entry. The cursor/snapshot stay valid — it's the same Item.
    @discardableResult
    func rotateToken(id: String) async -> Bool {
        guard let entry = apiManager.tokenEntries.first(where: { $0.id == id }) else { return false }
        let host = apiManager.environment(forTokenId: id)
        statusMessage = "Rotating \(entry.label)…"
        do {
            let credentials = try apiManager.credentials(forTokenId: id)
            let client = PlaidClient(credentials: credentials, environment: host)

            let newToken = try await client.rotateAccessToken()
            // Persist the new token before the old one is relied on again.
            try apiManager.updateAccessToken(id: id, token: newToken)

            recordRotation()
            statusMessage = "Rotated \(entry.label)"
            errorMessage = nil
            return true
        } catch let apiError as PlaidAPIError {
            errorMessage = "\(entry.label): \(describe(apiError, environment: host))"
            statusMessage = "Rotation failed"
            print("Rotation error [\(entry.label)]: \(apiError.errorCode ?? "?") — \(apiError.errorMessage ?? "")")
            return false
        } catch {
            errorMessage = "\(entry.label): \(describe(error, environment: host))"
            statusMessage = "Rotation failed"
            print("Rotation error [\(entry.label)]: \(Self.plaidErrorCode(error))")
            return false
        }
    }

    /// Rotate every stored token sequentially.
    func rotateAllTokens() async {
        guard !isRotating else { return }
        let entries = apiManager.tokenEntries
        guard !entries.isEmpty else {
            statusMessage = "No access tokens to rotate"
            return
        }

        isRotating = true
        defer { isRotating = false }

        var failureCount = 0
        for entry in entries {
            let ok = await rotateToken(id: entry.id)
            if !ok { failureCount += 1 }
        }

        statusMessage = failureCount == 0
            ? "Rotated \(entries.count) token(s)"
            : "Rotated with \(failureCount) error(s)"
    }

    private func recordRotation() {
        let now = Date()
        lastRotation = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastRotationKey)
        // Reset the due-clock so the next rotation is one full interval away.
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: rotateAnchorKey)
    }

    // MARK: - Auto-Rotate Scheduling
    func startAutoRotate() {
        rotateActivity?.invalidate()

        let activity = NSBackgroundActivityScheduler(identifier: "com.mlaid.finagent.rotate")
        activity.repeats = true
        activity.interval = rotateInterval
        activity.tolerance = min(3600, rotateInterval * 0.1)

        activity.schedule { completion in
            Task { @MainActor in
                await self.rotateAllTokens()
                completion(.finished)
            }
        }

        rotateActivity = activity
        isAutoRotateActive = true
        UserDefaults.standard.set(true, forKey: autoRotateEnabledKey)
        // Anchor the due-clock from now if this is a fresh enable.
        if UserDefaults.standard.double(forKey: rotateAnchorKey) == 0 {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: rotateAnchorKey)
        }
        statusMessage = "Auto-rotate started"
    }

    func stopAutoRotate() {
        rotateActivity?.invalidate()
        rotateActivity = nil
        isAutoRotateActive = false
        UserDefaults.standard.set(false, forKey: autoRotateEnabledKey)
        UserDefaults.standard.removeObject(forKey: rotateAnchorKey)
        statusMessage = "Auto-rotate stopped"
    }

    /// If auto-rotate was enabled in a previous session, re-arm the scheduler
    /// on launch and rotate immediately when a scheduled rotation was missed
    /// while the app was closed. Runs at most once per launch.
    func resumeAutoRotateIfEnabled() async {
        guard !didResumeAutoRotate else { return }
        didResumeAutoRotate = true

        guard UserDefaults.standard.bool(forKey: autoRotateEnabledKey) else { return }

        // Re-arm the repeating scheduler (preserves the existing anchor).
        startAutoRotate()

        if isRotationDue, !apiManager.tokenEntries.isEmpty {
            await rotateAllTokens()
        }
    }

    /// True when at least one full interval has elapsed since the due-clock anchor.
    private var isRotationDue: Bool {
        let anchor = UserDefaults.standard.double(forKey: rotateAnchorKey)
        guard anchor > 0 else { return false }
        return Date().timeIntervalSince1970 - anchor >= rotateInterval
    }

    // MARK: - Background Scheduling
    func startBackgroundActivity() {
        backgroundActivity?.invalidate()

        let activity = NSBackgroundActivityScheduler(identifier: "com.mlaid.finagent.periodic")
        activity.repeats = true
        activity.interval = backgroundInterval
        // Generous tolerance (up to 1h) lets the OS batch the wake-up efficiently.
        activity.tolerance = min(3600, backgroundInterval * 0.1)

        activity.schedule { completion in
            Task { @MainActor in
                await self.performPeriodicAPICall()
                completion(.finished)
            }
        }

        backgroundActivity = activity
        isBackgroundActive = true
        UserDefaults.standard.set(true, forKey: backgroundEnabledKey)
        statusMessage = "Background started"
    }

    func stopBackgroundActivity() {
        backgroundActivity?.invalidate()
        backgroundActivity = nil
        isBackgroundActive = false
        UserDefaults.standard.set(false, forKey: backgroundEnabledKey)
        statusMessage = "Background stopped"
    }

    /// Auto-arm background pulls on launch when enabled (default ON) and tokens
    /// exist. Runs at most once per launch.
    func resumeBackgroundIfEnabled() {
        guard !didResumeBackground else { return }
        let enabled = UserDefaults.standard.object(forKey: backgroundEnabledKey) as? Bool ?? true
        // Don't consume the one-shot until there's actually something to schedule.
        guard enabled, !apiManager.tokenEntries.isEmpty else { return }
        didResumeBackground = true
        startBackgroundActivity()
    }
}
