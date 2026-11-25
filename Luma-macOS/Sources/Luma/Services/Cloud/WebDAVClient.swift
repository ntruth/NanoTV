import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import AVFoundation
import Network
import NetFS
import LumaContentCore

// MARK: - WebDAV 错误

enum WebDAVError: LocalizedError {
    case invalidURL
    case unauthorized
    case forbidden
    case notFound
    case unsupported
    case exists
    case status(Int)
    case transport(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务器地址无效"
        case .unauthorized: return "认证失败（401），请检查账号或密码"
        case .forbidden: return "没有访问权限（403）"
        case .notFound: return "路径不存在（404）"
        case .unsupported: return "该地址不是可用的 WebDAV 服务"
        case .exists: return "目标位置已存在同名项目"
        case .status(let code): return "服务器返回 HTTP \(code)"
        case .transport(let message): return message
        case .invalidResponse: return "服务器响应无法解析"
        }
    }
}

// MARK: - WebDAV 客户端

struct WebDAVClient {
    let baseURL: URL
    let username: String
    let password: String
    /// NAS 常使用自签名证书：开启后只对本次挂载放行服务器证书校验。
    let allowsSelfSignedCertificate: Bool

    init?(baseURLString: String, username: String, password: String,
          allowsSelfSignedCertificate: Bool = false) {
        guard let url = Self.normalizedBaseURL(baseURLString) else { return nil }
        self.baseURL = url
        self.username = username
        self.password = password
        self.allowsSelfSignedCertificate = allowsSelfSignedCertificate
    }

    /// 补全协议、去掉查询参数，并确保路径以「/」结尾。
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if !path.hasSuffix("/") { path += "/" }
        components.percentEncodedPath = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    var requestHeaders: [String: String] {
        guard !username.isEmpty || !password.isEmpty,
              let data = "\(username):\(password)".data(using: .utf8) else { return [:] }
        return ["Authorization": "Basic " + data.base64EncodedString()]
    }

    func fileURL(path: String) -> URL? {
        url(for: path, isDirectory: false)
    }

    func folderURL(path: String) -> URL? {
        url(for: path, isDirectory: true)
    }

    private func url(for path: String, isDirectory: Bool) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let escaped = path
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        var encodedPath = components.percentEncodedPath
        if !encodedPath.hasSuffix("/") { encodedPath += "/" }
        encodedPath += escaped
        if isDirectory && !escaped.isEmpty && !encodedPath.hasSuffix("/") {
            encodedPath += "/"
        }
        components.percentEncodedPath = encodedPath
        return components.url
    }

    /// 用最新一次 PROPFIND 的结果定位文件的真实地址。
    /// 服务器返回的 href 可能与「挂载点 + 相对路径」拼出来的不一样（编码、别名、目录重定向等），
    /// 直接按 href 下载可以避免 404；文件确实不在目录里时返回 nil。
    func resolveFileURL(path: String) async throws -> URL? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, let folder = folderURL(path: parent) else { return nil }
        var request = URLRequest(url: folder, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 207 else { return nil }

        let parsed = WebDAVMultistatusParser.parse(data)
        for item in parsed where !item.isCollection {
            guard let hrefURL = URL(string: item.href, relativeTo: folder) else { continue }
            let decoded = (hrefURL.path.removingPercentEncoding ?? hrefURL.path)
            guard (decoded as NSString).lastPathComponent == name else { continue }
            // href 是绝对地址：直接用；相对地址：沿用挂载点的 scheme/host/port，路径用服务器返回的。
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.percentEncodedPath = hrefURL.path(percentEncoded: true)
            components?.query = nil
            components?.fragment = nil
            return components?.url ?? hrefURL
        }
        return nil
    }

    func list(path: String) async throws -> [CloudEntry] {
        guard let url = folderURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WebDAVError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        switch http.statusCode {
        case 207:
            break
        case 401:
            throw WebDAVError.unauthorized
        case 403:
            throw WebDAVError.forbidden
        case 404:
            throw WebDAVError.notFound
        case 405, 501:
            throw WebDAVError.unsupported
        default:
            throw WebDAVError.status(http.statusCode)
        }

        let parsed = WebDAVMultistatusParser.parse(data)
        let basePath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let decodedBase = basePath.removingPercentEncoding ?? basePath
        // 挂载根路径：entry.path 必须是「相对挂载根」的完整路径，扫描、相册树与播放都依赖它。
        let rootPath = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? baseURL.path
        let decodedRoot = rootPath.removingPercentEncoding ?? rootPath
        let requestedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // 诊断：确认服务器返回的 href 与本地拼接的 base 是否一致（排查 404）。
        let samples = parsed.prefix(2).map(\.href).joined(separator: " , ")
        Diagnostics.record("WebDAV 列表 base=\(decodedBase) href=\(samples)")

        var entries: [CloudEntry] = []
        for item in parsed {
            guard !item.href.isEmpty else { continue }
            let encodedPath = URL(string: item.href)?.path(percentEncoded: true) ?? item.href
            let decoded = encodedPath.removingPercentEncoding ?? encodedPath
            // 优先按挂载根截断；href 与挂载根前缀不一致时退回「当前目录 + 剩余部分」。
            var relative = decoded
            if relative.hasPrefix(decodedRoot) {
                relative = String(relative.dropFirst(decodedRoot.count))
            } else if relative.hasPrefix(decodedBase) {
                let rest = String(relative.dropFirst(decodedBase.count))
                relative = requestedPath.isEmpty ? rest : requestedPath + "/" + rest
            }
            relative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty, relative != requestedPath else { continue }
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }

            let name = relative.split(separator: "/").last.map(String.init) ?? relative
            entries.append(CloudEntry(path: relative,
                                      name: name,
                                      isDirectory: item.isCollection,
                                      size: item.size,
                                      modifiedAt: item.modifiedAt,
                                      contentType: item.contentType))
        }
        return entries
    }

    func data(path: String) async throws -> Data {
        guard let url = fileURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return data
    }

    /// 只读取指定字节区间。partial 为 false 表示服务器忽略了 Range（或文件本身就比区间小）。
    func data(path: String, byteRange: ClosedRange<Int>) async throws -> (data: Data, partial: Bool) {
        guard let url = fileURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("bytes=\(byteRange.lowerBound)-\(byteRange.upperBound)", forHTTPHeaderField: "Range")
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return (data, status == 206)
    }

    func download(path: String, to destination: URL) async throws {
        guard let url = fileURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (temp, response) = try await session.download(for: request)
        try Self.validate(response)
        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: temp, to: destination)
    }

    // MARK: - 写操作

    func createFolder(path: String) async throws {
        guard let url = folderURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "MKCOL"
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let http = try await perform(request)
        switch http.statusCode {
        case 200, 201:
            return
        case 405:
            throw WebDAVError.exists
        default:
            try Self.validate(http)
        }
    }

    func delete(path: String) async throws {
        guard let url = fileURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "DELETE"
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let http = try await perform(request)
        switch http.statusCode {
        case 200, 202, 204:
            return
        default:
            try Self.validate(http)
        }
    }

    func move(from path: String, to destinationPath: String) async throws {
        guard let url = fileURL(path: path),
              let destination = fileURL(path: destinationPath) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "MOVE"
        request.setValue(destination.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let http = try await perform(request)
        switch http.statusCode {
        case 200, 201, 204:
            return
        case 412:
            throw WebDAVError.exists
        default:
            try Self.validate(http)
        }
    }

    func upload(path: String, from localURL: URL) async throws {
        guard let url = fileURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 600)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (_, response) = try await session.upload(for: request, fromFile: localURL)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        switch http.statusCode {
        case 200, 201, 204:
            return
        case 412:
            throw WebDAVError.exists
        default:
            try Self.validate(http)
        }
    }

    private func perform(_ request: URLRequest) async throws -> HTTPURLResponse {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        return http
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        switch http.statusCode {
        case 200, 206:
            return
        case 401:
            throw WebDAVError.unauthorized
        case 403:
            throw WebDAVError.forbidden
        case 404:
            throw WebDAVError.notFound
        default:
            throw WebDAVError.status(http.statusCode)
        }
    }

    private static let propfindBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:getcontentlength/>
            <D:getlastmodified/>
            <D:getcontenttype/>
            <D:resourcetype/>
          </D:prop>
        </D:propfind>
        """.utf8)

    private var session: URLSession {
        allowsSelfSignedCertificate ? Self.trustingSession : Self.session
    }

    /// WebDAV 会话画像：25s 请求、180s 资源、每主机 4 条连接；Cookie 保留给 NAS 登录态。
    private static let profile = HTTPSessionProfile(timeout: 25,
                                                     resourceTimeout: 180,
                                                     maximumConnectionsPerHost: 4,
                                                     allowsCookies: true)

    private static let session: URLSession = {
        URLSession(configuration: profile.configuration())
    }()

    /// 放行自签名证书的会话：仅用于用户明确勾选「信任自签名证书」的挂载。
    private static let trustingSession: URLSession = {
        URLSession(configuration: profile.configuration(),
                   delegate: SelfSignedTrustDelegate(),
                   delegateQueue: nil)
    }()
}

/// 接受服务器证书（含自签名）的 URLSession 代理。
private final class SelfSignedTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        complete(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        complete(challenge, completionHandler)
    }

    private func complete(_ challenge: URLAuthenticationChallenge,
                          _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - PROPFIND 解析

final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    struct Item {
        var href: String = ""
        var size: Int64 = 0
        var modifiedAt: Date?
        var contentType: String?
        var isCollection = false
    }

    private var items: [Item] = []
    private var current: Item?
    private var text = ""
    private var inResponse = false

    static func parse(_ data: Data) -> [Item] {
        let parser = WebDAVMultistatusParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        text = ""
        if name == "response" {
            inResponse = true
            current = Item()
        } else if name == "collection", inResponse {
            current?.isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        if inResponse, var item = current {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href":
                if item.href.isEmpty { item.href = value }
            case "getcontentlength":
                item.size = Int64(value) ?? 0
            case "getlastmodified":
                item.modifiedAt = Self.parseDate(value)
            case "getcontenttype":
                item.contentType = value.isEmpty ? nil : value
            case "response":
                items.append(item)
                current = nil
                inResponse = false
                text = ""
                return
            default:
                break
            }
            current = item
        }
        text = ""
    }

    private func localName(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        return dateFormatter.date(from: value)
    }
}
