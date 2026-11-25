import Foundation

/// 海报 / 视频缓存统计与清理，以及已知的镜像建议。
struct CatalogArtworkStat: Identifiable, Hashable {
    var sourceID: UUID
    var bytes: Int64
    var files: Int
    var updatedAt: Date?

    var id: UUID { sourceID }
}

enum CatalogMaintenance {
    // MARK: - 海报缓存

    static func artworkStats() -> [CatalogArtworkStat] {
        CatalogDatabase.shared.artworkSummaries().map { summary in
            CatalogArtworkStat(sourceID: summary.sourceID,
                               bytes: summary.bytes,
                               files: summary.files,
                               updatedAt: summary.lastUsed)
        }
    }

    static func artworkTotalBytes() -> Int64 {
        artworkStats().reduce(0) { $0 + $1.bytes }
    }

    static func clearArtwork(sourceID: UUID?) {
        let fm = FileManager.default
        if let sourceID {
            try? fm.removeItem(at: CatalogPaths.artwork(scriptSourceID: sourceID))
            CatalogDatabase.shared.deleteArtwork(sourceID: sourceID)
        } else {
            try? fm.removeItem(at: CatalogPaths.root.appendingPathComponent("artwork", isDirectory: true))
            CatalogDatabase.shared.deleteAllArtwork()
        }
        CatalogArtworkMemory.shared.removeAll()
    }

    // MARK: - 视频缓存

    static func videoCacheBytes() -> Int64 {
        VideoCache.luma.totalSize()
    }

    static func clearVideoCache() {
        VideoCache.luma.clear()
    }

    // MARK: - 镜像

    private static let mirrors: [String: String] = [
        "missav.ws": "https://missav.live",
        "missav.ai": "https://missav.live",
        "missav.com": "https://missav.live",
        "missav.vip": "https://missav.live",
        "avple.tv": "https://avple.app"
    ]

    static func mirrorURL(for source: CatalogSource) -> URL? {
        guard let host = URLComponents(string: source.baseURL)?.host?.lowercased(),
              let mirror = mirrors[host] else { return nil }
        return URL(string: mirror)
    }

    static func mirrorSuggestion(for source: CatalogSource) -> String? {
        guard let url = mirrorURL(for: source) else { return nil }
        return "当前域名可能被拦截，建议切换到 \(url.absoluteString)"
    }

    /// 把源切到建议的镜像地址，保留其它配置。
    static func source(_ source: CatalogSource, using mirror: URL) -> CatalogSource {
        var copy = source
        copy.baseURL = mirror.absoluteString
        copy.referer = mirror.absoluteString + "/"
        return copy
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
