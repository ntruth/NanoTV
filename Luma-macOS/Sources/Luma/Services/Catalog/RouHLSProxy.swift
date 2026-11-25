import Foundation
import Compression
import Darwin

/// rou.video 的 HLS 是以 PNG 为外壳下发的：播放列表和每个分片都会先包成图片，
/// 客户端按 PNG chunk 取出 `roUd` 载荷（可能还是 deflate 压缩的）再还原。
/// AVPlayer 不会做这层解包，所以这里起一个 127.0.0.1 回环代理：
/// 对播放器暴露普通 m3u8，内部转发时把 PNG 壳剥掉。
final class RouHLSProxy {
    static let shared = RouHLSProxy()

    private let lock = NSLock()
    private var server: RouHLSProxyServer?

    private init() {}

    /// 把站点给出的播放地址换成本机代理地址。
    func url(for upstream: URL, source: CatalogSource) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        if server == nil {
            server = RouHLSProxyServer(headers: [
                "User-Agent": source.userAgent,
                "Referer": source.referer,
                "Accept": "*/*"
            ])
            _ = try? server?.start()
        }
        guard let server, server.port > 0 else {
            throw CatalogError.parse("本地播放代理启动失败")
        }
        let encoded = RouHLSProxyServer.encodeBase64(upstream.absoluteString)
        guard let local = URL(string: "http://127.0.0.1:\(server.port)/p/\(encoded).m3u8") else {
            throw CatalogError.parse("本地播放地址无效")
        }
        return local
    }
}

// MARK: - PNG 载荷

enum RouPNGCodec {
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    /// 站点自定义的 chunk 类型："roUd"。
    private static let marker: UInt32 = 1_919_898_980
    private static let deflatedFlag: UInt8 = 1

    /// 取出 PNG 里包裹的载荷；不是 PNG 时返回 nil。
    static func payload(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 16, Array(bytes.prefix(8)) == signature else { return nil }
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = Int(rawValue(bytes, at: offset))
            let type = rawValue(bytes, at: offset + 4)
            let start = offset + 8
            guard length > 0, start + length <= bytes.count else { return nil }
            if type == marker {
                let flag = bytes[start]
                let body = Data(bytes[(start + 1)..<(start + length)])
                return flag & deflatedFlag != 0 ? inflate(body) : body
            }
            offset = start + length + 4
        }
        return nil
    }

    private static func rawValue(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (UInt32(bytes[index]) << 24) | (UInt32(bytes[index + 1]) << 16)
            | (UInt32(bytes[index + 2]) << 8) | UInt32(bytes[index + 3])
    }

    /// 浏览器侧用的是 `DecompressionStream("deflate")`，即 zlib 包装的 deflate；
    /// 而 macOS 的 `COMPRESSION_ZLIB` 只吃裸 deflate，需要先去掉 2 字节头与 4 字节校验。
    private static func inflate(_ data: Data) -> Data? {
        var raw = data
        if raw.count > 6, raw.first == 0x78 {
            raw = Data(raw.dropFirst(2).dropLast(4))
        }
        var capacity = max(64 * 1024, raw.count * 8)
        for _ in 0..<10 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination -> Int in
                guard let outputBase = destination.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return raw.withUnsafeBytes { source -> Int in
                    guard let inputBase = source.bindMemory(to: UInt8.self).baseAddress
                    else { return 0 }
                    return compression_decode_buffer(outputBase, capacity,
                                                     inputBase, raw.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 {
                // 输出缓冲区刚好写满时，`compression_decode_buffer` 会直接返回缓冲区大小，
                // 而不是报错：播放列表一旦超过 64 KB 就会被静默截断（尾部丢 ENDLIST，
                // AVPlayer 当直播处理，时长变 0、进度条无法拖动）。必须扩容重解。
                if written < capacity { return output.prefix(written) }
                capacity *= 2
                continue
            }
            capacity *= 2
        }
        return nil
    }
}

// MARK: - 回环服务

private final class RouHLSProxyServer {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private var headers: [String: String]
    /// 分片会被反复请求（拖动进度），留一份内存缓存，按总量淘汰。
    private var cache: [String: Data] = [:]
    private var cachedBytes = 0
    private let cacheLimit = 96 * 1024 * 1024

    init(headers: [String: String]) {
        self.headers = headers
    }

    // MARK: 生命周期

    func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CatalogError.parse("本地代理无法创建套接字") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, listen(fd, 24) == 0 else {
            close(fd)
            throw CatalogError.parse("本地代理无法监听端口")
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: actual.sin_port)
        lock.lock()
        listenFD = fd
        lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        return port
    }

    // MARK: 接收

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            lock.unlock()
            guard fd >= 0 else { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            // 拉流是同步等待网络，单独开线程，避免堵住 accept。
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(client, raw.baseAddress, raw.count)
            }
            guard count > 0 else { return }
            request.append(buffer, count: count)
            if request.count > 128 * 1024 { return }
        }
        let head = String(decoding: request, as: UTF8.self)
        let response = respond(to: head)
        response.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(client, raw.baseAddress!.advanced(by: offset),
                                        raw.count - offset)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }

    // MARK: 路由

    private func respond(to head: String) -> Data {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return Self.build(status: "400 Bad Request", body: Data()) }
        let target = String(parts[1])

        if target.hasPrefix("/p/") {
            return playlist(target)
        }
        if target.hasPrefix("/s?") || target.hasPrefix("/s/") {
            return segment(target)
        }
        return Self.build(status: "404 Not Found", body: Data())
    }

    private func playlist(_ target: String) -> Data {
        var name = target
        if let query = name.firstIndex(of: "?") { name = String(name[..<query]) }
        name = String(name.dropFirst(3))
        if name.hasSuffix(".m3u8") { name.removeLast(5) }
        guard let upstreamText = Self.decodeBase64(name),
              let upstream = URL(string: upstreamText),
              let (data, finalURL) = fetch(upstream) else {
            return Self.build(status: "502 Bad Gateway", body: Data())
        }
        let raw = RouPNGCodec.payload(from: data) ?? data
        let text = String(decoding: raw, as: UTF8.self)
        let rewritten = Self.rewrite(text, base: finalURL)
        return Self.build(status: "200 OK", body: Data(rewritten.utf8),
                          contentType: "application/vnd.apple.mpegurl", noCache: true)
    }

    private func segment(_ target: String) -> Data {
        guard let components = URLComponents(string: "http://local" + target),
              let encoded = components.queryItems?.first(where: { $0.name == "u" })?.value,
              let upstreamText = Self.decodeBase64(encoded),
              let upstream = URL(string: upstreamText) else {
            return Self.build(status: "400 Bad Request", body: Data())
        }
        if let cached = cachedSegment(upstreamText) {
            return Self.build(status: "200 OK", body: cached,
                              contentType: Self.contentType(for: cached))
        }
        guard let (data, _) = fetch(upstream) else {
            return Self.build(status: "502 Bad Gateway", body: Data())
        }
        let decoded = RouPNGCodec.payload(from: data) ?? data
        storeSegment(decoded, key: upstreamText)
        return Self.build(status: "200 OK", body: decoded,
                          contentType: Self.contentType(for: decoded))
    }

    // MARK: 上游请求

    private func fetch(_ url: URL) -> (Data, URL)? {
        lock.lock()
        let headers = headers
        lock.unlock()

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, URL)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data,
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                result = (data, http.url ?? url)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 40)
        return result
    }

    // MARK: 播放列表重写

    private static func rewrite(_ text: String, base: URL) -> String {
        var output: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                output.append(line)
                continue
            }
            guard let absolute = URL(string: trimmed, relativeTo: base)?.absoluteURL else {
                output.append(line)
                continue
            }
            output.append("/s?u=" + encodeBase64(absolute.absoluteString))
        }
        return output.joined(separator: "\n")
    }

    private static func contentType(for data: Data) -> String {
        if data.starts(with: Data("#EXTM3U".utf8)) {
            return "application/vnd.apple.mpegurl"
        }
        if data.first == 0x47 {
            return "video/mp2t"
        }
        if data.count > 12, data.subdata(in: 4..<8) == Data("ftyp".utf8) {
            return "video/mp4"
        }
        return "application/octet-stream"
    }

    private static func build(status: String, body: Data,
                              contentType: String = "text/plain",
                              noCache: Bool = false) -> Data {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Connection: close\r\n"
        if noCache { header += "Cache-Control: no-cache, no-store\r\n" }
        header += "\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        return packet
    }

    // MARK: 缓存

    private func cachedSegment(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    private func storeSegment(_ data: Data, key: String) {
        guard data.count < 8 * 1024 * 1024 else { return }
        lock.lock()
        defer { lock.unlock() }
        if let old = cache[key] { cachedBytes -= old.count }
        cache[key] = data
        cachedBytes += data.count
        while cachedBytes > cacheLimit, let first = cache.keys.first {
            if let removed = cache.removeValue(forKey: first) {
                cachedBytes -= removed.count
            }
        }
    }

    // MARK: Base64

    static func encodeBase64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64(_ text: String) -> String? {
        var value = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
