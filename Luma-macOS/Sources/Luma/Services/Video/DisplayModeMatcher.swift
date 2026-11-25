import AppKit
import CoreGraphics

/// 按片源帧率切换显示器刷新率。
///
/// 24p 电影在 60Hz 屏幕上会走 3:2 pulldown，每 5 帧重复一帧，长镜头有轻微 judder。
/// 这里只改刷新率、不动分辨率：优先挑与当前尺寸相同、刷新率最接近片源的模式，
/// 并用 `.forSession` 提交，退出播放或登出后系统自动恢复。
@MainActor
enum DisplayModeMatcher {
    private static var originalMode: CGDisplayMode?
    private static var activeDisplay: CGDirectDisplayID?

    /// 按帧率切到最接近的刷新率；找不到合适模式就保持原样。
    static func match(frameRate rate: Double, display: CGDirectDisplayID? = nil) {
        guard rate > 1 else { return }
        let displayID = display ?? CGMainDisplayID()
        guard let current = CGDisplayCopyDisplayMode(displayID) else { return }

        // 记住进入播放前的模式：换片 / 退出时恢复。
        if activeDisplay != displayID {
            if activeDisplay != nil { restore() }
            originalMode = current
            activeDisplay = displayID
        }

        let target = targetRefresh(for: rate)
        guard abs(current.refreshRate - target) > 0.5 else { return }
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else { return }

        // 必须保持当前分辨率与像素尺寸，只换刷新率，避免切模式时窗口重排。
        let candidates = modes.filter {
            $0.width == current.width
                && $0.height == current.height
                && $0.pixelWidth == current.pixelWidth
                && $0.pixelHeight == current.pixelHeight
                && $0.refreshRate > 0
        }
        guard let best = candidates.min(by: {
            abs($0.refreshRate - target) < abs($1.refreshRate - target)
        }) else { return }
        // 最近模式离目标超过 2.5Hz 就不切，避免 24p 被硬切到 30Hz 这类更差的结果。
        guard abs(best.refreshRate - target) <= 2.5 else { return }
        apply(best, on: displayID)
    }

    /// 恢复进入播放前的刷新率。
    static func restore() {
        guard let display = activeDisplay, let mode = originalMode else { return }
        apply(mode, on: display)
        activeDisplay = nil
        originalMode = nil
    }

    private static func apply(_ mode: CGDisplayMode, on display: CGDirectDisplayID) {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
              let configuration else { return }
        CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
        CGCompleteDisplayConfiguration(configuration, .forSession)
    }

    /// 片源帧率 → 目标刷新率；不认识的帧率原样返回，交给候选模式去取最接近值。
    private static func targetRefresh(for rate: Double) -> Double {
        let table: [(source: Double, refresh: Double)] = [
            (23.976, 24), (24, 24), (25, 25),
            (29.97, 30), (30, 30),
            (48, 48), (50, 50),
            (59.94, 60), (60, 60),
            (100, 100), (119.88, 120), (120, 120)
        ]
        var best = rate
        var delta = Double.greatestFiniteMagnitude
        for item in table {
            let distance = abs(rate - item.source)
            if distance < delta {
                delta = distance
                best = item.refresh
            }
        }
        // 23.976 这类 NTSC 帧率允许 0.6 的误差；超过说明是少见帧率，直接按原值找最近模式。
        return delta <= 0.6 ? best : rate
    }
}
