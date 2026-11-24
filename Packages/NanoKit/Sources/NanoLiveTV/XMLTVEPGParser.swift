import Compression
import Foundation
import NanoCore

/// 原生流式 XMLTV 电子节目单解析器（自动识别 `.xml` 与 `.xml.gz` Gzip 压缩流，并将节目单绑定至归一化频道名）
public final class XMLTVEPGParser: NSObject, XMLParserDelegate {
    private var channelIDToStdName: [String: String] = [:]
    private var programsByStdName: [String: [EPGProgramItem]] = [:]

    private var currentElement: String = ""
    private var currentChannelID: String = ""
    private var currentDisplayNameBuffer: String = ""

    private var currentProgChannelRef: String = ""
    private var currentProgStartRaw: String = ""
    private var currentProgStopRaw: String = ""
    private var currentProgTitleBuffer: String = ""
    private var insideChannel: Bool = false
    private var insideProgramme: Bool = false

    /// 从远程 URL（支持 `.xml` 或 `.xml.gz`）拉取并解析全量节目单字典 `[归一化频道名: [EPGProgramItem]]`
    public static func fetchAndParse(from url: URL) async throws -> [String: [EPGProgramItem]] {
        let (rawData, _) = try await URLSession.shared.data(from: url)
        let xmlData = decompressGzipIfNeeded(rawData)
        return parseXMLData(xmlData)
    }

    public static func parseXMLData(_ data: Data) -> [String: [EPGProgramItem]] {
        let handler = XMLTVEPGParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.shouldProcessNamespaces = false
        _ = parser.parse()

        var sortedOutput: [String: [EPGProgramItem]] = [:]
        for (stdKey, list) in handler.programsByStdName {
            sortedOutput[stdKey] = list.sorted { $0.startTime < $1.startTime }
        }
        return sortedOutput
    }

    /// 解析 XMLTV 标准时间格式：`20261124183000 +0800` 或 `20261124183000`
    public static func parseXMLTVDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fWithTZ = DateFormatter()
        fWithTZ.locale = Locale(identifier: "en_US_POSIX")
        fWithTZ.dateFormat = "yyyyMMddHHmmss Z"
        if let d = fWithTZ.date(from: trimmed) {
            return d
        }
        let digitsOnly = String(trimmed.prefix(14))
        let fLocal = DateFormatter()
        fLocal.locale = Locale(identifier: "en_US_POSIX")
        fLocal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        fLocal.dateFormat = "yyyyMMddHHmmss"
        return fLocal.date(from: digitsOnly)
    }

    /// 使用 Apple 原生 Compression 框架自动识别 Gzip 魔数 (`1F 8B`) 并解压 Deflate 数据流
    public static func decompressGzipIfNeeded(_ data: Data) -> Data {
        guard data.count > 18 else { return data }
        let bytes = [UInt8](data.prefix(10))
        guard bytes[0] == 0x1F && bytes[1] == 0x8B && bytes[2] == 0x08 else {
            return data
        }

        // 计算 Gzip Header 偏移量（跳过可选的 FEXTRA / FNAME / FCOMMENT / FHCRC）
        let flags = bytes[3]
        var headerOffset = 10
        let allBytes = [UInt8](data)

        if (flags & 0x04) != 0 && headerOffset + 2 <= allBytes.count {
            let xlen = Int(allBytes[headerOffset]) | (Int(allBytes[headerOffset + 1]) << 8)
            headerOffset += 2 + xlen
        }
        if (flags & 0x08) != 0 {
            while headerOffset < allBytes.count && allBytes[headerOffset] != 0 { headerOffset += 1 }
            headerOffset += 1
        }
        if (flags & 0x10) != 0 {
            while headerOffset < allBytes.count && allBytes[headerOffset] != 0 { headerOffset += 1 }
            headerOffset += 1
        }
        if (flags & 0x02) != 0 {
            headerOffset += 2
        }

        guard headerOffset < data.count - 8 else { return data }
        let deflatePayload = data.subdata(in: headerOffset..<(data.count - 8))

        // 分配可扩展目标缓冲区解压 Raw Deflate (COMPRESSION_ZLIB 支持无头或标准流，配合大容量缓冲)
        let dstCapacity = max(data.count * 8, 4 * 1024 * 1024)
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dstBuffer.deallocate() }

        let decodedSize = deflatePayload.withUnsafeBytes { srcPtr -> Int in
            guard let base = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                dstBuffer,
                dstCapacity,
                base,
                deflatePayload.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        if decodedSize > 0 {
            return Data(bytes: dstBuffer, count: decodedSize)
        }
        return data
    }

    // MARK: - XMLParserDelegate

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "channel" {
            insideChannel = true
            currentChannelID = attributeDict["id"] ?? ""
            currentDisplayNameBuffer = ""
        } else if elementName == "programme" {
            insideProgramme = true
            currentProgChannelRef = attributeDict["channel"] ?? ""
            currentProgStartRaw = attributeDict["start"] ?? ""
            currentProgStopRaw = attributeDict["stop"] ?? ""
            currentProgTitleBuffer = ""
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideChannel && currentElement == "display-name" {
            currentDisplayNameBuffer += string
        } else if insideProgramme && currentElement == "title" {
            currentProgTitleBuffer += string
        }
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "channel" {
            insideChannel = false
            let name = currentDisplayNameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentChannelID.isEmpty && !name.isEmpty {
                channelIDToStdName[currentChannelID] = IPTVLiveEngine.normalizeChannelName(name)
            }
        } else if elementName == "programme" {
            insideProgramme = false
            let title = currentProgTitleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  let start = Self.parseXMLTVDate(currentProgStartRaw),
                  let stop = Self.parseXMLTVDate(currentProgStopRaw) else { return }

            let stdName = channelIDToStdName[currentProgChannelRef] ?? IPTVLiveEngine.normalizeChannelName(currentProgChannelRef)
            let item = EPGProgramItem(channelStdName: stdName, title: title, startTime: start, endTime: stop)
            programsByStdName[stdName, default: []].append(item)
        }
        currentElement = ""
    }
}
