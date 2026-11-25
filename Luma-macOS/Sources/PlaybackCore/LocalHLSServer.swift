import Foundation
import Darwin

/// 仅监听 127.0.0.1 的极简静态文件服务：把 ffmpeg 边写边生成的 HLS 目录交给 AVPlayer。
/// AVPlayer 无法直接读取自定义 scheme 的 HLS，但可以正常播放本机回环地址上的 m3u8。
/// 这里直接用 BSD socket：Network.framework 的 NWListener 在部分系统上创建会失败。
final class LocalHLSServer {
    private let directory: URL
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    /// 已由 stop() 摘下的监听 fd：只由接收线程关闭。
    /// 关闭与 accept 分处两个线程时，fd 号可能立刻被新服务复用，
    /// 旧线程的 accept 会落到别的 socket 上；快速跳转连续重建流时最容易踩到。
    private var closingFD: Int32 = -1
    /// 最近一份校验通过的播放列表：ffmpeg 正在重写时读到半截，就先用它兜底。
    private var playlistCache: [String: Data] = [:]
    private(set) var port: UInt16 = 0
    /// 播放中会滚动删除旧分片：返回当前保留的最小分片序号，
    /// 服务播放列表时过滤掉已删除的条目，并把 MEDIA-SEQUENCE 前移。
    var minSegmentIndexProvider: (() -> Int)?
    /// 请求级诊断（播放列表 / 失败 / 慢响应）：由会话注入，默认关闭。
    var onRequest: ((String) -> Void)?

    init(directory: URL) {
        self.directory = directory
    }

    deinit {
        stop()
    }

    /// 绑定 127.0.0.1 的随机端口并启动接收线程。
    func start() throws -> UInt16 {
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
        lock.lock()
        listenFD = fd
        lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        return port
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        if fd >= 0 { closingFD = fd }
        lock.unlock()
        guard fd >= 0 else { return }
        // 只唤醒，不在这里 close：fd 归接收线程所有。
        // 关闭交给 acceptLoop 退出时做，避免另一个线程的 accept 用到被复用后的 fd 号。
        shutdown(fd, SHUT_RDWR)
    }

    // MARK: - 接收

    private func acceptLoop() {
        defer { closeListenSocket() }
        while true {
            lock.lock()
            let fd = listenFD
            lock.unlock()
            guard fd >= 0 else { return }

            // 用 poll 等连接而不是直接阻塞 accept：stop() 后最多 250ms 就能退出，
            // 不会留下一个永远卡在 accept 里的线程。
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            if descriptor.revents & Int16(POLLNVAL) != 0 { return }

            // poll 返回后 stop() 可能已经发生：再确认一次，避免继续 accept 旧 fd。
            lock.lock()
            let stillOpen = listenFD == fd
            lock.unlock()
            guard stillOpen else { return }

            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            // 每个连接独立线程：AVPlayer 会并发请求播放列表与多个分片，
            // 单个连接一旦卡住（客户端提前关闭 / 读得慢），不能把整个服务堵死。
            // 强引用 self：连接处理期间服务对象必须存活。
            let handler = self
            Thread.detachNewThread { handler.serve(client) }
        }
    }

    /// 接收线程负责关闭监听 fd：正常退出、stop()、启动后立即停止都走这里。
    private func closeListenSocket() {
        lock.lock()
        var fd = listenFD
        listenFD = -1
        if fd < 0 {
            fd = closingFD
            closingFD = -1
        }
        lock.unlock()
        guard fd >= 0 else { return }
        close(fd)
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        // 播放器跳转时会直接关掉连接：没有 SO_NOSIGPIPE 时下一次 write 会收到
        // SIGPIPE，整个 App 会被系统直接杀掉（这正是快进 / 拖动时偶发退出的原因）。
        var noPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe,
                   socklen_t(MemoryLayout<Int32>.size))
        // 客户端不读数据时 write 会一直阻塞：给发送也设超时，避免线程永久挂住。
        var sendTimeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
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
        let response = makeResponse(for: head)
        response.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }

    // MARK: - 响应

    private func makeResponse(for head: String) -> Data {
        let started = Date()
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else {
            return finish(name: "-", status: "400 Bad Request", body: Data(),
                          contentType: "text/plain", started: started)
        }
        var path = String(parts[1])
        let method = String(parts[0]).uppercased()
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !name.contains("..") else {
            return finish(name: "-", status: "400 Bad Request", body: Data(),
                          contentType: "text/plain", started: started)
        }
        let fileURL = directory.appendingPathComponent(name)
        let isPlaylist = name.hasSuffix(".m3u8")
        var data: Data
        if isPlaylist {
            // ffmpeg 重写 m3u8 会先截断再写：直接读可能拿到 0 字节 / 半截列表，
            // AVPlayer 会把这种列表当成「已经结束」，表现为有缓冲却停在原地。
            if let snapshot = Self.playlistSnapshot(at: fileURL) {
                lock.lock()
                playlistCache[name] = snapshot
                lock.unlock()
                data = snapshot
            } else {
                lock.lock()
                let cached = playlistCache[name]
                lock.unlock()
                guard let cached else {
                    return finish(name: name, status: "503 Service Unavailable",
                                  body: Data(), contentType: "text/plain",
                                  started: started)
                }
                data = cached
            }
        } else {
            guard let read = try? Data(contentsOf: fileURL) else {
                return finish(name: name, status: "404 Not Found", body: Data(),
                              contentType: "text/plain", started: started)
            }
            data = read
        }

        // 播放中不改写播放列表：EVENT 列表只追加时 AVPlayer 最稳定。
        // 旧分片由会话结束统一清理，避免每次滚动删除都让播放器重新对齐、出现周期性卡顿。
        var body = data
        var status = "200 OK"
        var extra: [String] = []
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let range = HTTPByteRange.parse(rangeLine, total: Int64(data.count)) {
            let upper = Int(min(range.end ?? Int64(data.count - 1), Int64(data.count - 1)))
            let start = Int(range.start)
            if start >= 0, start <= upper, start < data.count {
                body = data.subdata(in: start..<(upper + 1))
                status = "206 Partial Content"
                extra.append("Content-Range: bytes \(start)-\(upper)/\(data.count)")
            }
        }
        return finish(name: name, status: status, body: body,
                      contentType: isPlaylist ? "application/vnd.apple.mpegurl" : "video/mp4",
                      noCache: isPlaylist, extra: extra, isPlaylist: isPlaylist,
                      started: started, headOnly: method == "HEAD")
    }

    /// 统一出口：先记录请求，再构造响应。
    private func finish(name: String, status: String, body: Data, contentType: String,
                        noCache: Bool = false, extra: [String] = [],
                        isPlaylist: Bool = false, started: Date,
                        headOnly: Bool = false) -> Data {
        recordRequest(name: name, status: status, body: body,
                      isPlaylist: isPlaylist, started: started)
        return Self.build(status: status, body: body, contentType: contentType,
                          noCache: noCache, extra: extra, headOnly: headOnly)
    }

    /// 请求级诊断：只记播放列表、失败与慢响应，避免正常分片把日志刷爆。
    /// 卡死排查最需要知道的是「AVPlayer 还在不在拉列表」「分片是不是 404」。
    private func recordRequest(name: String, status: String, body: Data,
                               isPlaylist: Bool, started: Date) {
        guard let onRequest else { return }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let failed = !(status.hasPrefix("200") || status.hasPrefix("206"))
        guard failed || isPlaylist || ms > 300 else { return }
        var message = "\(name) status=\(status.prefix(3)) \(ms)ms \(body.count)B"
        if isPlaylist {
            let count = String(decoding: body, as: UTF8.self)
                .components(separatedBy: "#EXTINF").count - 1
            message += " 分片=\(count)"
        }
        if failed {
            onRequest("HLS 请求失败 " + message)
        } else if ms > 300 {
            onRequest("HLS 响应慢 " + message)
        } else {
            onRequest("HLS 列表 " + message)
        }
    }

    /// ffmpeg 重写播放列表时会先截断再写：直接读可能拿到 0 字节或半截内容。
    /// 这里短暂重试几次，只接受「以换行结尾、且有分片」的完整快照。
    private static func playlistSnapshot(at url: URL) -> Data? {
        for _ in 0..<4 {
            if let data = try? Data(contentsOf: url), isValidPlaylist(data) { return data }
            usleep(12_000)
        }
        return nil
    }

    private static func isValidPlaylist(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count < 8 * 1024 * 1024 else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("#EXTM3U"), text.hasSuffix("\n") else { return false }
        // 多音轨 master 列表没有分片，但必须有 variant。
        if text.contains("#EXT-X-STREAM-INF") { return true }
        return text.contains("#EXTINF") || text.contains("#EXT-X-ENDLIST")
    }

    /// 丢弃序号小于 minIndex 的分片条目，避免播放器请求已删除的文件。
    private static func filterPlaylist(_ text: String, minIndex: Int) -> String {
        guard minIndex > 0 else { return text }
        var output: [String] = []
        var pendingExtinf: String?
        var sawMediaSequence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                output.append("#EXT-X-MEDIA-SEQUENCE:\(minIndex)")
                sawMediaSequence = true
                pendingExtinf = nil
                continue
            }
            if trimmed.hasPrefix("#EXTINF") {
                pendingExtinf = line
                continue
            }
            if let index = segmentIndex(trimmed) {
                if index >= minIndex {
                    if let pendingExtinf { output.append(pendingExtinf) }
                    output.append(line)
                }
                pendingExtinf = nil
                continue
            }
            if let extinf = pendingExtinf {
                output.append(extinf)
                pendingExtinf = nil
            }
            output.append(line)
        }
        if !sawMediaSequence, output.count > 1 {
            output.insert("#EXT-X-MEDIA-SEQUENCE:\(minIndex)", at: 1)
        }
        return output.joined(separator: "\n")
    }

    private static func segmentIndex(_ line: String) -> Int? {
        guard line.hasPrefix("seg"), line.hasSuffix(".m4s") else { return nil }
        let digits = line.dropFirst(3).dropLast(4)
        return Int(digits)
    }

    private static func build(status: String, body: Data, contentType: String,
                              noCache: Bool = false, extra: [String] = [],
                              headOnly: Bool = false) -> Data {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Connection: close\r\n"
        if noCache { header += "Cache-Control: no-cache, no-store\r\n" }
        for line in extra { header += line + "\r\n" }
        header += "\r\n"
        var packet = Data(header.utf8)
        // HEAD 只回头部：Content-Length 仍是完整长度，但不能再发 body。
        if !headOnly { packet.append(body) }
        return packet
    }
}
