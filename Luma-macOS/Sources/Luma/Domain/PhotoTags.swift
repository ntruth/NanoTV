import Foundation

/// 一个端侧识别标签：中文标准名、去重分组、检索别名与命中阈值。
struct PhotoTagDefinition: Decodable {
    let id: String
    let title: String
    let group: String
    let prompts: [String]
    let aliases: [String]
    let threshold: Double
}

/// 端侧标签目录（`Resources/Models/SigLIP2/tags.json`）。
/// 标准名唯一，分组用于互斥去重：同一组只保留得分最高的若干个，避免「猫 / 狗 / 动物」叠在一起。
final class PhotoTagCatalog: Decodable {
    let version: Int
    let embeddingDim: Int
    let defaultThreshold: Double
    let groupLimits: [String: Int]
    let tags: [PhotoTagDefinition]

    /// 分析结果里的版本标记：旧分析结果没有它，会按需重扫。
    static let sentinel = "siglip2"

    private let orderIndex: [String: Int]
    private let aliasEntries: [(alias: String, title: String)]

    private static let sharedLock = NSLock()
    private static var cached: PhotoTagCatalog?
    private static var loaded = false

    /// 词表随模型一起安装，所以不能只做一次性静态缓存：模型后装也要能读到。
    static var shared: PhotoTagCatalog? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if !loaded {
            cached = load()
            loaded = true
        }
        return cached
    }

    /// 模型重新安装后调用，下一次读取会重新加载 tags.json。
    static func invalidateShared() {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        cached = nil
        loaded = false
    }

    private enum CodingKeys: String, CodingKey {
        case version, embeddingDim, defaultThreshold, groupLimits, tags
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        embeddingDim = try container.decodeIfPresent(Int.self, forKey: .embeddingDim) ?? 768
        defaultThreshold = try container.decodeIfPresent(Double.self, forKey: .defaultThreshold) ?? 0.08
        groupLimits = try container.decodeIfPresent([String: Int].self, forKey: .groupLimits) ?? [:]
        tags = try container.decode([PhotoTagDefinition].self, forKey: .tags)
        var order: [String: Int] = [:]
        var aliases: [(String, String)] = []
        for (index, tag) in tags.enumerated() {
            order[tag.title] = index
            aliases.append((tag.title.lowercased(), tag.title))
            for alias in tag.aliases where !alias.isEmpty {
                aliases.append((alias.lowercased(), tag.title))
            }
        }
        orderIndex = order
        aliasEntries = aliases
    }

    private static func load() -> PhotoTagCatalog? {
        guard let url = LumaModelResources.file("SigLIP2/tags.json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(PhotoTagCatalog.self, from: data),
              !catalog.tags.isEmpty else { return nil }
        return catalog
    }

    /// 按目录顺序整理已命中的标签，过滤掉版本标记与未知标签。
    func canonicalTitles(from labels: Set<String>) -> [String] {
        labels
            .filter { orderIndex[$0] != nil }
            .sorted { (orderIndex[$0] ?? 0) < (orderIndex[$1] ?? 0) }
    }

    /// 检索词命中：先精确匹配别名，再允许「查询包含别名 / 别名包含查询」。
    func searchTitles(for token: String) -> [String] {
        let query = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var seen: Set<String> = []
        var hits: [String] = []
        for entry in aliasEntries {
            let value = entry.alias
            let matched: Bool
            if value == query {
                matched = true
            } else if query.count >= 3, value.count >= 2 {
                // 「海边日落」包含「海边」；单字查询只做精确匹配，避免「手」命中「手机」。
                matched = query.contains(value)
            } else if value.count >= 3, query.count >= 3 {
                matched = value.contains(query)
            } else {
                matched = false
            }
            guard matched, seen.insert(entry.title).inserted else { continue }
            hits.append(entry.title)
            if hits.count >= 8 { break }
        }
        return hits
    }

    func definition(for title: String) -> PhotoTagDefinition? {
        guard let index = orderIndex[title] else { return nil }
        return tags[index]
    }
}

// 模型资源定位已迁到 `Services/Models/ModelRegistry.swift`，
// 统一处理「下载目录 → App 包内 → 开发源码目录」的解析顺序。
