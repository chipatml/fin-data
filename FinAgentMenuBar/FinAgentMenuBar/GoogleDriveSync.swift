//
//  GoogleDriveSync.swift
//  FinAgentMenuBar
//
//  Legacy mirror of the per-day JSON to Google Drive. Cloud Storage
//  (GCSSync) is the default. This stays so an existing Drive folder can be
//  copied once, then removed.
//
//  The local container stays the source of truth: FinAgentDataManager does its
//  read-merge-write on disk exactly as before, and every file it touches is
//  queued here. The queue is persisted, so an upload that fails (offline, token
//  expired, Drive hiccup) is retried on the next pull instead of being lost.
//
//  Drive layout mirrors the local one:
//      <Root folder>/<YYYY-MM-DD>/<Label>.json
//

import Foundation
import Combine

@MainActor
final class GoogleDriveSync: ObservableObject, DayFileMirror {
    static let shared = GoogleDriveSync()

    private let auth = GoogleDriveAuth.shared

    @Published private(set) var isSyncing = false
    @Published private(set) var pendingCount = 0
    @Published var lastSync: Date?
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    private let enabledKey = "com.mlaid.finagent.gdrive.enabled"
    private let folderNameKey = "com.mlaid.finagent.gdrive.folder_name"
    private let pendingKey = "com.mlaid.finagent.gdrive.pending"
    private let folderCacheKey = "com.mlaid.finagent.gdrive.folder_ids"
    private let fileCacheKey = "com.mlaid.finagent.gdrive.file_ids"
    private let lastSyncKey = "com.mlaid.finagent.gdrive.last_sync"

    static let defaultFolderName = "FinAgentMenuBar"

    /// Uploading is opt-in: off until the user connects Drive and enables it.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: enabledKey) }
    }

    /// Top-level Drive folder that holds the `YYYY-MM-DD` folders. Renaming it
    /// drops the cached ids so the next sync resolves (or creates) the new one.
    @Published var folderName: String {
        didSet {
            guard folderName != oldValue else { return }
            UserDefaults.standard.set(folderName, forKey: folderNameKey)
            clearCaches()
            status = nil // the verdict described the old folder
        }
    }

    // MARK: - Queued work

    /// One pending mirror operation. Upload payloads aren't stored — the file
    /// is re-read from disk at flush time, so a queued upload always sends the
    /// latest merged content rather than a stale snapshot.
    private struct Operation: Codable, Hashable {
        enum Kind: String, Codable {
            case upload      // create or overwrite <day>/<name>
            case deleteFile  // trash <day>/<name>
            case deleteDay   // trash the whole <day> folder
        }
        let kind: Kind
        let day: String
        /// nil for `deleteDay`.
        let name: String?
    }

    /// Insertion-ordered queue; re-queuing an identical operation is a no-op.
    private var pending: [Operation] = [] {
        didSet { pendingCount = pending.count }
    }

    // Resolved Drive ids, cached so a routine pull doesn't re-list the tree.
    // Keys: "" for the root folder, "YYYY-MM-DD" for a day folder, and
    // "YYYY-MM-DD/Label.json" for a file.
    private var folderIds: [String: String] = [:]
    private var fileIds: [String: String] = [:]

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: enabledKey)
        folderName = defaults.string(forKey: folderNameKey) ?? Self.defaultFolderName
        pending = Self.decode([Operation].self, from: defaults.data(forKey: pendingKey)) ?? []
        pendingCount = pending.count
        folderIds = Self.decode([String: String].self, from: defaults.data(forKey: folderCacheKey)) ?? [:]
        fileIds = Self.decode([String: String].self, from: defaults.data(forKey: fileCacheKey)) ?? [:]
        let stamp = defaults.double(forKey: lastSyncKey)
        lastSync = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    // MARK: - Enqueueing (called by FinAgentDataManager)

    /// A day file was written locally and should be mirrored.
    func markWritten(day: String, fileName: String) {
        enqueue(Operation(kind: .upload, day: day, name: fileName))
    }

    /// A day file was deleted locally and should be trashed on Drive.
    func markDeleted(day: String, fileName: String) {
        guard isEnabled else { return }
        // A pending upload for the same file is now moot.
        pending.removeAll { $0.day == day && $0.name == fileName && $0.kind == .upload }
        enqueue(Operation(kind: .deleteFile, day: day, name: fileName))
    }

    /// An emptied day folder was removed locally.
    func markDayRemoved(day: String) {
        guard isEnabled else { return }
        pending.removeAll { $0.day == day }
        enqueue(Operation(kind: .deleteDay, day: day, name: nil))
    }

    /// Queue an operation, unless mirroring is off — otherwise the queue would
    /// grow forever for someone who never turns Drive on. Turning it on runs
    /// `syncAll`, which re-queues from what's actually on disk. (Deletions made
    /// while off aren't replayed; a file removed locally during that window
    /// stays in Drive until it's trashed there by hand.)
    private func enqueue(_ operation: Operation) {
        guard isEnabled, !pending.contains(operation) else { return }
        pending.append(operation)
        savePending()
    }

    // MARK: - Flushing

    /// Push every queued operation to Drive. Safe to call when disabled,
    /// disconnected, or with an empty queue — it just returns.
    func flush(localRoot: URL) async {
        guard isEnabled, auth.isConnected, !pending.isEmpty, !isSyncing else { return }

        isSyncing = true
        statusMessage = "Uploading \(pending.count) file(s) to Drive…"
        errorMessage = nil
        defer { isSyncing = false }

        let client = GoogleDriveClient { force in
            try await GoogleDriveAuth.shared.validAccessToken(forceRefresh: force)
        }

        // Resolve the root folder once. If this fails there's nothing sensible
        // to do with the individual operations, so keep them queued and bail.
        let root: String
        do {
            root = try await rootFolderId(client: client)
        } catch {
            report(error, context: "Drive folder")
            return
        }

        // Claim the queue up front: `apply` suspends, and a pull or a token
        // removal on the other side of an await can enqueue more work. Taking a
        // batch means that work is added to a queue we no longer overwrite.
        let batch = pending
        pending = []

        var failed: [Operation] = []
        var firstFailure: Error?

        for operation in batch {
            do {
                try await apply(operation, root: root, client: client, localRoot: localRoot)
            } catch {
                failed.append(operation)
                if firstFailure == nil { firstFailure = error }
                print("Drive sync failed [\(operation.kind.rawValue) \(operation.day)/\(operation.name ?? "")]: \(error)")
            }
        }

        // Failures go to the front; anything queued mid-flush keeps its place.
        pending = failed + pending.filter { !failed.contains($0) }
        savePending()
        saveCaches()

        if let firstFailure {
            report(firstFailure, context: "Drive sync")
            statusMessage = "\(failed.count) file(s) still pending"
        } else {
            let now = Date()
            lastSync = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastSyncKey)
            // A non-empty queue here is work that arrived mid-flush; it goes out
            // on the next one.
            statusMessage = pending.isEmpty ? "Synced to Drive" : "\(pending.count) file(s) queued"
            errorMessage = nil
        }
    }

    /// Queue every day file currently on disk and push it. Used by "Sync All to
    /// Drive" and after a first connection, so an existing local history lands
    /// in Drive without waiting for it to be rewritten by a pull.
    func syncAll(localRoot: URL) async {
        for path in Self.localInventory(localRoot) {
            markWritten(day: path.day, fileName: path.name)
        }
        await flush(localRoot: localRoot)
    }

    // MARK: - Status

    /// What a status check found: how the local tree compares to what's
    /// actually in Drive right now. Counts are of day files, never folders.
    struct Status {
        var folderExists = false
        var localFiles = 0
        var localDays = 0
        var driveFiles = 0
        var driveDays = 0
        /// Local files with no counterpart in Drive — these need uploading.
        var missing: [String] = []
        /// Files in Drive with nothing matching locally — stale leftovers.
        var extra: [String] = []
        var queued = 0
        var checkedAt = Date()
        var errorMessage: String?

        var inSync: Bool {
            errorMessage == nil && folderExists && missing.isEmpty && extra.isEmpty && queued == 0
        }
    }

    @Published private(set) var isCheckingStatus = false
    @Published private(set) var status: Status?

    /// Compare the local day files against what's really in the Drive folder,
    /// rather than trusting the queue — the answer the old status script gave
    /// for the shared folder. Read-only: it uploads and deletes nothing.
    func checkStatus(localRoot: URL) async {
        guard !isCheckingStatus else { return }
        isCheckingStatus = true
        defer { isCheckingStatus = false }

        var result = Status()
        result.queued = pending.count

        let local = Self.localInventory(localRoot)
        result.localFiles = local.count
        result.localDays = Set(local.map(\.day)).count

        guard auth.isConnected else {
            result.errorMessage = GoogleDriveError.notConnected.errorDescription
            status = result
            return
        }

        let client = GoogleDriveClient { force in
            try await GoogleDriveAuth.shared.validAccessToken(forceRefresh: force)
        }

        do {
            // Look the folder up by name without creating it — "not there yet"
            // is a legitimate answer for a check.
            guard let root = try await client.fileId(named: folderName, parent: "root", isFolder: true) else {
                result.missing = local.map(\.path).sorted()
                status = result
                return
            }
            result.folderExists = true

            // Day folder ids, then every file in one go — a listing per day
            // would be hundreds of requests once there's real history.
            let dayFolders = try await client.childFolders(of: root)
            let dayNameById = Dictionary(dayFolders.compactMap { folder in
                folder.name.map { (folder.id, $0) }
            }, uniquingKeysWith: { first, _ in first })
            result.driveDays = Set(dayNameById.values).count

            var remote = Set<String>()
            for file in try await client.allFiles() {
                guard let name = file.name,
                      let day = file.parents?.compactMap({ dayNameById[$0] }).first else { continue }
                remote.insert("\(day)/\(name)")
            }
            result.driveFiles = remote.count

            let localPaths = Set(local.map(\.path))
            result.missing = localPaths.subtracting(remote).sorted()
            result.extra = remote.subtracting(localPaths).sorted()
        } catch {
            result.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        status = result
    }

    /// Download every day JSON file in the configured Drive folder.
    func downloadDayFiles() async throws -> [(day: String, name: String, data: Data)] {
        guard auth.isConnected else { throw GoogleDriveError.notConnected }
        let client = GoogleDriveClient { force in
            try await GoogleDriveAuth.shared.validAccessToken(forceRefresh: force)
        }
        guard let root = try await client.fileId(named: folderName, parent: "root", isFolder: true) else {
            return []
        }
        let dayFolders = try await client.childFolders(of: root)
        let dayNameById = Dictionary(dayFolders.compactMap { folder in
            folder.name.map { (folder.id, $0) }
        }, uniquingKeysWith: { first, _ in first })

        var downloaded: [(day: String, name: String, data: Data)] = []
        for file in try await client.allFiles() {
            guard let name = file.name, name.hasSuffix(".json"),
                  let day = file.parents?.compactMap({ dayNameById[$0] }).first,
                  DayFileLayout.isDayFolder(day) else { continue }
            let data = try await client.download(id: file.id)
            downloaded.append((day: day, name: name, data: data))
        }
        return downloaded
    }

    /// Every `YYYY-MM-DD/<name>.json` currently on disk.
    private static func localInventory(_ root: URL) -> [(day: String, name: String, path: String)] {
        let fm = FileManager.default
        guard let dayNames = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }

        var found: [(day: String, name: String, path: String)] = []
        for day in dayNames where isDayFolder(day) {
            let dayURL = root.appendingPathComponent(day, isDirectory: true)
            let files = (try? fm.contentsOfDirectory(atPath: dayURL.path)) ?? []
            for file in files where file.hasSuffix(".json") {
                found.append((day: day, name: file, path: "\(day)/\(file)"))
            }
        }
        return found
    }

    private func apply(_ operation: Operation,
                       root: String,
                       client: GoogleDriveClient,
                       localRoot: URL) async throws {
        switch operation.kind {
        case .upload:
            guard let name = operation.name else { return }
            let localURL = localRoot
                .appendingPathComponent(operation.day, isDirectory: true)
                .appendingPathComponent(name)
            // Deleted between queueing and flushing — nothing to upload.
            guard let json = try? Data(contentsOf: localURL) else { return }
            try await upload(json, day: operation.day, name: name, root: root, client: client)

        case .deleteFile:
            guard let name = operation.name else { return }
            let key = Self.fileKey(day: operation.day, name: name)
            // No day folder on Drive means nothing was ever uploaded for it.
            guard let dayFolder = try await existingDayFolderId(operation.day, root: root, client: client) else {
                fileIds[key] = nil
                return
            }
            var id = fileIds[key]
            if id == nil {
                id = try await client.fileId(named: name, parent: dayFolder)
            }
            if let id {
                try await trashIgnoringMissing(id: id, client: client)
            }
            fileIds[key] = nil

        case .deleteDay:
            if let dayFolder = try await existingDayFolderId(operation.day, root: root, client: client) {
                try await trashIgnoringMissing(id: dayFolder, client: client)
            }
            folderIds[operation.day] = nil
            fileIds = fileIds.filter { !$0.key.hasPrefix(operation.day + "/") }
        }
    }

    /// Create-or-overwrite one day file, healing a stale cached id (the file or
    /// its folder was moved/trashed in Drive) by re-resolving once.
    private func upload(_ json: Data,
                        day: String,
                        name: String,
                        root: String,
                        client: GoogleDriveClient) async throws {
        let key = Self.fileKey(day: day, name: name)

        if let cached = fileIds[key] {
            do {
                try await client.updateJSONFile(id: cached, json: json)
                return
            } catch let error as GoogleDriveError where error.isNotFound {
                fileIds[key] = nil
            }
        }

        let dayFolder = try await dayFolderId(day, root: root, client: client)
        if let existing = try await client.fileId(named: name, parent: dayFolder) {
            try await client.updateJSONFile(id: existing, json: json)
            fileIds[key] = existing
        } else {
            fileIds[key] = try await client.createJSONFile(name: name, parent: dayFolder, json: json)
        }
    }

    private func trashIgnoringMissing(id: String, client: GoogleDriveClient) async throws {
        do {
            try await client.trash(id: id)
        } catch let error as GoogleDriveError where error.isNotFound {
            // Already gone — the desired end state.
        }
    }

    // MARK: - Folder resolution

    private func rootFolderId(client: GoogleDriveClient) async throws -> String {
        if let cached = folderIds[""] { return cached }
        // "root" is Drive's alias for the user's My Drive.
        let id = try await client.folderId(named: folderName, parent: "root")
        folderIds[""] = id
        saveCaches()
        return id
    }

    private func dayFolderId(_ day: String, root: String, client: GoogleDriveClient) async throws -> String {
        if let cached = folderIds[day] { return cached }
        let id = try await client.folderId(named: day, parent: root)
        folderIds[day] = id
        return id
    }

    /// Day folder id *without* creating it — for deletions, where creating the
    /// folder just to trash it would be absurd.
    private func existingDayFolderId(_ day: String, root: String, client: GoogleDriveClient) async throws -> String? {
        if let cached = folderIds[day] { return cached }
        let id = try await client.fileId(named: day, parent: root, isFolder: true)
        folderIds[day] = id
        return id
    }

    // MARK: - Persistence

    private func savePending() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: pendingKey)
    }

    private func saveCaches() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(folderIds), forKey: folderCacheKey)
        defaults.set(try? JSONEncoder().encode(fileIds), forKey: fileCacheKey)
    }

    /// Forget every resolved Drive id. The next sync re-resolves by name, which
    /// is what makes renaming the folder (or restoring from trash) work.
    func clearCaches() {
        folderIds = [:]
        fileIds = [:]
        saveCaches()
    }

    /// Drop the queue and the caches — used when Drive is disconnected, so a
    /// later reconnection to a different account doesn't chase dead ids.
    func reset() {
        pending = []
        savePending()
        clearCaches()
        lastSync = nil
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
        statusMessage = ""
        errorMessage = nil
        status = nil
    }

    private func report(_ error: Error, context: String) {
        errorMessage = "\(context): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
    }

    private static func isDayFolder(_ name: String) -> Bool {
        name.count == 10 && name.allSatisfy { $0.isNumber || $0 == "-" }
    }

    private static func fileKey(day: String, name: String) -> String { "\(day)/\(name)" }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
