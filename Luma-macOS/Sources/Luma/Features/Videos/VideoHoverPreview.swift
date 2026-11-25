import SwiftUI
import AppKit
import AVFoundation
import QuartzCore

/// 视频卡片悬停预览的句柄：卡片持有它，播放器视图挂载后把自身登记进来，
/// 这样拖动进度的 seek 不需要把 AVPlayer 暴露给视图层。
@MainActor
final class VideoPreviewHandle {
    fileprivate weak var surface: VideoPreviewNSView?

    func seek(toFraction fraction: Double) {
        surface?.seek(toFraction: fraction)
    }
}

/// 悬停时才挂载的静音循环预览。移除视图即停止播放，保证同一时间最多一个解码器。
struct HoverVideoSurface: NSViewRepresentable {
    let url: URL
    /// 远端流需要的请求头（Referer / UA 等）；本地文件为空。
    var headers: [String: String] = [:]
    let handle: VideoPreviewHandle
    var onProgress: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, headers: headers)
    }

    func makeNSView(context: Context) -> VideoPreviewNSView {
        let view = VideoPreviewNSView()
        view.onProgress = onProgress
        view.load(url: url, headers: headers)
        handle.surface = view
        return view
    }

    func updateNSView(_ nsView: VideoPreviewNSView, context: Context) {
        nsView.onProgress = onProgress
        guard context.coordinator.url != url || context.coordinator.headers != headers else { return }
        context.coordinator.url = url
        context.coordinator.headers = headers
        nsView.load(url: url, headers: headers)
    }

    static func dismantleNSView(_ nsView: VideoPreviewNSView, coordinator: Coordinator) {
        nsView.stop()
    }

    final class Coordinator {
        var url: URL
        var headers: [String: String]

        init(url: URL, headers: [String: String] = [:]) {
            self.url = url
            self.headers = headers
        }
    }
}

/// 只负责把 AVPlayerLayer 铺满卡片：静音、循环、回调播放进度。
final class VideoPreviewNSView: NSView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    var onProgress: ((Double) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let host = CALayer()
        host.backgroundColor = NSColor.clear.cgColor
        layer = host
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.player = player
        host.addSublayer(playerLayer)
        player.isMuted = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func load(url: URL, headers: [String: String] = [:]) {
        stop()
        var options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        if !headers.isEmpty {
            options[CloudPlayback.headerFieldsKey] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        // HLS 用 AVPlayerLooper 反而容易卡在准备阶段：改成播完回到开头，兼容点播流。
        player.removeAllItems()
        player.insert(item, after: nil)
        player.play()
        statusObservation = item.observe(\.status, options: [.new]) { item, _ in
            if item.status == .failed {
                Diagnostics.record("悬停预览播放失败：\(item.error?.localizedDescription ?? "未知错误")")
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.player.seek(to: .zero)
            self.player.play()
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.15, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            let total = self.player.currentItem?.duration.seconds ?? 0
            guard total.isFinite, total > 0 else { return }
            self.onProgress?(min(1, max(0, seconds / total)))
        }
    }

    func seek(toFraction fraction: Double) {
        guard let item = player.currentItem else { return }
        let total = item.duration.seconds
        guard total.isFinite, total > 0 else { return }
        let target = CMTime(seconds: total * min(1, max(0, fraction)),
                            preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        player.removeAllItems()
    }
}
