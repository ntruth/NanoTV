import Foundation
import NanoCore

/// 时间轴歌词单行模型（供 macOS 桌面歌词与 Apple TV 流体大屏滚动高亮）
public struct LyricTimedLine: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let timestampSec: Double
    public let content: String

    public init(timestampSec: Double, content: String) {
        self.timestampSec = timestampSec
        self.content = content
    }
}

/// 高解析度音乐中心引擎：支持整轨无损 `.cue` 自动虚拟分轨与 `.lrc` 时间轴解析
public struct HiFiMusicEngine: Sendable {
    public init() {}

    /// 解析整轨 `.cue` 文件，将单张大体积 `.flac/.wav/.ape` 拆分为多首独立虚拟曲目
    public static func parseCueSheet(
        cueText: String,
        sourceID: UUID,
        directoryPath: String,
        totalAudioDurationSec: Double = 3600
    ) -> [MusicTrack] {
        var albumTitle = "未知专辑"
        var albumArtist = "未知艺术家"
        var referencedAudioFile = ""

        struct RawCueTrack {
            var number: Int
            var title: String = ""
            var performer: String?
            var startSec: Double = 0
        }

        var rawTracks: [RawCueTrack] = []
        var currentTrack: RawCueTrack? = nil

        for rawLine in cueText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.uppercased().hasPrefix("PERFORMER ") {
                let val = extractQuotedValue(from: line)
                if currentTrack != nil {
                    currentTrack?.performer = val
                } else {
                    albumArtist = val
                }
            } else if line.uppercased().hasPrefix("TITLE ") {
                let val = extractQuotedValue(from: line)
                if currentTrack != nil {
                    currentTrack?.title = val
                } else {
                    albumTitle = val
                }
            } else if line.uppercased().hasPrefix("FILE ") {
                referencedAudioFile = extractQuotedValue(from: line)
            } else if line.uppercased().hasPrefix("TRACK ") {
                if let prev = currentTrack {
                    rawTracks.append(prev)
                }
                let parts = line.split(separator: " ")
                let num = parts.count >= 2 ? (Int(parts[1]) ?? (rawTracks.count + 1)) : (rawTracks.count + 1)
                currentTrack = RawCueTrack(number: num)
            } else if line.uppercased().hasPrefix("INDEX 01 ") {
                let timePart = line.dropFirst("INDEX 01 ".count).trimmingCharacters(in: .whitespaces)
                currentTrack?.startSec = parseCueTimestampToSeconds(String(timePart))
            }
        }
        if let last = currentTrack {
            rawTracks.append(last)
        }

        let cleanDir = directoryPath == "/" ? "" : directoryPath
        let targetVFSPath = "\(cleanDir)/\(referencedAudioFile)"
        let extUpper = (referencedAudioFile as NSString).pathExtension.uppercased()

        return rawTracks.enumerated().map { idx, item in
            let nextStart = (idx + 1 < rawTracks.count) ? rawTracks[idx + 1].startSec : totalAudioDurationSec
            let duration = max(1, nextStart - item.startSec)
            return MusicTrack(
                sourceID: sourceID,
                vfsPath: targetVFSPath,
                title: item.title.isEmpty ? "Track \(item.number)" : item.title,
                artist: item.performer ?? albumArtist,
                album: albumTitle,
                formatTag: extUpper.isEmpty ? "FLAC · CUE" : "\(extUpper) · CUE",
                startOffsetSec: item.startSec,
                durationSec: duration
            )
        }
    }

    /// 解析 `.lrc` 歌词文本并按时间戳升序排列
    public static func parseLRCLyrics(_ lrcText: String) -> [LyricTimedLine] {
        guard let regex = try? NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{2})(?:\\.(\\d{1,3}))?\\](.*)", options: []) else {
            return []
        }
        var lines: [LyricTimedLine] = []
        for raw in lrcText.components(separatedBy: .newlines) {
            let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let m = regex.firstMatch(in: raw, options: [], range: nsRange) else { continue }
            let minStr = Range(m.range(at: 1), in: raw).map { String(raw[$0]) } ?? "0"
            let secStr = Range(m.range(at: 2), in: raw).map { String(raw[$0]) } ?? "0"
            let msStr = (m.range(at: 3).location != NSNotFound) ? (Range(m.range(at: 3), in: raw).map { String(raw[$0]) } ?? "0") : "0"
            let text = Range(m.range(at: 4), in: raw).map { String(raw[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
            guard !text.isEmpty else { continue }

            let minutes = Double(minStr) ?? 0
            let seconds = Double(secStr) ?? 0
            let frac = (Double(msStr) ?? 0) / (msStr.count == 3 ? 1000.0 : 100.0)
            lines.append(LyricTimedLine(timestampSec: minutes * 60.0 + seconds + frac, content: text))
        }
        return lines.sorted { $0.timestampSec < $1.timestampSec }
    }

    public static func activeLyricIndex(in lines: [LyricTimedLine], at currentTimeSec: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        return lines.lastIndex { $0.timestampSec <= currentTimeSec } ?? 0
    }

    private static func extractQuotedValue(from line: String) -> String {
        let parts = line.split(separator: "\"")
        if parts.count >= 2 {
            return String(parts[1])
        }
        return line.split(separator: " ").dropFirst().joined(separator: " ")
    }

    /// CUE 时间格式为 `mm:ss:ff`，其中 `ff` 为 CD 扇区帧（1 秒 = 75 帧）
    private static func parseCueTimestampToSeconds(_ stamp: String) -> Double {
        let comps = stamp.split(separator: ":").compactMap { Double($0) }
        guard comps.count == 3 else { return 0 }
        return comps[0] * 60.0 + comps[1] + (comps[2] / 75.0)
    }
}
