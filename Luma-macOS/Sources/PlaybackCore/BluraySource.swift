import Foundation

/// 蓝光原盘（BDMV 目录 / 光盘镜像）的输入封装。
///
/// ffmpeg 内置 `bluray` 协议（依赖 libbluray）：把盘根目录交给它，
/// 由 libbluray 解析 `.mpls` 播放列表，无缝分支 / 多角度 / 章节都由它处理，
/// 不需要自己解析原盘结构。加密盘（AACS）需要额外解密，不在支持范围。
public enum BluraySource {
    /// ffmpeg / ffprobe 的输入串；不是蓝光时返回 nil。
    /// 注意：返回值是协议串（`bluray:/path`），不能再当普通文件路径使用。
    public static func ffmpegInput(for url: URL) -> String? {
        guard let root = discRoot(for: url) else { return nil }
        return "bluray:" + root.path
    }

    /// 蓝光根目录（含 BDMV 的那一级）或 ISO 文件；不是蓝光时返回 nil。
    public static func discRoot(for url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        if !isDirectory.boolValue {
            // 光盘镜像：libbluray 通过 libudfread 直接读 UDF，不需要挂载。
            return url.pathExtension.lowercased() == "iso" ? url : nil
        }

        if fm.fileExists(atPath: url.appendingPathComponent("BDMV", isDirectory: true).path) {
            return url
        }
        // 用户直接选中了 BDMV 这一层。
        if url.lastPathComponent.caseInsensitiveCompare("BDMV") == .orderedSame,
           fm.fileExists(atPath: url.appendingPathComponent("STREAM", isDirectory: true).path) {
            return url.deletingLastPathComponent()
        }
        return nil
    }

    /// 枚举目录时把 `BDMV/STREAM/00000.m2ts` 折叠成整张盘的根目录，
    /// 避免把菜单 / 花絮片段当成一堆独立视频导入。
    public static func discRoot(containing file: URL) -> URL? {
        let components = file.pathComponents
        guard let index = components.firstIndex(where: {
            $0.caseInsensitiveCompare("BDMV") == .orderedSame
        }) else { return nil }
        let root = NSString.path(withComponents: Array(components.prefix(upTo: index)))
        guard !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    /// 是否为光盘镜像文件（只按扩展名判断，是否真是蓝光交由 ffmpeg 校验）。
    public static func isDiscImage(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "iso"
    }

    /// 主播放列表的信息：时长、章节、多角度数量。
    public struct PlaylistInfo {
        public let duration: Double
        public let chapters: [VideoChapter]
        /// 多角度视角数量；普通影片 / 无法解析时为 1。
        public let angleCount: Int
    }

    /// 读取主播放列表（与 libbluray / ffmpeg 一致：忽略 3 分钟以下，取最长的一条）。
    /// 只支持目录形式的原盘（ISO 内部文件无法用文件读取）。
    public static func playlistInfo(for url: URL) -> PlaylistInfo? {
        guard let root = discRoot(for: url), root.pathExtension.lowercased() != "iso" else { return nil }
        let playlistDirectory = root.appendingPathComponent("BDMV/PLAYLIST", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: playlistDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return nil }
        let playlists = files
            .filter { $0.pathExtension.lowercased() == "mpls" }
            .compactMap(Playlist.init(url:))
            .filter { $0.duration >= 180 }
        guard let main = playlists.max(by: { $0.duration < $1.duration }) else { return nil }
        return PlaylistInfo(duration: main.duration,
                            chapters: main.chapters,
                            angleCount: main.angleCount)
    }

    /// 蓝光章节：libbluray 不把播放列表的章节标记交给 ffmpeg，
    /// 这里直接读主播放列表（MPLS）的 PlayListMark 补上，否则电影盘的章节菜单是空的。
    /// 解析失败返回空数组。
    public static func chapters(for url: URL) -> [VideoChapter] {
        guard let info = playlistInfo(for: url), info.chapters.count > 1 else { return [] }
        return info.chapters
    }

    /// 多角度视角数量：1 表示普通影片（或无法解析）。
    /// 调用方用它决定是否显示「角度」菜单，并把选择交给 ffmpeg 的 `-angle`。
    public static func angleCount(for url: URL) -> Int {
        max(1, playlistInfo(for: url)?.angleCount ?? 1)
    }

    /// 盘内元数据标题（`BDMV/META/DL/bdmt_*.xml` 的 `<di:name>`）。
    ///
    /// 蓝光标准里没有「逐章文本名」：章节名只存在于 IG 交互菜单的位图里，
    /// ffmpeg / libbluray 读不出来。盘内可用的稳定文字信息只有碟片标题，
    /// 章节菜单用它做标题行，章节本身用「第 N 章」。
    public static func discTitle(for url: URL) -> String? {
        guard let root = discRoot(for: url), root.pathExtension.lowercased() != "iso" else { return nil }
        let directory = root.appendingPathComponent("BDMV/META/DL", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return nil }
        // 中文优先，其次英文，最后任意一份；bdmt_*.xml 是 UTF-8 的文本。
        let names = files.filter { $0.lastPathComponent.lowercased().hasSuffix(".xml") }
        let ordered = names.sorted { lhs, rhs in
            let left = preferredLanguageRank(lhs.lastPathComponent)
            let right = preferredLanguageRank(rhs.lastPathComponent)
            return left != right ? left < right : lhs.lastPathComponent < rhs.lastPathComponent
        }
        for file in ordered {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let title = firstValue(named: "name", in: text) else { continue }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func preferredLanguageRank(_ fileName: String) -> Int {
        let name = fileName.lowercased()
        if name.contains("zh") || name.contains("chi") || name.contains("zho") || name.contains("chs")
            || name.contains("cht") { return 0 }
        if name.contains("eng") { return 1 }
        return 2
    }

    /// 取 XML 里第一个 `<前缀:name>…</前缀:name>`（bdmt 的命名空间前缀与属性都不固定）。
    private static func firstValue(named field: String, in text: String) -> String? {
        let pattern = "<(?:[\\w.-]+:)?\(field)(?:\\s[^>]*)?>(.*?)</(?:[\\w.-]+:)?\(field)>"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text,
                                           range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// MPLS（Movie PlayList）里的时长、章节标记与角度数。
    private struct Playlist {
        let duration: Double
        let chapters: [VideoChapter]
        let angleCount: Int

        init?(url: URL) {
            guard let data = try? Data(contentsOf: url), data.count >= 20 else { return nil }
            let bytes = [UInt8](data)
            guard bytes[0] == 0x4D, bytes[1] == 0x50, bytes[2] == 0x4C, bytes[3] == 0x53 else {
                return nil // "MPLS"
            }
            let playlistStart = Int(Self.be32(bytes, 8))
            let markStart = Int(Self.be32(bytes, 12))
            guard playlistStart > 0, playlistStart + 10 <= bytes.count else { return nil }

            // PlayList：长度 4 + 保留 2 + 播放项数 2 + 子路径数 2。
            let itemCount = Int(Self.be16(bytes, playlistStart + 6))
            var offset = playlistStart + 10
            var itemStarts: [Double] = []
            var total: Double = 0
            var angles = 1
            for _ in 0..<itemCount {
                guard offset + 22 <= bytes.count else { break }
                let length = Int(Self.be16(bytes, offset))
                let inTime = Self.be32(bytes, offset + 14)
                let outTime = Self.be32(bytes, offset + 18)
                itemStarts.append(total)
                total += max(0, Double(outTime) - Double(inTime)) / 45_000
                // 角度数：playitem 的 flags 第 4 位是 multi_angle，
                // 置位时 UO mask(8) + random_access(1) + still_mode(1) + still_time(2) 之后是角度数。
                let flags = Self.be16(bytes, offset + 11)
                if (flags >> 4) & 1 == 1, offset + 35 <= bytes.count {
                    let count = Int(bytes[offset + 34])
                    if count > 1, count <= 9 { angles = max(angles, count) }
                }
                guard length > 0 else { break }
                offset += 2 + length
            }
            guard total > 0 else { return nil }

            // PlayListMark：长度 4 + 条目数 2，每条 15 字节（含 16 位保留）。
            // 少数工具生成的表每条 14 字节，按段长度自适应步长。
            var starts: [Double] = []
            if markStart > 0, markStart + 6 <= bytes.count {
                let markLength = Int(Self.be32(bytes, markStart))
                let markCount = Int(Self.be16(bytes, markStart + 4))
                let body = max(0, markLength - 2)
                var stride = 15
                if markCount > 0 {
                    let candidate = body / markCount
                    if candidate == 14 || candidate == 15 { stride = candidate }
                }
                var cursor = markStart + 6
                for _ in 0..<markCount {
                    guard cursor + 9 <= bytes.count else { break }
                    let type = bytes[cursor + 2]
                    let itemRef = Int(Self.be16(bytes, cursor + 3))
                    let timestamp = Self.be32(bytes, cursor + 5)
                    // type 1 = 章节标记；itemRef 是 1 起的播放项序号。
                    if type == 1, itemRef >= 1, itemRef <= itemStarts.count {
                        starts.append(itemStarts[itemRef - 1] + Double(timestamp) / 45_000)
                    }
                    cursor += stride
                }
            }
            let unique = Array(Set(starts.filter { $0.isFinite && $0 >= 0 && $0 < total - 1 })).sorted()

            self.duration = total
            self.angleCount = angles
            self.chapters = unique.enumerated().map { index, start in
                let end = index + 1 < unique.count ? unique[index + 1] : total
                return VideoChapter(start: start, end: end, title: "第 \(index + 1) 章")
            }
        }

        private static func be16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
            guard offset + 2 <= bytes.count else { return 0 }
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }

        private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
    }
}
