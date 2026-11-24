import Foundation
import NanoCore

// MARK: - 1. 115 网盘双轨驱动（方案 A: proapi.115.com 官方 OpenAPI | 方案 B: Web/TV 扫码 Cookie + LocalProxy）

public struct Drive115OpenAPISchemeADriver: VirtualFileSystemDriver {
    public let source: StorageSource
    public let accessToken: String

    public init(source: StorageSource, accessToken: String) {
        self.source = source
        self.accessToken = accessToken
    }

    public func listDirectory(at path: String, parentFileID: String?) async throws -> [VFSNode] {
        guard !accessToken.isEmpty else {
            throw VFSError.schemeAUnsupportedFallbackRequired("未配置 115 OpenAPI AccessToken")
        }
        let cid = parentFileID ?? "0"
        guard var comps = URLComponents(string: "https://proapi.115.com/open/ufile/files") else {
            throw VFSError.networkFailure("115 OpenAPI URL 构造失败")
        }
        comps.queryItems = [
            URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "show_dir", value: "1")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw VFSError.schemeAUnsupportedFallbackRequired("115 OpenAPI Token 过期或权限受限")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            throw VFSError.schemeAUnsupportedFallbackRequired("115 OpenAPI 响应异常，触发方案 B 兜底")
        }

        return list.compactMap { item in
            guard let fn = item["fn"] as? String else { return nil }
            let fc = (item["fc"] as? String) ?? "1" // 0: 目录, 1: 文件
            let isDir = (fc == "0")
            let fid = (item["fid"] as? String) ?? ""
            let pc = (item["pc"] as? String) ?? fid
            let size = (item["fs"] as? Int64) ?? 0
            return VFSNode(
                sourceID: source.id,
                fileID: isDir ? fid : pc,
                name: fn,
                path: path == "/" ? "/\(fn)" : "\(path)/\(fn)",
                kind: VFSNode.inferKind(from: fn, isDirectory: isDir),
                sizeBytes: size
            )
        }
    }

    public func searchFiles(keyword: String) async throws -> [VFSNode] { [] }

    public func resolvePlayableTicket(for node: VFSNode) async throws -> PlayableStreamTicket {
        guard !accessToken.isEmpty else {
            throw VFSError.schemeAUnsupportedFallbackRequired("无 AccessToken")
        }
        var req = URLRequest(url: URL(string: "https://proapi.115.com/open/ufile/downurl")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "pick_code=\(node.fileID)".data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let firstEntry = dataDict.values.first as? [String: Any],
              let urlObj = firstEntry["url"] as? [String: Any],
              let rawURLStr = urlObj["url"] as? String,
              let rawURL = URL(string: rawURLStr) else {
            throw VFSError.schemeAUnsupportedFallbackRequired("115 OpenAPI 未返回原画直链，转交方案 B")
        }

        let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) NanoPlayer/1.0"]
        let proxiedURL = try await LocalStreamProxyServer.shared.registerStream(remoteURL: rawURL, headers: headers)
        return PlayableStreamTicket(title: node.name, subtitle: "115 网盘 (OpenAPI)", streamURL: proxiedURL, headers: headers)
    }
}

public struct Drive115CookieSchemeBDriver: VirtualFileSystemDriver {
    public let source: StorageSource
    public let cookieHeader: String
    private static let clientUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 115Browser/27.0.0"

    public init(source: StorageSource, cookieHeader: String) {
        self.source = source
        self.cookieHeader = cookieHeader
    }

    public func listDirectory(at path: String, parentFileID: String?) async throws -> [VFSNode] {
        let cid = parentFileID ?? "0"
        let urlStr = "https://webapi.115.com/files?aid=1&cid=\(cid)&o=user_ptime&asc=0&offset=0&show_dir=1&limit=200&format=json"
        var req = URLRequest(url: URL(string: urlStr)!)
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(Self.clientUA, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item in
            guard let name = item["n"] as? String else { return nil }
            let isDir = (item["fid"] == nil)
            let idVal = (item["pc"] as? String) ?? (item["cid"] as? String) ?? ""
            let size = (item["s"] as? Int64) ?? 0
            return VFSNode(
                sourceID: source.id,
                fileID: idVal,
                name: name,
                path: path == "/" ? "/\(name)" : "\(path)/\(name)",
                kind: VFSNode.inferKind(from: name, isDirectory: isDir),
                sizeBytes: size
            )
        }
    }

    public func searchFiles(keyword: String) async throws -> [VFSNode] { [] }

    public func resolvePlayableTicket(for node: VFSNode) async throws -> PlayableStreamTicket {
        let m3u8URL = URL(string: "https://115.com/api/video/m3u8/\(node.fileID).m3u8")!
        let headers = [
            "Cookie": cookieHeader,
            "User-Agent": Self.clientUA,
            "Referer": "https://115.com/"
        ]
        let proxied = try await LocalStreamProxyServer.shared.registerStream(remoteURL: m3u8URL, headers: headers)
        return PlayableStreamTicket(title: node.name, subtitle: "115 网盘 (扫码直链)", streamURL: proxied, headers: headers)
    }
}

// MARK: - 2. 百度网盘双轨驱动（方案 A: 官方 xpan OpenAPI | 方案 B: 扫码 BDUSS/STOKEN Cookie 直链）

public struct BaiduPanOpenAPISchemeADriver: VirtualFileSystemDriver {
    public let source: StorageSource
    public let accessToken: String

    public init(source: StorageSource, accessToken: String) {
        self.source = source
        self.accessToken = accessToken
    }

    public func listDirectory(at path: String, parentFileID: String?) async throws -> [VFSNode] {
        guard !accessToken.isEmpty else {
            throw VFSError.schemeAUnsupportedFallbackRequired("未配置百度网盘 OpenAPI Token")
        }
        var comps = URLComponents(string: "https://pan.baidu.com/rest/2.0/xpan/file")!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "dir", value: path.isEmpty ? "/" : path),
            URLQueryItem(name: "access_token", value: accessToken)
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["errno"] as? Int ?? -1) == 0,
              let list = json["list"] as? [[String: Any]] else {
            throw VFSError.schemeAUnsupportedFallbackRequired("百度 OpenAPI 鉴权失效或触发频控")
        }

        return list.compactMap { item in
            guard let serverFilename = item["server_filename"] as? String,
                  let fullPath = item["path"] as? String else { return nil }
            let isDir = ((item["isdir"] as? Int) ?? 0) == 1
            let fsID = String((item["fs_id"] as? Int64) ?? 0)
            let size = (item["size"] as? Int64) ?? 0
            return VFSNode(
                sourceID: source.id,
                fileID: fsID,
                name: serverFilename,
                path: fullPath,
                kind: VFSNode.inferKind(from: serverFilename, isDirectory: isDir),
                sizeBytes: size
            )
        }
    }

    public func searchFiles(keyword: String) async throws -> [VFSNode] { [] }

    public func resolvePlayableTicket(for node: VFSNode) async throws -> PlayableStreamTicket {
        guard !accessToken.isEmpty else {
            throw VFSError.schemeAUnsupportedFallbackRequired("无百度 OpenAPI Token")
        }
        var comps = URLComponents(string: "https://pan.baidu.com/rest/2.0/xpan/multimedia")!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "filemetas"),
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "fsids", value: "[\(node.fileID)]"),
            URLQueryItem(name: "dlink", value: "1")
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["list"] as? [[String: Any]],
              let dlink = list.first?["dlink"] as? String,
              let remoteURL = URL(string: "\(dlink)&access_token=\(accessToken)") else {
            throw VFSError.schemeAUnsupportedFallbackRequired("百度 OpenAPI dlink 获取失败，转交方案 B")
        }

        // 百度官方要求下载/播放 dlink 必须携带特定 User-Agent: pan.baidu.com
        let headers = ["User-Agent": "pan.baidu.com"]
        let proxiedURL = try await LocalStreamProxyServer.shared.registerStream(remoteURL: remoteURL, headers: headers)
        return PlayableStreamTicket(title: node.name, subtitle: "百度网盘 (OpenAPI)", streamURL: proxiedURL, headers: headers)
    }
}

public struct BaiduPanCookieSchemeBDriver: VirtualFileSystemDriver {
    public let source: StorageSource
    public let cookieHeader: String

    public init(source: StorageSource, cookieHeader: String) {
        self.source = source
        self.cookieHeader = cookieHeader
    }

    public func listDirectory(at path: String, parentFileID: String?) async throws -> [VFSNode] {
        var comps = URLComponents(string: "https://pan.baidu.com/api/list")!
        comps.queryItems = [
            URLQueryItem(name: "dir", value: path.isEmpty ? "/" : path),
            URLQueryItem(name: "num", value: "200"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "order", value: "time")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["list"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item in
            guard let name = item["server_filename"] as? String,
                  let fullPath = item["path"] as? String else { return nil }
            let isDir = ((item["isdir"] as? Int) ?? 0) == 1
            let fsID = String((item["fs_id"] as? Int64) ?? 0)
            let size = (item["size"] as? Int64) ?? 0
            return VFSNode(
                sourceID: source.id,
                fileID: fsID,
                name: name,
                path: fullPath,
                kind: VFSNode.inferKind(from: name, isDirectory: isDir),
                sizeBytes: size
            )
        }
    }

    public func searchFiles(keyword: String) async throws -> [VFSNode] { [] }

    public func resolvePlayableTicket(for node: VFSNode) async throws -> PlayableStreamTicket {
        var comps = URLComponents(string: "https://pan.baidu.com/api/streaming")!
        comps.queryItems = [
            URLQueryItem(name: "path", value: node.path),
            URLQueryItem(name: "type", value: "M3U8_AUTO_4K"),
            URLQueryItem(name: "app_id", value: "250528")
        ]
        let headers = [
            "Cookie": cookieHeader,
            "User-Agent": "netdisk;13.0.0;Mac",
            "Referer": "https://pan.baidu.com/"
        ]
        let proxiedURL = try await LocalStreamProxyServer.shared.registerStream(remoteURL: comps.url!, headers: headers)
        return PlayableStreamTicket(title: node.name, subtitle: "百度网盘 (扫码直链)", streamURL: proxiedURL, headers: headers)
    }
}

// MARK: - 3. 夸克网盘驱动（官方无个人直链 OpenAPI，方案 A 检测不支持后自动运行方案 B 扫码 Cookie + LocalProxy）

public struct QuarkCookieSchemeBDriver: VirtualFileSystemDriver {
    public let source: StorageSource
    public let cookieHeader: String
    private static let quarkUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 quark-cloud-drive/3.14.0"

    public init(source: StorageSource, cookieHeader: String) {
        self.source = source
        self.cookieHeader = cookieHeader
    }

    public func listDirectory(at path: String, parentFileID: String?) async throws -> [VFSNode] {
        let pdirFid = parentFileID ?? "0"
        let urlStr = "https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&pdir_fid=\(pdirFid)&_page=1&_size=200&_sort=file_type:asc,updated_at:desc"
        var req = URLRequest(url: URL(string: urlStr)!)
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(Self.quarkUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item in
            guard let fid = item["fid"] as? String,
                  let fileName = item["file_name"] as? String else { return nil }
            let isDir = ((item["dir"] as? Bool) == true) || ((item["file"] as? Bool) == false)
            let size = (item["size"] as? Int64) ?? 0
            return VFSNode(
                sourceID: source.id,
                fileID: fid,
                name: fileName,
                path: path == "/" ? "/\(fileName)" : "\(path)/\(fileName)",
                kind: VFSNode.inferKind(from: fileName, isDirectory: isDir),
                sizeBytes: size
            )
        }
    }

    public func searchFiles(keyword: String) async throws -> [VFSNode] { [] }

    public func resolvePlayableTicket(for node: VFSNode) async throws -> PlayableStreamTicket {
        let dlURL = URL(string: "https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc")!
        var req = URLRequest(url: dlURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(Self.quarkUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["fids": [node.fileID]])

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]],
              let downloadURLStr = dataArr.first?["download_url"] as? String,
              let remoteURL = URL(string: downloadURLStr) else {
            throw VFSError.fileNotFound("无法获取夸克网盘 SVIP 原画直链，请检查扫码 Cookie 是否有效")
        }

        let headers = [
            "Cookie": cookieHeader,
            "User-Agent": Self.quarkUA,
            "Referer": "https://pan.quark.cn/"
        ]
        let proxiedURL = try await LocalStreamProxyServer.shared.registerStream(remoteURL: remoteURL, headers: headers)
        return PlayableStreamTicket(title: node.name, subtitle: "夸克网盘 (原画直链)", streamURL: proxiedURL, headers: headers)
    }
}

// MARK: - 4. 标准 WebDAV 与 NAS SMB 适配器 + 统一构建工厂

public struct WebDAVStorageDriver: VirtualFileSystemDriver {
    public let source: StorageSource
    public let username: String
    public let password: String

    public init(source: StorageSource, username: String = "", password: String = "") {
        self.source = source
        self.username = username
        self.password = password
    }

    private var authHeader: String? {
        guard !username.isEmpty else { return nil }
        let raw = "\(username):\(password)"
        return "Basic \(Data(raw.utf8).base64EncodedString())"
    }

    public func listDirectory(at path: String, parentFileID: String?) async throws -> [VFSNode] {
        let base = source.endpointURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "\(base)\(encodedPath)") else { return [] }

        var req = URLRequest(url: url)
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        if let auth = authHeader {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        let xmlString = String(data: data, encoding: .utf8) ?? ""
        return Self.parseSimplePropfindHrefs(xml: xmlString, basePath: path, sourceID: source.id)
    }

    public func searchFiles(keyword: String) async throws -> [VFSNode] { [] }

    public func resolvePlayableTicket(for node: VFSNode) async throws -> PlayableStreamTicket {
        let base = source.endpointURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedPath = node.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node.path
        let url = URL(string: "\(base)\(encodedPath)")!
        var headers: [String: String] = [:]
        if let auth = authHeader {
            headers["Authorization"] = auth
        }
        return PlayableStreamTicket(title: node.name, subtitle: source.name, streamURL: url, headers: headers)
    }

    private static func parseSimplePropfindHrefs(xml: String, basePath: String, sourceID: UUID) -> [VFSNode] {
        let pattern = "<[a-zA-Z0-9]*:?href>([^<]+)</[a-zA-Z0-9]*:?href>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = regex.matches(in: xml, options: [], range: nsRange)

        var nodes: [VFSNode] = []
        for match in matches.dropFirst() { // 第一项通常是当前目录自身
            guard let r = Range(match.range(at: 1), in: xml) else { continue }
            let rawHref = String(xml[r]).removingPercentEncoding ?? String(xml[r])
            let isDir = rawHref.hasSuffix("/")
            let trimmed = rawHref.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let lastName = trimmed.split(separator: "/").last.map(String.init), !lastName.isEmpty else { continue }
            let fullPath = basePath == "/" ? "/\(lastName)" : "\(basePath)/\(lastName)"
            nodes.append(
                VFSNode(
                    sourceID: sourceID,
                    fileID: fullPath,
                    name: lastName,
                    path: fullPath,
                    kind: VFSNode.inferKind(from: lastName, isDirectory: isDir)
                )
            )
        }
        return nodes
    }
}

/// 统一构建入口：自动为网盘装配「方案 A (OpenAPI) -> 方案 B (扫码 Cookie)」双轨协调器，并完整覆盖 SMB / WebDAV / 小雅
public enum VFSDriverRegistry {
    public static func makeDualTrackCoordinator(
        for source: StorageSource,
        openAPIToken: String?,
        cookieHeader: String,
        basicUsername: String = ""
    ) -> DualTrackCloudDriveCoordinator {
        switch source.type {
        case .drive115:
            let driverA = (openAPIToken?.isEmpty == false)
                ? Drive115OpenAPISchemeADriver(source: source, accessToken: openAPIToken!)
                : nil
            let driverB = Drive115CookieSchemeBDriver(source: source, cookieHeader: cookieHeader)
            return DualTrackCloudDriveCoordinator(
                preferredTrack: source.authTrack,
                schemeADriver: driverA,
                schemeBDriver: driverB
            )

        case .baidu:
            let driverA = (openAPIToken?.isEmpty == false)
                ? BaiduPanOpenAPISchemeADriver(source: source, accessToken: openAPIToken!)
                : nil
            let driverB = BaiduPanCookieSchemeBDriver(source: source, cookieHeader: cookieHeader)
            return DualTrackCloudDriveCoordinator(
                preferredTrack: source.authTrack,
                schemeADriver: driverA,
                schemeBDriver: driverB
            )

        case .quark, .aliyun:
            let driverB = QuarkCookieSchemeBDriver(source: source, cookieHeader: cookieHeader)
            return DualTrackCloudDriveCoordinator(
                preferredTrack: source.authTrack,
                schemeADriver: nil,
                schemeBDriver: driverB
            )

        case .smb, .nfs:
            let smb = SMBStorageDriver(source: source, username: basicUsername, password: cookieHeader)
            return DualTrackCloudDriveCoordinator(
                preferredTrack: .basicCredential,
                schemeADriver: nil,
                schemeBDriver: smb
            )

        case .webdav:
            let dav = WebDAVStorageDriver(source: source, username: basicUsername, password: cookieHeader)
            return DualTrackCloudDriveCoordinator(
                preferredTrack: .basicCredential,
                schemeADriver: nil,
                schemeBDriver: dav
            )

        case .xiaoyaOpenList, .emby, .jellyfin:
            let xiaoya = XiaoyaOpenListDriver(source: source, apiToken: openAPIToken ?? cookieHeader)
            return DualTrackCloudDriveCoordinator(
                preferredTrack: .basicCredential,
                schemeADriver: nil,
                schemeBDriver: xiaoya
            )
        }
    }
}
