import AppKit
import AVFoundation
import SwiftUI

/// 进度条悬停 / 拖动时的画面预览：用当前播放项生成该时间点附近的一帧。
///
/// 取帧密度按片长自适应——短片段 1 秒一帧，长片 10 秒一帧。
/// 和 YouTube / Plex 的 storyboard 取向一致：预览只用来认场景，
/// 不必逐秒解码；同一采样段内来回滑动直接命中缓存。
enum VideoScrubThumbnails {
    private static var generators: [ObjectIdentifier: AVAssetImageGenerator] = [:]
    private static let lock = NSLock()

    /// 预览帧缓存：按「片源 + 采样段」存储，来回滑动不再重复解码。
    private static let images = MemoryImageCache(totalCostLimit: 120 * 1024 * 1024, countLimit: 120)

    /// 一段距离一帧：片长越长，采样段越长。
    static func sampleInterval(for duration: Double) -> Double {
        if duration <= 180 { return 1 }
        if duration <= 600 { return 2 }
        if duration <= 1800 { return 5 }
        return 10
    }

    /// 把时间点对齐到所在采样段的中间：同一段内滑动不会触发新的解码。
    static func sampleSeconds(for seconds: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        let interval = sampleInterval(for: duration)
        let clamped = max(0, min(duration, seconds))
        return min(duration, floor(clamped / interval) * interval + interval / 2)
    }

    static func image(player: AVPlayer, fraction: Double, duration: Double) async -> NSImage? {
        guard duration > 0 else { return nil }
        return await image(player: player,
                           seconds: duration * fraction,
                           duration: duration)
    }

    /// 同步查缓存：命中时气泡立即出图，不经过取帧任务。
    static func cachedImage(player: AVPlayer,
                            fraction: Double,
                            duration: Double) -> NSImage? {
        guard duration > 0, let asset = player.currentItem?.asset else { return nil }
        let target = sampleSeconds(for: duration * fraction, duration: duration)
        return images.object(forKey: cacheKey(asset: asset, seconds: target))
    }

    static func image(player: AVPlayer, seconds: Double, duration: Double) async -> NSImage? {
        guard seconds.isFinite, seconds >= 0, let asset = player.currentItem?.asset else { return nil }
        let target = sampleSeconds(for: seconds, duration: duration)
        let key = cacheKey(asset: asset, seconds: target)
        if let cached = images.object(forKey: key) { return cached }

        let generator = generator(for: asset)
        generator.maximumSize = CGSize(width: 320, height: 180)
        // HLS 的关键帧间隔较大，放宽一点容差，避免经常取不到帧。
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.8, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.8, preferredTimescale: 600)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            let image = NSImage(cgImage: cgImage,
                                size: NSSize(width: cgImage.width, height: cgImage.height))
            images.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }

    private static func cacheKey(asset: AVAsset, seconds: Double) -> NSString {
        let identity = UInt(bitPattern: ObjectIdentifier(asset))
        return "\(identity)-\(Int((seconds * 1000).rounded()))" as NSString
    }

    /// 从原始片源抽帧：HLS 会话只覆盖已生成区间，拖到未生成位置时用 ffmpeg 补一帧。
    static func sourceImage(source: URL,
                            headers: [String: String],
                            seconds: Double,
                            duration: Double) async -> NSImage? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let target = sampleSeconds(for: seconds, duration: duration)
        let key = "src-\(source.path)-\(Int((target * 1000).rounded()))" as NSString
        if let cached = images.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .utility) {
            ffmpegFrame(source: source, headers: headers, seconds: target)
        }.value
        if let image { images.setObject(image, forKey: key) }
        return image
    }

    private static func ffmpegFrame(source: URL,
                                    headers: [String: String],
                                    seconds: Double) -> NSImage? {
        guard let ffmpeg = FFmpeg.executable else { return nil }
        var arguments = ["-v", "error"]
        if !headers.isEmpty {
            let fields = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
            arguments += ["-headers", fields]
        }
        // -ss 放在 -i 之前：快速定位，只读目标附近的数据。
        arguments += ["-ss", String(format: "%.3f", seconds),
                      "-i", source.isFileURL ? source.path : source.absoluteString,
                      "-frames:v", "1",
                      "-vf", "scale=320:-2",
                      "-f", "image2pipe", "-vcodec", "png", "-"]

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
            return nil
        }
        // SMB / 网盘定位可能要一两秒：最多等 8 秒，超时就放弃这一帧。
        if finished.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.terminationHandler = nil
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    private static func generator(for asset: AVAsset) -> AVAssetImageGenerator {
        let key = ObjectIdentifier(asset)
        lock.lock()
        defer { lock.unlock() }
        if let cached = generators[key] { return cached }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generators[key] = generator
        return generator
    }
}

// MARK: - 工具栏进度条的悬停预览

/// 顶栏进度条的悬停预览状态。
/// 工具栏自己的容器装不下预览气泡，所以只在这里发状态，由播放页在画面上画；
/// 取帧按采样段缓存，来回滑动命中缓存就不必再解码。
@MainActor
final class VideoScrubPreviewCenter: ObservableObject {
    static let shared = VideoScrubPreviewCenter()

    @Published private(set) var fraction: Double?
    @Published private(set) var image: NSImage?
    @Published private(set) var duration: Double = 0
    /// 鼠标在窗口坐标里的横坐标（左下原点）：播放页据此把气泡对准光标。
    @Published private(set) var windowX: CGFloat?

    /// 由播放页注册：HLS 会话取不到帧（拖到未生成区间）时，用原始源补一帧。
    var fallbackProvider: ((Double, Double) async -> NSImage?)?

    private var task: Task<Void, Never>?

    func hover(fraction: Double, duration: Double, player: AVPlayer, window: NSWindow?) {
        self.fraction = fraction
        self.duration = duration
        if let window {
            windowX = window.convertPoint(fromScreen: NSEvent.mouseLocation).x
        }
        requestFrame(player: player)
    }

    func end() {
        fraction = nil
        image = nil
        windowX = nil
        task?.cancel()
        task = nil
    }

    private func requestFrame(player: AVPlayer) {
        task?.cancel()
        guard let requested = fraction else { return }
        let total = duration
        task = Task { @MainActor in
            // 快速划过时先不取帧：停住 55ms 再取，既不闪也不抢解码。
            try? await Task.sleep(nanoseconds: 55_000_000)
            guard !Task.isCancelled else { return }
            if let cached = VideoScrubThumbnails.cachedImage(player: player,
                                                             fraction: requested,
                                                             duration: total) {
                if self.fraction != nil { image = cached }
                return
            }
            var frame = await VideoScrubThumbnails.image(player: player,
                                                         fraction: requested,
                                                         duration: total)
            if frame == nil, let provider = fallbackProvider {
                // 拖到未生成区间：HLS 里没有这一帧，改从原始片源抽一帧。
                frame = await provider(requested, total)
            }
            guard !Task.isCancelled, let frame else { return }
            if self.fraction != nil { image = frame }
        }
    }
}

/// 顶栏进度条的悬停预览气泡：画在工具栏之外（视频这一层），
/// 水平跟着光标、竖直贴在进度条下方，像 YouTube / Infuse 那样。
struct VideoScrubPreviewOverlay: View {
    @ObservedObject private var center = VideoScrubPreviewCenter.shared
    /// 气泡顶部在画面里的位置：全屏视频浮在工具栏下方，窗口内贴着画面上沿。
    var topInset: CGFloat = 8

    private let bubbleWidth: CGFloat = 176
    private let bubbleHeight: CGFloat = 99

    @State private var originInWindow: CGRect = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                if center.fraction != nil {
                    bubble
                        .frame(width: bubbleWidth, height: bubbleHeight, alignment: .top)
                        .position(x: bubbleX(in: proxy.size),
                                  y: topInset + bubbleHeight / 2)
                        .transition(.opacity)
                }
            }
            .background {
                WindowOriginReader { rect in
                    guard abs(rect.minX - originInWindow.minX) > 0.5
                            || abs(rect.minY - originInWindow.minY) > 0.5 else { return }
                    originInWindow = rect
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: center.fraction != nil)
    }

    @ViewBuilder
    private var bubble: some View {
        if let image = center.image {
            ZStack {
                Color.black.opacity(0.72)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
            .frame(width: bubbleWidth, height: bubbleHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.26), lineWidth: 0.8)
            }
            .overlay(alignment: .bottomTrailing) {
                timeBadge
            }
            .shadow(color: .black.opacity(0.50), radius: 16, y: 6)
        } else if let fraction = center.fraction, center.duration > 0 {
            // 还没取到帧（或该位置不可预览）：只显示时间胶囊，不画空黑框。
            Text(formatScrubTime(center.duration * fraction))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(.black.opacity(0.72)))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        }
    }

    @ViewBuilder
    private var timeBadge: some View {
        if let fraction = center.fraction, center.duration > 0 {
            Text(formatScrubTime(center.duration * fraction))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(.black.opacity(0.62), in: Capsule(style: .continuous))
                .padding(6)
        }
    }

    /// 气泡中心的横坐标：优先跟光标（窗口坐标换算到画面坐标），
    /// 拿不到窗口时按进度比例在顶栏播放舱里估算。
    private func bubbleX(in size: CGSize) -> CGFloat {
        let half = bubbleWidth / 2
        let raw: CGFloat
        if let windowX = center.windowX {
            raw = windowX - originInWindow.minX
        } else if let fraction = center.fraction {
            let deckWidth: CGFloat = 560
            let trackLeft = max(0, (size.width - deckWidth) / 2) + 12
            let trackWidth = max(40, deckWidth - 24 - 28 - 6)
            raw = trackLeft + trackWidth * fraction
        } else {
            raw = size.width / 2
        }
        return min(max(half + 4, raw), max(half + 4, size.width - half - 4))
    }
}

/// 把自身在窗口坐标里的位置报出来（左下原点）：预览气泡要贴着进度条，
/// 但工具栏自己装不下它，只能换算到播放页的坐标里。
private struct WindowOriginReader: NSViewRepresentable {
    var onChange: (CGRect) -> Void

    final class Probe: NSView {
        var onChange: ((CGRect) -> Void)?

        override func layout() {
            super.layout()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        private func report() {
            guard window != nil else { return }
            let rect = convert(bounds, to: nil)
            // 布局过程中改状态要推到下一轮，避免 «Modifying state during view update»。
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(rect)
            }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.onChange = onChange
    }
}

/// 进度条气泡上的时间：留小时位，短片段仍显示 mm:ss。
func formatScrubTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}
