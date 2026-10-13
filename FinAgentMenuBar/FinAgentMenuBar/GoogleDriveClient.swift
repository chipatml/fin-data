//
//  GoogleDriveClient.swift
//  FinAgentMenuBar
//
//  Thin async client over the Google Drive v3 REST API — just the handful of
//  calls needed to mirror the per-day JSON: resolve/create folders, create or
//  overwrite a file by name, and trash one that's gone locally.
//
//  Access tokens come from the caller (see GoogleDriveAuth) via an async
//  provider, so an expired token is refreshed transparently and a 401 is
//  retried once with a forced refresh.
//

import Foundation

struct GoogleDriveClient {
    /// Supplies a bearer token; `forceRefresh` is passed after a 401.
    typealias TokenProvider = (_ forceRefresh: Bool) async throws -> String

    static let folderMimeType = "application/vnd.google-apps.folder"
    private static let filesEndpoint = URL(string: "https://www.googleapis.com/drive/v3/files")!
    private static let uploadEndpoint = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!

    let token: TokenProvider
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(token: @escaping TokenProvider, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    // MARK: - Lookup

    private struct FileList: Decodable {
        let files: [DriveFile]
        let nextPageToken: String?
    }

    struct DriveFile: Decodable {
        let id: String
        let name: String?
        let mimeType: String?
        let parents: [String]?

        var isFolder: Bool { mimeType == GoogleDriveClient.folderMimeType }
    }

    /// Run a Drive search, walking every page unless `limit` caps it. With the
    /// `drive.file` scope only files this app created are visible, so even an
    /// unqualified query returns just the tree we manage.
    func list(query: String, limit: Int? = nil) async throws -> [DriveFile] {
        var results: [DriveFile] = []
        var pageToken: String?

        repeat {
            var items = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,parents)"),
                URLQueryItem(name: "spaces", value: "drive"),
                URLQueryItem(name: "pageSize", value: String(min(limit ?? 1000, 1000))),
            ]
            if let pageToken {
                items.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            var components = URLComponents(url: Self.filesEndpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = items

            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"

            let page = try await decoder.decode(FileList.self, from: send(request))
            results.append(contentsOf: page.files)
            if let limit, results.count >= limit {
                return Array(results.prefix(limit))
            }
            pageToken = page.nextPageToken
        } while pageToken != nil

        return results
    }

    /// Id of the first non-trashed child of `parent` with this exact name, or nil.
    func fileId(named name: String, parent: String, isFolder: Bool = false) async throws -> String? {
        var query = "name = '\(Self.escape(name))' and '\(Self.escape(parent))' in parents and trashed = false"
        if isFolder {
            query += " and mimeType = '\(Self.folderMimeType)'"
        }
        return try await list(query: query, limit: 1).first?.id
    }

    /// Every non-trashed folder directly under `parent`.
    func childFolders(of parent: String) async throws -> [DriveFile] {
        try await list(query: "'\(Self.escape(parent))' in parents"
                       + " and mimeType = '\(Self.folderMimeType)'"
                       + " and trashed = false")
    }

    /// Every non-trashed, non-folder file visible to the app, with its parent
    /// ids. One paged query, rather than a listing per day folder.
    func allFiles() async throws -> [DriveFile] {
        try await list(query: "mimeType != '\(Self.folderMimeType)' and trashed = false")
    }

    // MARK: - Folders

    /// Existing folder id for `name` under `parent`, creating it if absent.
    /// `parent` may be the alias `"root"` for the user's Drive root.
    func folderId(named name: String, parent: String) async throws -> String {
        if let existing = try await fileId(named: name, parent: parent, isFolder: true) {
            return existing
        }
        let metadata: [String: Any] = [
            "name": name,
            "mimeType": Self.folderMimeType,
            "parents": [parent],
        ]
        var components = URLComponents(url: Self.filesEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fields", value: "id")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let data = try await send(request)
        return try decoder.decode(DriveFile.self, from: data).id
    }

    // MARK: - Upload

    /// Create `name` under `parent` with `json` as its content, returning the
    /// new file id. Drive allows duplicate names in a folder, so callers must
    /// look up an existing id first (see `fileId`) rather than blindly create.
    func createJSONFile(name: String, parent: String, json: Data) async throws -> String {
        let metadata: [String: Any] = [
            "name": name,
            "parents": [parent],
            "mimeType": "application/json",
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)

        let boundary = "finagent-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadataJSON)
        body.append("\r\n--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(json)
        body.append("\r\n--\(boundary)--\r\n")

        var components = URLComponents(url: Self.uploadEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data = try await send(request)
        return try decoder.decode(DriveFile.self, from: data).id
    }

    /// Replace the content of an existing file, keeping its id (so anyone the
    /// file is shared with keeps their link and history).
    func updateJSONFile(id: String, json: Data) async throws {
        var components = URLComponents(
            url: Self.uploadEndpoint.appendingPathComponent(id), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "media"),
            URLQueryItem(name: "fields", value: "id"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = json

        _ = try await send(request)
    }

    /// Raw bytes of a file. Used by the one-time Drive → Cloud Storage copy.
    func download(id: String) async throws -> Data {
        var components = URLComponents(
            url: Self.filesEndpoint.appendingPathComponent(id), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return try await send(request)
    }

    // MARK: - Delete

    /// Move a file or folder to the Drive trash. Recoverable, unlike an
    /// outright delete, which matters for financial records.
    func trash(id: String) async throws {
        var request = URLRequest(url: Self.filesEndpoint.appendingPathComponent(id))
        request.httpMethod = "PATCH"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["trashed": true])
        _ = try await send(request)
    }

    // MARK: - Request plumbing

    /// Authorize and send `request`, retrying once with a forced token refresh
    /// if Google rejects the token.
    private func send(_ request: URLRequest) async throws -> Data {
        do {
            return try await perform(request, forceRefresh: false)
        } catch let error as GoogleDriveError where error.isUnauthorized {
            return try await perform(request, forceRefresh: true)
        }
    }

    private func perform(_ request: URLRequest, forceRefresh: Bool) async throws -> Data {
        var authorized = request
        authorized.setValue("Bearer \(try await token(forceRefresh))",
                            forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: authorized)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleDriveError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw GoogleDriveError.http(status: http.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "<no body>")
        }
        return data
    }

    /// Escape a value for interpolation into a Drive `q` search string, where
    /// the literal is single-quoted — a label like `Chirag's Visa` would
    /// otherwise break the query.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "'", with: "\\'")
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
