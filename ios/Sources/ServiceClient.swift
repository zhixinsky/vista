// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security
import UIKit
import Darwin

actor ServiceClient {
    static let shared = ServiceClient()
    private var token: String?
    private var queue: [[String: Any]] = []
    private var flushing = false

    static var machine: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var systemBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            sysctlbyname("kern.osversion", pointer.baseAddress, &size, nil, 0)
        }
        return result == 0 ? String(cString: buffer) : ""
    }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(version)（\(build)）"
    }

    func startup() async {
        guard ServiceGate.enabled else { return }
        loadQueue()
        await register()
        await record(type: "launch", ok: nil, payload: ["device_machine": Self.machine])
    }

    func record(type: String, ok: Bool?, payload: [String: Any]) async {
        guard ServiceGate.enabled else { return }
        loadQueue()
        var body = payload
        body["device_machine"] = Self.machine
        body["ios_build"] = Self.systemBuild
        body["app_build"] = Self.appBuild
        let facts = await deviceFacts()
        var event: [String: Any] = [
            "id": UUID().uuidString,
            "type": type,
            "at": Self.stamp(Date()),
            "app_version": Self.appVersion,
            "ios_version": facts.ios,
            "ios_build": Self.systemBuild,
            "app_build": Self.appBuild,
            "api_version": 2,
            "payload": body
        ]
        event["ok"] = ok.map { $0 as Any } ?? NSNull()
        queue.append(event)
        if queue.count > 200 { queue.removeFirst(queue.count - 200) }
        saveQueue()
        await flush()
    }

    func submitSaved(_ entry: SavedWallpaper, source: String, assetID: String?) async {
        guard ServiceGate.enabled else { return }
        guard let preview = try? Data(contentsOf: entry.preview), !preview.isEmpty else { return }
        guard let token = await ensureToken() else { return }
        let boundary = "CarVista\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("id", entry.id.uuidString)
        field("source", source)
        field("source_asset_id", assetID ?? "")
        field("width", String(entry.width))
        field("height", String(entry.height))
        field("mode", entry.mode)
        field("created_at", Self.stamp(entry.created))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"preview\"; filename=\"preview.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(preview)
        if let original = try? Data(contentsOf: entry.originalImage), !original.isEmpty {
            body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"original\"; filename=\"original.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
            body.append(original)
        }
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: Self.endpoint("v1/works"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }

    func submitReport(_ data: Data) async -> Bool {
        guard ServiceGate.enabled, data.count <= 1_000_000 else { return false }
        guard let token = await ensureToken() else { return false }
        var request = URLRequest(url: Self.endpoint("v1/reports"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
            return true
        } catch { return false }
    }

    func submitShare(_ entry: SavedWallpaper, title: String, description: String, author: String = "") async -> Bool {
        guard ServiceGate.enabled else { return false }
        guard let preview = try? Data(contentsOf: entry.preview), !preview.isEmpty,
              let original = try? Data(contentsOf: entry.originalImage), !original.isEmpty else { return false }
        guard let token = await ensureToken() else { return false }
        let boundary = "CarVista\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("id", entry.id.uuidString)
        field("title", title)
        field("description", String(description.prefix(200)))
        field("author", String(author.prefix(60)))
        field("width", String(entry.width))
        field("height", String(entry.height))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"preview\"; filename=\"preview.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(preview)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"original\"; filename=\"original.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(original)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: Self.endpoint("v1/shares"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
            var sharedIDs = Set(UserDefaults.standard.string(forKey: "CarVistaSharedHistory")?.split(separator: "|").map(String.init) ?? [])
            sharedIDs.insert(entry.id.uuidString)
            UserDefaults.standard.set(sharedIDs.sorted().joined(separator: "|"), forKey: "CarVistaSharedHistory")
            return true
        } catch { return false }
    }

    struct ShareMetadata: Decodable {
        let title: String
        let description: String
        let author: String?
    }

    func shareMetadata(_ id: UUID) async -> ShareMetadata? {
        guard let token = await ensureToken() else { return nil }
        var request = URLRequest(url: Self.endpoint("v1/shares/\(id.uuidString.lowercased())/metadata"), timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(ShareMetadata.self, from: data)
        } catch { return nil }
    }

    func removeShare(_ id: UUID) async -> Bool {
        guard let token = await ensureToken() else { return false }
        var request = URLRequest(url: Self.endpoint("v1/shares/\(id.uuidString.lowercased())"), timeoutInterval: 20)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
            var ids = Set(UserDefaults.standard.string(forKey: "CarVistaSharedHistory")?.split(separator: "|").map(String.init) ?? [])
            ids.remove(id.uuidString)
            UserDefaults.standard.set(ids.sorted().joined(separator: "|"), forKey: "CarVistaSharedHistory")
            return true
        } catch { return false }
    }

    func updateShare(_ id: UUID, title: String, description: String, author: String = "") async -> Bool {
        guard let token = await ensureToken() else { return false }
        var request = URLRequest(url: Self.endpoint("v1/shares/\(id.uuidString.lowercased())/metadata"), timeoutInterval: 20)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "title", value: title),
                           URLQueryItem(name: "description", value: String(description.prefix(200))),
                           URLQueryItem(name: "author", value: String(author.prefix(60)))]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch { return false }
    }

    func compatibility() async throws -> CompatibilityFeed {
        let request = URLRequest(url: Self.endpoint("v1/compatibility"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(CompatibilityFeed.self, from: data)
    }

    func fetchShares(sort: ShareSort = .likes) async -> [SharedWallpaper]? {
        guard ServiceGate.enabled else { return nil }
        var url = URLComponents(url: Self.endpoint("v1/shares"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "sort", value: sort.rawValue)]
        var request = URLRequest(url: url.url!, timeoutInterval: 20)
        if let token = await ensureToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let items = try JSONDecoder().decode(ShareFeed.self, from: data).items.map(SharedWallpaper.init)
            if sort == .likes { CatalogLibrary.rememberData(data, name: "shares") }
            return items
        } catch { return nil }
    }

    func comments(_ id: String, offset: Int = 0) async throws -> ShareCommentPage {
        var url = URLComponents(url: Self.endpoint("v1/shares/\(id)/comments"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "offset", value: String(offset))]
        var request = URLRequest(url: url.url!, timeoutInterval: 20)
        if let token = await ensureToken() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "CarVista", code: 1, userInfo: [NSLocalizedDescriptionKey: "评论暂时无法加载，请稍后重试。"])
        }
        return try JSONDecoder().decode(ShareCommentPage.self, from: data)
    }

    func setCommentLike(_ shareID: String, commentID: String, liked: Bool) async throws -> CommentLikeResult {
        guard ServiceGate.enabled, let token = await ensureToken() else { throw URLError(.notConnectedToInternet) }
        var request = URLRequest(url: Self.endpoint("v1/shares/\(shareID)/comments/\(commentID)/like"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["liked": liked])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(CommentLikeResult.self, from: data)
    }

    func postComment(_ shareID: String, id: UUID, body: String) async throws {
        guard ServiceGate.enabled, let token = await ensureToken() else {
            throw NSError(domain: "CarVista", code: 1, userInfo: [NSLocalizedDescriptionKey: "暂时无法连接，请稍后再发送。"])
        }
        var request = URLRequest(url: Self.endpoint("v1/shares/\(shareID)/comments"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "body": body])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw NSError(domain: "CarVista", code: 1, userInfo: [NSLocalizedDescriptionKey: object?["detail"] as? String ?? object?["message"] as? String ?? "发送失败，评论内容已保留，请重试。"])
        }
    }

    func toggleLike(_ id: String) async -> (likes: Int, liked: Bool)? {
        guard ServiceGate.enabled, let token = await ensureToken() else { return nil }
        var request = URLRequest(url: Self.endpoint("v1/shares/\(id)/like"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let likes = object["likes"] as? Int, let liked = object["liked"] as? Bool else { return nil }
            return (likes, liked)
        } catch { return nil }
    }

    private func flush() async {
        guard !flushing, !queue.isEmpty else { return }
        guard let token = await ensureToken() else { return }
        flushing = true
        defer { flushing = false }
        var request = URLRequest(url: Self.endpoint("v1/events"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let httpBody = try? JSONSerialization.data(withJSONObject: ["events": queue]) else { return }
        request.httpBody = httpBody
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                self.token = nil
                KeychainStore.write("device_token", "")
                await register()
                return
            }
            guard (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let done = Set((object["accepted"] as? [String] ?? []) + (object["rejected"] as? [String] ?? []))
            queue.removeAll { event in
                guard let id = event["id"] as? String else { return false }
                return done.contains(id)
            }
            saveQueue()
        } catch { }
    }

    private func ensureToken() async -> String? {
        if let token, !token.isEmpty { return token }
        if let stored = KeychainStore.read("device_token"), !stored.isEmpty {
            token = stored
            return stored
        }
        await register()
        return token
    }

    private func register() async {
        let installID = KeychainStore.installID()
        let facts = await deviceFacts()
        let payload: [String: Any] = [
            "install_id": installID,
            "app_version": Self.appVersion,
            "ios_version": facts.ios,
            "ios_build": Self.systemBuild,
            "app_build": Self.appBuild,
            "api_version": 2,
            "device_model": facts.model,
            "device_machine": Self.machine
        ]
        var request = URLRequest(url: Self.endpoint("v1/devices"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issued = object["device_token"] as? String, !issued.isEmpty else { return }
        token = issued
        KeychainStore.write("device_token", issued)
    }

    private func loadQueue() {
        guard queue.isEmpty, let url = try? Self.queueURL(), let data = try? Data(contentsOf: url),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        queue = saved
    }

    private func saveQueue() {
        guard let url = try? Self.queueURL(), let data = try? JSONSerialization.data(withJSONObject: queue) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func deviceFacts() async -> (ios: String, model: String) {
        await MainActor.run { (UIDevice.current.systemVersion, UIDevice.current.model) }
    }

    private static func endpoint(_ path: String) -> URL {
        ServiceGate.join(path)
    }

    static func publicURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased() else { return url }
        let local = ["127.0.0.1", "localhost", "::1"].contains(host)
        let apiHost = ServiceGate.baseURL.host?.lowercased()
        let insecureAPI = url.scheme?.lowercased() == "http" && (host == apiHost || host == "carplayv2.dokor.cn")
        guard local || insecureAPI else { return url }
        let path = url.path.split(separator: "/").joined(separator: "/")
        guard !path.isEmpty else { return ServiceGate.baseURL }
        return ServiceGate.join(path)
    }

    private static func queueURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("CarVistaService", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("events.json")
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: date)
    }
}

enum KeychainStore {
    private static let service = "local.carvista.service"

    static func installID() -> String {
        if let existing = read("install_id"), !existing.isEmpty { return existing }
        let created = UUID().uuidString
        write("install_id", created)
        return created
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func write(_ account: String, _ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
