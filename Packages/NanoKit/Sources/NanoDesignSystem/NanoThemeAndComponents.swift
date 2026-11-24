import NanoCore
import SwiftUI

// MARK: - 1. 暗夜深空色彩与材质 Token（1:1 提炼自参考 UI）

public enum NanoPalette {
    public static let deepSpaceTop = Color(red: 0.05, green: 0.07, blue: 0.12)      // #0D121F
    public static let deepSpaceBottom = Color(red: 0.03, green: 0.05, blue: 0.08)   // #080C14
    public static let sidebarBackground = Color(red: 0.04, green: 0.06, blue: 0.10) // #0A0F1A
    public static let cardSurface = Color(red: 0.09, green: 0.13, blue: 0.20).opacity(0.78)
    public static let cardHoverSurface = Color(red: 0.13, green: 0.19, blue: 0.29).opacity(0.92)

    public static let electricBlue = Color(red: 0.18, green: 0.49, blue: 0.96)      // #2F7CF6 (顶部选中胶囊)
    public static let amberGold = Color(red: 0.96, green: 0.69, blue: 0.25)         // #F5B041 (继续播放/焦点胶囊)
    public static let liveRed = Color(red: 0.91, green: 0.30, blue: 0.24)           // #E74C3C (● 直播)
    public static let onlineGreen = Color(red: 0.18, green: 0.80, blue: 0.44)       // #2ECC71 (● 在线)
    public static let warningAmber = Color(red: 0.95, green: 0.61, blue: 0.07)      // #F39C12 (● 需验证)

    public static let textPrimary = Color.white.opacity(0.95)
    public static let textSecondary = Color.white.opacity(0.60)
    public static let textMuted = Color.white.opacity(0.38)
    public static let subtleBorder = Color.white.opacity(0.09)
}

// MARK: - 2. 沉浸式深空径向微光背景容器

public struct NanoDeepSpaceBackground<Content: View>: View {
    public var accentGlowColor: Color
    @ViewBuilder public var content: () -> Content

    public init(accentGlowColor: Color = NanoPalette.electricBlue, @ViewBuilder content: @escaping () -> Content) {
        self.accentGlowColor = accentGlowColor
        self.content = content
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [NanoPalette.deepSpaceTop, NanoPalette.deepSpaceBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [accentGlowColor.opacity(0.16), .clear],
                center: .top,
                startRadius: 20,
                endRadius: 560
            )
            .ignoresSafeArea()

            content()
        }
    }
}

// MARK: - 3. 毛玻璃微光卡片（同时支持 macOS 鼠标悬停高光与 Apple TV 遥控器焦点放大）

public struct NanoGlassCard<Content: View>: View {
    public var cornerRadius: CGFloat
    public var padding: CGFloat
    public var isHighlighted: Bool
    public var onTap: (() -> Void)?
    @ViewBuilder public var content: () -> Content

    @State private var isHovered = false
    @FocusState private var isTVFocused: Bool

    public init(
        cornerRadius: CGFloat = 14,
        padding: CGFloat = 16,
        isHighlighted: Bool = false,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.isHighlighted = isHighlighted
        self.onTap = onTap
        self.content = content
    }

    private var activeVisualState: Bool {
        isHighlighted || isHovered || isTVFocused
    }

    public var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    cardBody
                }
                .buttonStyle(.plain)
                .focused($isTVFocused)
            } else {
                cardBody
            }
        }
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
        #endif
    }

    private var cardBody: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(activeVisualState ? NanoPalette.cardHoverSurface : NanoPalette.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        activeVisualState ? NanoPalette.electricBlue.opacity(0.65) : NanoPalette.subtleBorder,
                        lineWidth: activeVisualState ? 1.5 : 1.0
                    )
            )
            .scaleEffect(isTVFocused ? 1.03 : 1.0)
            .shadow(color: .black.opacity(activeVisualState ? 0.35 : 0.15), radius: activeVisualState ? 14 : 6, y: 4)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isTVFocused)
    }
}

// MARK: - 4. 顶部悬浮胶囊导航栏（对齐参考图1/图2/图6：`直播 77 | 节目单 | 回看 99 | 信号 | 源库 3`）

public struct NanoPillTabItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public let systemIcon: String
    public let badgeCount: Int?

    public init(id: ID, title: String, systemIcon: String, badgeCount: Int? = nil) {
        self.id = id
        self.title = title
        self.systemIcon = systemIcon
        self.badgeCount = badgeCount
    }
}

public struct NanoFloatingPillBar<ID: Hashable>: View {
    public let items: [NanoPillTabItem<ID>]
    @Binding public var selection: ID

    public init(items: [NanoPillTabItem<ID>], selection: Binding<ID>) {
        self.items = items
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                let isSelected = (selection == item.id)
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selection = item.id
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.systemIcon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                        if let count = item.badgeCount {
                            Text("\(count)")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.white.opacity(0.24) : Color.white.opacity(0.10))
                                )
                        }
                    }
                    .foregroundStyle(isSelected ? Color.white : NanoPalette.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(isSelected ? NanoPalette.electricBlue : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(Capsule().strokeBorder(NanoPalette.subtleBorder, lineWidth: 1))
        )
    }
}

// MARK: - 5. 直播与资源状态徽章 + 分段格子容量条（对齐参考图1 & 图6）

public struct NanoLiveBadge: View {
    public var text: String
    public init(text: String = "直播") { self.text = text }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(NanoPalette.liveRed)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NanoPalette.liveRed)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(NanoPalette.liveRed.opacity(0.14))
                .overlay(Capsule().strokeBorder(NanoPalette.liveRed.opacity(0.30), lineWidth: 0.8))
        )
    }
}

public struct NanoSegmentedQuotaBar: View {
    public var ratio: Double
    public var tint: Color
    public var totalSegments: Int = 18

    public init(ratio: Double, tint: Color, totalSegments: Int = 18) {
        self.ratio = ratio
        self.tint = tint
        self.totalSegments = totalSegments
    }

    public var body: some View {
        let filledCount = max(1, Int((ratio * Double(totalSegments)).rounded()))
        HStack(spacing: 3) {
            ForEach(0..<totalSegments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < filledCount ? tint : Color.white.opacity(0.10))
                    .frame(height: 7)
            }
        }
    }
}
