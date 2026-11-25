import Foundation
import Darwin

/// 把网盘远端文件代理成本机可 Range 读取的 HTTP 源。
///
/// 之前的做法是用 URLSession 顺序拉流灌进 ffmpeg stdin，整部片子只能从头读；
/// 这里改成本机回环 HTTP 服务：ffmpeg 需要哪个字节区间就取哪个区间，
/// 顺带把下过的 8MB 分块留在本地缓存里，回退 / 重读不必再走网络。
/// 请求头、302 跟随、自签名证书策略仍由 App 的 URLSession 统一处理。
final class RemoteRangeSource {
    private enum UpstreamMode {
        /// 上游支持 Range，并给出文件总长度。
        case ranged(Int64)
        /// 上游忽略 Range（或长度未知）：只能从头顺序转发。
        case sequential
    }

    private var upstream: URL
    private var headers: [String: String]
    private let trustSelfSigned: Bool
    private let cacheDirectory: URL
    /// 分块大小：太小会放大请求数，太大首段等待变长。由缓冲档位注入。
    private let chunkSize: Int64
    /// 单次响应上限：避免 ffmpeg 发 `bytes=0-` 时一次性读进几十 GB。
    private let maxResponseBytes: Int64
    /// 只保留最近若干块，避免把整部影片（几十 GB）落在磁盘上。
    private let retainedChunks: Int64
    /// 并行预取窗口：千兆网下单条连接往往吃不满，多开几路才能把带宽打满。
    private var prefetchWindow: Int
    /// 同时在途的分块下载上限。
    private var maxParallelChunks: Int

    private let downloadQueue = DispatchQueue(label: "luma.remote.range.download",
                                              qos: .userInitiated,
                                              attributes: .concurrent)
    private let resolveLock = NSLock()
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    /// 已由 stop() 摘下的监听 fd：只由接收线程关闭，避免 fd 号被新服务复用后误 accept。
    private var closingFD: Int32 = -1
    private var session: URLSession?
    /// 共享的 Range 下载会话：连接复用 + 多路并发，避免每块都新建 URLSession。
    private var rangeSession: RangeFetchSession?
    private var resolvedMode: UpstreamMode?
    private var cachedContentType: String?
    private var completedChunks = Set<Int64>()
    private var downloadingChunks = Set<Int64>()
    private var chunkWaiters: [Int64: DispatchSemaphore] = [:]
    /// 最近读到过的分块：缓存按它保留，预取不会把正在读的块淘汰掉。
    private var servedChunk: Int64 = 0
    private var failure: String?
    private var closed = false
    private let log: (String) -> Void

    private(set) var port: UInt16 = 0
    /// 网络 / 鉴权层失败：调用方据此判断"不是编码问题，别再尝试转码兜底"。
    var onFailure: ((String) -> Void)?
    /// 云盘直链过期时重新解析地址（返回新的 URL 与请求头）。
    var onAuthFailure: (() -> (URL, [String: String])?)?
    /// 每完成一块下载上报一次吞吐（bit/s），供缓冲档位自适应使用。
    var onThroughput: ((Double) -> Void)?

    init(upstream: URL, headers: [String: String], trustSelfSigned: Bool,
         cacheDirectory: URL,
         profile: BufferProfile = .defaultProfile,
         log: @escaping (String) -> Void) {
        self.upstream = upstream
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
        self.cacheDirectory = cacheDirectory
        self.chunkSize = profile.chunkSize
        self.maxResponseBytes = max(16 * 1024 * 1024, profile.chunkSize * 2)
        self.retainedChunks = profile.retainedChunks
        self.prefetchWindow = profile.prefetchWindow
        self.maxParallelChunks = profile.maxParallelChunks
        self.log = log
    }

    deinit {
        stop()
    }

    /// 播放中按网络自适应结果调整预取强度；分块大小保持不变，避免正在下载的块尺寸不一致。
    func updateProfile(_ profile: BufferProfile) {
        stateLock.lock()
        prefetchWindow = profile.prefetchWindow
        maxParallelChunks = profile.maxParallelChunks
        stateLock.unlock()
    }

    /// 绑定 127.0.0.1 的随机端口，返回可直接交给 ffmpeg 的地址。
    func start() throws -> URL {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let delegate = RangeFetchSession(headers: headers, trustSelfSigned: trustSelfSigned)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 预取要多路并发：每路一条连接，实测单连接吃不完整条千兆带宽。
        configuration.httpMaximumConnectionsPerHost = maxParallelChunks
        rangeSession = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VideoError.transcodeUnavailable }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw VideoError.transcodeUnavailable
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: actual.sin_port)
        stateLock.lock()
        listenFD = fd
        stateLock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        guard let url = URL(string: "http://127.0.0.1:\(port)/stream") else {
            throw VideoError.transcodeUnavailable
        }
        return url
    }

    func stop() {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        let fd = listenFD
        listenFD = -1
        if fd >= 0 { closingFD = fd }
        // 唤醒所有等块的线程，让它们尽快退出。
        let waiters = Array(chunkWaiters.values)
        chunkWaiters.removeAll()
        stateLock.unlock()
        if fd >= 0 {
            // fd 由接收线程关闭：这里只 shutdown 唤醒阻塞中的 accept / poll。
            shutdown(fd, SHUT_RDWR)
        }
        for waiter in waiters { waiter.signal() }
        session?.invalidateAndCancel()
        session = nil
        rangeSession = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    private func record(_ message: String) {
        stateLock.lock()
        if failure == nil { failure = message }
        stateLock.unlock()
        onFailure?(message)
    }

    // MARK: - 接收

    private func acceptLoop() {
        defer { closeListenSocket() }
        while true {
            stateLock.lock()
            let fd = listenFD
            stateLock.unlock()
            guard fd >= 0 else { return }

            // poll + 超时：stop() 之后最迟 250ms 退出，不会留下卡死在 accept 的线程。
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            if descriptor.revents & Int16(POLLNVAL) != 0 { return }

            stateLock.lock()
            let stillOpen = listenFD == fd
            stateLock.unlock()
            guard stillOpen else { return }

            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    /// 监听 fd 只由接收线程关闭，停止时另一线程不会拿到被复用的 fd 号。
    private func closeListenSocket() {
        stateLock.lock()
        var fd = listenFD
        listenFD = -1
        if fd < 0 {
            fd = closingFD
            closingFD = -1
        }
        stateLock.unlock()
        guard fd >= 0 else { return }
        close(fd)
    }

    private func serve(_ client: Int32) {
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        // 客户端提前断开时不要用 SIGPIPE 杀掉整个进程。
        var noPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe,
                   socklen_t(MemoryLayout<Int32>.size))

        guard let head = readRequest(client) else {
            close(client)
            return
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else {
            send(client, status: "400 Bad Request", headers: [:], body: Data())
            close(client)
            return
        }
        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            send(client, status: "405 Method Not Allowed", headers: [:], body: Data())
            close(client)
            return
        }
        guard let mode = resolveUpstream() else {
            send(client, status: "502 Bad Gateway", headers: [:], body: Data())
            close(client)
            return
        }

        switch mode {
        case .sequential:
            if method == "HEAD" {
                send(client, status: "200 OK",
                     headers: ["Content-Type": contentType(), "Accept-Ranges": "none"],
                     body: Data())
                close(client)
            } else {
                // 连接所有权交给转发器，由它在结束时关闭。
                forwardSequentially(client)
            }
        case .ranged(let total):
            let rangeLine = lines.first { $0.lowercased().hasPrefix("range:") }
            if method == "HEAD" {
                send(client, status: "200 OK",
                     headers: ["Content-Type": contentType(),
                               "Content-Length": "\(total)",
                               "Accept-Ranges": "bytes"],
                     body: Data())
                close(client)
                return
            }
            let requested = HTTPByteRange.parse(rangeLine, total: total)
            let start = requested?.start ?? 0
            guard start < total else {
                send(client, status: "416 Range Not Satisfiable", headers: [:], body: Data())
                close(client)
                return
            }
            // 客户端给了明确终点：一次返回这一段（单次上限 16MB）。
            if let end = requested?.end {
                let upper = min(end, total - 1, start + maxResponseBytes - 1)
                guard let data = readChunks(from: start, to: upper, total: total) else {
                    send(client, status: "502 Bad Gateway", headers: [:], body: Data())
                    close(client)
                    return
                }
                send(client, status: "206 Partial Content",
                     headers: ["Content-Type": contentType(),
                               "Content-Length": "\(data.count)",
                               "Accept-Ranges": "bytes",
                               "Content-Range": "bytes \(start)-\(upper)/\(total)"],
                     body: data)
                close(client)
                return
            }
            // 开放式请求（bytes=X- 或未带 Range）：按 Content-Length 流式写完剩余全部内容，
            // 不能只回一小段，否则 ffmpeg 会把 16MB 处当文件结尾。
            let remaining = total - start
            var header = "HTTP/1.1 \(requested == nil ? "200 OK" : "206 Partial Content")\r\n"
            header += "Content-Type: \(contentType())\r\n"
            header += "Content-Length: \(remaining)\r\n"
            header += "Accept-Ranges: bytes\r\n"
            if requested != nil {
                header += "Content-Range: bytes \(start)-\(total - 1)/\(total)\r\n"
            }
            header += "Connection: close\r\n\r\n"
            guard writeAll(client, Data(header.utf8)) else {
                close(client)
                return
            }
            let ok = streamChunks(to: client, from: start, to: total - 1, total: total)
            if !ok {
                log("网盘分段流中断：\(start)-\(total - 1)")
            }
            close(client)
        }
    }

    private func readRequest(_ client: Int32) -> String? {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(client, raw.baseAddress, raw.count)
            }
            guard count > 0 else { return nil }
            request.append(buffer, count: count)
            if request.count > 64 * 1024 { return nil }
        }
        return String(decoding: request, as: UTF8.self)
    }

    private func send(_ client: Int32, status: String, headers: [String: String], body: Data) {
        var header = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers { header += "\(key): \(value)\r\n" }
        header += "Connection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        _ = writeAll(client, packet)
    }

    @discardableResult
    private func writeAll(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private func contentType() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedContentType ?? "application/octet-stream"
    }

    // MARK: - 上游元数据

    private func resolveUpstream() -> UpstreamMode? {
        resolveLock.lock()
        defer { resolveLock.unlock() }
        if let resolvedMode { return resolvedMode }

        // 先用 HEAD 拿元数据：不要对有 Range 的请求直接 GET，否则上游忽略 Range 时会把整部片子拉下来。
        var response = probe(method: "HEAD", range: nil)
        let headResponse = response
        /// HEAD 200 的 Content-Length 才是整文件长度；206 的 Content-Length 只是分片长度。
        var headTotal: Int64?
        if let head = headResponse, head.statusCode == 200,
           let text = head.value(forHTTPHeaderField: "Content-Length"),
           let total = Int64(text), total > 0 {
            headTotal = total
        }
        var probedWithRange = false
        if response == nil || !(200...299).contains(response?.statusCode ?? 0) {
            // 少数网盘不支持 HEAD（405/403）：只探测 2 个字节，拿到响应头就取消，不下载正文。
            response = probe(method: "GET", range: 0...1)
            probedWithRange = true
        }
        // 还有 CDN 会拒绝 HEAD 与 Range 探测（如 115 的部分节点），但普通 GET 可用：
        // 再试一次无 Range 的 GET，成功则退化为顺序转发，至少能从头播放。
        if let status = response?.statusCode, [400, 403, 405, 416].contains(status),
           let plain = probe(method: "GET", range: nil),
           (200...299).contains(plain.statusCode) {
            log("上游拒绝 HEAD / Range（HTTP \(status)），改用顺序读取")
            response = plain
            probedWithRange = false
            headTotal = plain.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        }
        guard let response else {
            record("网盘没有返回有效响应")
            return nil
        }
        let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("text/html") || type.contains("application/json") {
            record("网盘返回的是网页/JSON（HTTP \(response.statusCode)），可能鉴权失败或路径不存在")
            return nil
        }
        guard (200...299).contains(response.statusCode) else {
            record("网盘返回 HTTP \(response.statusCode)（\(response.url?.host ?? "-")）")
            return nil
        }

        // 文件总长的可靠来源只有两个：Content-Range 的 "/total"，或 HEAD 200 的 Content-Length。
        // 206 响应的 Content-Length 是本次分片的字节数（探测时就是 2），绝不能当总长，
        // 否则本地代理会按 2 字节的文件对外服务。
        let contentRangeTotal: Int64? = [response, headResponse]
            .compactMap { $0 }
            .compactMap { item in
                item.value(forHTTPHeaderField: "Content-Range")?
                    .split(separator: "/").last
                    .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            }
            .first { $0 > 0 }
        let acceptsRange = (response.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")

        var mode: UpstreamMode = .sequential
        if let total = contentRangeTotal {
            mode = .ranged(total)
        } else if response.statusCode == 206 {
            // 支持 Range 却不给 Content-Range：拿不到可靠总长，只能顺序转发；
            // 至少能从头播，不会因为把分片长度当总长而整片失败。
            log("网盘返回 206 但缺少 Content-Range，无法确定文件总长，已退化为顺序播放")
        } else if probedWithRange {
            // 探测请求本身就带 Range 却回了 200：上游忽略 Range。
        } else if let total = headTotal ?? response.value(forHTTPHeaderField: "Content-Length")
                    .flatMap({ Int64($0) }), total > 0 {
            if acceptsRange {
                mode = .ranged(total)
            } else if let verify = probe(method: "GET", range: 0...1), verify.statusCode == 206 {
                // HEAD 没声明 Accept-Ranges 不代表不支持：用 2 字节的 Range 请求验证一次。
                mode = .ranged(total)
            }
        }

        stateLock.lock()
        resolvedMode = mode
        cachedContentType = response.value(forHTTPHeaderField: "Content-Type")
        stateLock.unlock()
        return mode
    }

    /// 只拿响应头，不读取正文：用于 HEAD / Range 能力探测。
    private func probe(method: String, range: ClosedRange<Int64>?,
                       allowRefresh: Bool = true) -> HTTPURLResponse? {
        guard let session else { return nil }
        let (url, headerFields) = credentials()
        var request = URLRequest(url: url)
        for (key, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)",
                             forHTTPHeaderField: "Range")
        }
        request.httpMethod = method
        let delegate = ProbeDelegate(headers: headerFields, trustSelfSigned: trustSelfSigned)
        let probeSession = URLSession(configuration: session.configuration,
                                      delegate: delegate, delegateQueue: nil)
        let task = probeSession.dataTask(with: request)
        task.resume()
        let finished = delegate.semaphore.wait(timeout: .now() + 20) != .timedOut
        task.cancel()
        probeSession.invalidateAndCancel()
        let response = finished ? delegate.response : nil
        if allowRefresh, let status = response?.statusCode, status == 401 || status == 403,
           refreshCredentials() {
            log("网盘地址已过期（HTTP \(status)），重新解析后重试")
            return probe(method: method, range: range, allowRefresh: false)
        }
        return response
    }

    private func credentials() -> (URL, [String: String]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (upstream, headers)
    }

    private func refreshCredentials() -> Bool {
        guard let refreshed = onAuthFailure?() else { return false }
        stateLock.lock()
        upstream = refreshed.0
        headers = refreshed.1
        stateLock.unlock()
        return true
    }

    /// 取一段字节。上游对 Range 请求返回 200 时立即取消，避免整文件下载。
    /// 走共享会话：连接可以复用，多路分块能真正并发跑满带宽。
    private func fetch(range: ClosedRange<Int64>, timeout: TimeInterval,
                       allowRefresh: Bool = true) -> (Data, HTTPURLResponse)? {
        guard let session, let rangeSession else { return nil }
        let (url, headerFields) = credentials()
        var request = URLRequest(url: url)
        for (key, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)",
                         forHTTPHeaderField: "Range")
        let outcome = rangeSession.fetch(request,
                                         expectedLength: range.upperBound - range.lowerBound + 1,
                                         session: session,
                                         timeout: timeout)
        if let response = outcome.response, response.statusCode == 206,
           outcome.failure == nil, !outcome.data.isEmpty {
            return (outcome.data, response)
        }
        let status = outcome.response?.statusCode
        if allowRefresh, let status, status == 401 || status == 403, refreshCredentials() {
            log("网盘地址已过期（HTTP \(status)），重新解析后重试分块")
            return fetch(range: range, timeout: timeout, allowRefresh: false)
        }
        if let message = outcome.failure {
            record(message)
        } else if outcome.response != nil {
            record("网盘未按 Range 返回数据")
        } else {
            record("读取网盘数据超时")
        }
        return nil
    }

    // MARK: - 分块缓存

    private func chunkFile(_ index: Int64) -> URL {
        cacheDirectory.appendingPathComponent("\(index).chunk")
    }

    private func markServed(_ index: Int64) {
        stateLock.lock()
        if index > servedChunk { servedChunk = index }
        stateLock.unlock()
    }

    /// 确保这一块可用：已完成直接返回；别人在下载就等它；没人下就自己同步下。
    private func ensureChunk(_ index: Int64, total: Int64) -> Bool {
        var attempt = 0
        while attempt < 3 {
            attempt += 1
            stateLock.lock()
            if closed {
                stateLock.unlock()
                return false
            }
            if completedChunks.contains(index) {
                stateLock.unlock()
                return true
            }
            if FileManager.default.fileExists(atPath: chunkFile(index).path) {
                completedChunks.insert(index)
                stateLock.unlock()
                return true
            }
            if let semaphore = chunkWaiters[index] {
                stateLock.unlock()
                _ = semaphore.wait(timeout: .now() + 180)
                stateLock.lock()
                let ready = completedChunks.contains(index)
                stateLock.unlock()
                if ready { return true }
                continue   // 那次下载失败：自己认领重试
            }
            downloadingChunks.insert(index)
            chunkWaiters[index] = DispatchSemaphore(value: 0)
            stateLock.unlock()
            return downloadChunk(index, total: total)
        }
        return false
    }

    /// 下载一块并落盘，完成后唤醒等这一块的调用方。
    private func downloadChunk(_ index: Int64, total: Int64) -> Bool {
        stateLock.lock()
        let isClosed = closed
        let ready = completedChunks.contains(index)
        stateLock.unlock()
        if isClosed {
            finishChunk(index, success: false)
            return false
        }
        if ready {
            finishChunk(index, success: true)
            return true
        }
        var success = false
        let start = index * chunkSize
        let end = min(start + chunkSize - 1, total - 1)
        let startedAt = Date()
        if let (data, _) = fetch(range: start...end, timeout: 120), !data.isEmpty {
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 0.05 {
                onThroughput?(Double(data.count) * 8 / elapsed)
            }
            do {
                try data.write(to: chunkFile(index), options: .atomic)
                success = true
            } catch {
                record("写入分块缓存失败：\(error.localizedDescription)")
            }
        }
        finishChunk(index, success: success)
        stateLock.lock()
        let isClosedNow = closed
        stateLock.unlock()
        return success && !isClosedNow
    }

    /// 收尾：登记完成、唤醒等待者，并按读取位置淘汰旧块。
    private func finishChunk(_ index: Int64, success: Bool) {
        stateLock.lock()
        if success { completedChunks.insert(index) }
        downloadingChunks.remove(index)
        let waiter = chunkWaiters.removeValue(forKey: index)
        let stale = completedChunks.filter { $0 < servedChunk - retainedChunks }
        for old in stale {
            completedChunks.remove(old)
            try? FileManager.default.removeItem(at: chunkFile(old))
        }
        stateLock.unlock()
        waiter?.signal()
    }

    /// 并行预取：一次把后面几块同时排进下载，多路连接一起抢带宽。
    private func prefetch(from index: Int64, total: Int64) {
        var starts: [Int64] = []
        stateLock.lock()
        if !closed {
            var offset = 0
            while offset < prefetchWindow {
                let idx = index + Int64(offset)
                offset += 1
                if idx * chunkSize >= total { break }
                if completedChunks.contains(idx) || downloadingChunks.contains(idx) { continue }
                if downloadingChunks.count >= maxParallelChunks { break }
                downloadingChunks.insert(idx)
                chunkWaiters[idx] = DispatchSemaphore(value: 0)
                starts.append(idx)
            }
        }
        stateLock.unlock()
        for idx in starts {
            downloadQueue.async { [weak self] in
                _ = self?.downloadChunk(idx, total: total)
            }
        }
    }

    /// 边取边写：开放式请求体量可能几十 GB，不能先读进内存。
    private func streamChunks(to client: Int32, from lower: Int64, to upper: Int64,
                              total: Int64) -> Bool {
        let firstIndex = lower / chunkSize
        let lastIndex = upper / chunkSize
        markServed(firstIndex)
        // 先把预取窗口排满：几路连接同时下，边下边往客户端写。
        prefetch(from: firstIndex, total: total)
        for index in firstIndex...lastIndex {
            guard ensureChunk(index, total: total) else { return false }
            markServed(index)
            let chunkStart = index * chunkSize
            let from = max(lower, chunkStart) - chunkStart
            let to = min(upper, chunkStart + chunkSize - 1) - chunkStart
            let wrote: Bool = {
                guard let handle = try? FileHandle(forReadingFrom: chunkFile(index)) else { return false }
                defer { try? handle.close() }
                if from > 0 { try? handle.seek(toOffset: UInt64(from)) }
                var remaining = Int(to - from + 1)
                while remaining > 0 {
                    let slice = min(remaining, 512 * 1024)
                    guard let data = try? handle.read(upToCount: slice), !data.isEmpty else { return false }
                    guard writeAll(client, data) else { return false }
                    remaining -= data.count
                }
                return true
            }()
            guard wrote else { return false }
            prefetch(from: index + 1, total: total)
        }
        return true
    }

    private func readChunks(from lower: Int64, to upper: Int64, total: Int64) -> Data? {
        let clampedUpper = min(upper, total - 1)
        guard lower <= clampedUpper else { return nil }
        let firstIndex = lower / chunkSize
        let lastIndex = clampedUpper / chunkSize
        var output = Data()
        output.reserveCapacity(Int(min(clampedUpper - lower + 1, maxResponseBytes)))
        for index in firstIndex...lastIndex {
            guard ensureChunk(index, total: total) else { return nil }
            let chunkStart = index * chunkSize
            let from = max(lower, chunkStart) - chunkStart
            let to = min(clampedUpper, chunkStart + chunkSize - 1) - chunkStart
            guard let handle = try? FileHandle(forReadingFrom: chunkFile(index)) else { return nil }
            defer { try? handle.close() }
            if from > 0 { try? handle.seek(toOffset: UInt64(from)) }
            let length = Int(to - from + 1)
            if let data = try? handle.read(upToCount: length) {
                output.append(data)
            }
        }
        markServed(lastIndex)
        prefetch(from: lastIndex + 1, total: total)
        return output
    }

    // MARK: - 无 Range 时的顺序转发

    private func forwardSequentially(_ client: Int32) {
        guard let session else {
            close(client)
            return
        }
        let (url, headerFields) = credentials()
        var request = URLRequest(url: url)
        for (key, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let delegate = ForwardDelegate(client: client, headers: headerFields,
                                       trustSelfSigned: trustSelfSigned)
        let forwardSession = URLSession(configuration: session.configuration,
                                        delegate: delegate, delegateQueue: nil)
        delegate.session = forwardSession
        forwardSession.dataTask(with: request).resume()
    }
}

// MARK: - URLSession 委托

/// 公共的会话行为：302 时重新带上鉴权头，按挂载设置放行自签名证书。
private class SessionBehaviour: NSObject, URLSessionTaskDelegate {
    let headers: [String: String]
    let trustSelfSigned: Bool

    init(headers: [String: String], trustSelfSigned: Bool) {
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        for (key, value) in headers {
            redirected.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard trustSelfSigned,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// 只取响应头：一拿到响应就取消，避免触发整文件下载。
private final class ProbeDelegate: SessionBehaviour, URLSessionDataDelegate {
    let semaphore = DispatchSemaphore(value: 0)
    private(set) var response: HTTPURLResponse?
    private var signalled = false

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(.cancel)
        signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        signal()
    }

    private func signal() {
        guard !signalled else { return }
        signalled = true
        semaphore.signal()
    }
}

/// 共享的 Range 下载会话：多路并发 + 连接复用。
///
/// 原来每块都新建一个 URLSession，一块一条新连接，握手和慢启动反复来一遍，
/// 千兆网也只跑出单连接的速度；这里统一挂在一个会话上，任务按 id 路由，
/// `httpMaximumConnectionsPerHost` 打开多路，预取才能真正并发。
private final class RangeFetchSession: NSObject, URLSessionDataDelegate {
    struct Outcome {
        var data = Data()
        var response: HTTPURLResponse?
        var failure: String?
    }

    private final class TaskState {
        let expectedLength: Int64
        var data = Data()
        var response: HTTPURLResponse?
        var failure: String?
        var signalled = false
        let semaphore = DispatchSemaphore(value: 0)

        init(expectedLength: Int64) {
            self.expectedLength = expectedLength
        }
    }

    private let headers: [String: String]
    private let trustSelfSigned: Bool
    private let lock = NSLock()
    private var tasks: [Int: TaskState] = [:]

    init(headers: [String: String], trustSelfSigned: Bool) {
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
    }

    func fetch(_ request: URLRequest, expectedLength: Int64, session: URLSession,
               timeout: TimeInterval) -> Outcome {
        let state = TaskState(expectedLength: expectedLength)
        let task = session.dataTask(with: request)
        lock.lock()
        tasks[task.taskIdentifier] = state
        lock.unlock()
        task.resume()
        let finished = state.semaphore.wait(timeout: .now() + timeout) != .timedOut
        if !finished {
            state.failure = "读取网盘数据超时"
            task.cancel()
        }
        lock.lock()
        tasks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        return Outcome(data: state.data, response: state.response, failure: state.failure)
    }

    // MARK: 委托

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        for (key, value) in headers {
            redirected.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard trustSelfSigned,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = state(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            state.failure = "网盘没有返回有效响应"
            completionHandler(.cancel)
            signal(state)
            return
        }
        state.response = http
        guard http.statusCode == 206 else {
            state.failure = "网盘未按 Range 返回数据（HTTP \(http.statusCode)）"
            completionHandler(.cancel)
            signal(state)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(for: dataTask) else { return }
        state.data.append(data)
        // 上游忽略终点时及时取消，避免把整部电影拉进内存。
        if Int64(state.data.count) > state.expectedLength {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = state(for: task) else { return }
        if let error, state.failure == nil { state.failure = error.localizedDescription }
        signal(state)
    }

    private func state(for task: URLSessionTask) -> TaskState? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[task.taskIdentifier]
    }

    private func signal(_ state: TaskState) {
        lock.lock()
        let already = state.signalled
        state.signalled = true
        lock.unlock()
        if !already { state.semaphore.signal() }
    }
}

/// 上游忽略 Range 时，按 200 顺序把数据转发给 ffmpeg。
private final class ForwardDelegate: SessionBehaviour, URLSessionDataDelegate {
    private let client: Int32
    private var sentHeader = false
    private var finished = false
    var session: URLSession?

    init(client: Int32, headers: [String: String], trustSelfSigned: Bool) {
        self.client = client
        super.init(headers: headers, trustSelfSigned: trustSelfSigned)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish()
            return
        }
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")\r\n"
        header += "Connection: close\r\n\r\n"
        write(Data(header.utf8))
        sentHeader = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, sentHeader else { return }
        write(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard sent > 0 else {
                    finished = true
                    return
                }
                offset += sent
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        close(client)
    }
}
