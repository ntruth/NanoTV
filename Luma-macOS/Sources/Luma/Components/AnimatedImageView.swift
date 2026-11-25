import SwiftUI
import AppKit

/// 动图播放：基于 `NSImageView` 的逐帧能力，打开即循环播放。
/// 只负责渲染，解码与取图由 `ImageLoader` / `LibraryStore` 负责。
struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.animates = true
        view.image = image
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard view.image !== image else { return }
        // 关闭再打开 animates，切换动图时从头开始播放。
        view.animates = false
        view.image = image
        view.animates = true
    }
}
