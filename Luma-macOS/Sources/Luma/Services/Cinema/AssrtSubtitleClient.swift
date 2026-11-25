import Foundation

/// Assrt（伪射手网）字幕源：官方 API，需在 assrt.net 用户中心获取访问令牌。
/// 国内中文字幕为主，搜索结果与 OpenSubtitles 统一成 `CinemaSubtitleMatch`。
enum AssrtSubtitleClient {
    enum AssrtError: LocalizedError {
        case missingToken
        case http(Int, String)
        case decoding
        case noFile
        case unsupportedArchive(String)

        var errorDescription: String? {
            switch self {
            case .missingToken: return "请先在设置 › 影院 › 字幕里填写 Assrt 访问令牌"
            case .http(let status, let message): return "Assrt 请求失败（\(status)）：\(message)"
            case .decoding: return "Assrt 返回内容无法解析"
            case .noFile: return "Assrt 没有提供可用的字幕文件"
            case .unsupportedArchive(let ext):
                return "Assrt 返回的是 \(ext.uppercased()) 压缩包，暂不支持解压；可换一条结果"
            }
        }
    }

    private static let base = "https://api.assrt.net/v1"
    private static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]

    static func search(query: String, token: String) async throws -> [CinemaSubtitleMatch] {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw AssrtError.missingToken }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }

        var components = URLComponents(string: base + "/sub/search")
        components?.queryItems = [
            URLQueryItem(name: "token", value: trimmedToken),
            URLQueryItem(name: "q", value: keyword),
            URLQueryItem(name: "no_muxer", value: "1"),
            URLQueryItem(name: "pos", value: "0"),
            URLQueryItem(name: "cnt", value: "20")
        ]
        guard let url = components?.url else { throw AssrtError.decoding }

        let object = try await request(url)
        guard let sub = object["sub"] as? [String: Any],
              let list = sub["subs"] as? [[String: Any]] else { return [] }

        return list.compactMap { item in
            guard let fileID = intValue(item["id"]) else { return nil }
            let release = stringValue(item["videoname"]) ?? stringValue(item["native_name"])
            let title = stringValue(item["video_chinese_name"])
                ?? stringValue(item["native_name"])
                ?? release
                ?? keyword
            let langText = languageText(item["lang"])
            return CinemaSubtitleMatch(provider: .assrt,
                                       fileID: fileID,
                                       title: title,
                                       // 伪射手以中文字幕为主；接口没给语言时按简体处理。
                                       language: normalizeLanguage(langText.isEmpty ? "中文" : langText),
                                       release: release,
                                       downloads: intValue(item["downloadcount"]))
        }
    }

    /// 设置页「测试连接」：用一次轻量搜索验证访问令牌。
    static func testConnection(token: String) async -> CinemaConnectionResult {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CinemaConnectionResult(ok: false, message: "请先填写 Assrt 访问令牌")
        }
        do {
            _ = try await search(query: "test", token: trimmed)
            return CinemaConnectionResult(ok: true, message: "访问令牌可用")
        } catch {
            return CinemaConnectionResult(ok: false, message: error.localizedDescription)
        }
    }

    static func download(_ match: CinemaSubtitleMatch, token: String) async throws -> URL {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw AssrtError.missingToken }

        var components = URLComponents(string: base + "/sub/detail")
        components?.queryItems = [
            URLQueryItem(name: "token", value: trimmedToken),
            URLQueryItem(name: "id", value: String(match.fileID))
        ]
        guard let url = components?.url else { throw AssrtError.decoding }

        let object = try await request(url)
        guard let sub = object["sub"] as? [String: Any],
              let subs = sub["subs"] as? [[String: Any]],
              let filelist = subs.first?["filelist"] as? [[String: Any]] else {
            throw AssrtError.noFile
        }

        let candidates: [(name: String, url: URL)] = filelist.compactMap { item in
            guard let raw = stringValue(item["url"]), let url = resolve(raw) else { return nil }
            let name = stringValue(item["f"]) ?? url.lastPathComponent
            return (name, url)
        }
        guard !candidates.isEmpty else { throw AssrtError.noFile }

        let direct = candidates.first { isSubtitleFile($0.name) || isSubtitleFile($0.url.lastPathComponent) }
        let archive = candidates.first {
            $0.name.lowercased().hasSuffix(".zip") || $0.url.pathExtension.lowercased() == "zip"
        }
        guard let chosen = direct ?? archive else {
            throw AssrtError.unsupportedArchive(candidates[0].name)
        }

        let (data, response) = try await URLSession.shared.data(from: chosen.url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else {
            throw AssrtError.http(status, "字幕文件下载失败")
        }

        let directory = subtitleCacheDirectory()
        if isSubtitleFile(chosen.name) || isSubtitleFile(chosen.url.lastPathComponent) {
            return try write(data, name: chosen.name, to: directory)
        }
        return try extractZip(data, to: directory)
    }

    // MARK: - 网络

    private static func request(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Luma/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            throw AssrtError.http(status, stringValue(object["errmsg"]) ?? "HTTP \(status)")
        }
        if let apiStatus = intValue(object["status"]), apiStatus != 0 {
            throw AssrtError.http(apiStatus, stringValue(object["errmsg"]) ?? "接口返回失败")
        }
        return object
    }

    // MARK: - 解析

    private static func languageText(_ raw: Any?) -> String {
        guard let dict = raw as? [String: Any] else { return "" }
        if let desc = stringValue(dict["desc"]), !desc.isEmpty { return desc }
        guard let list = dict["langlist"] as? [[String: Any]] else { return "" }
        let names = list.compactMap { stringValue($0["desc"]) ?? stringValue($0["lang"]) }
        return names.joined(separator: "/")
    }

    private static func normalizeLanguage(_ raw: String) -> String {
        let value = raw.lowercased()
        if value.contains("简") || value.contains("chs") || value.contains("chi") || value.contains("中文") {
            return "zh-cn"
        }
        if value.contains("繁") || value.contains("cht") || value.contains("香港") || value.contains("台湾") {
            return "zh-tw"
        }
        if value.contains("英") || value == "en" { return "en" }
        return raw.isEmpty ? "unknown" : raw
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text) }
        return nil
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func resolve(_ raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(string: raw, relativeTo: URL(string: "https://assrt.net"))?.absoluteURL
    }

    private static func isSubtitleFile(_ name: String) -> Bool {
        subtitleExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    // MARK: - 落盘

    private static func subtitleCacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Luma/Subtitles", isDirectory: true)
    }

    private static func write(_ data: Data, name: String, to directory: URL) throws -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = directory.appendingPathComponent(safeName, isDirectory: false)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Assrt 多数结果打包成 zip：用系统 ditto 解压后挑一个最大的字幕文件。
    private static func extractZip(_ data: Data, to directory: URL) throws -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = directory.appendingPathComponent("assrt-\(UUID().uuidString)", isDirectory: true)
        let zipURL = work.appendingPathComponent("subtitle.zip", isDirectory: false)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try data.write(to: zipURL, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, work.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: zipURL)
        guard process.terminationStatus == 0 else { throw AssrtError.noFile }

        let files = (FileManager.default.enumerator(at: work,
                                                    includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { isSubtitleFile($0.lastPathComponent) }
        guard let best = files.max(by: {
            ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }) else {
            try? FileManager.default.removeItem(at: work)
            throw AssrtError.noFile
        }
        return best
    }
}
