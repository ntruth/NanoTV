import Foundation

// MARK: - 1. Infuse Pro 同片多版本切换 (Multi-Version Editions) 与系列电影合集 (Collections)

/// 同一部电影在不同存储源或不同清晰度下的版本实例（如 `[115网盘 · 4K DV REMUX]` vs `[群晖NAS · 1080P]`）
public struct MediaEditionVariant: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var mediaID: UUID
    public var sourceID: UUID
    public var sourceName: String
    public var editionLabel: String     // e.g. "4K Dolby Vision · REMUX" / "导演剪辑版 · 1080P"
    public var vfsPath: String
    public var fileSizeBytes: Int64
    public var spec: VideoTechnicalSpec

    public init(
        id: UUID = UUID(),
        mediaID: UUID,
        sourceID: UUID,
        sourceName: String,
        editionLabel: String,
        vfsPath: String,
        fileSizeBytes: Int64 = 0,
        spec: VideoTechnicalSpec = VideoTechnicalSpec()
    ) {
        self.id = id
        self.mediaID = mediaID
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.editionLabel = editionLabel
        self.vfsPath = vfsPath
        self.fileSizeBytes = fileSizeBytes
        self.spec = spec
    }
}

/// TMDB 系列电影合集模型（例如《沙丘系列合集》、《漫威宇宙合集》）
public struct MediaCollectionGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var tmdbCollectionID: Int?
    public var title: String
    public var overview: String
    public var posterURL: String?
    public var memberMediaIDs: [UUID]

    public init(
        id: UUID = UUID(),
        tmdbCollectionID: Int? = nil,
        title: String,
        overview: String = "",
        posterURL: String? = nil,
        memberMediaIDs: [UUID] = []
    ) {
        self.id = id
        self.tmdbCollectionID = tmdbCollectionID
        self.title = title
        self.overview = overview
        self.posterURL = posterURL
        self.memberMediaIDs = memberMediaIDs
    }
}

// MARK: - 2. Infuse Pro 次世代音视频调校参数枚举

/// 画面比例与宽银幕黑边裁剪模式
public enum VideoAspectCropMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case originalFit = "原始比例"
    case fillScreen = "铺满全屏 (去黑边)"
    case anamorphic239 = "2.39:1 宽银幕"
    case classic4x3 = "4:3 经典比例"

    public var id: String { rawValue }
}

/// 音频动态增强模式（拯救原盘人声过小与夜间轰头）
public enum AudioDSPMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case passthrough = "原声直通"
    case dialogueClarity = "人声对白增强"
    case lateNightDRC = "夜间防扰民模式"

    public var id: String { rawValue }
}

/// HDR -> SDR 色调映射算法曲线
public enum HDRToneMappingCurve: String, CaseIterable, Identifiable, Codable, Sendable {
    case bt2390 = "ITU BT.2390 (标准推荐)"
    case hable = "Hable (保留暗部细节)"
    case mobius = "Mobius (高光自然过渡)"

    public var id: String { rawValue }

    public var mpvOptionValue: String {
        switch self {
        case .bt2390: return "bt.2390"
        case .hable: return "hable"
        case .mobius: return "mobius"
        }
    }
}

/// 影片章节书签点（支持片头、高能片段快速跳章与 A-B 循环）
public struct MediaChapterPoint: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let timestampSec: Double

    public init(id: UUID = UUID(), title: String, timestampSec: Double) {
        self.id = id
        self.title = title
        self.timestampSec = timestampSec
    }
}

// MARK: - 3. 家庭儿童分级家长控制策略 (Parental Controls)

public enum ContentRatingTier: Int, CaseIterable, Identifiable, Codable, Comparable, Sendable {
    case gAllAges = 0       // G：全年龄段适宜
    case pg = 1             // PG：建议家长指导
    case pg13 = 2           // PG-13：13岁以上适宜
    case rRestricted = 3    // R / 18+：成人限制级（触发家长锁 PIN 验证）

    public var id: Int { rawValue }

    public var displayBadge: String {
        switch self {
        case .gAllAges: return "G (全年龄)"
        case .pg: return "PG (温和)"
        case .pg13: return "PG-13 (青少年)"
        case .rRestricted: return "R (限制级)"
        }
    }

    public static func < (lhs: ContentRatingTier, rhs: ContentRatingTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
