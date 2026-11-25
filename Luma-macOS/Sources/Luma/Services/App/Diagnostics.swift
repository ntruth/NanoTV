import Foundation
import AppKit

/// 本地诊断日志与导出。
/// 不接入第三方崩溃平台；只把启动信息、未捕获异常与用户主动导出的环境信息写到本机日志，
/// 方便用户反馈问题时附上，不包含照片内容或 API Key。
enum Diagnostics {
    /// 日志详细程度：设置页 › 影院 › 高级可调。
    enum Level: Int, CaseIterable {
        case important = 0
        case standard = 1
        case verbose = 2

        var title: String {
            switch self {
            case .important: return "精简（只记关键事件）"
            case .standard: return "标准"
            case .verbose: return "详细（含逐帧诊断）"
            }
        }

        static var current: Level {
            switch UserDefaults.standard.string(forKey: SettingsKeys.cinemaLogLevel) ?? "standard" {
            case "important": return .important
            case "verbose": return .verbose
            default: return .standard
            }
        }
    }

    private static let lock = NSLock()
    private static let logDirectory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/Luma", isDirectory: true)
    }()
    static var logURL: URL { logDirectory.appendingPathComponent("diagnostics.log") }

    static func install() {
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        NSSetUncaughtExceptionHandler { exception in
            Diagnostics.record("Uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "")")
            Diagnostics.record(exception.callStackSymbols.joined(separator: "\n"))
        }
        record("App launched: \(appVersion) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    static func record(_ message: String, level: Level = .important) {
        guard level.rawValue <= Level.current.rawValue else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    /// 导出到桌面，返回生成的文件 URL，便于用户附在反馈里。
    @discardableResult
    static func exportReport(libraryPath: String?) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "Luma-Diagnostics-\(formatter.string(from: Date())).txt"
        let destination = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        var report = """
        Luma 诊断报告
        版本：\(appVersion)
        系统：\(ProcessInfo.processInfo.operatingSystemVersionString)
        架构：\(machineArchitecture)
        当前图库：\(libraryPath ?? "未打开")
        生成时间：\(Date())
        ----------------------------------------
        最近日志：
        """
        if let data = try? Data(contentsOf: logURL),
           let text = String(data: data, encoding: .utf8) {
            let lines = text.split(separator: "\n").suffix(200)
            report += "\n" + lines.joined(separator: "\n")
        } else {
            report += "\n（暂无日志）"
        }
        report += "\n"
        do {
            try report.write(to: destination, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            return destination
        } catch {
            record("导出诊断报告失败：\(error.localizedDescription)")
            return nil
        }
    }

    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    private static var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
