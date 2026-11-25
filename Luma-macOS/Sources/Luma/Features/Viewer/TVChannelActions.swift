import SwiftUI
import LumaContentCore

/// 电视频道动作的唯一实现：窗口工具栏与画面 OSD 共用同一套按钮、同一顺序。
/// 顺序固定：回到直播（时移中）/ 时移 / 线路 / 睡眠 / 录制 / 截帧 / 节目单 / 收藏。
struct TVChannelActionCluster: View {
    /// 放的位置不同，视觉不同，但动作与顺序完全一致。
    enum Style {
        case toolbar
        case overlay
    }

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel
    @EnvironmentObject private var viewer: ViewerModel

    let channel: TVChannel
    let photoID: UUID
    let isLive: Bool
    @Binding var timeshiftActive: Bool
    @Binding var showGuide: Bool
    var style: Style = .toolbar
    /// 时移中「回到直播」的出口：OSD 用它播收束动画，工具栏直接跳回直播边缘。
    var onReturnToLive: (() -> Void)?
    var onToggleTimeshift: () -> Void
    var onCapture: () -> Void

    private var lineIndex: Int { store.tvLineIndex(for: photoID) }
    private var lineCount: Int { store.tvLineCount(for: photoID) }
    private var isFavorite: Bool { tv.isFavorite(channel) }

    var body: some View {
        HStack(spacing: style == .overlay ? 4 : 1) {
            if isLive, timeshiftActive, let onReturnToLive {
                button("play.circle.fill", help: "回到直播 (L)", active: true, action: onReturnToLive)
                if style == .overlay { keyHint("L") }
            }
            if isLive {
                button("clock.arrow.circlepath",
                       help: timeshiftActive ? "收起时间河" : "时移：暂停直播，回看刚过去的画面",
                       active: timeshiftActive,
                       action: onToggleTimeshift)
            }
            if isLive, lineCount > 1 { lineMenu }
            if isLive {
                sleepMenu
                button("record.circle", help: "录制 30 秒片段") {
                    TVClipRecorder.shared.record(channel: channel) { message in
                        store.showToast(message)
                    }
                }
            }
            button("camera", help: "截帧保存（连同频道 / 节目信息）", action: onCapture)
            button(showGuide ? "sidebar.right" : "list.bullet.rectangle",
                   help: "节目单 (E)",
                   active: showGuide) {
                showGuide.toggle()
            }
            button(isFavorite ? "star.fill" : "star",
                   help: "收藏频道 (S)",
                   active: isFavorite) {
                tv.toggleFavorite(channel)
                store.showToast(tv.isFavorite(channel)
                                ? "已收藏 \(channel.name)"
                                : "已取消收藏 \(channel.name)")
            }
        }
    }

    // MARK: - 按钮

    @ViewBuilder
    private func button(_ symbol: String,
                        help: String,
                        active: Bool = false,
                        action: @escaping () -> Void) -> some View {
        switch style {
        case .toolbar:
            VideoDeckButton(icon: symbol, active: active, help: help, action: action)
        case .overlay:
            Button(action: action) {
                iconLabel(symbol, active: active)
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }

    /// 线路选择：与 OSD / 工具栏共用同一枚图标。
    private var lineMenu: some View {
        Menu {
            ForEach(Array(channel.streamLines.enumerated()), id: \.offset) { pair in
                Button {
                    store.selectTVLine(pair.offset, for: photoID)
                } label: {
                    Text(pair.offset == lineIndex
                         ? "✓ 线路 \(pair.offset + 1)"
                         : "线路 \(pair.offset + 1)")
                }
            }
        } label: {
            iconLabel("arrow.triangle.2.circlepath")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("选择线路 · 当前 \(lineIndex + 1)/\(lineCount)（← → 循环）")
    }

    /// 睡眠定时：30 / 60 / 90 分钟后渐隐停止。
    private var sleepMenu: some View {
        Menu {
            ForEach([30, 60, 90], id: \.self) { minutes in
                Button("\(minutes) 分钟后停止") {
                    viewer.startTVSleepTimer(minutes: minutes)
                    store.showToast("已设置 \(minutes) 分钟睡眠定时")
                }
            }
            if viewer.tvSleepMinutes != nil {
                Divider()
                Button("关闭睡眠定时") {
                    viewer.cancelTVSleepTimer()
                    store.showToast("已关闭睡眠定时")
                }
            }
        } label: {
            iconLabel("moon.zzz", active: viewer.tvSleepMinutes != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(viewer.tvSleepMinutes.map { "睡眠定时：\($0) 分钟后停止" } ?? "睡眠定时")
    }

    // MARK: - 图标样式

    @ViewBuilder
    private func iconLabel(_ symbol: String, active: Bool = false) -> some View {
        switch style {
        case .toolbar:
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.82))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        case .overlay:
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(active ? TVBrand.gold : Color.white.opacity(0.82))
                .frame(width: 26, height: 24)
                .background(Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func keyHint(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.62))
            .frame(width: 22, height: 22)
            .background(Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
            }
            .help("\(key) 回到直播")
    }
}
