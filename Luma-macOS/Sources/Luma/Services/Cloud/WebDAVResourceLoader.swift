import Foundation
import AVFoundation
import LumaContentCore

/// 让 AVFoundation 通过 App 自己的网络会话读取云端资源。
///
/// AVFoundation 直连远程地址时既不会使用 App 的自签名证书信任，也不会走我们的请求头策略；
/// 百度网盘的直链进一步要求固定 UA、会 302 到 CDN，且 URL 不带文件扩展名。
/// 这里把资源地址换成自定义 scheme，由 `AVAssetResourceLoader` 接管读取：
/// 收到读取请求后用带认证头与证书信任的会话转发（含 Range、跟随跳转时重放请求头），
/// 并按原文件名补全 Content-Type，边下边写回给 AVFoundation。
final class CloudAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate,
                                      URLSessionDataDelegate, URLSessionTaskDelegate {
    static let scheme = "luma-cloud"

    let queue: DispatchQueue
    private let upstreamURL: URL
    private let headers: [String: String]
    private let trustSelfSigned: Bool
    /// 直链路径没有扩展名时（例如百度 `/file/<md5>`），用原始文件名推断 MIME。
    private let extensionHint: String?

    private struct Pending {
        let loadingRequest: AVAssetResourceLoadingRequest
        let dataRequest: AVAssetResourceLoadingDataRequest?
        /// 还需要交付给 AVFoundation 的字节数；0 表示「读到结尾」。
        var remaining: Int64
        /// 服务器忽略 Range 返回整份文件时需要丢弃的前缀字节数。
        var skip: Int64
    }

    private var pending: [Int: Pending] = [:]
    private var tasks: [ObjectIdentifier: URLSessionTask] = [:]
    private var sessionCreated = false
    /// 会话销毁后 AVFoundation 仍可能补发读取请求，再建任务会直接抛异常。
    private var invalidated = false

    private lazy var session: URLSession = {
        sessionCreated = true
        // 与资源读取器共用同一条串行队列，状态无需再加锁。
        let delegateQueue = OperationQueue()
        delegateQueue.name = "luma.webdav.asset.session"
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: HTTPSessionProfile.stream.configuration(),
                          delegate: self,
                          delegateQueue: delegateQueue)
    }()

    init(upstreamURL: URL, headers: [String: String], trustSelfSigned: Bool,
         extensionHint: String? = nil) {
        self.upstreamURL = upstreamURL
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
        self.extensionHint = extensionHint?.isEmpty == false ? extensionHint : nil
        self.queue = DispatchQueue(label: "luma.cloud.asset")
        super.init()
    }

    /// 交给 AVFoundation 的本地资源地址：不直接暴露服务器地址。
    /// 保留（或按提示补上）文件扩展名，AVFoundation 需要它判定容器格式。
    static func localURL(for upstream: URL, pathExtension: String? = nil) -> URL? {
        var filename = upstream.lastPathComponent
        let ext = (pathExtension?.isEmpty == false ? pathExtension! : upstream.pathExtension)
        if !ext.isEmpty, (filename as NSString).pathExtension.isEmpty {
            filename += "." + ext
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "asset"
        components.path = "/" + filename
        components.queryItems = [URLQueryItem(name: "src", value: upstream.absoluteString)]
        return components.url
    }

    /// 建立带自定义读取器的资产；返回的 loader 必须在资产使用期间保持强引用。
    static func makeAsset(upstreamURL: URL,
                          headers: [String: String],
                          trustSelfSigned: Bool,
                          pathExtension: String? = nil) -> (asset: AVURLAsset, loader: CloudAssetResourceLoader)? {
        guard let local = localURL(for: upstreamURL, pathExtension: pathExtension) else { return nil }
        let asset = AVURLAsset(url: local)
        let loader = CloudAssetResourceLoader(upstreamURL: upstreamURL,
                                              headers: headers,
                                              trustSelfSigned: trustSelfSigned,
                                              extensionHint: pathExtension)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        start(loadingRequest)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let task = tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) else { return }
        pending.removeValue(forKey: task.taskIdentifier)
        task.cancel()
    }

    /// 缩略图 / 播放结束后调用：URLSession 会强引用代理，必须显式结束，避免逐张累积会话。
    /// 标记失效后再收到的读取请求直接以取消结束，不能往已销毁的会话里建任务。
    func invalidate() {
        queue.async {
            guard !self.invalidated else { return }
            self.invalidated = true
            self.pending.removeAll()
            self.tasks.removeAll()
            guard self.sessionCreated else { return }
            self.session.invalidateAndCancel()
        }
    }

    // MARK: - 转发

    private func start(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard !invalidated else {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain,
                                                       code: NSURLErrorCancelled))
            return
        }
        var request = URLRequest(url: upstreamURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 60)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let dataRequest = loadingRequest.dataRequest
        var length: Int64 = 0
        if let dataRequest {
            let offset = max(0, dataRequest.requestedOffset)
            length = Int64(dataRequest.requestedLength)
            let end: String
            if length > 0, offset <= Int64.max - length {
                end = String(offset + length - 1)
            } else {
                end = ""
            }
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        } else {
            // 元数据请求：百度直链不一定支持 HEAD，用两个字节的 Range GET
            // 同样能拿到 Content-Range / Content-Type，又不会把整份文件拉下来。
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: request)
        pending[task.taskIdentifier] = Pending(loadingRequest: loadingRequest,
                                               dataRequest: dataRequest,
                                               remaining: length,
                                               skip: 0)
        tasks[ObjectIdentifier(loadingRequest)] = task
        task.resume()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard var entry = pending[dataTask.taskIdentifier],
              let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        if let content = entry.loadingRequest.contentInformationRequest {
            fill(content, from: http)
        }
        // 只为取元数据的请求：拿到响应头就可以结束，不再下载文件内容。
        if entry.dataRequest == nil {
            pending.removeValue(forKey: dataTask.taskIdentifier)
            tasks.removeValue(forKey: ObjectIdentifier(entry.loadingRequest))
            entry.loadingRequest.finishLoading()
            completionHandler(.cancel)
            return
        }
        if http.statusCode == 200 {
            entry.skip = entry.dataRequest.map { max(0, $0.requestedOffset) } ?? 0
        }
        pending[dataTask.taskIdentifier] = entry
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var entry = pending[dataTask.taskIdentifier],
              let dataRequest = entry.dataRequest else { return }
        var payload = data
        if entry.skip > 0 {
            let drop = min(entry.skip, Int64(payload.count))
            entry.skip -= drop
            payload = payload.dropFirst(Int(drop))
        }
        // 服务器忽略 Range 返回整份文件时，只交付请求的那一段。
        if entry.remaining > 0 {
            if Int64(payload.count) > entry.remaining {
                payload = payload.prefix(Int(entry.remaining))
            }
            entry.remaining -= Int64(payload.count)
        }
        pending[dataTask.taskIdentifier] = entry
        guard !payload.isEmpty else { return }
        dataRequest.respond(with: payload)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = pending.removeValue(forKey: task.taskIdentifier) else { return }
        tasks.removeValue(forKey: ObjectIdentifier(entry.loadingRequest))
        if let error, (error as NSError).code != NSURLErrorCancelled {
            entry.loadingRequest.finishLoading(with: error)
        } else {
            entry.loadingRequest.finishLoading()
        }
    }

    /// 百度直链经常 302 到 d.pcs.baidu.com 一类的 CDN，跳转后的请求仍要带上同样的 UA / Referer；
    /// 安全加固：Authorization / Cookie 敏感认证头仅在同源或同主域重定向时透传，防止凭据跨域泄露。
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        let origHost = task.originalRequest?.url?.host?.lowercased() ?? ""
        let targetHost = request.url?.host?.lowercased() ?? ""
        let isSameOriginOrRootDomain: Bool = {
            guard !origHost.isEmpty, !targetHost.isEmpty else { return false }
            if origHost == targetHost { return true }
            let origParts = origHost.split(separator: ".")
            let targetParts = targetHost.split(separator: ".")
            if origParts.count >= 2 && targetParts.count >= 2 {
                return origParts.suffix(2) == targetParts.suffix(2)
            }
            return false
        }()

        for (key, value) in headers {
            let lower = key.lowercased()
            if (lower == "authorization" || lower == "cookie") && !isSameOriginOrRootDomain {
                continue
            }
            redirected.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard trustSelfSigned,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 安全加固：仅在自签证书对应的目标 host 与原始请求 host 一致时放行
        let expectedHost = sourceURL.host?.lowercased() ?? ""
        guard expectedHost.isEmpty || challenge.protectionSpace.host.lowercased() == expectedHost else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    // MARK: - 响应头

    /// 补齐 AVFoundation 需要的总长度、类型与 Range 支持标记。
    private func fill(_ content: AVAssetResourceLoadingContentInformationRequest,
                      from http: HTTPURLResponse) {
        if let total = Self.totalLength(from: http) {
            content.contentLength = total
        }
        if let type = mimeType(from: http), !type.isEmpty {
            content.contentType = type
        }
        content.isByteRangeAccessSupported = true
    }

    private func mimeType(from http: HTTPURLResponse) -> String? {
        let header = http.value(forHTTPHeaderField: "Content-Type")?.trimmingCharacters(in: .whitespaces)
        if let header, !header.isEmpty, !header.lowercased().contains("octet-stream") {
            return header
        }
        switch (extensionHint ?? upstreamURL.pathExtension).lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov", "qt": return "video/quicktime"
        case "m4a": return "audio/mp4"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        default: return header
        }
    }

    private static func totalLength(from http: HTTPURLResponse) -> Int64? {
        // 206 的 Content-Range 形如 "bytes 0-1/123456"。
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last,
           let value = Int64(total) {
            return value
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length"),
           let value = Int64(length), value > 0 {
            return value
        }
        return nil
    }
}
