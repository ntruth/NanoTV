import AppKit
import AVFoundation
import CoreImage
import Foundation

/// 实时画面缓存：台标是兜底，抓到直播首帧后替换成画面预览。
/// 内存 / 磁盘 / 并发合并与台标、海报共用 `ArtworkCache`，这里只声明 30 分钟保鲜期。
actor TVPreviewCache {
    static let shared = TVPreviewCache()

    /// 画面预览的保鲜期：过期后重新抓一帧，避免长期显示已经换节目的旧画面。
    static let ttl: TimeInterval = 30 * 60

    func isFresh(_ id: String) -> Bool {
        ArtworkCache.isFresh(fileURL(id), maxAge: Self.ttl)
    }

    /// 只读内存 / 磁盘：截帧由信号页主动触发，这里不发起网络请求。
    /// 文件过期时仍先返回旧画面，等新一轮探测替换。
    func image(for id: String) async -> NSImage? {
        await ArtworkCache.shared.image(for: Self.key(id),
                                        diskURL: fileURL(id),
                                        maxPixelSize: 480,
                                        maxDiskAge: Self.ttl) { nil }
    }

    func store(_ image: NSImage, id: String) async {
        await ArtworkCache.shared.store(image,
                                        for: Self.key(id),
                                        diskURL: fileURL(id),
                                        maxWidth: 480,
                                        jpegQuality: 0.72)
    }

    func clearAll() async {
        await ArtworkCache.shared.removeAll()
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: - 路径

    private static var directory: URL {
        LibraryPaths.tvPreviewsDir
    }

    private func fileURL(_ id: String) -> URL {
        Self.directory.appendingPathComponent("\(Self.fnv1a64(id)).jpg")
    }

    private static func key(_ id: String) -> String {
        "tv-preview:\(id)"
    }

    private static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// 一次探测的可用率采样点：信号详情用它画 24 小时小折线。
struct TVProbePoint: Codable, Hashable {
    var date: Date
    var success: Bool
    var latencyMilliseconds: Int?
}

/// 一次频道探测的结果：截帧 + 媒体参数。
/// 信号页把这些数字当作「可看的证据」，失败时保留原因，不伪造画面。
struct TVProbeReport {
    var image: NSImage?
    /// 从发起请求到拿到第一帧的时间。
    var ttfbMilliseconds: Int?
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    /// 视频码率（bps）；拿不到时为 nil。
    var bitrate: Double?
    var error: String?
    var updatedAt: Date = Date()

    var isSuccess: Bool { image != nil }

    /// 短边决定「720p / 1080p」，避免竖屏素材把分辨率写成 1080×1920。
    var resolutionText: String {
        guard pixelWidth > 0, pixelHeight > 0 else { return "—" }
        let shortSide = min(pixelWidth, pixelHeight)
        switch shortSide {
        case 2000...: return "4K"
        case 1000...: return "1080p"
        case 700...: return "720p"
        case 500...: return "576p"
        default: return "\(shortSide)p"
        }
    }

    var bitrateText: String {
        guard let bitrate, bitrate > 0 else { return "—" }
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", bitrate / 1_000_000)
        }
        return String(format: "%.0f kbps", bitrate / 1000)
    }

    var latencyText: String {
        ttfbMilliseconds.map { "\($0) ms" } ?? "—"
    }
}
enum TVPreviewProbe {
    /// 直播首帧抓取：用 AVPlayer + VideoOutput 等第一帧，同时记录 TTFB、分辨率与码率。
    /// 只读不播，抓到一帧就停，避免长时间占用带宽。失败时保留原因，供信号卡展示。
    static func report(url: URL,
                       headers: [String: String],
                       timeout: TimeInterval = 12) async -> TVProbeReport {
        var report = TVProbeReport()
        let started = Date()
        let options: [String: Any] = headers.isEmpty
            ? [:]
            : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }

        let deadline = Date().addingTimeInterval(timeout)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        while Date() < deadline {
            if Task.isCancelled {
                report.error = "已取消"
                return report
            }
            if item.status == .failed {
                report.error = item.error?.localizedDescription ?? "连接失败"
                return report
            }
            let time = player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                report.ttfbMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
                let ciImage = CIImage(cvPixelBuffer: buffer)
                report.pixelWidth = Int(ciImage.extent.width.rounded())
                report.pixelHeight = Int(ciImage.extent.height.rounded())
                let scale = min(1, 480 / max(1, ciImage.extent.width))
                let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let cgImage = context.createCGImage(scaled, from: scaled.extent) {
                    report.image = NSImage(cgImage: cgImage,
                                           size: NSSize(width: cgImage.width, height: cgImage.height))
                } else {
                    report.error = "无法截帧"
                }
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if report.image == nil, report.error == nil {
            report.error = "\(Int(timeout)) 秒内没有画面"
        }
        report.bitrate = await bitrate(item: item, asset: asset)
        report.updatedAt = Date()
        return report
    }

    /// 优先用播放器实测码率；首帧阶段还没采样时退回轨道声明的码率。
    private static func bitrate(item: AVPlayerItem, asset: AVURLAsset) async -> Double? {
        if let observed = item.accessLog()?.events.last?.observedBitrate, observed > 0 {
            return observed
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            return Double(rate)
        }
        if let indicated = item.accessLog()?.events.last?.indicatedBitrate, indicated > 0 {
            return indicated
        }
        return nil
    }
}
