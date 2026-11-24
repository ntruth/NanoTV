import Foundation
import NanoCore

/// 小雅 / AList / OpenList V3 原生 API 驱动（免全量扫库，支持 302 直链穿透与全局秒搜）
public struct XiaoyaOpenListDriver: VirtualFileSystemDriver {
    public let source: StorageSource
    public let apiToken: String?

    public init(source: StorageSource, apiToken: String? = nil) {
        self.source = source
        self.apiToken = apiToken
    }

    private var baseEndpoint: String {
        source.endpointURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public func listDirectory(at path: String, parentFileID: String?) async throws -> [VFSNode] {
        guard let url = URL(string: "\(baseEndpoint)/api/fs/list") else {
            throw VFSError.networkFailure("无效的小雅/OpenList 地址")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = apiToken, !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "path": path.isEmpty ? "/" : path,
            "page": 1,
            "per_page": 200,
            "refresh": false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let contentList = dataObj["content"] as? [[String: Any]] else {
            return []
        }

        let cleanParent = path == "/" ? "" : path
        return contentList.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let isDir = (item["is_dir"] as? Bool) ?? false
            let size = (item["size"] as? Int64) ?? Int64((item["size"] as? Int) ?? 0)
            let thumb = item["thumb"] as? String
            let fullPath = "\(cleanParent)/\(name)"
            return VFSNode(
                sourceID: source.id,
                fileID: fullPath,
                name: name,
                path: fullPath,
                kind: VFSNode.inferKind(from: name, isDirectory: isDir),
                sizeBytes: size,
                thumbnailURL: (thumb?.isEmpty == false) ? thumb : nil
            )
        }
    }

    public func searchFiles(keyword: String) async throws -> [VFSNode] {
        guard let url = URL(string: "\(baseEndpoint)/api/fs/search") else {
            throw VFSError.networkFailure("无效的小雅搜索接口地址")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = apiToken, !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "parent": source.rootPath.isEmpty ? "/" : source.rootPath,
            "keywords": keyword,
            "scope": 0,
            "page": 1,
            "per_page": 100
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let contentList = dataObj["content"] as? [[String: Any]] else {
            return []
        }

        return contentList.compactMap { item in
            guard let parent = item["parent"] as? String,
                  let name = item["name"] as? String else { return nil }
            let isDir = (item["is_dir"] as? Bool) ?? false
            let size = (item["size"] as? Int64) ?? 0
            let cleanParent = parent == "/" ? "" : parent
            let fullPath = "\(cleanParent)/\(name)"
            return VFSNode(
                sourceID: source.id,
                fileID: fullPath,
                name: name,
                path: fullPath,
                kind: VFSNode.inferKind(from: name, isDirectory: isDir),
                sizeBytes: size
            )
        }
    }

    public func resolvePlayableTicket(for node: VFSNode) async throws -> PlayableStreamTicket {
        guard let url = URL(string: "\(baseEndpoint)/api/fs/get") else {
            throw VFSError.networkFailure("无效的小雅详情接口地址")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = apiToken, !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["path": node.path])

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let rawURLString = dataObj["raw_url"] as? String,
              let rawURL = URL(string: rawURLString) else {
            throw VFSError.fileNotFound("无法解析小雅 302 直链 raw_url")
        }

        // 解析 OpenList 返回的可选自定义请求头（例如直通夸克/阿里/115所需的 UA）
        var headers: [String: String] = [:]
        if let headerObj = dataObj["header"] as? [String: [String]] {
            for (k, arr) in headerObj {
                if let first = arr.first { headers[k] = first }
            }
        }

        return PlayableStreamTicket(
            title: node.name,
            subtitle: source.name,
            streamURL: rawURL,
            headers: headers,
            isLiveStream: false
        )
    }
}
