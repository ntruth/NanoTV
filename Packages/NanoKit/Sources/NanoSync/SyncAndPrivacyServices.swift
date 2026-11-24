import Foundation
import NanoCore
import Network
import Observation
import Security
#if os(macOS)
import LocalAuthentication
#endif

// MARK: - 1. iCloud Keychain 跨端凭证保险箱（Mac 扫码一次，Apple TV 免输密码自动登录）

public struct iCloudKeychainVault: Sendable {
    public static let shared = iCloudKeychainVault()
    private let serviceName = "app.nano.media.credentials"

    public init() {}

    public func saveSecret(_ secret: String, forKey accountKey: String, syncOverICloud: Bool = true) {
        let data = Data(secret.utf8)
        deleteSecret(forKey: accountKey)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountKey,
            kSecValueData as String: data
        ]
        if syncOverICloud {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        SecItemAdd(query as CFDictionary, nil)
    }

    public func readSecret(forKey accountKey: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountKey,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deleteSecret(forKey accountKey: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountKey,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 2. WebDAV 全量配置与播放进度快照同步服务

public struct WebDAVBackupSyncService: Sendable {
    public var endpointURL: String
    public var username: String
    public var password: String

    public init(endpointURL: String, username: String, password: String) {
        self.endpointURL = endpointURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.username = username
        self.password = password
    }

    private var basicAuthHeader: String {
        "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
    }

    public func uploadSnapshotToWebDAV() async throws {
        let snapshotData = try await NanoDatabaseStore.shared.exportDatabaseSnapshot()
        guard let targetURL = URL(string: "\(endpointURL)/nano_backup_v1.sqlite") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: targetURL)
        req.httpMethod = "PUT"
        req.setValue(basicAuthHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.upload(for: req, from: snapshotData)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    public func downloadAndRestoreFromWebDAV() async throws {
        guard let targetURL = URL(string: "\(endpointURL)/nano_backup_v1.sqlite") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: targetURL)
        req.httpMethod = "GET"
        req.setValue(basicAuthHeader, forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.cannotOpenFile)
        }
        try await NanoDatabaseStore.shared.restoreDatabaseSnapshot(data)
    }
}

// MARK: - 3. Apple TV / macOS 局域网扫码网页快传服务（解决遥控器输入长链接与网盘 Cookie 痛点）

public struct LanDroppedPayload: Sendable {
    public let category: String // "iptv" | "xiaoya" | "fongmi" | "cookie_115" | "cookie_quark" | "cookie_baidu"
    public let name: String
    public let value: String
}

public actor TVLanQuickDropServer {
    public static let shared = TVLanQuickDropServer()

    private var listener: NWListener?
    private(set) public var serverURLString: String = ""
    public var onReceivePayload: (@Sendable (LanDroppedPayload) -> Void)?

    public init() {}

    public func startServer(port: UInt16 = 8899, handler: @escaping @Sendable (LanDroppedPayload) -> Void) throws -> String {
        self.onReceivePayload = handler
        if listener != nil, !serverURLString.isEmpty {
            return serverURLString
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let nwListener = try NWListener(using: params, on: nwPort)

        nwListener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { await self.handleHTTP(conn) }
        }
        nwListener.start(queue: .global(qos: .utility))
        self.listener = nwListener

        let ip = Self.detectLocalIPv4Address() ?? "127.0.0.1"
        let urlStr = "http://\(ip):\(port)"
        self.serverURLString = urlStr
        return urlStr
    }

    public func stopServer() {
        listener?.cancel()
        listener = nil
        serverURLString = ""
    }

    private func handleHTTP(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let rawReq = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task {
                await self.routeRequest(rawReq, over: connection)
            }
        }
    }

    private func routeRequest(_ rawReq: String, over connection: NWConnection) {
        if rawReq.hasPrefix("POST /submit") {
            let bodyPart = rawReq.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            if let bodyData = bodyPart.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String],
               let category = json["category"],
               let value = json["value"], !value.isEmpty {
                let name = json["name"] ?? "局域网快传源"
                onReceivePayload?(LanDroppedPayload(category: category, name: name, value: value))
            }
            let okResp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"ok\":true}"
            connection.send(content: okResp.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
        } else {
            let html = Self.portalHTMLPage
            let bodyBytes = Data(html.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n"
            var full = Data(header.utf8)
            full.append(bodyBytes)
            connection.send(content: full, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func detectLocalIPv4Address() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
            for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
                let flags = Int32(ptr.pointee.ifa_flags)
                let addr = ptr.pointee.ifa_addr.pointee
                if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING),
                   addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let candidate = String(cString: hostname)
                        if candidate.hasPrefix("192.") || candidate.hasPrefix("10.") || candidate.hasPrefix("172.") {
                            address = candidate
                            break
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    private static let portalHTMLPage = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Nano 局域网快传助手</title>
    <style>
      body { background:#0B0F17; color:#F3F4F6; font-family:-apple-system,BlinkMacSystemFont,sans-serif; padding:24px; max-width:520px; margin:0 auto; }
      .card { background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:16px; padding:20px; }
      h2 { margin-top:0; color:#F5B041; }
      label { display:block; margin:12px 0 6px; font-size:14px; color:#9CA3AF; }
      select, input, textarea { width:100%; box-sizing:border-box; background:#141C2B; border:1px solid rgba(255,255,255,0.14); color:#fff; border-radius:10px; padding:10px; font-size:15px; }
      button { margin-top:18px; width:100%; background:#2F7CF6; color:#fff; border:none; border-radius:10px; padding:12px; font-size:16px; font-weight:600; cursor:pointer; }
    </style>
    </head>
    <body>
      <div class="card">
        <h2>Nano · Apple TV 扫码快传</h2>
        <label>推送类型</label>
        <select id="cat">
          <option value="iptv">IPTV 直播源 (M3U / TXT 链接)</option>
          <option value="xiaoya">小雅 / OpenList 服务地址</option>
          <option value="fongmi">FongMi / TVBox / CMS JSON 订阅</option>
          <option value="cookie_115">115 网盘 Cookie / Token</option>
          <option value="cookie_quark">夸克网盘 Cookie</option>
          <option value="cookie_baidu">百度网盘 Token / Cookie</option>
        </select>
        <label>源名称备注</label>
        <input id="name" placeholder="例如：我的家庭 IPTV / 夸克SVIP" />
        <label>链接地址 / JSON / Cookie 内容</label>
        <textarea id="val" rows="5" placeholder="在此粘贴长链接或 Cookie..."></textarea>
        <button onclick="send()">一键推送到 Nano</button>
        <p id="msg" style="color:#2ECC71;text-align:center;"></p>
      </div>
      <script>
        async function send() {
          const payload = { category: document.getElementById('cat').value, name: document.getElementById('name').value, value: document.getElementById('val').value };
          const r = await fetch('/submit', { method:'POST', body: JSON.stringify(payload) });
          if (r.ok) { document.getElementById('msg').innerText = '推送成功！电视端已实时生效'; document.getElementById('val').value = ''; }
        }
      </script>
    </body>
    </html>
    """
}

// MARK: - 4. 隐私保险箱守卫（macOS Touch ID + Apple TV 遥控器 PIN 码双端保护，默认彻底隐藏私密源）

@Observable
public final class PrivacyVaultGuard: @unchecked Sendable {
    public static let shared = PrivacyVaultGuard()

    public private(set) var isUnlocked: Bool = false
    private let pinKeychainKey = "nano_privacy_vault_pin"

    public init() {}

    public func lockImmediately() {
        isUnlocked = false
    }

    public func verifyPIN(_ inputPIN: String) -> Bool {
        let savedPIN = iCloudKeychainVault.shared.readSecret(forKey: pinKeychainKey) ?? "8888"
        if inputPIN == savedPIN {
            isUnlocked = true
            return true
        }
        return false
    }

    public func updatePIN(_ newPIN: String) {
        iCloudKeychainVault.shared.saveSecret(newPIN, forKey: pinKeychainKey, syncOverICloud: true)
    }

    /// macOS 端支持调用 Touch ID / Apple Watch 解锁隐私资源空间
    public func unlockWithBiometricsIfAvailable() async -> Bool {
        #if os(macOS)
        let context = LAContext()
        var authError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            do {
                let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁 Nano 隐私媒体空间")
                if success {
                    await MainActor.run { self.isUnlocked = true }
                }
                return success
            } catch {
                return false
            }
        }
        #endif
        return false
    }
}
