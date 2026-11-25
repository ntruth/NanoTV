import Foundation
import PlaybackCore

/// 外挂字幕加载：解析在 PlaybackCore，本文件只保留图库 / 本地目录的发现逻辑。
/// 这里仍只做文本渲染，不处理 ASS 样式与定位（复杂排版会被压成纯文本）。
enum SubtitleLoader {
    static let supportedExtensions = SubtitleParser.supportedExtensions

    static func load(url: URL) -> [SubtitleCue] {
        SubtitleParser.load(url: url)
    }

    static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        SubtitleParser.cue(at: time, in: cues)
    }

    /// 同目录同名的外挂字幕候选：movie.mkv → movie.srt / movie.zh-Hans.srt / movie.en.srt。
    /// 图库的 originals 分片目录可能有几万个文件，逐个构造 URL 枚举会卡住调用线程：
    /// 先按精确同名做 4 次 stat，实在没有再退回字符串枚举。
    static func discoverSiblings(of videoURL: URL) -> [URL] {
        guard videoURL.isFileURL else { return [] }
        // 图库里（originals / renders）的文件不会带外挂字幕：一个分片目录可能有几万个文件，
        // 直接跳过整目录扫描，否则打开本地视频会卡住好几秒。
        if videoURL.path.hasPrefix(LibraryPaths.root.path + "/") { return [] }
        let directory = videoURL.deletingLastPathComponent()
        let base = videoURL.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        var found: [URL] = []
        for ext in supportedExtensions {
            let exact = directory.appendingPathComponent("\(base).\(ext)", isDirectory: false)
            if fm.fileExists(atPath: exact.path) { found.append(exact) }
        }
        // 目录枚举在后台队列执行：only 精确同名会漏掉 movie.zh-Hans.srt 这类带语言后缀的文件，
        // 只有枚举失败时才退回已找到的精确同名。
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return found
        }
        var seen = Set(found.map(\.lastPathComponent))
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            guard supportedExtensions.contains(ext), !seen.contains(name) else { continue }
            let stem = (name as NSString).deletingPathExtension
            guard stem.hasPrefix(base) else { continue }
            seen.insert(name)
            found.append(directory.appendingPathComponent(name))
        }
        return found
    }

    /// 按字幕语言偏好挑一条外挂字幕：简体 > 繁体 > 中文 > 无语言标记 > 英语 > 其他。
    /// 同分时文件名更短的优先（`movie.zh.srt` 优于 `movie.zh-Hans.forced.srt`）。
    static func preferredSibling(of videoURL: URL) -> URL? {
        let base = videoURL.deletingPathExtension().lastPathComponent
        let candidates = discoverSiblings(of: videoURL)
        return candidates.min { lhs, rhs in
            let leftRank = SubtitlePreference.rank(externalFileName: lhs.lastPathComponent,
                                                   baseName: base)
            let rightRank = SubtitlePreference.rank(externalFileName: rhs.lastPathComponent,
                                                    baseName: base)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftName = lhs.lastPathComponent
            let rightName = rhs.lastPathComponent
            if leftName.count != rightName.count { return leftName.count < rightName.count }
            return leftName < rightName
        }
    }

    /// 恢复记忆时按文件名精确查找同目录外挂字幕。
    static func sibling(named name: String, of videoURL: URL) -> URL? {
        guard videoURL.isFileURL, !name.isEmpty else { return nil }
        if videoURL.path.hasPrefix(LibraryPaths.root.path + "/") { return nil }
        let directory = videoURL.deletingLastPathComponent()
        let candidate = directory.appendingPathComponent(name, isDirectory: false)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
