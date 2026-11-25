import Foundation
import LumaContentCore

/// XMLTV 节目单拉取与解析。
/// 只保留前后 3 天（外加半天时区缓冲）的节目，避免一次性把几十 MB 的 EPG 全塞进内存。
/// 解析结果按地址落盘缓存：同一份 XMLTV 在 TTL 内不重复下载与解析。
enum TVEPGService {
    /// 缓存有效期：公共节目单通常几小时更新一次，6 小时足够新。
    static let cacheMaxAge: TimeInterval = 6 * 3600

    /// 节目单保留窗口：历史 3 天、未来 3 天，下午 / 上午的时区边界各留半天缓冲。
    static let windowDays: Double = 3
    static let windowBufferDays: Double = 0.5

    /// 磁盘缓存快照：启动时先把上次的节目单垫进内存，界面不用等网络。
    struct Snapshot {
        var data: TVEPGData
        var savedAt: Date
    }

    private struct CachedEPG: Codable {
        var savedAt: Date
        var programs: [TVEPGProgram]
        var channelNames: [String: [String]]
    }

    static func load(urlString: String, maxAge: TimeInterval = cacheMaxAge) async throws -> TVEPGData {
        if let cached = readCache(urlString, maxAge: maxAge) {
            return TVEPGData(programs: cached.programs, channelNames: cached.channelNames)
        }
        guard let url = URL(string: urlString) else {
            throw SourceError.parse("EPG 地址无效：\(urlString)")
        }
        let response = try await HTTPSourceTransport.shared.send(
            HTTPTransportRequest(url: url, timeout: 30),
            profile: .luma,
            retryPolicy: HTTPRetryPolicy(maxRetries: 1, baseDelay: 0.6)
        )
        guard let text = response.text else {
            throw SourceError.parse("EPG 不是文本格式")
        }
        let data = try await Task.detached(priority: .utility) {
            try parse(text)
        }.value
        writeCache(data, urlString: urlString)
        return data
    }

    /// 只读磁盘缓存，不联网；过期也返回（启动时先用旧数据垫上，后台再刷新）。
    static func cachedSnapshot(urlString: String) -> Snapshot? {
        guard let cached = readCache(urlString, maxAge: .greatestFiniteMagnitude) else { return nil }
        return Snapshot(data: TVEPGData(programs: cached.programs,
                                        channelNames: cached.channelNames),
                        savedAt: cached.savedAt)
    }

    /// 缓存写入时间：只读一个几字节的旁文件，比解码整份 JSON 快得多。
    static func cachedSavedAt(urlString: String) -> Date? {
        guard let text = try? String(contentsOf: metaFile(for: urlString), encoding: .utf8),
              let stamp = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }

    /// 缓存目录：跟着当前图库走，换库不会串用旧节目单。
    private static var cacheDirectory: URL {
        LibraryPaths.tvDir.appendingPathComponent("epg-cache", isDirectory: true)
    }

    private static func cacheFile(for urlString: String) -> URL {
        // Swift 的 hashValue 每次启动都会变，缓存会永远命中不了；这里用稳定的 FNV-1a。
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in urlString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return cacheDirectory.appendingPathComponent("\(String(hash, radix: 16)).json", isDirectory: false)
    }

    private static func metaFile(for urlString: String) -> URL {
        cacheFile(for: urlString).deletingPathExtension().appendingPathExtension("meta")
    }

    private static func readCache(_ urlString: String, maxAge: TimeInterval) -> CachedEPG? {
        let file = cacheFile(for: urlString)
        guard let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(CachedEPG.self, from: data),
              Date().timeIntervalSince(cached.savedAt) < maxAge else { return nil }
        return cached
    }

    private static func writeCache(_ data: TVEPGData, urlString: String) {
        let savedAt = Date()
        let payload = CachedEPG(savedAt: savedAt,
                                programs: data.programs,
                                channelNames: data.channelNames)
        guard let encoded = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? encoded.write(to: cacheFile(for: urlString), options: .atomic)
        try? String(savedAt.timeIntervalSince1970).write(to: metaFile(for: urlString),
                                                          atomically: true,
                                                          encoding: .utf8)
    }

    static func parse(_ text: String) throws -> TVEPGData {
        guard let data = text.data(using: .utf8) else {
            throw SourceError.parse("EPG 编码无法识别")
        }
        let delegate = XMLTVParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SourceError.parse(parser.parserError?.localizedDescription ?? "EPG 解析失败")
        }
        let now = Date()
        let earliest = now.addingTimeInterval(-(windowDays + windowBufferDays) * 24 * 3600)
        let latest = now.addingTimeInterval((windowDays + windowBufferDays) * 24 * 3600)
        let programs = delegate.programs
            .filter { $0.end >= earliest && $0.start <= latest }
            .sorted { $0.start < $1.start }
        return TVEPGData(programs: programs, channelNames: delegate.channelNames)
    }
}

private final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    var programs: [TVEPGProgram] = []
    var channelNames: [String: [String]] = [:]

    private var currentChannelID: String?
    private var currentProgram: TVEPGProgram?
    private var currentText = ""
    private var currentElement = ""

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "channel":
            currentChannelID = attributeDict["id"]
        case "programme":
            guard let channel = attributeDict["channel"],
                  let start = XMLTVDate.parse(attributeDict["start"]),
                  let end = XMLTVDate.parse(attributeDict["stop"]),
                  end > start else {
                currentProgram = nil
                return
            }
            currentProgram = TVEPGProgram(id: "\(channel)#\(start.timeIntervalSince1970)",
                                          channelID: channel,
                                          title: "",
                                          subtitle: nil,
                                          overview: nil,
                                          start: start,
                                          end: end)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentProgram != nil || currentChannelID != nil else { return }
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        defer { currentText = "" }

        if elementName == "display-name", let id = currentChannelID {
            let name = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                var names = channelNames[id] ?? []
                if !names.contains(name) { names.append(name) }
                channelNames[id] = names
            }
            return
        }

        guard var program = currentProgram else {
            if elementName == "channel" { currentChannelID = nil }
            return
        }

        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":
            if program.title.isEmpty { program.title = value }
        case "sub-title":
            if !value.isEmpty { program.subtitle = value }
        case "desc":
            if !value.isEmpty { program.overview = value }
        case "programme":
            if !program.title.isEmpty {
                programs.append(program)
            }
            currentProgram = nil
            return
        default:
            break
        }
        currentProgram = program
    }
}

private enum XMLTVDate {
    private static let withZone: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        return formatter
    }()

    private static let withoutZone: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = .current
        return formatter
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let date = withZone.date(from: value) { return date }
        if let date = withoutZone.date(from: value) { return date }
        // 少数 EPG 用 ISO8601。
        return ISO8601DateFormatter().date(from: value)
    }
}
