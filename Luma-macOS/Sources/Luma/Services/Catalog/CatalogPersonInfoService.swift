import Foundation

// MARK: - 模型

/// 人物资料里的一条字段（出生、身高、事务所…）。
struct CatalogPersonFact: Codable, Hashable, Identifiable {
    var label: String
    var value: String
    var id: String { "\(label)|\(value)" }
}

/// 内置资料库里的一个人物 / 片商档案。
struct CatalogPersonInfo: Codable, Hashable {
    var name: String
    var role: String
    var summary: String
    /// 一句话描述（例如「日本女优」「中国大陆模特」）。
    var description: String?
    var imageURL: String?
    /// 数据库内置的头像（96×96 JPEG base64），优先于外链。
    var avatarBase64: String?
    var facts: [CatalogPersonFact]
    var sourceTitle: String
    var sourceURL: String?
    var provider: String
    var fetchedAt: Date
}

// MARK: - 取资料

/// 人物 / 片商档案：全部来自内置的 `Resources/Catalog/catalog.sqlite`，不再联网检索。
/// 打开档案时只做一次内存索引查找，字段一次给全。
@MainActor
final class CatalogPersonInfoService {
    static let shared = CatalogPersonInfoService()

    struct Fetch {
        var info: CatalogPersonInfo
        var image: Data?
        var fromCache: Bool
    }

    func cached(name: String, role: String) -> Fetch? {
        guard let info = localInfo(name: name, role: role) else { return nil }
        return Fetch(info: info, image: nil, fromCache: true)
    }

    /// 保留异步签名，方便界面继续用 `.task`；实际只查本地库。
    func fetch(name: String, role: String) async -> Fetch? {
        cached(name: name, role: role)
    }

    // MARK: 内置资料库

    private func localInfo(name: String, role: String) -> CatalogPersonInfo? {
        if role.contains("片商") || role.lowercased().contains("studio") {
            guard let studio = CatalogNameDictionary.studio(matching: name) else { return nil }
            var facts: [CatalogPersonFact] = [
                CatalogPersonFact(label: "类型", value: studio.kindTitle),
                CatalogPersonFact(label: "地区", value: studio.regionTitle)
            ]
            if let en = nonEmpty(studio.nameEN), en != studio.name {
                facts.append(CatalogPersonFact(label: "英文名", value: en))
            }
            let workUnit = studio.kind == "photo" ? "套" : "部"
            if let works = studio.workCount, works > 0 {
                facts.append(CatalogPersonFact(label: "收录", value: "\(works) \(workUnit)"))
            }
            let others = studio.aliases.filter {
                CatalogNameParser.normalize($0) != CatalogNameParser.normalize(studio.name)
            }
            if !others.isEmpty {
                facts.append(CatalogPersonFact(label: "别名",
                                               value: others.prefix(4).joined(separator: "、")))
            }
            if let website = nonEmpty(studio.website) {
                facts.append(CatalogPersonFact(label: "官网", value: website))
            }
            let summary = nonEmpty(studio.summary)
            // 没有现成简介时，用库里已有的字段拼一段，而不是只给一句「收录了某片商」。
            var parts: [String] = ["\(studio.regionTitle)\(studio.kindTitle)"]
            if let works = studio.workCount, works > 0 {
                parts.append("收录 \(works) \(workUnit)作品")
            }
            if !others.isEmpty { parts.append("别名 \(others.prefix(3).joined(separator: "、"))") }
            return CatalogPersonInfo(name: studio.name, role: role,
                                     summary: summary ?? parts.joined(separator: " · "),
                                     description: "\(studio.regionTitle)\(studio.kindTitle)",
                                     imageURL: studio.imageURL,
                                     avatarBase64: studio.avatarBase64,
                                     facts: facts,
                                     sourceTitle: studio.name,
                                     sourceURL: studio.sourceURL,
                                     provider: "内置资料库",
                                     fetchedAt: Date())
        }

        guard let actress = CatalogNameDictionary.actress(matching: name) else { return nil }
        var facts: [CatalogPersonFact] = [
            CatalogPersonFact(label: "地区", value: actress.regionTitle)
        ]
        if let ja = nonEmpty(actress.nameJA), ja != actress.name {
            facts.append(CatalogPersonFact(label: "日文名", value: ja))
        }
        if let en = nonEmpty(actress.nameEN) {
            facts.append(CatalogPersonFact(label: "英文名", value: en))
        }
        if let birth = actress.birthDate, !birth.isEmpty {
            facts.append(CatalogPersonFact(label: "出生", value: birth))
        } else if let age = actress.age {
            facts.append(CatalogPersonFact(label: "年龄", value: "\(age) 岁"))
        }
        if let height = actress.heightCM {
            facts.append(CatalogPersonFact(label: "身高", value: "\(height) cm"))
        }
        if let measurements = actress.measurements {
            facts.append(CatalogPersonFact(label: "三围", value: measurements))
        }
        if let cup = actress.cup, !cup.isEmpty {
            facts.append(CatalogPersonFact(label: "罩杯", value: cup))
        }
        if let works = actress.workCount, works > 0 {
            facts.append(CatalogPersonFact(label: actress.isModel ? "收录" : "作品",
                                           value: actress.isModel ? "\(works) 套"
                                                                  : "\(works) 部"))
        }
        if !actress.tags.isEmpty {
            facts.append(CatalogPersonFact(label: "标签",
                                           value: actress.tags.prefix(6).joined(separator: "、")))
        }
        let others = actress.aliases.filter {
            CatalogNameParser.normalize($0) != CatalogNameParser.normalize(actress.name)
        }
        if !others.isEmpty {
            facts.append(CatalogPersonFact(label: "别名",
                                           value: others.prefix(4).joined(separator: "、")))
        }
        let summary = nonEmpty(actress.summary)
        let description = nonEmpty(actress.description)
        let kind = actress.isModel ? "模特" : "女优"
        // 库里没有现成简介：把出生 / 身高 / 三围 / 作品数拼成一段，能显示的都显示。
        var parts: [String] = ["\(actress.regionTitle)\(kind)"]
        if let birth = actress.birthDate, !birth.isEmpty { parts.append("\(birth) 出生") }
        if let height = actress.heightCM { parts.append("身高 \(height) cm") }
        if let measurements = actress.measurements { parts.append("三围 \(measurements)") }
        if let cup = actress.cup, !cup.isEmpty { parts.append("\(cup) 罩杯") }
        if let works = actress.workCount, works > 0 {
            parts.append(actress.isModel ? "收录 \(works) 套作品" : "收录 \(works) 部作品")
        }
        if !actress.tags.isEmpty {
            parts.append(actress.tags.prefix(3).joined(separator: "、"))
        }
        return CatalogPersonInfo(name: actress.name, role: role,
                                 summary: summary ?? parts.joined(separator: " · "),
                                 description: description ?? "\(actress.regionTitle)\(kind)",
                                 imageURL: actress.imageURL,
                                 avatarBase64: actress.avatarBase64,
                                 facts: facts,
                                 sourceTitle: actress.name,
                                 sourceURL: actress.sourceURL,
                                 provider: "内置资料库",
                                 fetchedAt: Date())
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
