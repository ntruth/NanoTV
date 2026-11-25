import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import AVFoundation
import Network
import NetFS

enum CloudKind: String, Codable {
    case webdav
    case smb
    case aliyun
    case baidu
    case quark
    case pan115

    var title: String {
        switch self {
        case .webdav: return "WebDAV"
        case .smb: return "SMB 共享"
        case .aliyun: return "阿里云盘"
        case .baidu: return "百度网盘"
        case .quark: return "夸克网盘"
        case .pan115: return "115 网盘"
        }
    }

    /// 只有 WebDAV 允许写入；SMB 与官方网盘均为只读。
    var supportsWrite: Bool { self == .webdav }

    /// 是否支持在向导里选择接入范围与排除目录（Cookie 模式、SMB 与百度 OAuth）。
    var supportsAccessScope: Bool {
        self == .smb || self == .aliyun || self == .quark || self == .pan115 || self == .baidu
    }

    /// 需要 OAuth 令牌的官方网盘（夸克使用浏览器 Cookie）。
    var usesOAuth: Bool { self == .aliyun || self == .baidu }

    /// 侧边栏与确认卡片共用的图标。
    var symbolName: String {
        switch self {
        case .webdav: return "externaldrive.connected.to.line.below"
        case .smb: return "network"
        case .aliyun: return "cloud"
        case .baidu: return "cloud.fill"
        case .quark: return "square.stack.3d.up.fill"
        case .pan115: return "externaldrive.fill"
        }
    }

    /// 官方网盘的品牌图标；WebDAV / SMB 没有对应产品。
    var brand: CloudBrand? {
        switch self {
        case .webdav, .smb: return nil
        case .aliyun: return .aliyun
        case .baidu: return .baidu
        case .quark: return .quark
        case .pan115: return .pan115
        }
    }

    /// 重新连接时走的向导流程。
    var wizardFlow: CloudWizardFlow {
        switch self {
        case .webdav: return .webdav
        case .smb: return .smb
        case .aliyun: return .aliyunCookie
        case .baidu: return .baidu
        case .quark: return .quark
        case .pan115: return .pan115
        }
    }

    /// 根据用户输入的地址推断接入类型。
    static func detect(from address: String) -> CloudKind? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("smb://") ? .smb : nil
    }
}

/// 网盘账号的鉴权方式：官方 OAuth 或浏览器 Cookie / 令牌。
enum CloudAuthMode: String, Codable {
    case oauth
    case cookie
}

/// 面包屑节点。WebDAV 用相对路径，阿里云盘用 file_id，百度网盘用绝对路径。
struct CloudCrumb: Identifiable, Hashable {
    let id: String
    let name: String
}

/// 接入范围里的一个目录（Cookie 模式可在向导里多选）。
struct CloudScopeRoot: Codable, Hashable, Identifiable {
    var path: String
    var name: String

    var id: String { path }
}

/// 向导里的目录勾选：额外记录当前浏览路径上的祖先，便于多选时去重。
struct CloudScopePick: Identifiable, Hashable {
    var root: CloudScopeRoot
    var ancestors: [String]

    var id: String { root.path }
}

/// 一个网络存储挂载点。
struct CloudMount: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: CloudKind = .webdav
    var name: String
    var baseURL: String = ""
    var username: String = ""
    var remoteDriveID: String?
    var createdAt: Date = Date()
    var lastPath: String = ""
    /// SMB 专用：是否递归扫描整个共享，而不是按文件夹浏览。
    var scanAll: Bool = false
    /// WebDAV 专用：是否信任自签名证书（常见于 NAS 的 HTTPS 端口）。
    var trustSelfSigned: Bool = false
    /// 鉴权方式：默认官方 OAuth；Cookie 模式不需要开发者应用。
    var authMode: CloudAuthMode = .oauth
    /// 接入范围：为空表示整个网盘；否则只扫描这些目录（Cookie 模式与 SMB 共用）。
    var scopeRoots: [CloudScopeRoot] = []
    /// 排除目录：始终跳过这些目录（及其子目录）。
    var excludedRoots: [CloudScopeRoot] = []

    init(id: UUID = UUID(), kind: CloudKind = .webdav, name: String,
         baseURL: String = "", username: String = "", remoteDriveID: String? = nil,
         createdAt: Date = Date(), lastPath: String = "", scanAll: Bool = false,
         trustSelfSigned: Bool = false, authMode: CloudAuthMode = .oauth,
         scopeRoots: [CloudScopeRoot] = [],
         excludedRoots: [CloudScopeRoot] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.remoteDriveID = remoteDriveID
        self.createdAt = createdAt
        self.lastPath = lastPath
        self.scanAll = scanAll
        self.trustSelfSigned = trustSelfSigned
        self.authMode = authMode
        self.scopeRoots = scopeRoots
        self.excludedRoots = excludedRoots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? container.decodeIfPresent(CloudKind.self, forKey: .kind)) ?? .webdav
        name = (try? container.decode(String.self, forKey: .name)) ?? "网络存储"
        baseURL = (try? container.decode(String.self, forKey: .baseURL)) ?? ""
        username = (try? container.decode(String.self, forKey: .username)) ?? ""
        remoteDriveID = try? container.decodeIfPresent(String.self, forKey: .remoteDriveID)
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        lastPath = (try? container.decode(String.self, forKey: .lastPath)) ?? ""
        scanAll = (try? container.decodeIfPresent(Bool.self, forKey: .scanAll)) ?? false
        trustSelfSigned = (try? container.decodeIfPresent(Bool.self, forKey: .trustSelfSigned)) ?? false
        authMode = (try? container.decodeIfPresent(CloudAuthMode.self, forKey: .authMode)) ?? .oauth
        scopeRoots = (try? container.decodeIfPresent([CloudScopeRoot].self, forKey: .scopeRoots)) ?? []
        excludedRoots = (try? container.decodeIfPresent([CloudScopeRoot].self, forKey: .excludedRoots)) ?? []
    }
}

/// 云端重命名 / 新建文件夹的输入请求。
struct CloudNameRequest: Identifiable {
    enum Mode {
        case rename(photoID: UUID, current: String)
        case newFolder
    }

    let id = UUID()
    let mode: Mode

    var title: String {
        switch mode {
        case .rename: return "重命名云端项目"
        case .newFolder: return "新建文件夹"
        }
    }

    var actionTitle: String {
        switch mode {
        case .rename: return "重命名"
        case .newFolder: return "创建"
        }
    }

    var initialText: String {
        switch mode {
        case .rename(_, let current): return current
        case .newFolder: return ""
        }
    }

    var isRename: Bool {
        if case .rename = mode { return true }
        return false
    }
}

/// 网盘全盘扫描状态。
enum CloudScanPhase: Equatable {
    case idle
    case scanning
    case finished(Date)
    case cancelled
    case failed(String)

    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }
}

/// 扫描到的目录：在侧边栏里映射成相簿（文件夹 = 相簿）。
struct CloudScanFolder: Codable, Hashable, Identifiable {
    var path: String
    var name: String
    var parentPath: String
    /// 扫描时父目录列表返回的修改时间：下一轮增量扫描据此判断子树是否变化。
    var modifiedAt: Date? = nil

    var id: String { path }
}

/// 侧边栏「相簿」里的一层文件夹节点：带聚合数量与封面（取最新一张）。
struct CloudFolderNode: Identifiable {
    var path: String
    var name: String
    var parentPath: String
    var photoCount: Int
    var cover: PhotoItem?
    var children: [CloudFolderNode]

    var id: String { path }
}

/// 全盘扫描快照里的一条媒体记录：只存轻量字段，恢复时再换算成 `PhotoItem`。
struct CloudScanRecord: Codable {
    var path: String
    var name: String
    var size: Int64
    var modifiedAt: Date?
    var width: Int?
    var height: Int?
    var duration: Double?
    var remoteID: String?
    var thumbnailURL: String?
    var isVideo: Bool
    /// 所属目录（用于恢复后按文件夹相簿筛选）。
    var folderPath: String?
    /// 视频编码（Aliyun list 自带），恢复快照后转封装仍能写对 hvc1 标签。
    var codec: String?
    /// EXIF 拍摄时间：与远端修改时间分开保存，恢复后时间轴不会被「最近保存」覆盖。
    var capturedAt: Date? = nil
    /// 加入 / 保存时间（远端修改时间）。
    var addedAt: Date? = nil
}

/// 某个网盘挂载的全盘扫描结果（落当前图库的 `derived_reports`，重开即可先显示）。
struct CloudScanSnapshot: Codable {
    var savedAt: Date
    var folderCount: Int
    var truncated: Bool
    var records: [CloudScanRecord]
    var folders: [CloudScanFolder]?
    /// 上一轮是否完整扫完（未触顶、无目录失败、未取消）：只有完整快照才能用于增量扫描。
    var complete: Bool? = nil
    /// 路径语义版本：老版本 WebDAV 子目录条目只存文件名，快照需要作废重扫。
    var pathVersion: Int? = nil
    /// 接入范围签名（选中的目录路径集合）：范围变化后旧快照不能再用。
    var scopeSignature: String? = nil
}

/// WebDAV 目录中的一项。
struct CloudEntry: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?
    let contentType: String?

    var id: String { path }

    /// 服务端缩略图地址（阿里云盘 / 百度网盘提供）。
    var thumbnailURL: String?
    /// 服务端文件 ID（百度网盘用 fs_id 取直链）。
    var remoteID: String?
    /// 服务端返回的媒体尺寸与时长（阿里云盘提供）。
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: Double?
    /// 服务端标记为受限内容（夸克 risk_type ≠ 0 / ban）：播放与下载接口都会拒绝。
    var isRestricted = false
    /// 服务端给出的视频编码（如 hevc）：转封装时需要据此写 hvc1 标签。
    var codecName: String?

    var isVideo: Bool {
        if let contentType, contentType.lowercased().hasPrefix("video/") { return true }
        if let type = UTType(filenameExtension: (name as NSString).pathExtension.lowercased()),
           type.conforms(to: .movie) {
            return true
        }
        return VideoFormats.isVideo(URL(fileURLWithPath: name))
    }

    var isMedia: Bool {
        if isDirectory { return false }
        if let contentType {
            let lower = contentType.lowercased()
            if lower.hasPrefix("image/") || lower.hasPrefix("video/") { return true }
        }
        return ImportService.isSupported(URL(fileURLWithPath: name))
            || VideoFormats.isVideo(URL(fileURLWithPath: name))
    }
}

struct CloudStreamResource {
    let url: URL
    let headers: [String: String]
    /// 官方转码返回的 HLS 播放列表：交给 AVPlayer 直接播放，不能再走 ffmpeg 的按字节读取。
    var isHLS = false
}

struct CloudThumbnailResult {
    let image: NSImage?
    let size: CGSize?
    let duration: Double?
}
