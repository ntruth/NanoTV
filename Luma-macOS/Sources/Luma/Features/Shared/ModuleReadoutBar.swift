import SwiftUI

/// 模块读数带里的一项：一个数字 + 一句说明。
struct ModuleReadoutItem: Identifiable {
    let id: String
    let symbol: String
    let value: String
    let caption: String
    let tint: Color

    init(_ id: String,
         symbol: String,
         value: String,
         caption: String,
         tint: Color) {
        self.id = id
        self.symbol = symbol
        self.value = value
        self.caption = caption
        self.tint = tint
    }
}

/// 分页顶部的「读数带」：把这一页最值得看的几个数字并成一条，
/// 用着色图标 + 大号数字分层，窗口变窄时整条横向滚动，不挤压、不换行。
struct ModuleReadoutBar: View {
    let items: [ModuleReadoutItem]
    /// 整条读数带的品牌色：影院用紫、电视用电波青，默认跟随系统强调色。
    var accent: Color = .accentColor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { divider }
                        cell(item)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollClipDisabled()
            .frame(height: 54)
            .background(background)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06),
                                  lineWidth: 0.7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.05),
                    radius: 10, y: 2)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(width: 1, height: 24)
    }

    private func cell(_ item: ModuleReadoutItem) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(item.tint.opacity(0.14))
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.tint)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.value)
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.22), value: item.value)
                Text(item.caption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .fixedSize()
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                LinearGradient(colors: [accent.opacity(0.07), .clear],
                               startPoint: .leading,
                               endPoint: .trailing)
            }
    }
}

/// 工具栏版读数：一条扁胶囊，紧贴在窗口标题右侧，和分页胶囊同一行。
/// 每项只保留「图标 + 数字 + 说明」，整条固定宽度，窗口变窄时交给系统收进溢出菜单。
struct ModuleReadoutStrip: View {
    let items: [ModuleReadoutItem]
    var accent: Color = .accentColor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                            .frame(width: 1, height: 15)
                    }
                    cell(item)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: 28)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.14 : 0.08),
                                  lineWidth: 0.6)
            }
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [accent.opacity(0.16), .clear],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(width: 60)
                    .allowsHitTesting(false)
            }
            .fixedSize()
        }
    }

    private func cell(_ item: ModuleReadoutItem) -> some View {
        HStack(spacing: 5) {
            Image(systemName: item.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.value)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.caption)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .fixedSize()
        .help("\(item.caption)：\(item.value)")
    }
}
