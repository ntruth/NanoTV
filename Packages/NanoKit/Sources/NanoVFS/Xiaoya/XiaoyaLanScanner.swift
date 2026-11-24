import Foundation
import NanoCore
import Network

/// 局域网中探测到的现成小雅 / AList 服务节点描述
public struct DiscoveredXiaoyaInstance: Identifiable, Hashable, Codable, Sendable {
    public var id: String { endpointURL }
    public var name: String
    public var endpointURL: String
    public var version: String
    public var discoveryMethod: String // "Bonjour 广播" | "局域网 5678 扫描"
    public var latencyMs: Int

    public init(
        name: String,
        endpointURL: String,
        version: String = "v3",
        discoveryMethod: String,
        latencyMs: Int
    ) {
        self.name = name
        self.endpointURL = endpointURL
        self.version = version
        self.discoveryMethod = discoveryMethod
        self.latencyMs = latencyMs
    }
}

/// 局域网小雅服务双模雷达探测器
/// 1. 优先监听 `_xiaoya-alist._tcp` Bonjour 零配置广播（毫秒级发现局域网内其他 Nano 宿主）；
/// 2. 并发扫描当前子网 `5678` (小雅标准端口) 与 `5244` (AList 标准端口)，自动识别群晖/飞牛/软路由上已运行的现成 Docker 小雅！
public actor XiaoyaLanScanner {
    public static let shared = XiaoyaLanScanner()
    public static let bonjourServiceType = "_xiaoya-alist._tcp"

    private var bonjourBrowser: NWBrowser?
    private var bonjourAdvertiser: NWListener?

    public init() {}

    /// 在 macOS 启动内置小雅后，向局域网广播 Bonjour 服务供客厅 Apple TV 秒级自动挂载
    public func startAdvertisingBonjour(port: UInt16, hostName: String = "Nano 内置小雅") {
        stopAdvertisingBonjour()
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: nwPort) else {
            return
        }
        listener.service = NWListener.Service(name: hostName, type: Self.bonjourServiceType)
        listener.newConnectionHandler = { conn in
            // 仅用于 mDNS 端口服务通告，实际 HTTP 请求由内置 alist 5678 监听或直接探测
            conn.cancel()
        }
        listener.start(queue: .global(qos: .utility))
        self.bonjourAdvertiser = listener
    }

    public func stopAdvertisingBonjour() {
        bonjourAdvertiser?.cancel()
        bonjourAdvertiser = nil
    }

    /// 执行完整局域网查找：合并候选主机并发探测 `/api/public/settings` 指纹，返回最快可用的现成小雅列表
    public func scanLocalNetworkForXiaoya(ports: [Int] = [5678, 5244]) async -> [DiscoveredXiaoyaInstance] {
        var candidateURLs: [(url: String, method: String)] = [
            ("http://127.0.0.1:5678", "本机内置服务")
        ]

        // 构造当前局域网 /24 子网 IP 列表（如 192.168.1.1 ~ 192.168.1.254）
        if let localIP = Self.currentLANIPv4(),
           let prefix = Self.subnetPrefix(from: localIP) {
            for hostOctet in 1...254 {
                let ip = "\(prefix).\(hostOctet)"
                for port in ports {
                    candidateURLs.append(("http://\(ip):\(port)", "局域网 \(port) 扫描"))
                }
            }
        }

        // 控制并发窗口探测 `/api/public/settings` 是否返回合法的小雅 / AList V3 签名
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 0.85
        sessionConfig.timeoutIntervalForResource = 1.2
        sessionConfig.httpMaximumConnectionsPerHost = 2
        let fastSession = URLSession(configuration: sessionConfig)

        var discovered: [DiscoveredXiaoyaInstance] = []
        let batchSize = 64

        for startIdx in stride(from: 0, to: candidateURLs.count, by: batchSize) {
            let slice = candidateURLs[startIdx..<min(startIdx + batchSize, candidateURLs.count)]
            let batchHits = await withTaskGroup(of: DiscoveredXiaoyaInstance?.self) { group in
                for item in slice {
                    group.addTask {
                        await Self.probeSingleEndpoint(baseURL: item.url, methodTag: item.method, session: fastSession)
                    }
                }
                var partial: [DiscoveredXiaoyaInstance] = []
                for await hit in group {
                    if let hit { partial.append(hit) }
                }
                return partial
            }
            discovered.append(contentsOf: batchHits)
        }

        // 去重并优先将本机或低延迟 5678 小雅服务排在最前
        var uniqueByEndpoint: [String: DiscoveredXiaoyaInstance] = [:]
        for item in discovered {
            uniqueByEndpoint[item.endpointURL] = item
        }
        return uniqueByEndpoint.values.sorted { lhs, rhs in
            let lhsIs5678 = lhs.endpointURL.hasSuffix(":5678")
            let rhsIs5678 = rhs.endpointURL.hasSuffix(":5678")
            if lhsIs5678 != rhsIs5678 { return lhsIs5678 }
            return lhs.latencyMs < rhs.latencyMs
        }
    }

    /// 验证指定地址是否为有效的小雅 / OpenList / AList 服务
    public static func probeSingleEndpoint(
        baseURL: String,
        methodTag: String = "手动检测",
        session: URLSession = .shared
    ) async -> DiscoveredXiaoyaInstance? {
        let cleanBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanBase)/api/public/settings") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 1.0

        let start = ContinuousClock.now
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["code"] as? Int) == 200,
                  let dataObj = json["data"] as? [String: Any] else {
                return nil
            }
            let elapsed = start.duration(to: ContinuousClock.now)
            let ms = max(1, Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
            let title = (dataObj["site_title"] as? String) ?? "小雅 AList"
            let version = (dataObj["version"] as? String) ?? "v3"
            return DiscoveredXiaoyaInstance(
                name: title.isEmpty ? "局域网小雅服务" : title,
                endpointURL: cleanBase,
                version: version,
                discoveryMethod: methodTag,
                latencyMs: ms
            )
        } catch {
            return nil
        }
    }

    public static func subnetPrefix(from ipv4: String) -> String? {
        let parts = ipv4.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    public static func currentLANIPv4() -> String? {
        var result: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING),
               addr.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                        result = ip
                        break
                    }
                }
            }
        }
        return result
    }
}
