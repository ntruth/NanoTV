import SwiftUI
import AppKit

/// 框选共用的命名坐标系：网格单元格把自身矩形上报到这个空间，手指/鼠标位置也按它换算。
enum PhotoMarqueeSpace {
    static let name = "photoMarqueeGrid"
}

/// 给照片网格加上「从空白处拖动框选」。
///
/// - 单元格通过 `PhotoFramePreferenceKey` 上报矩形；
/// - `fillHeight` 传滚动视口高度，内容不足一屏时下方空白也能起框；
/// - 从照片内部按下时让位给系统拖拽（拖到桌面 / Finder / 相簿）。
struct PhotoMarqueeModifier: ViewModifier {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var selectionModel: SelectionModel

    var fillHeight: CGFloat?

    @State private var frames: [UUID: CGRect] = [:]
    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @State private var base: Set<UUID> = []
    /// 从照片内部按下时让位给系统拖拽，避免同时触发框选。
    @State private var blockedStart: CGPoint?

    private var marqueeRect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x),
                      y: min(start.y, current.y),
                      width: abs(current.x - start.x),
                      height: abs(current.y - start.y))
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: fillHeight, alignment: .top)
            .contentShape(Rectangle())
            .coordinateSpace(name: PhotoMarqueeSpace.name)
            .onPreferenceChange(PhotoFramePreferenceKey.self) { frames = $0 }
            .overlay(alignment: .topLeading) { marqueeOverlay }
            .simultaneousGesture(blankTapGesture)
            .simultaneousGesture(marqueeGesture)
    }

    /// 点空白处取消选择。用同时手势而不是 `onTapGesture`：
    /// 网格空白区域由容器命中，同时手势不会被单元格的点击吞掉，也不会抢单元格的点击。
    private var blankTapGesture: some Gesture {
        SpatialTapGesture(coordinateSpace: .named(PhotoMarqueeSpace.name))
            .onEnded { value in
                let hitPhoto = frames.values.contains { $0.contains(value.location) }
                guard !hitPhoto else { return }
                store.clearSelection()
            }
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let rect = marqueeRect, rect.width > 2, rect.height > 2 {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1)
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(PhotoMarqueeSpace.name))
            .onChanged { value in
                if let blocked = blockedStart {
                    if blocked == value.startLocation { return }
                    blockedStart = nil
                }
                if start == nil {
                    if frames.values.contains(where: { $0.contains(value.startLocation) }) {
                        blockedStart = value.startLocation
                        return
                    }
                    start = value.startLocation
                    let flags = NSEvent.modifierFlags
                    let additive = flags.contains(.command) || flags.contains(.shift)
                    base = additive ? selectionModel.ids : []
                    if !additive {
                        store.clearSelection()
                    }
                }
                current = value.location
                guard let rect = marqueeRect else { return }
                let hits = frames.filter { $0.value.intersects(rect) }.map(\.key)
                selectionModel.ids = base.union(hits)
            }
            .onEnded { _ in
                start = nil
                current = nil
                base = []
                blockedStart = nil
            }
    }
}

extension View {
    /// 在照片网格容器上加「空白处拖拽框选」；`fillHeight` 传滚动视口高度。
    func photoMarqueeSelection(fillHeight: CGFloat? = nil) -> some View {
        modifier(PhotoMarqueeModifier(fillHeight: fillHeight))
    }
}
