import Foundation
import NanoCore

/// 虚拟文件节点类型
public enum VFSItemKind: String, Codable, Sendable {
    case folder
    case video
    case audio
    case subtitle
    case metadataNFO
    case cueSheet
    case other
}

/// 统一虚拟文件/目录节点
public struct VFSNode: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var sourceID: UUID
    public var fileID: String        // 网盘 fid / fs_id / pick_code
    public var name: String
    public var path: String
    public var kind: VFSItemKind
    public var sizeBytes: Int64
    public var modifiedAt: Date?
    public var thumbnailURL: String?

    public init(
        id: String = UUID().uuidString,
        sourceID: UUID,
        fileID: String,
        name: String,
        path: String,
        kind: VFSItemKind,
        sizeBytes: Int64 = 0,
        modifiedAt: Date? = nil,
        thumbnailURL: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.fileID = fileID
        self.name = name
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.thumbnailURL = thumbnailURL
    }

    public static func inferKind(from fileName: String, isDirectory: Bool) -> VFSItemKind {
        if isDirectory { return .folder }
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mkv", "avi", "mov", "ts", "m2ts", "iso", "rmvb", "wmv", "flv", "webm":
            return .video
        case "flac", "ape", "wav", "alac", "m4a", "mp3", "aac", "dsf", "dff", "ogg":
            return .audio
        case "ass", "ssa", "srt", "vtt", "sup", "sub":
            return .subtitle
        case "nfo":
            return .metadataNFO
        case "cue":
            return .cueSheet
        default:
            return .other
        }
    }
}

/// 扫码授权会话（兼容方案 A OAuth 设备码扫码 与 方案 B Web/TV 客户端扫码）
public struct CloudQRAuthSession: Sendable {
    public let sessionID: String
    public let qrCodeContentOrURL: String
    public let userCodeHint: String? // 方案 A 设备码提示（如百度开放平台 user_code）
    public let resolvedTrack: CloudAuthTrack
    public let expiresInSec: Int

    public init(
        sessionID: String,
        qrCodeContentOrURL: String,
        userCodeHint: String? = nil,
        resolvedTrack: CloudAuthTrack,
        expiresInSec: Int = 300
    ) {
        self.sessionID = sessionID
        self.qrCodeContentOrURL = qrCodeContentOrURL
        self.userCodeHint = userCodeHint
        self.resolvedTrack = resolvedTrack
        self.expiresInSec = expiresInSec
    }
}

public enum CloudQRPollState: Sendable {
    case waitingScan
    case scannedPendingConfirm
    case authorized(credentialPayload: String, resolvedTrack: CloudAuthTrack)
    case expiredOrFailed(reason: String)
}

public enum VFSError: LocalizedError, Sendable {
    case schemeAUnsupportedFallbackRequired(String)
    case unauthorized(String)
    case networkFailure(String)
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .schemeAUnsupportedFallbackRequired(let msg): return "方案 A 不可用，切换方案 B: \(msg)"
        case .unauthorized(let msg): return "存储源鉴权失效: \(msg)"
        case .networkFailure(let msg): return "存储网络请求异常: \(msg)"
        case .fileNotFound(let msg): return "未找到目标媒体文件: \(msg)"
        }
    }
}

/// 统一虚拟文件系统驱动协议
public protocol VirtualFileSystemDriver: Sendable {
    var source: StorageSource { get }
    func listDirectory(at path: String, parentFileID: String?) async throws -> [VFSNode]
    func searchFiles(keyword: String) async throws -> [VFSNode]
    func resolvePlayableTicket(for node: VFSNode) async throws -> PlayableStreamTicket
}

/// 网盘双轨协调器：严格执行「优先尝试方案 A (OpenAPI)，不支持或受限时自动降级至方案 B (扫码 Cookie + 本地流代理)」
public actor DualTrackCloudDriveCoordinator {
    private let schemeADriver: (any VirtualFileSystemDriver)?
    private let schemeBDriver: any VirtualFileSystemDriver
    private(set) public var activeTrack: CloudAuthTrack

    public init(
        preferredTrack: CloudAuthTrack,
        schemeADriver: (any VirtualFileSystemDriver)?,
        schemeBDriver: any VirtualFileSystemDriver
    ) {
        self.schemeADriver = schemeADriver
        self.schemeBDriver = schemeBDriver
        if preferredTrack == .cookieSchemeB || schemeADriver == nil {
            self.activeTrack = .cookieSchemeB
        } else {
            self.activeTrack = .openAPISchemeA
        }
    }

    public func listDirectory(at path: String, parentFileID: String? = nil) async throws -> [VFSNode] {
        if activeTrack == .openAPISchemeA, let driverA = schemeADriver {
            do {
                return try await driverA.listDirectory(at: path, parentFileID: parentFileID)
            } catch {
                // 方案 A 受限或失效，自动无缝降级至方案 B
                self.activeTrack = .cookieSchemeB
                return try await schemeBDriver.listDirectory(at: path, parentFileID: parentFileID)
            }
        }
        return try await schemeBDriver.listDirectory(at: path, parentFileID: parentFileID)
    }

    public func resolvePlayableTicket(for node: VFSNode) async throws -> PlayableStreamTicket {
        if activeTrack == .openAPISchemeA, let driverA = schemeADriver {
            do {
                return try await driverA.resolvePlayableTicket(for: node)
            } catch {
                // 例如部分网盘 OpenAPI 对原画/大码率直链限制，自动回退方案 B 原画代理直链
                self.activeTrack = .cookieSchemeB
                return try await schemeBDriver.resolvePlayableTicket(for: node)
            }
        }
        return try await schemeBDriver.resolvePlayableTicket(for: node)
    }
}
