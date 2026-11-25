import SwiftUI
import LumaCore
import LumaContentCore

/// 五种形态共用的页面状态：加载 / 空态 / 失败。
/// 图库、网络云盘、网络影院、网络资源、网络电视都走这一套版式与按钮，不再各写一遍。

// MARK: - 空态

/// 空态上的一个动作：主行动用 `filled`，次要行动保持玻璃胶囊。
struct LumaEmptyAction: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String?
    var tint: Color = .accentColor
    var filled: Bool = false
    var handler: () -> Void
}

/// 统一空态：图标 + 标题 + 说明 + 动作。
/// - `.plain`：直接铺在页面里（影院 / 电视 / 资源）。
/// - `.card`：包一层玻璃卡（云盘总览 / 影院聚合页）。
struct LumaEmptyState: View {
    enum Style {
        case plain
        case card
    }

    let symbol: String
    let title: String
    var message: String = ""
    var style: Style = .plain
    var actions: [LumaEmptyAction] = []

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 74, height: 74)
                Image(systemName: symbol)
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(actions) { action in
                        Button(action: action.handler) {
                            HStack(spacing: 6) {
                                if let symbol = action.symbol {
                                    Image(systemName: symbol)
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                Text(action.title)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(action.filled ? Color.white : action.tint)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background {
                                if action.filled {
                                    Capsule().fill(action.tint)
                                } else {
                                    Capsule().fill(.ultraThinMaterial)
                                }
                            }
                            .overlay {
                                Capsule().strokeBorder(action.tint.opacity(action.filled ? 0 : 0.30),
                                                       lineWidth: 0.8)
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .modifier(LumaEmptyStateContainer(style: style))
    }
}

private struct LumaEmptyStateContainer: ViewModifier {
    let style: LumaEmptyState.Style

    func body(content: Content) -> some View {
        switch style {
        case .plain:
            content.padding(.vertical, 40)
        case .card:
            content
                .padding(.vertical, 52)
                .padding(.horizontal, 24)
                .lumaGlassCard(cornerRadius: 22)
        }
    }
}

// MARK: - 加载

/// 统一加载态：转环 + 一句进度说明。
struct LumaLoadingState: View {
    var message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 骨架

/// 占位流光：加载中不显示一块死灰，而是缓慢扫过一道高光。
struct LumaShimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color(nsColor: .quaternaryLabelColor).opacity(0.18),
                                        Color(nsColor: .quaternaryLabelColor).opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.clear, .white.opacity(0.16), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(40, proxy.size.width * 0.5))
                    .offset(x: phase * proxy.size.width)
            }
            .clipped()
        }
        .onAppear {
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                phase = 1.6
            }
        }
    }
}

/// 统一骨架网格：影院海报墙、资源海报墙、云盘聚合网格共用。
/// `aspectRatio` 有值时按封面比例铺卡，否则用固定卡高。
struct LumaSkeletonGrid: View {
    var columns: [GridItem]
    var count: Int = 12
    var cardHeight: CGFloat = 210
    var aspectRatio: CGFloat?
    var footerLines: Int = 2
    var spacing: CGFloat = 16

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    card
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if footerLines > 0 {
                        LumaShimmer()
                            .frame(height: 10)
                            .clipShape(Capsule())
                    }
                    if footerLines > 1 {
                        LumaShimmer()
                            .frame(width: 64, height: 8)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .opacity(0.7)
    }

    @ViewBuilder
    private var card: some View {
        if let aspectRatio {
            LumaShimmer()
                .aspectRatio(aspectRatio, contentMode: .fit)
        } else {
            LumaShimmer()
                .frame(height: cardHeight)
        }
    }
}

// MARK: - 失败

/// 统一失败态：把 `SourceErrorView` 放进页面居中的位置，保持与空态同一套节奏。
struct LumaFailureState: View {
    let error: SourceError
    var onAction: (RecoveryAction) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.orange)
            SourceErrorView(error: error, onAction: onAction)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
