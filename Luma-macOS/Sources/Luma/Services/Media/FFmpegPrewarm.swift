import Foundation

/// ffmpeg 的杜比视界运行时预热。
///
/// 打包进来的 ffmpeg-full 带 ~100 个动态库，libplacebo 还要初始化 Vulkan（MoltenVK）。
/// 冷启动第一次起流时，这些初始化会全部算在「点开视频 → 首帧」的等待里（约 1 秒）。
/// App 启动后空闲时先跑一个最小滤镜图，把动态库页缓存、Vulkan ICD 解析、
/// 设备创建与着色器编译都过一遍，真正播放时首段就只剩解码与封装的开销。
enum FFmpegPrewarm {
    private static let lock = NSLock()
    private static var hasScheduled = false

    static func schedule() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasScheduled else { return }
        hasScheduled = true
        // 没有 libplacebo 时（回退静态包）没有 Vulkan 初始化，预热收益可以忽略。
        guard FFmpeg.supportsLibplacebo else { return }

        // 让启动阶段的 UI / 图库加载先跑完，再占用一个低优先级后台线程。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard let ffmpeg = FFmpeg.libplaceboExecutable else { return }
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = [
                "-hide_banner", "-v", "error",
                "-f", "lavfi", "-i", "nullsrc=s=64x64:d=0.04",
                "-vf", "libplacebo=tonemapping=bt.2390:format=yuv420p",
                "-frames:v", "1", "-f", "null", "-"
            ]
            let environment = FFmpeg.processEnvironment
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment
                    .merging(environment) { _, new in new }
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let started = Date()
            do { try process.run() } catch { return }
            process.waitUntilExit()
            Diagnostics.record("视频运行时预热完成：\(Int(Date().timeIntervalSince(started) * 1000)) ms")
        }
    }
}
