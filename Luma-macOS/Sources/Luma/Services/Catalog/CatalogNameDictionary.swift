import Foundation

/// 内置的 AV 女优 / 片商资料库，数据来自仓库里的 `Resources/Catalog/catalog.sqlite`。
///
/// 这张库在构建时由 `Tools/catalog_build/build_catalog_db.py` 生成：
/// - 女优：姓名与别名、地区、出生日期、年龄、身高、三围、罩杯、作品数、标签、简介
/// - 片商：名称与别名、地区、作品数、简介
/// - 番号前缀 → 片商
///
/// 识别器用它做标题匹配，人物档案用它直接展示资料，不必再联网搜索。
enum CatalogNameDictionary {
    struct Payload {
        var japanese: [String] = []
        var korean: [String] = []
        var western: [String] = []
        var chinese: [String] = []
        var studios: [String] = []
        var codeMakers: [String: String] = [:]

        var actresses: [String] { japanese + korean + western + chinese }
    }

    static let payload: Payload = makePayload()
    static let codeMakers: [String: String] = makeCodeMakers()

    /// 所有女优的名字与别名（识别标题用）。
    static var allActressNames: [String] {
        actresses.flatMap { [$0.name] + $0.aliases }
    }

    /// 资料库浏览页用：全部人物 / 全部机构。
    static var allActresses: [CatalogActressRecord] { actresses }
    static var allStudios: [CatalogStudioRecord] { studios }

    static var allStudioNames: [String] {
        studios.flatMap { [$0.name] + $0.aliases }
    }

    /// 按姓名 / 别名查一个人：繁简、大小写、叠字符（々）、括号里的别名都做归一化；
    /// 精确命不中时再做包含匹配，让「高宫菜菜子 (高宫菜々子)」这类写法也能落到同一条记录。
    static func actress(matching name: String) -> CatalogActressRecord? {
        for key in lookupKeys(for: name) {
            if let hit = actressIndex[key] { return hit }
        }
        return fuzzyActress(name)
    }

    static func studio(matching name: String) -> CatalogStudioRecord? {
        for key in lookupKeys(for: name) {
            if let hit = studioIndex[key] { return hit }
        }
        return fuzzyStudio(name)
    }

    // MARK: - 模糊匹配

    /// 候选键：主名 + 括号里的别名，各自归一化。
    private static func lookupKeys(for name: String) -> [String] {
        let split = CatalogNameParser.splitAliases(name)
        var keys: [String] = []
        for candidate in [split.primary] + split.aliases + [name] {
            let key = CatalogNameParser.normalize(candidate)
            if !key.isEmpty, !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// 包含匹配：查询名与库里的名字一方包含另一方即可，
    /// 同分时优先资料更全的那条（作品数、出生、身高等）。
    private static func fuzzyActress(_ name: String) -> CatalogActressRecord? {
        let queries = lookupKeys(for: name).filter { $0.count >= 3 }
        guard !queries.isEmpty else { return nil }
        var best: (record: CatalogActressRecord, score: Int)?
        for (key, record) in actressIndex where key.count >= 3 {
            for query in queries {
                guard key.contains(query) || query.contains(key) else { continue }
                let score = min(key.count, query.count) * 10 + richness(record)
                if best == nil || score > (best?.score ?? .min) {
                    best = (record, score)
                }
            }
        }
        return best?.record
    }

    private static func fuzzyStudio(_ name: String) -> CatalogStudioRecord? {
        let queries = lookupKeys(for: name).filter { $0.count >= 2 }
        guard !queries.isEmpty else { return nil }
        var best: (record: CatalogStudioRecord, score: Int)?
        for (key, record) in studioIndex where key.count >= 2 {
            for query in queries {
                guard key.contains(query) || query.contains(key) else { continue }
                let score = min(key.count, query.count) * 10 + richness(record)
                if best == nil || score > (best?.score ?? .min) {
                    best = (record, score)
                }
            }
        }
        return best?.record
    }

    private static func richness(_ record: CatalogActressRecord) -> Int {
        var score = min(record.workCount ?? 0, 300) / 3
        if record.birthDate?.isEmpty == false { score += 20 }
        if record.heightCM != nil { score += 10 }
        if record.cup?.isEmpty == false { score += 6 }
        if record.summary?.isEmpty == false { score += 15 }
        score += record.aliases.count + record.tags.count
        return score
    }

    private static func richness(_ record: CatalogStudioRecord) -> Int {
        var score = min(record.workCount ?? 0, 300) / 3
        if record.summary?.isEmpty == false { score += 20 }
        if record.imageURL?.isEmpty == false { score += 6 }
        score += record.aliases.count
        return score
    }

    // MARK: - 读取

    private static let actresses: [CatalogActressRecord] = {
        guard let database = openDatabase() else { return [] }
        let rows = (try? database.query("""
            SELECT id, name, name_ja, name_en, aliases, region, birth_date, age,
                   age_asof, height_cm, bust, waist, hips, cup, work_count, tags,
                   summary, description, image_url, avatar_base64, source_url, source
            FROM actresses
            ORDER BY COALESCE(work_count, -1) DESC, name
            """)) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.int64, let name = row["name"]?.string else { return nil }
            return CatalogActressRecord(
                id: id,
                name: name,
                nameJA: row["name_ja"]?.string,
                nameEN: row["name_en"]?.string,
                aliases: decodeArray(row["aliases"]?.string),
                region: row["region"]?.string ?? "japan",
                birthDate: row["birth_date"]?.string,
                age: row["age"]?.int,
                ageAsOf: row["age_asof"]?.string,
                heightCM: row["height_cm"]?.int,
                bust: row["bust"]?.int,
                waist: row["waist"]?.int,
                hips: row["hips"]?.int,
                cup: row["cup"]?.string,
                workCount: row["work_count"]?.int,
                tags: decodeArray(row["tags"]?.string),
                summary: row["summary"]?.string,
                description: row["description"]?.string,
                imageURL: row["image_url"]?.string,
                avatarBase64: row["avatar_base64"]?.string,
                sourceURL: row["source_url"]?.string,
                source: row["source"]?.string ?? ""
            )
        }
    }()

    private static let studios: [CatalogStudioRecord] = {
        guard let database = openDatabase() else { return [] }
        let rows = (try? database.query("""
            SELECT id, name, name_en, aliases, region, kind, work_count, summary,
                   logo_url, avatar_base64, website, source_url, source
            FROM studios
            ORDER BY COALESCE(work_count, -1) DESC, name
            """)) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.int64, let name = row["name"]?.string else { return nil }
            return CatalogStudioRecord(
                id: id,
                name: name,
                nameEN: row["name_en"]?.string,
                aliases: decodeArray(row["aliases"]?.string),
                region: row["region"]?.string ?? "japan",
                kind: row["kind"]?.string ?? "studio",
                workCount: row["work_count"]?.int,
                summary: row["summary"]?.string,
                imageURL: row["logo_url"]?.string,
                avatarBase64: row["avatar_base64"]?.string,
                website: row["website"]?.string,
                sourceURL: row["source_url"]?.string,
                source: row["source"]?.string ?? ""
            )
        }
    }()

    private static let actressIndex: [String: CatalogActressRecord] = {
        var index: [String: CatalogActressRecord] = [:]
        for record in actresses {
            let names = [record.name] + record.aliases
                + [record.nameJA, record.nameEN].compactMap { $0 }
            for name in names {
                let key = CatalogNameParser.normalize(name)
                guard !key.isEmpty, index[key] == nil else { continue }
                index[key] = record
            }
        }
        return index
    }()

    private static let studioIndex: [String: CatalogStudioRecord] = {
        var index: [String: CatalogStudioRecord] = [:]
        for record in studios {
            let names = [record.name] + record.aliases + [record.nameEN].compactMap { $0 }
            for name in names {
                let key = CatalogNameParser.normalize(name)
                guard !key.isEmpty, index[key] == nil else { continue }
                index[key] = record
            }
        }
        return index
    }()

    private static func openDatabase() -> SQLiteDatabase? {
        for url in databaseCandidates() where FileManager.default.fileExists(atPath: url.path) {
            if let database = try? SQLiteDatabase(path: url.path, readonly: true, wal: false) {
                return database
            }
        }
        return nil
    }

    private static func databaseCandidates() -> [URL] {
        var urls: [URL] = []
        if let resource = Bundle.main.resourceURL {
            urls.append(resource.appendingPathComponent("Catalog/catalog.sqlite"))
        }
        // 开发期 `swift run` 时包资源里没有这份文件，退回仓库路径。
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Catalog/catalog.sqlite"))
        return urls
    }

    private static func decodeArray(_ text: String?) -> [String] {
        guard let text, let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func makePayload() -> Payload {
        var payload = Payload()
        for record in actresses {
            let names = [record.name] + record.aliases
            switch record.region {
            case "korea": payload.korean += names
            case "western": payload.western += names
            case "china", "taiwan", "hongkong": payload.chinese += names
            default: payload.japanese += names
            }
        }
        payload.studios = allStudioNames
        payload.codeMakers = codeMakers
        return payload
    }

    private static func makeCodeMakers() -> [String: String] {
        guard let database = openDatabase() else { return [:] }
        let rows = (try? database.query("SELECT prefix, studio_name FROM code_makers")) ?? []
        var makers: [String: String] = [:]
        for row in rows {
            guard let prefix = row["prefix"]?.string,
                  let studio = row["studio_name"]?.string else { continue }
            makers[prefix] = studio
        }
        return makers
    }
}

// MARK: - 记录

struct CatalogActressRecord: Identifiable, Hashable {
    var id: Int64
    var name: String
    var nameJA: String?
    var nameEN: String?
    var aliases: [String]
    var region: String
    var birthDate: String?
    var age: Int?
    var ageAsOf: String?
    var heightCM: Int?
    var bust: Int?
    var waist: Int?
    var hips: Int?
    var cup: String?
    var workCount: Int?
    var tags: [String]
    var summary: String?
    var description: String?
    var imageURL: String?
    var avatarBase64: String?
    var sourceURL: String?
    var source: String

    var regionTitle: String { CatalogRegion.title(for: region) }

    /// 福利姬 / 秀人 / 网红系模特，而不是 AV 女优。
    var isModel: Bool {
        tags.contains("福利姬") || tags.contains("秀人") || tags.contains("网红")
    }

    /// 「88-59-94」；三项都有才显示。
    var measurements: String? {
        guard let bust, let waist, let hips else { return nil }
        return "\(bust)-\(waist)-\(hips)"
    }

    var allNames: [String] { [name] + aliases }
}

struct CatalogStudioRecord: Identifiable, Hashable {
    var id: Int64
    var name: String
    var nameEN: String?
    var aliases: [String]
    var region: String
    /// 厂牌类型：studio（片商）/ photo（写真机构）/ platform（平台）。
    var kind: String
    var workCount: Int?
    var summary: String?
    var imageURL: String?
    var avatarBase64: String?
    var website: String?
    var sourceURL: String?
    var source: String

    var regionTitle: String { CatalogRegion.title(for: region) }

    var kindTitle: String {
        switch kind {
        case "photo": return "写真机构"
        case "platform": return "平台"
        default: return "片商"
        }
    }

    var allNames: [String] { [name] + aliases }
}

enum CatalogRegion {
    static func title(for region: String) -> String {
        switch region {
        case "japan": return "日本"
        case "korea": return "韩国"
        case "taiwan": return "台湾"
        case "hongkong": return "香港"
        case "china": return "中国大陆"
        case "western": return "欧美"
        default: return region
        }
    }
}
