import Foundation
import NanoCore
#if canImport(AMSMB2)
import AMSMB2
#endif

/// SMB 2/3 与本地挂载共享存储驱动
/// - 开启 `NANO_USE_VENDOR_LIBS=1` 时自动通过 `AMSMB2` 原生协议栈直连 NAS（支持 macOS & Apple TV）；
/// - 默认零外部依赖模式下，支持直连 macOS `/Volumes/...` 挂载共享目录或本地媒体目录。
public struct SMBStorageDriver: VirtualFileSystemDriver {
    public let source: StorageSource
    public let username: String
    public let password: String

    public init(source: StorageSource, username: String = "guest", password: String = "") {
        self.source = source
        self.username = username
        self.password = password
    }

    public func listDirectory(at path: String, parentFileID: String?) async throws -> [VFSNode] {
        #if canImport(AMSMB2)
        if source.endpointURL.lowercased().hasPrefix("smb://"), let serverURL = URL(string: source.endpointURL) {
            let shareName = serverURL.pathComponents.dropFirst().first ?? ""
            let baseServerURL = URL(string: "\(serverURL.scheme ?? "smb")://\(serverURL.host ?? "")")!
            let credential = URLCredential(user: username, password: password, persistence: .forSession)
            guard let client = AMSMB2(url: baseServerURL, credential: credential) else {
                throw VFSError.networkFailure("无法初始化 SMB 客户端连接")
            }
            try await connectShare(client: client, shareName: shareName)
            let subPath = path == "/" ? "" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let items = try await listSMBContents(client: client, path: subPath)
            return items.compactMap { attrs in
                guard let name = attrs[.nameKey] as? String, !name.hasPrefix(".") else { return nil }
                let resourceType = attrs[.fileResourceTypeKey] as? URLFileResourceType
                let isDir = (resourceType == .directory)
                let size = Int64((attrs[.fileSizeKey] as? Int) ?? 0)
                let modDate = attrs[.contentModificationDateKey] as? Date
                let fullPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
                return VFSNode(
                    sourceID: source.id,
                    fileID: fullPath,
                    name: name,
                    path: fullPath,
                    kind: VFSNode.inferKind(from: name, isDirectory: isDir),
                    sizeBytes: size,
                    modifiedAt: modDate
                )
            }
        }
        #endif

        // 本地目录或 macOS /Volumes 已挂载 SMB 路径读取
        let localRoot = resolveLocalMountRoot()
        let cleanRel = path == "/" ? "" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let dirURL = cleanRel.isEmpty ? localRoot : localRoot.appendingPathComponent(cleanRel, isDirectory: true)

        guard FileManager.default.fileExists(atPath: dirURL.path) else {
            return []
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let contents = try FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        return contents.map { itemURL in
            let vals = try? itemURL.resourceValues(forKeys: Set(keys))
            let isDir = vals?.isDirectory ?? false
            let size = Int64(vals?.fileSize ?? 0)
            let name = itemURL.lastPathComponent
            let fullPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            return VFSNode(
                sourceID: source.id,
                fileID: fullPath,
                name: name,
                path: fullPath,
                kind: VFSNode.inferKind(from: name, isDirectory: isDir),
                sizeBytes: size,
                modifiedAt: vals?.contentModificationDate
            )
        }
        .sorted { lhs, rhs in
            if lhs.kind == .folder && rhs.kind != .folder { return true }
            if lhs.kind != .folder && rhs.kind == .folder { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func searchFiles(keyword: String) async throws -> [VFSNode] {
        let topItems = try await listDirectory(at: source.rootPath, parentFileID: nil)
        return topItems.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    public func resolvePlayableTicket(for node: VFSNode) async throws -> PlayableStreamTicket {
        #if canImport(AMSMB2)
        if source.endpointURL.lowercased().hasPrefix("smb://"), let base = URL(string: source.endpointURL) {
            // 暂存流式缓存或转交 MPV 原生 smb:// 协议打开
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            if !username.isEmpty {
                comps?.user = username
                comps?.password = password
            }
            let baseWithAuth = comps?.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? source.endpointURL
            let encoded = node.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node.path
            if let smbURL = URL(string: "\(baseWithAuth)\(encoded)") {
                return PlayableStreamTicket(title: node.name, subtitle: source.name, streamURL: smbURL)
            }
        }
        #endif

        let localRoot = resolveLocalMountRoot()
        let cleanRel = node.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL = localRoot.appendingPathComponent(cleanRel)
        return PlayableStreamTicket(title: node.name, subtitle: source.name, streamURL: fileURL)
    }

    private func resolveLocalMountRoot() -> URL {
        if source.endpointURL.hasPrefix("file://"), let u = URL(string: source.endpointURL) {
            return u
        }
        if source.endpointURL.hasPrefix("/") {
            return URL(fileURLWithPath: source.endpointURL)
        }
        // 将 smb://DiskStation/Movies_4K 映射至 macOS 标准挂载点 /Volumes/Movies_4K
        if let u = URL(string: source.endpointURL), let share = u.pathComponents.dropFirst().first {
            return URL(fileURLWithPath: "/Volumes/\(share)")
        }
        return URL(fileURLWithPath: "/Volumes")
    }

    #if canImport(AMSMB2)
    private func connectShare(client: AMSMB2, shareName: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            client.connectShare(name: shareName) { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    private func listSMBContents(client: AMSMB2, path: String) async throws -> [[URLResourceKey: Any]] {
        try await withCheckedThrowingContinuation { cont in
            client.contentsOfDirectory(atPath: path) { result in
                cont.resume(with: result)
            }
        }
    }
    #endif
}
