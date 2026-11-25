import Foundation
import PlaybackCore

/// 从视频文件里提取内嵌字幕轨，转成 ASS 文本后交给统一的字幕覆盖层渲染。
/// 只处理文本字幕；PGS / VobSub 等图形字幕会失败，调用方提示改用烧录。
enum EmbeddedSubtitleLoader {
    /// 提取指定字幕轨；失败或超时返回空数组。
    static func extract(source: URL,
                        headers: [String: String],
                        trustSelfSigned: Bool,
                        track: Int) async -> [SubtitleCue] {
        await Task.detached(priority: .userInitiated) {
            extractSync(source: source,
                        headers: headers,
                        trustSelfSigned: trustSelfSigned,
                        track: track)
        }.value
    }

    private static func extractSync(source: URL,
                                    headers: [String: String],
                                    trustSelfSigned: Bool,
                                    track: Int) -> [SubtitleCue] {
        guard let ffmpeg = FFmpeg.executable else { return [] }
        var arguments = ["-v", "error"]
        if trustSelfSigned { arguments += ["-tls_verify", "0"] }
        if !headers.isEmpty {
            // ffmpeg 的 -headers 用 CRLF 分隔多条请求头，必须放在 -i 之前。
            let fields = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
            arguments += ["-headers", fields]
        }
        // 蓝光目录 / ISO 交给 bluray 协议；普通文件用路径。
        let input = BluraySource.ffmpegInput(for: source)
            ?? (source.isFileURL ? source.path : source.absoluteString)
        arguments += ["-i", input,
                      "-map", "0:s:\(track)",
                      // ASS muxer 接受任意文本字幕并保留样式；SRT 会补一套默认样式。
                      "-f", "ass", "-"]

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return []
        }
        // 网盘读区间偶尔很慢：最多等 30 秒。
        if finished.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.terminationHandler = nil
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return SubtitleParser.parse(text: text, fileExtension: "ass")
    }
}
