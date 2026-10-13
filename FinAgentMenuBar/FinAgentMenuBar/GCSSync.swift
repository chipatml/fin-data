//
//  GCSSync.swift
//  FinAgentMenuBar
//
//  Default remote mirror. The queue is the same shape as the Drive mirror:
//  local files stay authoritative, and a failed upload is retried next pull.
//
//  Objects:
//      gs://<bucket>/<prefix>/<YYYY-MM-DD>/<Label>.json
//
//  One-time copy from an existing Drive folder, when that account is still
//  connected, is `importFromDrive`. Otherwise, from the Mac that holds the
//  local Data folder:
//
//      gcloud storage rsync --recursive \
//        "$HOME/Library/Application Support/FinAgentMenuBar/Data" \
//        "gs://BUCKET/FinAgentMenuBar"
//

import Foundation
import Combine

@MainActor
final class GCSSync: ObservableObject, DayFileMirror {
    static let shared = GCSSync()
    static let defaultPrefix = "FinAgentMenuBar"

    private let auth = GCSAuth.shared

    @Published private(set) var isSyncing = false
    @Published private(set) var isMigrating = false
    @Published private(set) var pendingCount = 0
    @Published var lastSync: Date?
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    private let enabledKey = "com.mlaid.finagent.gcs.enabled"
    private let bucketKey = "com.mlaid.finagent.gcs.bucket"
    private let prefixKey = "com.mlaid.finagent.gcs.prefix"
    private let pendingKey = "com.mlaid.finagent.gcs.pending"
    private let lastSyncKey = "com.mlaid.finagent.gcs.last_sync"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: enabledKey) }
    }

    /// GCS bucket. Not a secret. Changing it sends the next upload to the new bucket.
    @Published var bucketName: String {
        didSet {
            guard bucketName != oldValue else { return }
            UserDefaults.standard.set(bucketName, forKey: bucketKey)
            status = nil
        }
    }

    /// Object prefix that replaces the old Drive folder name.
    @Published var prefix: String {
        didSet {
            guard prefix != oldValue else { return }
            UserDefaults.standard.set(prefix, forKey: prefixKey)
            status = nil
        }
    }

    struct Status {
        var bucketExists = false
        var localFiles = 0
        var localDays = 0
        var remoteFiles = 0
        var remoteDays = 0
        var missing: [String] = []
        var extra: [String] = []
        var queued = 0
        var checkedAt = Date()
        var errorMessage: String?

        var inSync: Bool {
            errorMessage == nil && bucketExists && missing.isEmpty && extra.isEmpty && queued == 0
        }
    }

    @Published private(set) var isCheckingStatus = false
    @Published private(set) var status: Status?

    private struct Operation: Codable, Hashable {
        enum Kind: String, Codable {
            case upload
            case deleteFile
            case deleteDay
        }
        let kind: Kind
        let day: String
        let name: String?
    }

    private var pending: [Operation] = [] {
        didSet { pendingCount = pending.count }
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: enabledKey)
        bucketName = defaults.string(forKey: bucketKey) ?? ""
        prefix = defaults.string(forKey: prefixKey) ?? Self.defaultPrefix
        if let data = defaults.data(forKey: pendingKey),
           let decoded = try? JSONDecoder().decode([Operation].self, from: data) {
            pending = decoded
        } else {
            pending = []
        }
        pendingCount = pending.count
        let stamp = defaults.double(forKey: lastSyncKey)
        lastSync = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    static func migrationCommand(bucket: String, prefix: String) -> String {
        let b = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return """
        gcloud storage rsync --recursive \\
          "$HOME/Library/Application Support/FinAgentMenuBar/Data" \\
          "gs://\(b.isEmpty ? "BUCKET" : b)/\(p.isEmpty ? defaultPrefix : p)"
        """
    }

    func markWritten(day: String, fileName: String) {
        enqueue(Operation(kind: .upload, day: day, name: fileName))
    }

    func markDeleted(day: String, fileName: String) {
        guard isEnabled else { return }
        pending.removeAll { $0.day == day && $0.name == fileName && $0.kind == .upload }
        enqueue(Operation(kind: .deleteFile, day: day, name: fileName))
    }

    func markDayRemoved(day: String) {
        guard isEnabled else { return }
        pending.removeAll { $0.day == day }
        enqueue(Operation(kind: .deleteDay, day: day, name: nil))
    }

    private func enqueue(_ operation: Operation) {
        guard isEnabled, !pending.contains(operation) else { return }
        pending.append(operation)
        savePending()
    }

    func flush(localRoot: URL) async {
        guard isEnabled, !pending.isEmpty, !isSyncing else { return }
        guard auth.isConfigured else {
            errorMessage = GCSError.notConfigured.errorDescription
            return
        }
        guard !bucketName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = GCSError.missingBucket.errorDescription
            return
        }

        isSyncing = true
        statusMessage = "Uploading \(pending.count) file(s) to Cloud Storage…"
        errorMessage = nil
        defer { isSyncing = false }

        let client: GCSClient
        do {
            client = try makeClient()
            try await client.probeBucket()
        } catch {
            report(error, context: "Cloud Storage")
            return
        }

        let batch = pending
        pending = []
        var failed: [Operation] = []
        var firstFailure: Error?

        for operation in batch {
            do {
                try await apply(operation, client: client, localRoot: localRoot)
            } catch {
                failed.append(operation)
                if firstFailure == nil { firstFailure = error }
            }
        }

        pending = failed + pending.filter { !failed.contains($0) }
        savePending()

        if let firstFailure {
            report(firstFailure, context: "Cloud Storage sync")
            statusMessage = "\(failed.count) file(s) still pending"
        } else {
            let now = Date()
            lastSync = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastSyncKey)
            statusMessage = pending.isEmpty ? "Synced to Cloud Storage" : "\(pending.count) file(s) queued"
            errorMessage = nil
        }
    }

    func syncAll(localRoot: URL) async {
        for path in DayFileLayout.inventory(localRoot) {
            markWritten(day: path.day, fileName: path.name)
        }
        await flush(localRoot: localRoot)
    }

    /// Upload the local tree, then copy any Drive day files that are not already
    /// in the bucket. Drive must still be connected for the second step.
    func importFromDrive(localRoot: URL) async {
        guard !isMigrating, !isSyncing else { return }
        isMigrating = true
        defer { isMigrating = false }
        errorMessage = nil

        isEnabled = true
        await syncAll(localRoot: localRoot)
        if errorMessage != nil { return }

        guard GoogleDriveAuth.shared.isConnected else {
            statusMessage = "Local files uploaded. Drive is not connected, so nothing else was copied. Use the gcloud command for a machine that only has the Data folder."
            return
        }

        do {
            let client = try makeClient()
            let remote = try await GoogleDriveSync.shared.downloadDayFiles()
            var copied = 0
            for file in remote {
                let object = DayFileLayout.objectName(prefix: prefix, day: file.day, name: file.name)
                try await client.upload(data: file.data, objectName: object)
                copied += 1
            }
            statusMessage = copied == 0
                ? "Drive folder had no day files to copy"
                : "Copied \(copied) Drive file(s) into gs://\(bucketName)/\(prefix)"
            errorMessage = nil
        } catch {
            report(error, context: "Drive copy")
        }
    }

    func checkStatus(localRoot: URL) async {
        guard !isCheckingStatus else { return }
        isCheckingStatus = true
        defer { isCheckingStatus = false }

        var result = Status()
        result.queued = pending.count
        let local = DayFileLayout.inventory(localRoot)
        result.localFiles = local.count
        result.localDays = Set(local.map(\.day)).count

        guard auth.isConfigured else {
            result.errorMessage = GCSError.notConfigured.errorDescription
            status = result
            return
        }
        guard !bucketName.isEmpty else {
            result.errorMessage = GCSError.missingBucket.errorDescription
            status = result
            return
        }

        do {
            let client = try makeClient()
            let names = try await client.listNames(prefix: listPrefix)
            result.bucketExists = true
            let relative = names.compactMap { relativePath(of: $0) }
            result.remoteFiles = relative.count
            result.remoteDays = Set(relative.compactMap { $0.split(separator: "/").first.map(String.init) }).count
            let localPaths = Set(local.map(\.path))
            let remotePaths = Set(relative)
            result.missing = localPaths.subtracting(remotePaths).sorted()
            result.extra = remotePaths.subtracting(localPaths).sorted()
        } catch {
            result.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        status = result
    }

    func reset() {
        pending = []
        savePending()
        lastSync = nil
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
        statusMessage = ""
        errorMessage = nil
        status = nil
    }

    // MARK: - Operations

    private func apply(_ operation: Operation, client: GCSClient, localRoot: URL) async throws {
        switch operation.kind {
        case .upload:
            guard let name = operation.name else { return }
            let localURL = localRoot
                .appendingPathComponent(operation.day, isDirectory: true)
                .appendingPathComponent(name)
            guard let json = try? Data(contentsOf: localURL) else { return }
            let object = DayFileLayout.objectName(prefix: prefix, day: operation.day, name: name)
            try await client.upload(data: json, objectName: object)

        case .deleteFile:
            guard let name = operation.name else { return }
            let object = DayFileLayout.objectName(prefix: prefix, day: operation.day, name: name)
            try await client.delete(objectName: object)

        case .deleteDay:
            let dayPrefix = DayFileLayout.objectName(prefix: prefix, day: operation.day, name: "")
            let names = try await client.listNames(prefix: dayPrefix)
            for name in names {
                try await client.delete(objectName: name)
            }
        }
    }

    private var listPrefix: String {
        let root = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return root.isEmpty ? "" : root + "/"
    }

    private func relativePath(of objectName: String) -> String? {
        let root = listPrefix
        let relative: String
        if root.isEmpty {
            relative = objectName
        } else if objectName.hasPrefix(root) {
            relative = String(objectName.dropFirst(root.count))
        } else {
            return nil
        }
        guard !relative.isEmpty else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].hasSuffix(".json"), DayFileLayout.isDayFolder(String(parts[0])) else {
            return nil
        }
        return relative
    }

    private func makeClient() throws -> GCSClient {
        let bucket = try GCSBucketName.validate(bucketName)
        return GCSClient(bucket: bucket) { force in
            try await GCSAuth.shared.accessToken(forceRefresh: force)
        }
    }

    private func savePending() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: pendingKey)
    }

    private func report(_ error: Error, context: String) {
        errorMessage = "\(context): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
    }
}
