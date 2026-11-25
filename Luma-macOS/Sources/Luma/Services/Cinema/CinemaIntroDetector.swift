import Foundation
import AVFoundation

/// 片头 / 片尾自动识别：对本地视频的开头与结尾跑 ffmpeg 静音检测。
/// 找到开头最后一段静音的结束点作为片头时长，结尾第一段静音的起点作为片尾时长。
/// 只做本地文件；网盘视频需要先落地，不在自动识别范围内。
enum CinemaIntroDetector {
    static func detect(url: URL, duration: Double) async -> CinemaIntroMark? {
        guard let ffmpeg = FFmpeg.executable else { return nil }
        var total = duration
        if total <= 0 {
            total = await VideoSupport.probe(asset: AVURLAsset(url: url)).duration
        }
        guard total > 60 else { return nil }

        let headSegments = await silenceSegments(ffmpeg: ffmpeg, url: url, start: 0,
                                                 length: min(240, total))
        let tailBase = max(0, total - 240)
        let tail = await silenceSegments(ffmpeg: ffmpeg, url: url, start: tailBase,
                                         length: min(240, total - tailBase))

        // 片头：开头 180 秒内最后一段静音的结束点，限制在 5–150 秒。
        var intro = 0
        for segment in headSegments {
            if let end = segment.end, end <= 180 {
                intro = Int(end.rounded())
            }
        }
        if intro < 5 || intro > 150 { intro = 0 }

        // 片尾：结尾 240 秒内第一段静音的起点，换算成「剩余多少秒」。
        var outro = 0
        if let first = tail.first, let start = first.start {
            let remaining = total - (tailBase + start)
            if remaining >= 5, remaining <= 240 {
                outro = Int(remaining.rounded())
            }
        }

        // 圆整到 5 秒，避免出现 37 秒这类难读的数值。
        intro = roundToFive(intro)
        outro = roundToFive(outro)
        guard intro > 0 || outro > 0 else { return nil }
        return CinemaIntroMark(introSeconds: intro, outroSeconds: outro)
    }

    private struct Segment {
        var start: Double?
        var end: Double?
    }

    private static func silenceSegments(ffmpeg: URL,
                                        url: URL,
                                        start: Double,
                                        length: Double) async -> [Segment] {
        guard length > 1 else { return [] }
        let process = Process()
        process.executableURL = ffmpeg
        var arguments = ["-hide_banner", "-nostats", "-v", "info"]
        if start > 0 { arguments += ["-ss", String(format: "%.2f", start)] }
        arguments += ["-t", String(format: "%.2f", length),
                      "-i", url.path,
                      "-af", "silencedetect=noise=-35dB:d=1.5",
                      "-f", "null", "-"]
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        // 静音检测要顺序解音频，给 25 秒上限，超时直接放弃。
        let deadline = Date().addingTimeInterval(25)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    private static func parse(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var current: Segment?
        for line in text.split(separator: "\n") {
            if let range = line.range(of: "silence_start:") {
                let value = Double(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
                if let value {
                    if let finished = current { segments.append(finished) }
                    current = Segment(start: value, end: nil)
                }
            } else if let range = line.range(of: "silence_end:") {
                let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                let value = Double(rest.split(separator: " ").first ?? "")
                if let value {
                    if var segment = current {
                        segment.end = value
                        segments.append(segment)
                    } else {
                        segments.append(Segment(start: nil, end: value))
                    }
                    current = nil
                }
            }
        }
        if let current { segments.append(current) }
        return segments
    }

    private static func roundToFive(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        return Int((Double(value) / 5).rounded()) * 5
    }
}
