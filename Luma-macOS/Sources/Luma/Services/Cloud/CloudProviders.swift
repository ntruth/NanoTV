import Foundation
import AppKit
import Network
import ImageIO
import LumaContentCore

// MARK: - 错误

enum CloudOAuthError: LocalizedError {
    case missingCredentials
    case unsupportedProvider
    case notAuthorized
    /// 钥匙串里的条目存在，但当前 App 无权读取（重新签名 / ACL 变化时会出现）。
    case keychainDenied(OSStatus)
    case invalidCallback
    case stateMismatch
    case cancelled
    case timeout
    case token(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "请先填写该平台的 AppID / AppSecret"
        case .unsupportedProvider: return "该接入方式不支持此操作"
        case .notAuthorized: return "尚未授权或授权已失效，请重新登录"
        case .keychainDenied(let status):
            return "钥匙串里有授权，但当前 App 无权读取（错误码 \(status)）。"
                + "如果是 App 重新签名导致，请在系统弹窗里选择「始终允许」；否则点「重新登录」重新写入授权。"
        case .invalidCallback: return "授权回调无效，请重试"
        case .stateMismatch: return "授权校验失败（state 不一致），请重试"
        case .cancelled: return "已取消授权"
        case .timeout: return "等待授权超时，请重新发起"
        case .token(let message): return "获取令牌失败：\(message)"
        case .api(let message): return "接口请求失败：\(message)"
        }
    }

    /// 需要用户重新登录（或允许钥匙串访问）才能继续的错误。
    var requiresReauth: Bool {
        switch self {
        case .notAuthorized, .keychainDenied:
            return true
        default:
            return false
        }
    }
}

// MARK: - 凭据与令牌

struct CloudClientCredentials: Codable {
    var clientID: String
    var clientSecret: String
    /// 百度网盘专用：AppID 仅作为授权链接的 device_id，可留空。
    var appID: String? = nil
}

struct CloudToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var accountName: String?
    var driveID: String?
}

enum CloudOAuthStore {
    private static let service = "com.baymax.photosclone.oauth"
    /// 旧版包标识时期使用的 Keychain service，仅用于一次性迁移。
    private static let legacyService = "com.lijialong.photosclone.oauth"

    /// 进程内令牌缓存：每次点击目录都会请求令牌，但不必每次都读钥匙串。
    private static let cacheLock = NSLock()
    private static var tokenCache: [UUID: CloudToken] = [:]

    /// 钥匙串读取结果：区分「确实没有」和「条目存在但无权读取」，后者要提示用户允许访问而不是重新登录。
    enum ReadOutcome {
        case data(Data)
        case missing
        case denied(OSStatus)
    }

    enum TokenLoadResult {
        case token(CloudToken)
        case missing
        case denied(OSStatus)
    }

    enum CredentialsLoadResult {
        case credentials(CloudClientCredentials)
        case missing
        case denied(OSStatus)
    }

    static func credentials(for kind: CloudKind) -> CloudClientCredentials? {
        if case .credentials(let value) = credentialsResult(for: kind) { return value }
        return nil
    }

    static func credentialsResult(for kind: CloudKind) -> CredentialsLoadResult {
        let account = "client.\(kind.rawValue)"
        if let data = CloudSecretStore.data(for: account) {
            guard let credentials = try? JSONDecoder().decode(CloudClientCredentials.self, from: data) else {
                return .missing
            }
            return .credentials(credentials)
        }
        switch migrateLegacy(account: account) {
        case .missing:
            return .missing
        case .denied(let status):
            return .denied(status)
        case .data(let data):
            guard let credentials = try? JSONDecoder().decode(CloudClientCredentials.self, from: data) else {
                return .missing
            }
            return .credentials(credentials)
        }
    }

    static func saveCredentials(_ credentials: CloudClientCredentials, for kind: CloudKind) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let account = "client.\(kind.rawValue)"
        LumaKeychainVault.suppressLegacy(vaultKey: vaultKey(account))
        CloudSecretStore.set(data, for: account)
    }

    static func token(mountID: UUID) -> CloudToken? {
        if case .token(let value) = tokenResult(mountID: mountID) { return value }
        return nil
    }

    static func tokenResult(mountID: UUID) -> TokenLoadResult {
        cacheLock.lock()
        if let cached = tokenCache[mountID] {
            cacheLock.unlock()
            return .token(cached)
        }
        cacheLock.unlock()

        let account = "token.\(mountID.uuidString)"
        if let data = CloudSecretStore.data(for: account) {
            guard let token = try? JSONDecoder().decode(CloudToken.self, from: data) else {
                return .missing
            }
            cacheLock.lock()
            tokenCache[mountID] = token
            cacheLock.unlock()
            return .token(token)
        }

        // 旧版本的令牌在钥匙串里：迁入统一保险库后就不再访问钥匙串。
        switch migrateLegacy(account: account) {
        case .missing:
            return .missing
        case .denied(let status):
            return .denied(status)
        case .data(let data):
            guard let token = try? JSONDecoder().decode(CloudToken.self, from: data) else {
                return .missing
            }
            cacheLock.lock()
            tokenCache[mountID] = token
            cacheLock.unlock()
            return .token(token)
        }
    }

    static func saveToken(_ token: CloudToken, mountID: UUID) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let account = "token.\(mountID.uuidString)"
        LumaKeychainVault.suppressLegacy(vaultKey: vaultKey(account))
        CloudSecretStore.set(data, for: account)
        cacheLock.lock()
        tokenCache[mountID] = token
        cacheLock.unlock()
    }

    static func deleteToken(mountID: UUID) {
        let account = "token.\(mountID.uuidString)"
        LumaKeychainVault.suppressLegacy(vaultKey: vaultKey(account))
        CloudSecretStore.remove(account)
        cacheLock.lock()
        tokenCache[mountID] = nil
        cacheLock.unlock()
    }

    private static func vaultKey(_ account: String) -> String {
        "cloud.\(account)"
    }

    /// 旧钥匙串条目只读取一次：结果由统一保险库记录，之后不再访问旧条目，也不会重复弹授权框。
    private static func migrateLegacy(account: String) -> ReadOutcome {
        switch LumaKeychainVault.migrateLegacy(vaultKey: vaultKey(account),
                                               services: [service, legacyService],
                                               account: account) {
        case .data(let data):
            return .data(data)
        case .denied(let status):
            Diagnostics.record("网盘凭据旧条目读取被拒绝 status=\(status)")
            return .denied(status)
        case .missing:
            return .missing
        }
    }
}

// MARK: - 本机回调监听

/// 监听 127.0.0.1:53682/callback，接收系统浏览器授权后的 code。
final class OAuthLoopbackServer {
    static let shared = OAuthLoopbackServer()
    static let port: UInt16 = 53682
    static var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    private let queue = DispatchQueue(label: "com.baymax.luma.oauth.callback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var expectedState = ""
    private var isFinished = true

    func waitForCode(state: String, timeout: TimeInterval = 180) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.shutdownLocked()
                self.isFinished = false
                self.expectedState = state
                self.continuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.allowLocalEndpointReuse = true
                    guard let port = NWEndpoint.Port(rawValue: Self.port) else {
                        throw CloudOAuthError.invalidCallback
                    }
                    // 安全加固：强制仅绑定本机回环 127.0.0.1，防止局域网其他设备访问回调端口
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
                    let listener = try NWListener(using: parameters)
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.stateUpdateHandler = { [weak self] newState in
                        if case .failed(let error) = newState {
                            self?.finish(.failure(error))
                        }
                    }
                    listener.start(queue: self.queue)
                    self.listener = listener
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(CloudOAuthError.timeout))
                    }
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CloudOAuthError.cancelled)) }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self.handle(request, connection: connection)
        }
    }

    private func handle(_ request: String, connection: NWConnection) {
        guard let firstLine = request.split(separator: "\r\n").first else {
            respond(connection, message: "无效请求", success: false)
            finish(.failure(CloudOAuthError.invalidCallback))
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else {
            respond(connection, message: "无效请求", success: false)
            finish(.failure(CloudOAuthError.invalidCallback))
            return
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        if let error = value("error") {
            let message = value("error_description") ?? error
            respond(connection, message: "授权失败：\(message)", success: false)
            finish(.failure(CloudOAuthError.token(message)))
            return
        }
        guard let code = value("code"), !code.isEmpty else {
            respond(connection, message: "未收到授权码，请返回 App 重试。", success: false)
            finish(.failure(CloudOAuthError.invalidCallback))
            return
        }
        guard value("state") == expectedState else {
            respond(connection, message: "授权校验失败，请重试。", success: false)
            finish(.failure(CloudOAuthError.stateMismatch))
            return
        }
        respond(connection, message: "授权完成，可以关闭此页面并返回 App。", success: true)
        finish(.success(code))
    }

    private func respond(_ connection: NWConnection, message: String, success: Bool) {
        let color = success ? "#0a7f5a" : "#c0392b"
        // 安全加固：对 query 传入文本做 HTML 实体转义，杜绝反射型 XSS
        let safeMessage = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>授权</title></head>
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif;background:#fafafa">
        <div style="text-align:center;padding:32px">
        <div style="font-size:42px;margin-bottom:16px">\(success ? "✅" : "⚠️")</div>
        <h2 style="color:\(color);margin:0 0 8px">\(safeMessage)</h2>
        </div></body></html>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<String, Error>) {
        guard !isFinished else { return }
        isFinished = true
        shutdownLocked()
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    private func shutdownLocked() {
        listener?.cancel()
        listener = nil
    }
}

// MARK: - 阿里云盘开放平台

enum AliyunOAuth {
    /// 允许本地联调时指向模拟服务（正式运行使用官方地址）。
    static var apiBase: String {
        ProcessInfo.processInfo.environment["LUMA_ALIYUN_API_BASE"]
            ?? "https://openapi.alipan.com"
    }
    static let scopes = "user:base,file:all:read"

    static func authorizeURL(clientID: String, redirectURI: String, state: String) -> URL? {
        var components = URLComponents(string: apiBase + "/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    static func exchange(clientID: String, clientSecret: String,
                         code: String, redirectURI: String) async throws -> CloudToken {
        try await requestToken([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "redirect_uri": redirectURI
        ])
    }

    static func refresh(clientID: String, clientSecret: String,
                        refreshToken: String) async throws -> CloudToken {
        try await requestToken([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken
        ])
    }

    static func driveInfo(accessToken: String) async throws -> (driveID: String, name: String?) {
        let object = try await post(path: "/adrive/v1.0/user/getDriveInfo",
                                    body: [:],
                                    accessToken: accessToken)
        let driveID = (object["default_drive_id"] as? String)
            ?? (object["resource_drive_id"] as? String)
            ?? (object["backup_drive_id"] as? String)
        guard let driveID, !driveID.isEmpty else {
            throw CloudOAuthError.api("未获取到网盘 ID")
        }
        let name = (object["name"] as? String) ?? (object["user_name"] as? String)
        return (driveID, name)
    }

    /// 阿里云盘一个账号最多有三个盘：默认盘、资源库、备份盘。
    /// 资源号 / 分享号的媒体通常只在「资源库」里，只扫默认盘会看起来几乎为空。
    static func drives(accessToken: String) async throws -> [(id: String, label: String)] {
        let object = try await post(path: "/adrive/v1.0/user/getDriveInfo",
                                    body: [:],
                                    accessToken: accessToken)
        var result: [(id: String, label: String)] = []
        func add(_ key: String, _ label: String) {
            guard let id = object[key] as? String, !id.isEmpty,
                  !result.contains(where: { $0.id == id }) else { return }
            result.append((id, label))
        }
        add("default_drive_id", "默认盘")
        add("resource_drive_id", "资源库")
        add("backup_drive_id", "备份盘")
        return result
    }

    /// 扫描与播放用 `盘ID|文件ID` 表示路径：同一账号的多个盘可以共存在一个挂载点下。
    static func splitPath(_ path: String?, fallbackDrive: String?) -> (drive: String, fileID: String)? {
        guard let path, !path.isEmpty else { return nil }
        if let separator = path.firstIndex(of: "|") {
            let drive = String(path[..<separator])
            let fileID = String(path[path.index(after: separator)...])
            if !drive.isEmpty, !fileID.isEmpty { return (drive, fileID) }
        }
        if let fallbackDrive, !fallbackDrive.isEmpty { return (fallbackDrive, path) }
        return nil
    }

    static func list(driveID: String, parentID: String, accessToken: String) async throws -> [CloudEntry] {
        var entries: [CloudEntry] = []
        var marker = ""
        var page = 0
        repeat {
            var body: [String: Any] = [
                "drive_id": driveID,
                "parent_file_id": parentID,
                "limit": 100,
                "order_by": "name",
                "order_direction": "ASC",
                "fields": "*"
            ]
            if !marker.isEmpty { body["marker"] = marker }
            let object = try await post(path: "/adrive/v1.0/openFile/list",
                                        body: body,
                                        accessToken: accessToken)
            let items = object["items"] as? [[String: Any]] ?? []
            entries.append(contentsOf: items.compactMap { parseEntry($0, driveID: driveID) })
            marker = (object["next_marker"] as? String) ?? ""
            page += 1
        } while !marker.isEmpty && page < 30
        return entries
    }

    static func downloadURL(driveID: String, fileID: String, accessToken: String) async throws -> URL {
        let object = try await post(path: "/adrive/v1.0/openFile/getDownloadUrl",
                                    body: ["drive_id": driveID, "file_id": fileID, "expire_sec": 900],
                                    accessToken: accessToken)
        guard let raw = object["url"] as? String, let url = URL(string: raw) else {
            throw CloudOAuthError.api("未获取到下载地址")
        }
        return url
    }

    static func videoURL(driveID: String, fileID: String, accessToken: String) async throws -> URL? {
        let object = try await post(path: "/adrive/v1.0/openFile/getVideoPreviewPlayInfo",
                                    body: ["drive_id": driveID,
                                           "file_id": fileID,
                                           "category": "live_transcoding",
                                           "url_expire_sec": 900],
                                    accessToken: accessToken)
        let play = object["video_preview_play_info"] as? [String: Any]
        let tasks = play?["live_transcoding_task_list"] as? [[String: Any]] ?? []
        let finished = tasks.filter {
            ($0["status"] as? String) == "finished"
                && (($0["url"] as? String)?.isEmpty == false)
        }
        let best = finished.max { lhs, rhs in
            rank(lhs) < rank(rhs)
        }
        guard let raw = best?["url"] as? String, let url = URL(string: raw) else { return nil }
        return url
    }

    /// 删除文件：官方没有单独的删除端点，走批量接口里的 `/file/delete`。
    /// 注意需要 `file:all` 写入权限；只有读权限的授权会返回 AccessDenied。
    static func delete(driveID: String, fileID: String, accessToken: String) async throws {
        let object = try await post(path: "/adrive/v3/batch", body: [
            "requests": [[
                "id": UUID().uuidString,
                "method": "POST",
                "url": "/file/delete",
                "body": ["drive_id": driveID, "file_id": fileID]
            ]]
        ], accessToken: accessToken)
        let responses = object["responses"] as? [[String: Any]] ?? []
        guard let first = responses.first else {
            throw CloudOAuthError.api("阿里云盘没有返回删除结果")
        }
        let status = (first["status"] as? NSNumber)?.intValue ?? 0
        let body = first["body"] as? [String: Any] ?? [:]
        let code = (body["code"] as? String) ?? ""
        if status >= 400 || !code.isEmpty {
            let message = (body["message"] as? String) ?? code
            if code.lowercased().contains("access") || status == 403 {
                throw CloudOAuthError.api("阿里云盘授权没有写入权限，请在「来源」里重新授权后再删除")
            }
            throw CloudOAuthError.api(message.isEmpty ? "阿里云盘拒绝删除（\(status)）" : message)
        }
    }

    // MARK: 内部

    private static func parseEntry(_ item: [String: Any], driveID: String) -> CloudEntry? {
        guard let fileID = item["file_id"] as? String,
              let name = item["name"] as? String else { return nil }
        let isDirectory = (item["type"] as? String) == "folder"
        let size = (item["size"] as? NSNumber)?.int64Value ?? 0
        let category = item["category"] as? String
        let imageMeta = item["image_media_metadata"] as? [String: Any]
        let videoMeta = item["video_media_metadata"] as? [String: Any]
        let width = (imageMeta?["width"] as? NSNumber)?.intValue
            ?? (videoMeta?["width"] as? NSNumber)?.intValue
        let height = (imageMeta?["height"] as? NSNumber)?.intValue
            ?? (videoMeta?["height"] as? NSNumber)?.intValue
        let duration = (videoMeta?["duration"] as? NSNumber)?.doubleValue

        var entry = CloudEntry(path: "\(driveID)|\(fileID)",
                               name: name,
                               isDirectory: isDirectory,
                               size: size,
                               modifiedAt: parseDate(item["updated_at"] as? String),
                               contentType: category == "video" ? "video/mp4" : nil)
        entry.thumbnailURL = item["thumbnail"] as? String
        entry.remoteID = fileID
        entry.pixelWidth = width
        entry.pixelHeight = height
        entry.duration = duration
        if let streams = videoMeta?["video_media_video_stream"] as? [[String: Any]],
           let codec = streams.first?["code_name"] as? String, !codec.isEmpty {
            entry.codecName = codec.lowercased()
        }
        return entry
    }

    private static func rank(_ task: [String: Any]) -> Int {
        let template = (task["template_id"] as? String)?.uppercased() ?? ""
        if template.contains("FHD") { return 4 }
        if template.contains("HD") { return 3 }
        if template.contains("SD") { return 2 }
        return 1
    }

    private static func requestToken(_ params: [String: String]) async throws -> CloudToken {
        guard let url = URL(string: apiBase + "/oauth/access_token") else {
            throw CloudOAuthError.token("地址无效")
        }
        let attempts: [(String, Data)] = [
            ("application/json", (try? JSONSerialization.data(withJSONObject: params)) ?? Data()),
            ("application/x-www-form-urlencoded", formData(params))
        ]
        var lastMessage = "未知错误"
        for (contentType, body) in attempts {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if let access = object["access_token"] as? String, !access.isEmpty {
                    let expires = (object["expires_in"] as? NSNumber)?.doubleValue
                        ?? (object["expires_in"] as? String).flatMap(Double.init)
                        ?? 7200
                    return CloudToken(accessToken: access,
                                      refreshToken: object["refresh_token"] as? String,
                                      expiresAt: Date().addingTimeInterval(max(300, expires - 60)))
                }
                lastMessage = (object["message"] as? String)
                    ?? (object["error_description"] as? String)
                    ?? (object["code"] as? String)
                    ?? "HTTP \(status)"
            } catch {
                lastMessage = error.localizedDescription
            }
        }
        throw CloudOAuthError.token(lastMessage)
    }

    private static func post(path: String, body: [String: Any], accessToken: String) async throws -> [String: Any] {
        guard let url = URL(string: apiBase + path) else {
            throw CloudOAuthError.api("地址无效")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = (object["message"] as? String)
                ?? (object["code"] as? String)
                ?? "HTTP \(status)"
            throw CloudOAuthError.api(message)
        }
        return object
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func formData(_ params: [String: String]) -> Data {
        let text = params.map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "&")
        return Data(text.utf8)
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let text = raw as? String { return Double(text) }
        return nil
    }

    static let session = HTTPSessionPool.shared.session(.cloud)
}

// MARK: - 百度网盘开放平台

enum BaiduOAuth {
    static var oauthBase: String {
        ProcessInfo.processInfo.environment["LUMA_BAIDU_OAUTH_BASE"]
            ?? "https://openapi.baidu.com"
    }
    static var panBase: String {
        ProcessInfo.processInfo.environment["LUMA_BAIDU_PAN_BASE"]
            ?? "https://pan.baidu.com"
    }
    static let scopes = "basic,netdisk"

    /// client_id 必须是应用的 AppKey（API Key），不是 AppID；
    /// device_id 填 AppID，软件类应用可留空。
    static func authorizeURL(clientID: String, appID: String?,
                             redirectURI: String, state: String) -> URL? {
        var components = URLComponents(string: oauthBase + "/oauth/2.0/authorize")
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes)
        ]
        if let appID, !appID.isEmpty {
            items.append(URLQueryItem(name: "device_id", value: appID))
        }
        items.append(URLQueryItem(name: "state", value: state))
        components?.queryItems = items
        return components?.url
    }

    static func exchange(clientID: String, clientSecret: String,
                         code: String, redirectURI: String) async throws -> CloudToken {
        try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI
        ])
    }

    static func refresh(clientID: String, clientSecret: String,
                        refreshToken: String) async throws -> CloudToken {
        try await requestToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret
        ])
    }

    static func list(dir: String, accessToken: String) async throws -> [CloudEntry] {
        var entries: [CloudEntry] = []
        var start = 0
        let limit = 1000
        while true {
            var components = URLComponents(string: panBase + "/rest/2.0/xpan/file")
            components?.queryItems = [
                URLQueryItem(name: "method", value: "list"),
                URLQueryItem(name: "access_token", value: accessToken),
                URLQueryItem(name: "dir", value: dir),
                URLQueryItem(name: "web", value: "1"),
                URLQueryItem(name: "start", value: "\(start)"),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "order", value: "name")
            ]
            guard let url = components?.url else { throw CloudOAuthError.api("地址无效") }
            let object = try await getJSON(url)
            let errno = (object["errno"] as? NSNumber)?.intValue ?? 0
            guard errno == 0 else {
                let message = (object["errmsg"] as? String) ?? "errno \(errno)"
                if errno == -6 { throw CloudOAuthError.notAuthorized }
                throw CloudOAuthError.api(message)
            }
            let list = object["list"] as? [[String: Any]] ?? []
            entries.append(contentsOf: list.compactMap { parseEntry($0) })
            if list.count < limit { break }
            start += limit
            if start >= 5000 { break }
        }
        return entries
    }

    /// 视频 / 音频流地址：dlink 之外补上 access_token，避免部分账号的直链要求鉴权参数。
    static func streamURL(fsID: String, accessToken: String) async throws -> URL {
        let dlink = try await downloadURL(fsID: fsID, accessToken: accessToken)
        guard var components = URLComponents(url: dlink, resolvingAgainstBaseURL: false) else {
            return dlink
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "access_token" }) {
            items.append(URLQueryItem(name: "access_token", value: accessToken))
            components.queryItems = items
        }
        return components.url ?? dlink
    }

    static func downloadURL(fsID: String, accessToken: String) async throws -> URL {
        var components = URLComponents(string: panBase + "/rest/2.0/xpan/multimedia")
        components?.queryItems = [
            URLQueryItem(name: "method", value: "filemetas"),
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "fsids", value: "[\(fsID)]"),
            URLQueryItem(name: "thumb", value: "1"),
            URLQueryItem(name: "dlink", value: "1"),
            URLQueryItem(name: "extra", value: "1")
        ]
        guard let url = components?.url else { throw CloudOAuthError.api("地址无效") }
        let object = try await getJSON(url)
        let errno = (object["errno"] as? NSNumber)?.intValue ?? 0
        guard errno == 0 else {
            throw CloudOAuthError.api((object["errmsg"] as? String) ?? "errno \(errno)")
        }
        // 百度实际把文件信息放在 `list` 里（部分文档写作 `info`），两种都要兼容，
        // 否则直链永远解析不到，图片只能看到缩略图、视频完全无法播放。
        let items = (object["list"] as? [[String: Any]])
            ?? (object["info"] as? [[String: Any]])
            ?? []
        guard let dlink = items.first?["dlink"] as? String,
              !dlink.isEmpty,
              let result = URL(string: dlink) else {
            let keys = object.keys.sorted().joined(separator: ",")
            let itemErrno = (items.first?["errno"] as? NSNumber)?.intValue ?? 0
            Diagnostics.record("百度直链缺失 fs_id=\(fsID) errno=\(errno) itemErrno=\(itemErrno) "
                               + "errmsg=\(object["errmsg"] ?? "-") keys=\(keys)")
            throw CloudOAuthError.api("未获取到下载地址")
        }
        return result
    }

    /// 删除文件：xpan filemanager 的 `opera=delete`，filelist 传完整路径数组。
    static func delete(paths: [String], accessToken: String) async throws {
        guard !paths.isEmpty else { return }
        var components = URLComponents(string: panBase + "/rest/2.0/xpan/file")
        components?.queryItems = [
            URLQueryItem(name: "method", value: "filemanager"),
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "opera", value: "delete"),
            URLQueryItem(name: "async", value: "0")
        ]
        guard let url = components?.url else { throw CloudOAuthError.api("地址无效") }
        let listData = (try? JSONSerialization.data(withJSONObject: paths)) ?? Data("[]".utf8)
        let listText = String(data: listData, encoding: .utf8) ?? "[]"
        let encoded = listText.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "async=0&filelist=\(encoded)".data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let errno = (object["errno"] as? NSNumber)?.intValue ?? 0
        guard errno == 0 else {
            let message = (object["errmsg"] as? String) ?? "errno \(errno)"
            if errno == -6 { throw CloudOAuthError.notAuthorized }
            throw CloudOAuthError.api(message)
        }
    }

    // MARK: 内部

    private static func parseEntry(_ item: [String: Any]) -> CloudEntry? {
        let fsID: String
        if let value = item["fs_id"] as? Int64 {
            fsID = String(value)
        } else if let value = item["fs_id"] as? Int {
            fsID = String(value)
        } else if let value = item["fs_id"] as? NSNumber {
            fsID = String(value.int64Value)
        } else {
            return nil
        }
        guard let path = item["path"] as? String else { return nil }
        let name = (item["server_filename"] as? String) ?? (path as NSString).lastPathComponent
        let isDirectory = ((item["isdir"] as? NSNumber)?.intValue ?? 0) == 1
        let size = (item["size"] as? NSNumber)?.int64Value ?? 0
        let mtime = (item["server_mtime"] as? NSNumber)?.doubleValue
        let category = (item["category"] as? NSNumber)?.intValue ?? 0

        var entry = CloudEntry(path: path,
                               name: name,
                               isDirectory: isDirectory,
                               size: size,
                               modifiedAt: mtime.map { Date(timeIntervalSince1970: $0) },
                               contentType: category == 1 ? "video/mp4" : nil)
        entry.remoteID = fsID
        if let thumbs = item["thumbs"] as? [String: String] {
            entry.thumbnailURL = thumbs["url3"] ?? thumbs["url2"] ?? thumbs["url1"]
        }
        return entry
    }

    private static func requestToken(_ params: [String: String]) async throws -> CloudToken {
        var components = URLComponents(string: oauthBase + "/oauth/2.0/token")
        components?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw CloudOAuthError.token("地址无效") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            let message = (object["error_description"] as? String)
                ?? (object["error"] as? String)
                ?? "HTTP \(status)"
            throw CloudOAuthError.token(message)
        }
        let expires = doubleValue(object["expires_in"]) ?? 2_592_000
        return CloudToken(accessToken: access,
                          refreshToken: object["refresh_token"] as? String,
                          expiresAt: Date().addingTimeInterval(max(300, expires - 60)))
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let text = raw as? String { return Double(text) }
        return nil
    }

    private static func getJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static let session = HTTPSessionPool.shared.session(.cloud)
}

// MARK: - 统一调度

enum CloudService {
    static func list(mount: CloudMount, containerID: String) async throws -> [CloudEntry] {
        switch mount.kind {
        case .webdav:
            guard let client = webdavClient(mount) else {
                throw CloudOAuthError.api("WebDAV 配置无效")
            }
            return try await client.list(path: containerID)
        case .smb:
            guard let client = smbClient(mount) else {
                throw CloudOAuthError.api("SMB 配置无效")
            }
            return try await client.list(path: containerID)
        case .aliyun:
            let token = try await accessToken(for: mount)
            let parsed = AliyunOAuth.splitPath(containerID, fallbackDrive: mount.remoteDriveID)
            guard let driveID = parsed?.drive ?? mount.remoteDriveID, !driveID.isEmpty else {
                throw CloudOAuthError.api("缺少网盘 ID，请重新授权")
            }
            let parentID = parsed?.fileID ?? "root"
            return try await AliyunOAuth.list(driveID: driveID,
                                              parentID: parentID,
                                              accessToken: token)
        case .baidu:
            let token = try await accessToken(for: mount)
            return try await BaiduOAuth.list(dir: containerID.isEmpty ? "/" : containerID,
                                             accessToken: token)
        case .quark:
            return try await QuarkDrive.list(cookie: try quarkCookie(for: mount),
                                             folderID: containerID,
                                             mountID: mount.id)
        case .pan115:
            return try await Pan115Drive.list(cookie: try pan115Cookie(for: mount),
                                              folderID: containerID)
        }
    }

    /// 仅 SMB 支持递归扫描整个共享；同时返回目录（带 mtime），供下一轮增量扫描复用。
    static func scanTree(mount: CloudMount, path: String) async throws -> SMBTreeScanResult {
        guard mount.kind == .smb else {
            throw CloudOAuthError.unsupportedProvider
        }
        guard let client = smbClient(mount) else {
            throw CloudOAuthError.api("SMB 配置无效")
        }
        return try await client.scanTreeWithFolders(path: path)
    }

    /// 删除单个文件：SMB / WebDAV / 官方网盘各走自己的通道，失败原因原样抛出。
    static func delete(mount: CloudMount, photo: PhotoItem) async throws {
        switch mount.kind {
        case .webdav:
            guard let client = webdavClient(mount),
                  let path = photo.cloudPath, !path.isEmpty else {
                throw CloudOAuthError.api("WebDAV 文件路径无效")
            }
            try await client.delete(path: path)

        case .smb:
            guard let client = smbClient(mount), let path = photo.cloudPath else {
                throw CloudOAuthError.api("SMB 文件路径无效")
            }
            _ = try await client.ensureMounted()
            guard let url = client.fileURL(path: path) else {
                throw CloudOAuthError.api("SMB 共享未挂载，请先在侧边栏连接")
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                let ns = error as NSError
                let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
                let posix = underlying?.domain == NSPOSIXErrorDomain ? Int32(underlying?.code ?? 0) : nil
                // 文件已经不在共享上（下载工具的临时文件被清理、已在别处改名或删除）：
                // 目标状态已经达成，按成功处理，否则索引里会一直留着一个删不掉的条目。
                if ns.code == NSFileNoSuchFileError || posix == ENOENT {
                    Diagnostics.record("SMB 删除跳过（文件已不存在）：\(path)")
                    return
                }
                switch Int(posix ?? 0) {
                case Int(EACCES), Int(EPERM):
                    throw CloudOAuthError.api("SMB 删除失败：账号没有删除权限（删除需要上级目录的写权限）")
                case Int(EBUSY), Int(ETXTBSY):
                    throw CloudOAuthError.api("SMB 删除失败：文件正被下载或播放占用，请稍后再试")
                case Int(EROFS):
                    throw CloudOAuthError.api("SMB 删除失败：共享以只读方式挂载")
                default:
                    throw CloudOAuthError.api("SMB 删除失败：\(error.localizedDescription)")
                }
            }

        case .aliyun:
            let token = try await accessToken(for: mount)
            guard let target = AliyunOAuth.splitPath(photo.cloudPath ?? photo.cloudRemoteID,
                                                     fallbackDrive: mount.remoteDriveID) else {
                throw CloudOAuthError.api("缺少阿里云盘文件 ID")
            }
            try await AliyunOAuth.delete(driveID: target.drive,
                                         fileID: target.fileID,
                                         accessToken: token)

        case .baidu:
            let token = try await accessToken(for: mount)
            guard let path = photo.cloudPath, !path.isEmpty else {
                throw CloudOAuthError.api("缺少百度网盘文件路径")
            }
            try await BaiduOAuth.delete(paths: [path], accessToken: token)

        case .quark:
            guard let fid = photo.cloudPath ?? photo.cloudRemoteID, !fid.isEmpty else {
                throw CloudOAuthError.api("缺少夸克文件 ID")
            }
            try await QuarkDrive.delete(fids: [fid],
                                        cookie: try quarkCookie(for: mount),
                                        mountID: mount.id)

        case .pan115:
            guard let fid = photo.cloudPath, !fid.isEmpty else {
                throw CloudOAuthError.api("缺少 115 文件 ID")
            }
            try await Pan115Drive.delete(fids: [fid], cookie: try pan115Cookie(for: mount))
        }
    }

    static func stream(mount: CloudMount, photo: PhotoItem) async throws -> CloudStreamResource {
        switch mount.kind {
        case .webdav:
            guard let client = webdavClient(mount) else {
                throw CloudOAuthError.api("WebDAV 地址无效")
            }
            let path = photo.cloudPath ?? ""
            // 视频优先用最新目录里的真实 href 定位：挂载点前缀、编码或服务端别名差异都会让拼接地址 404。
            if photo.isVideo {
                if let resolved = (try? await client.resolveFileURL(path: path)) ?? nil {
                    return CloudStreamResource(url: resolved, headers: client.requestHeaders)
                }
                Diagnostics.record("WebDAV 最新目录中未找到 \(path)，回退拼接地址")
            }
            guard let url = client.fileURL(path: path) else {
                throw CloudOAuthError.api("WebDAV 地址无效")
            }
            return CloudStreamResource(url: url, headers: client.requestHeaders)
        case .smb:
            guard let client = smbClient(mount), let path = photo.cloudPath else {
                throw CloudOAuthError.api("SMB 文件路径无效")
            }
            _ = try await client.ensureMounted()
            guard let url = client.fileURL(path: path) else {
                throw CloudOAuthError.api("SMB 挂载点不可用，请检查共享是否已连接")
            }
            return CloudStreamResource(url: url, headers: [:])
        case .aliyun:
            let token = try await accessToken(for: mount)
            guard let target = AliyunOAuth.splitPath(photo.cloudPath ?? photo.cloudRemoteID,
                                                     fallbackDrive: mount.remoteDriveID) else {
                throw CloudOAuthError.api("缺少文件 ID")
            }
            let driveID = target.drive
            let fileID = target.fileID
            // 阿里云盘的下载 / 转码地址只对带官方 Referer 与 UA 的请求放行。
            let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 Luma/1.0",
                           "Referer": "https://www.alipan.com/"]
            // 优先原始文件：CDN 直链支持 Range，MKV 等容器可以边下边播且保留原始画质；
            // 官方转码 m3u8 目前只对部分清晰度返回地址，作为「禁止下载」时的兜底。
            do {
                let url = try await AliyunOAuth.downloadURL(driveID: driveID,
                                                            fileID: fileID,
                                                            accessToken: token)
                return CloudStreamResource(url: url, headers: headers)
            } catch {
                guard photo.isVideo,
                      let hls = try? await AliyunOAuth.videoURL(driveID: driveID,
                                                                fileID: fileID,
                                                                accessToken: token) else {
                    throw error
                }
                return CloudStreamResource(url: hls, headers: headers, isHLS: true)
            }
        case .baidu:
            let token = try await accessToken(for: mount)
            guard let fsID = photo.cloudRemoteID else {
                throw CloudOAuthError.api("缺少文件 ID（fs_id），请刷新该目录后重试")
            }
            let url = try await BaiduOAuth.streamURL(fsID: fsID, accessToken: token)
            return CloudStreamResource(url: url,
                                       headers: ["User-Agent": "pan.baidu.com",
                                                 "Referer": "https://pan.baidu.com/"])
        case .quark:
            guard let fid = photo.cloudPath ?? photo.cloudRemoteID, !fid.isEmpty else {
                throw CloudOAuthError.api("缺少文件 ID（fid），请刷新该目录后重试")
            }
            // 夸克对风险内容会在列表接口就给出 risk_type，转码与直链接口都会直接拒绝，
            // 提前拦截避免用户看到 "invalid file" 这类无法理解的原始报错。
            if photo.cloudRestricted == true {
                throw CloudOAuthError.api(QuarkDrive.restrictedFileMessage)
            }
            let cookie = try quarkCookie(for: mount)
            let headers = QuarkDrive.headers(cookie: cookie)
            if photo.isVideo {
                do {
                    if let playURL = try await QuarkDrive.videoPlayURL(fid: fid,
                                                                       cookie: cookie,
                                                                       mountID: mount.id) {
                        // 转码地址是签名 CDN 链接，直接交给 AVPlayer。
                        return CloudStreamResource(url: playURL, headers: headers)
                    }
                } catch {
                    Diagnostics.record("Quark 转码播放地址获取失败 fid=\(fid)：\(error.localizedDescription)")
                }
            }
            let url = try await QuarkDrive.downloadURL(fid: fid, cookie: cookie, mountID: mount.id)
            return CloudStreamResource(url: url, headers: headers)
        case .pan115:
            guard let pickCode = photo.cloudRemoteID, !pickCode.isEmpty else {
                throw CloudOAuthError.api("缺少文件标识（pickcode），请刷新该目录后重试")
            }
            let cookie = try pan115Cookie(for: mount)
            let primaryURL = try await Pan115Drive.downloadURL(pickCode: pickCode, cookie: cookie)
            let primaryHeaders = Pan115Drive.downloadHeaders(cookie: cookie)
            guard photo.isVideo else {
                return CloudStreamResource(url: primaryURL, headers: primaryHeaders)
            }
            Diagnostics.record("115 直链 host=\(primaryURL.host ?? "-") "
                               + "ua=\(primaryHeaders["User-Agent"] ?? "-") cookie=\(cookie.count)字符")
            if await Pan115Drive.isReachable(url: primaryURL, headers: primaryHeaders) {
                return CloudStreamResource(url: primaryURL, headers: primaryHeaders)
            }
            // 115 网页端用浏览器 UA 播放；客户端 UA 被 CDN 拒绝时再申请一次并换头。
            let browserUA = Pan115Drive.browserUserAgent
            Diagnostics.record("115 直链被 CDN 拒绝，改用浏览器 UA 重试 host=\(primaryURL.host ?? "-")")
            if let alternateURL = try? await Pan115Drive.downloadURL(pickCode: pickCode,
                                                                     cookie: cookie,
                                                                     userAgent: browserUA) {
                let alternateHeaders = Pan115Drive.downloadHeaders(cookie: cookie, userAgent: browserUA)
                if await Pan115Drive.isReachable(url: alternateURL, headers: alternateHeaders) {
                    return CloudStreamResource(url: alternateURL, headers: alternateHeaders)
                }
            }
            Diagnostics.record("115 直链两种 UA 均无法读取 host=\(primaryURL.host ?? "-")")
            return CloudStreamResource(url: primaryURL, headers: primaryHeaders)
        }
    }

    /// 夸克网盘用浏览器 Cookie 鉴权：缺失时直接提示重新登录，而不是发一次空请求。
    static func quarkCookie(for mount: CloudMount) throws -> String {
        let cookie = QuarkDrive.normalizedCookie(CloudCredentials.password(for: mount.id))
        guard !cookie.isEmpty else { throw CloudOAuthError.notAuthorized }
        return cookie
    }

    /// 115 同样用浏览器 Cookie 鉴权。
    static func pan115Cookie(for mount: CloudMount) throws -> String {
        let cookie = Pan115Drive.normalizedCookie(CloudCredentials.password(for: mount.id))
        guard !cookie.isEmpty else { throw CloudOAuthError.notAuthorized }
        return cookie
    }

    static func accessToken(for mount: CloudMount) async throws -> String {
        // 阿里云盘的 Cookie 模式：用 refresh_token 换开放平台令牌，不走自建应用。
        if mount.kind == .aliyun, mount.authMode == .cookie {
            return try await aliyunCookieToken(for: mount).accessToken
        }
        guard mount.kind.usesOAuth else { throw CloudOAuthError.unsupportedProvider }
        let stored: CloudToken
        switch CloudOAuthStore.tokenResult(mountID: mount.id) {
        case .token(let value):
            stored = value
        case .missing:
            throw CloudOAuthError.notAuthorized
        case .denied(let status):
            throw CloudOAuthError.keychainDenied(status)
        }
        if stored.expiresAt > Date().addingTimeInterval(60) {
            return stored.accessToken
        }
        guard let refresh = stored.refreshToken else {
            throw CloudOAuthError.notAuthorized
        }
        let credentials: CloudClientCredentials
        switch CloudOAuthStore.credentialsResult(for: mount.kind) {
        case .credentials(let value):
            credentials = value
        case .missing:
            throw CloudOAuthError.notAuthorized
        case .denied(let status):
            throw CloudOAuthError.keychainDenied(status)
        }
        let updated: CloudToken
        switch mount.kind {
        case .aliyun:
            updated = try await AliyunOAuth.refresh(clientID: credentials.clientID,
                                                    clientSecret: credentials.clientSecret,
                                                    refreshToken: refresh)
        case .baidu:
            updated = try await BaiduOAuth.refresh(clientID: credentials.clientID,
                                                   clientSecret: credentials.clientSecret,
                                                   refreshToken: refresh)
        case .webdav, .smb, .quark, .pan115:
            throw CloudOAuthError.unsupportedProvider
        }
        var merged = updated
        if merged.refreshToken == nil { merged.refreshToken = refresh }
        merged.accountName = stored.accountName
        merged.driveID = stored.driveID
        CloudOAuthStore.saveToken(merged, mountID: mount.id)
        return merged.accessToken
    }

    /// Cookie 模式：令牌过期后用钥匙串里的 refresh_token 重新换取，并保存轮换后的令牌。
    static func aliyunCookieToken(for mount: CloudMount) async throws -> CloudToken {
        if case .token(let stored) = CloudOAuthStore.tokenResult(mountID: mount.id),
           stored.expiresAt > Date().addingTimeInterval(60) {
            return stored
        }
        let raw = CloudCredentials.password(for: mount.id)
        guard !raw.isEmpty else { throw CloudOAuthError.notAuthorized }
        var token = try await AliyunCookieAuth.token(from: raw)
        if let refresh = token.refreshToken, !refresh.isEmpty {
            // refresh_token 会轮换：写回钥匙串，下次过期仍能换取。
            CloudCredentials.setPassword(refresh, for: mount.id)
        }
        token.driveID = mount.remoteDriveID
        CloudOAuthStore.saveToken(token, mountID: mount.id)
        return token
    }

    static func webdavClient(_ mount: CloudMount) -> WebDAVClient? {
        WebDAVClient(baseURLString: mount.baseURL,
                     username: mount.username,
                     password: CloudCredentials.password(for: mount.id),
                     allowsSelfSignedCertificate: mount.trustSelfSigned)
    }

    static func smbClient(_ mount: CloudMount) -> SMBClient? {
        SMBClient(mount: mount, password: CloudCredentials.password(for: mount.id))
    }
}

// MARK: - 向导阶段的目录浏览

/// 挂载还没创建时，按当前接入方式直接读网盘目录，供向导里选择接入范围。
/// `cookie` 对 Cookie 模式是浏览器 Cookie，对百度是 OAuth access_token。
enum CloudSetupBrowser {
    static func folders(flow: CloudWizardFlow, cookie: String, containerID: String) async throws -> [CloudEntry] {
        switch flow {
        case .quark:
            return try await QuarkDrive.list(cookie: QuarkDrive.normalizedCookie(cookie),
                                             folderID: containerID)
        case .pan115:
            return try await Pan115Drive.list(cookie: Pan115Drive.normalizedCookie(cookie),
                                              folderID: containerID)
        case .baidu:
            return try await BaiduOAuth.list(dir: containerID.isEmpty ? "/" : containerID,
                                             accessToken: cookie)
        case .aliyunCookie:
            let token = try await AliyunCookieAuth.token(from: cookie)
            if containerID.isEmpty {
                // 阿里云盘一个账号最多三个盘：先当作虚拟根目录列出。
                return try await AliyunOAuth.drives(accessToken: token.accessToken).map {
                    CloudEntry(path: "\($0.id)|root",
                               name: $0.label,
                               isDirectory: true,
                               size: 0,
                               modifiedAt: nil,
                               contentType: nil)
                }
            }
            guard let target = AliyunOAuth.splitPath(containerID, fallbackDrive: nil) else {
                throw CloudOAuthError.api("阿里云盘目录无效，请返回根目录重新进入")
            }
            return try await AliyunOAuth.list(driveID: target.drive,
                                              parentID: target.fileID,
                                              accessToken: token.accessToken)
        case .smb, .webdav, .alist:
            throw CloudOAuthError.unsupportedProvider
        }
    }
}

// MARK: - 服务端缩略图下载

enum CloudImageFetcher {
    /// 服务端缩略图同样限流：否则滚动时会同时打出几十个 CDN 请求。
    private static let gate = CloudConcurrencyGate(limit: 4)

    static func thumbnail(for photo: PhotoItem, urlString: String,
                          headers: [String: String] = [:]) async -> NSImage? {
        guard let mountID = photo.cloudMountID, let path = photo.cloudPath,
              let url = URL(string: urlString) else { return nil }
        let cacheURL = CloudPaths.thumbnailURL(mountID: mountID, path: path)
        if let image = NSImage(contentsOf: cacheURL) { return image }

        let key = cacheURL.path
        // 刚失败过的项目 60 秒内不再重复请求。
        if await CloudThumbnailFailureCache.shared.isFailing(key) { return nil }

        await gate.acquire()
        let image = await downloadThumbnail(url: url, headers: headers, cacheURL: cacheURL,
                                            mountID: mountID, path: path)
        await gate.release()

        if image == nil {
            await CloudThumbnailFailureCache.shared.markFailure(key)
        } else {
            await CloudThumbnailFailureCache.shared.clear(key)
        }
        return image
    }

    private static func downloadThumbnail(url: URL, headers: [String: String],
                                          cacheURL: URL, mountID: UUID, path: String) async -> NSImage? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            logThumbnailFailure(url: url, status: status)
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        ImportService.writeJPEG(cgImage, to: cacheURL, quality: 0.9)
        // 顺手产出快速层：网格滚动时先出 192px 小图，不必等 900px 解码。
        if let quick = ImageTransform.downscale(cgImage, maxPixel: ImageLoader.gridQuickPixel) {
            ImportService.writeJPEG(quick,
                                    to: CloudPaths.quickThumbnailURL(mountID: mountID, path: path),
                                    quality: 0.75)
        }
        return NSImage(contentsOf: cacheURL)
    }

    /// 每次启动只记录一次缩略图失败，避免刷屏；包含域名与状态码，便于判断是鉴权还是 CDN 问题。
    private static let thumbnailFailureLock = NSLock()
    private static var loggedThumbnailFailure = false

    private static func logThumbnailFailure(url: URL, status: Int) {
        thumbnailFailureLock.lock()
        defer { thumbnailFailureLock.unlock() }
        guard !loggedThumbnailFailure else { return }
        loggedThumbnailFailure = true
        Diagnostics.record("缩略图下载失败 host=\(url.host ?? "-") status=\(status)")
    }

    static func fullImage(photo: PhotoItem, resource: CloudStreamResource) async -> NSImage? {
        var request = URLRequest(url: resource.url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 90)
        for (key, value) in resource.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let (data, response) = try? await session.data(for: request) else {
            Diagnostics.record("云端原图请求失败 \(photo.originalName) host=\(resource.url.host ?? "-")")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            let head = String(decoding: data.prefix(120), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            Diagnostics.record("云端原图解码失败 \(photo.originalName) host=\(resource.url.host ?? "-") "
                               + "status=\(status) bytes=\(data.count) head=\(head)")
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 6000,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            Diagnostics.record("云端原图缩略解码失败 \(photo.originalName) bytes=\(data.count)")
            return nil
        }
        // 直链若被服务端换成缩略图，尺寸会明显偏小：记录下来便于定位。
        if max(cgImage.width, cgImage.height) < 1600 {
            Diagnostics.record("云端原图偏小 \(photo.originalName)：\(cgImage.width)x\(cgImage.height) "
                               + "bytes=\(data.count) status=\(status)")
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static let session = HTTPSessionPool.shared.session(.artwork)
}
