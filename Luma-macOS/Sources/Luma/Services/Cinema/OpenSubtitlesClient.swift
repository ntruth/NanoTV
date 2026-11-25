import Foundation
import PlaybackCore

/// 在线字幕来源。
enum SubtitleProviderKind: String, CaseIterable, Identifiable, Hashable {
    case openSubtitles
    case assrt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openSubtitles: return "OpenSubtitles"
        case .assrt: return "伪射手"
        }
    }
}

/// 在线字幕的一条搜索结果。
struct CinemaSubtitleMatch: Identifiable, Hashable {
    var provider: SubtitleProviderKind = .openSubtitles
    var fileID: Int
    var title: String
    var language: String
    var release: String?
    var downloads: Int?

    var id: String { "\(provider.rawValue)-\(fileID)" }

    /// 是否中文结果：自动匹配优先用它。
    var isChinese: Bool {
        let value = language.lowercased()
        return value.hasPrefix("zh") || value.contains("chi") || value.contains("简") || value.contains("繁")
    }

    var languageTitle: String {
        switch language.lowercased() {
        case "zh-cn", "zh", "chs", "chi": return "简体中文"
        case "zh-tw", "zh-hk", "cht": return "繁體中文"
        case "en": return "English"
        default: return language
        }
    }
}

/// OpenSubtitles REST API：按片名 / 季集搜索，下载后落到本机缓存，再交给播放器加载。
enum OpenSubtitlesClient {
    struct Credentials {
        var apiKey: String
        var username: String
        var password: String

        var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
        var hasAccount: Bool {
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !password.isEmpty
        }
    }

    enum SubtitleError: LocalizedError {
        case missingKey
        case missingAccount
        case http(Int, String)
        case decoding

        var errorDescription: String? {
            switch self {
            case .missingKey: return "请先在设置 › 影院 › 字幕里填写 OpenSubtitles API Key"
            case .missingAccount: return "下载字幕需要 OpenSubtitles 账号，请在设置 › 影院 › 字幕里填写"
            case .http(let status, let message): return "OpenSubtitles 请求失败（\(status)）：\(message)"
            case .decoding: return "OpenSubtitles 返回内容无法解析"
            }
        }
    }

    private static let base = "https://api.opensubtitles.com/api/v1"

    static func search(query: String,
                       isTV: Bool,
                       season: Int?,
                       episode: Int?,
                       credentials: Credentials) async throws -> [CinemaSubtitleMatch] {
        guard !credentials.trimmedKey.isEmpty else { throw SubtitleError.missingKey }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard var components = URLComponents(string: base + "/subtitles") else {
            throw SubtitleError.decoding
        }
        var items = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "languages", value: SubtitlePreference.searchLanguageList),
            URLQueryItem(name: "order_by", value: "download_count"),
            URLQueryItem(name: "order_direction", value: "desc")
        ]
        if isTV, let season, let episode {
            items.append(URLQueryItem(name: "season_number", value: String(season)))
            items.append(URLQueryItem(name: "episode_number", value: String(episode)))
        }
        components.queryItems = items
        guard let url = components.url else { throw SubtitleError.decoding }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(credentials.trimmedKey, forHTTPHeaderField: "Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Luma/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = (object["message"] as? String) ?? "HTTP \(status)"
            throw SubtitleError.http(status, message)
        }
        guard let list = object["data"] as? [[String: Any]] else { throw SubtitleError.decoding }

        return list.compactMap { item in
            guard let attributes = item["attributes"] as? [String: Any],
                  let files = attributes["files"] as? [[String: Any]],
                  let fileID = (files.first?["file_id"] as? NSNumber)?.intValue else { return nil }
            let feature = attributes["feature_details"] as? [String: Any]
            let title = (feature?["title"] as? String)
                ?? (attributes["release"] as? String)
                ?? trimmed
            return CinemaSubtitleMatch(provider: .openSubtitles,
                                       fileID: fileID,
                                       title: title,
                                       language: (attributes["language"] as? String) ?? "zh-cn",
                                       release: attributes["release"] as? String,
                                       downloads: (attributes["download_count"] as? NSNumber)?.intValue)
        }
    }

    /// 下载字幕并保存到本机缓存目录，返回可直接加载的本地文件 URL。
    static func download(_ match: CinemaSubtitleMatch,
                         credentials: Credentials) async throws -> URL {
        guard !credentials.trimmedKey.isEmpty else { throw SubtitleError.missingKey }
        guard credentials.hasAccount else { throw SubtitleError.missingAccount }

        let token = try await login(credentials: credentials)
        guard var components = URLComponents(string: base + "/download") else {
            throw SubtitleError.decoding
        }
        components.queryItems = nil
        guard let url = components.url else { throw SubtitleError.decoding }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(credentials.trimmedKey, forHTTPHeaderField: "Api-Key")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Luma/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "file_id": match.fileID,
            "sub_format": "srt"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200,
              let link = object["link"] as? String,
              let remote = URL(string: link) else {
            let message = (object["message"] as? String) ?? "HTTP \(status)"
            throw SubtitleError.http(status, message)
        }

        let (fileData, fileResponse) = try await URLSession.shared.data(from: remote)
        guard (fileResponse as? HTTPURLResponse)?.statusCode ?? 0 == 200 else {
            throw SubtitleError.http((fileResponse as? HTTPURLResponse)?.statusCode ?? 0, "字幕文件下载失败")
        }

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Luma/Subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rawName = (object["file_name"] as? String) ?? "subtitle-\(match.fileID).srt"
        let name = rawName.replacingOccurrences(of: "/", with: "-")
        let fileURL = directory.appendingPathComponent(name)
        try fileData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// 设置页「测试连接」：用一次轻量搜索验证 API Key；填了账号时顺带验证登录。
    static func testConnection(credentials: Credentials) async -> CinemaConnectionResult {
        guard !credentials.trimmedKey.isEmpty else {
            return CinemaConnectionResult(ok: false, message: "请先填写 OpenSubtitles API Key")
        }
        do {
            _ = try await search(query: "the",
                                 isTV: false,
                                 season: nil,
                                 episode: nil,
                                 credentials: credentials)
            if credentials.hasAccount {
                _ = try await login(credentials: credentials)
                return CinemaConnectionResult(ok: true, message: "API Key 可用，账号登录成功")
            }
            return CinemaConnectionResult(ok: true, message: "API Key 可用；未填账号，只能搜索不能下载")
        } catch {
            return CinemaConnectionResult(ok: false, message: error.localizedDescription)
        }
    }

    private static func login(credentials: Credentials) async throws -> String {
        guard let url = URL(string: base + "/login") else { throw SubtitleError.decoding }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(credentials.trimmedKey, forHTTPHeaderField: "Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Luma/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "username": credentials.username,
            "password": credentials.password
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200, let token = object["token"] as? String else {
            let message = (object["message"] as? String) ?? "HTTP \(status)"
            throw SubtitleError.http(status, "登录失败：\(message)")
        }
        return token
    }
}
