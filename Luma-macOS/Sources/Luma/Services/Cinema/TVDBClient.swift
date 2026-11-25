import Foundation

/// TheTVDB API v4 刮削源：剧集 / 电影的基础资料。
///
/// 只有 TMDB 能补合集、演职员与预告，TVDB 定位是第三顺位的补充源：
/// 有些剧在 TVDB 上的分集信息更细，TMDB / 豆瓣都搜不到时可以用它兜底。
struct TVDBClient: CinemaMetadataSource {
    let apiKey: String
    let pin: String
    /// 刮削语言，如 zh-CN；请求时换成 TVDB 的三字母代码。
    let language: String
    var apiBase: String = "https://api4.thetvdb.com/v4"

    var provider: CinemaProvider { .tvdb }

    enum TVDBError: LocalizedError {
        case missingKey
        case loginFailed(String)
        case http(Int, String)
        case decoding

        var errorDescription: String? {
            switch self {
            case .missingKey: return "请先在设置 › 影院里填写 TVDB API Key"
            case .loginFailed(let message): return "TVDB 登录失败：\(message)"
            case .http(let status, let message): return "TVDB 请求失败（\(status)）：\(message)"
            case .decoding: return "TVDB 返回内容无法解析"
            }
        }
    }

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPin: String { pin.trimmingCharacters(in: .whitespacesAndNewlines) }

    func search(query: String, isTV: Bool, year: Int?) async throws -> [CinemaMatch] {
        guard !trimmedKey.isEmpty else { throw TVDBError.missingKey }
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "type", value: isTV ? "series" : "movie")
        ]
        if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
        let object = try await request(path: "/search", items: items)
        guard let data = object["data"] as? [[String: Any]] else { throw TVDBError.decoding }
        return data.compactMap { parse($0, isTV: isTV) }
    }

    private func parse(_ item: [String: Any], isTV: Bool) -> CinemaMatch? {
        // 搜索结果会混入人物 / 公司，按类型过滤掉。
        if let type = item["type"] as? String, !type.isEmpty {
            let normalized = type.lowercased()
            if isTV, normalized != "series" { return nil }
            if !isTV, normalized != "movie" { return nil }
        }
        guard let id = identifier(item) else { return nil }
        let name = (item["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }

        let translated = (item["name_translated"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (translated?.isEmpty ?? true) ? name : translated!
        let original = title == name ? nil : name

        var yearValue = Int((item["year"] as? String) ?? "")
        if yearValue == nil, let firstAir = item["first_air_time"] as? String {
            yearValue = Int(firstAir.prefix(4))
        }
        return CinemaMatch(
            id: id,
            isTV: isTV,
            title: title,
            originalTitle: original,
            year: yearValue,
            posterURL: item["image_url"] as? String,
            backdropURL: nil,
            overview: {
                let text = (item["overview"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (text?.isEmpty ?? true) ? nil : text
            }(),
            rating: nil,
            voteCount: nil,
            genres: (item["genres"] as? [String]) ?? [],
            provider: .tvdb
        )
    }

    /// `tvdb_id` / `objectID` 都可能是 "series-123" 这种带前缀的字符串。
    private func identifier(_ item: [String: Any]) -> String? {
        for key in ["tvdb_id", "objectID", "id"] {
            guard let raw = item[key] else { continue }
            let text = String(describing: raw)
            let digits = text.filter { $0.isNumber }
            if !digits.isEmpty { return digits }
        }
        return nil
    }

    // MARK: 网络

    private func request(path: String, items: [URLQueryItem]) async throws -> [String: Any] {
        let token = try await loginToken()
        let base = apiBase.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base + path) else {
            throw TVDBError.loginFailed("接口地址无效")
        }
        components.queryItems = items
        guard let url = components.url else { throw TVDBError.loginFailed("接口地址无效") }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.acceptLanguage(language), forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = (object["message"] as? String) ?? "HTTP \(status)"
            throw TVDBError.http(status, message)
        }
        return object
    }

    private func loginToken() async throws -> String {
        let cacheKey = trimmedKey + "|" + trimmedPin
        if let cached = await TVDBTokenStore.shared.token(for: cacheKey) { return cached }

        let base = apiBase.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/login") else {
            throw TVDBError.loginFailed("接口地址无效")
        }
        var body: [String: String] = ["apikey": trimmedKey]
        if !trimmedPin.isEmpty { body["pin"] = trimmedPin }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200,
              let payload = object["data"] as? [String: Any],
              let token = payload["token"] as? String, !token.isEmpty else {
            let message = (object["message"] as? String) ?? "HTTP \(status)"
            throw TVDBError.loginFailed(message)
        }
        await TVDBTokenStore.shared.store(token, for: cacheKey)
        return token
    }

    /// "zh-CN" → "zho"：TVDB 用三字母语言代码。
    private static func acceptLanguage(_ value: String) -> String {
        let code = value.lowercased()
        if code.hasPrefix("zh") { return "zho" }
        if code.hasPrefix("en") { return "eng" }
        if code.hasPrefix("ja") { return "jpn" }
        if code.hasPrefix("ko") { return "kor" }
        if code.hasPrefix("fr") { return "fra" }
        if code.hasPrefix("de") { return "deu" }
        if code.hasPrefix("es") { return "spa" }
        if code.hasPrefix("it") { return "ita" }
        if code.hasPrefix("ru") { return "rus" }
        return "eng"
    }

    private static let session = URLSession(configuration: .ephemeral)
}

/// TVDB 登录令牌按 API Key 缓存：一次刮削会搜几十次，不能每次都登录。
actor TVDBTokenStore {
    static let shared = TVDBTokenStore()

    private struct Entry {
        var token: String
        var expiresAt: Date
    }

    private var entries: [String: Entry] = [:]

    func token(for key: String) -> String? {
        guard let entry = entries[key], entry.expiresAt > Date() else { return nil }
        return entry.token
    }

    func store(_ token: String, for key: String) {
        // 官方令牌有效期约一个月，这里留 7 天余量后重登一次，避免中途失效。
        entries[key] = Entry(token: token, expiresAt: Date().addingTimeInterval(7 * 24 * 3600))
    }
}
