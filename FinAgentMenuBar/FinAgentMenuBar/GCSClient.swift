//
//  GCSClient.swift
//  FinAgentMenuBar
//
//  Google Cloud Storage JSON API. Object names keep the Drive layout:
//  `<prefix>/<YYYY-MM-DD>/<Label>.json`.
//

import Foundation

struct GCSClient {
    typealias TokenProvider = (_ forceRefresh: Bool) async throws -> String

    let bucket: String
    let token: TokenProvider
    private let session: URLSession

    init(bucket: String, token: @escaping TokenProvider, session: URLSession = .shared) {
        self.bucket = bucket
        self.token = token
        self.session = session
    }

    /// `storage.objects.list`. Confirms the bucket is reachable without needing
    /// `storage.buckets.get`, which Storage Object Admin does not grant.
    func probeBucket() async throws {
        _ = try await list(prefix: nil, pageToken: nil, maxResults: 1)
    }

    func listNames(prefix: String) async throws -> [String] {
        var names: [String] = []
        var page: String?
        repeat {
            let pageResult = try await list(prefix: prefix, pageToken: page, maxResults: nil)
            names.append(contentsOf: pageResult.names)
            page = pageResult.nextPageToken
        } while page != nil
        return names
    }

    func upload(data: Data, objectName: String, contentType: String = "application/json") async throws {
        var components = URLComponents(string: "https://storage.googleapis.com/upload/storage/v1/b/\(encodedBucket)/o")!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "media"),
            URLQueryItem(name: "name", value: objectName),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try await send(request)
    }

    func download(objectName: String) async throws -> Data {
        let url = URL(string: "https://storage.googleapis.com/storage/v1/b/\(encodedBucket)/o/\(encodedPath(objectName))?alt=media")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await send(request)
    }

    func delete(objectName: String) async throws {
        let url = URL(string: "https://storage.googleapis.com/storage/v1/b/\(encodedBucket)/o/\(encodedPath(objectName))")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        do {
            _ = try await send(request)
        } catch let error as GCSError where error.isNotFound {
            // Already gone.
        }
    }

    // MARK: - Request plumbing

    private struct Page {
        var names: [String]
        var nextPageToken: String?
    }

    private func list(prefix: String?, pageToken: String?, maxResults: Int?) async throws -> Page {
        var components = URLComponents(string: "https://storage.googleapis.com/storage/v1/b/\(encodedBucket)/o")!
        var items = [URLQueryItem(name: "fields", value: "items/name,nextPageToken")]
        if let prefix, !prefix.isEmpty {
            items.append(URLQueryItem(name: "prefix", value: prefix))
        }
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let maxResults {
            items.append(URLQueryItem(name: "maxResults", value: String(maxResults)))
        }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        let data = try await send(request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let names = (json["items"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        return Page(names: names, nextPageToken: json["nextPageToken"] as? String)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            return try await perform(request, forceRefresh: false)
        } catch let error as GCSError where error.isUnauthorized {
            return try await perform(request, forceRefresh: true)
        }
    }

    private func perform(_ request: URLRequest, forceRefresh: Bool) async throws -> Data {
        var authorized = request
        authorized.setValue("Bearer \(try await token(forceRefresh))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: authorized)
        guard let http = response as? HTTPURLResponse else {
            throw GCSError.http(status: -1, detail: "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.mapHTTP(status: http.statusCode, data: data, bucket: bucket)
        }
        return data
    }

    private var encodedBucket: String {
        bucket.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bucket
    }

    private func encodedPath(_ objectName: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return objectName.addingPercentEncoding(withAllowedCharacters: allowed) ?? objectName
    }

    static func mapHTTP(status: Int, data: Data, bucket: String) -> GCSError {
        switch status {
        case 401:
            return .unauthorized
        case 403:
            return .permissionDenied
        case 404:
            let message = detail(from: data).lowercased()
            if message.contains("bucket does not exist") || message.contains("nosuchbucket") {
                return .bucketNotFound(bucket)
            }
            return .notFound
        default:
            return .http(status: status, detail: detail(from: data))
        }
    }

    private static func detail(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty {
                return clip(message)
            }
            if let message = json["error_description"] as? String {
                return clip(message)
            }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "empty response" : clip(text)
    }

    private static func clip(_ text: String) -> String {
        text.count > 240 ? String(text.prefix(240)) + "…" : text
    }
}

enum GCSBucketName {
    static func validate(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GCSError.missingBucket }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let startsOk = name.first?.isLetter == true || name.first?.isNumber == true
        let ok = name.count >= 3 && name.count <= 63
            && startsOk
            && name.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !name.contains("/")
        guard ok else { throw GCSError.invalidBucket(name) }
        return name
    }
}
