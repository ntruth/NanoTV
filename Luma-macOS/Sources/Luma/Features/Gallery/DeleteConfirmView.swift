import SwiftUI

/// 两张确认卡片共用的外观：材质卡片、渐变描边与顶部一条强调色渐变。
struct ConfirmationCard<Content: View>: View {
    @EnvironmentObject private var settings: AppSettings
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            // 顶部一条强调色渐变，替代传统的粗边框。
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0), tint.opacity(0.9), tint.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 132, height: 2)
                .padding(.bottom, 20)

            content
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 22)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: settings.cardRadius + 8,
                                                          style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: settings.cardRadius + 8, style: .continuous)
                .strokeBorder(LinearGradient(colors: [tint.opacity(0.55), .white.opacity(0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.26), radius: 30, y: 14)
    }
}

/// 删除前的确认卡片：缩略图扇形预览 + 一句说明 + 主次按钮。
/// 移到最近删除可撤销（强调色），永久删除 / 清空最近删除不可撤销（红色且默认按钮为「取消」）。
struct DeleteConfirmOverlay: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    let request: LibraryStore.DeleteRequest

    /// 卡片出现时把扇形缩略图展开，受设置里的浮层动效控制。
    @State private var expanded = false

    private var summary: (preview: [PhotoItem], photos: Int, videos: Int) {
        store.deletionSummary(request.ids)
    }

    private var tint: Color {
        request.isIrreversible ? .red : .accentColor
    }

    private var title: String {
        switch request.kind {
        case .trash: return "将\(countText)移到最近删除？"
        case .permanent: return "永久删除\(countText)？"
        case .emptyTrash: return "清空最近删除中的\(countText)？"
        }
    }

    private var countText: String {
        let count = request.ids.count
        switch request.kind {
        case .emptyTrash: return " \(count) 个项目"
        default: return count == 1 ? "这个项目" : " \(count) 个项目"
        }
    }

    private var detail: String {
        switch request.kind {
        case .trash:
            if store.isSystemScope, store.canEditNativeOverlay {
                return "会移到「照片」的最近删除，30 天内可在「照片」中恢复；拾光的收藏、关键词等补充信息会一并清理。"
            }
            let days = settings.trashRetentionDays
            return days > 0
                ? "项目会离开相簿、收藏与搜索；\(days) 天内可在「最近删除」中恢复，也可以按 ⌘Z 撤销。"
                : "项目会离开相簿、收藏与搜索；可在「最近删除」中恢复，也可以按 ⌘Z 撤销。"
        case .permanent:
            return "原图、实况配对视频、编辑副本、压缩备份与端侧分析都会一并删除，无法撤销。"
        case .emptyTrash:
            return "最近删除中的项目会被永久删除，原图与编辑结果都不会保留，无法撤销。"
        }
    }

    private var kindText: String {
        let counts = summary
        switch (counts.photos, counts.videos) {
        case (0, 0): return ""
        case (_, 0): return "\(counts.photos) 张照片"
        case (0, _): return "\(counts.videos) 个视频"
        default: return "\(counts.photos) 张照片 · \(counts.videos) 个视频"
        }
    }

    private var confirmTitle: String {
        switch request.kind {
        case .trash: return "移到最近删除"
        case .permanent: return "永久删除"
        case .emptyTrash: return "清空最近删除"
        }
    }

    private var confirmIcon: String {
        request.isIrreversible ? "trash.slash" : "trash"
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.24))
                .ignoresSafeArea()
                .onTapGesture { store.cancelPendingDeletion() }

            card
                .scaleEffect(expanded ? 1 : 0.94)
                .opacity(expanded ? 1 : 0)
        }
        .animation(settings.motion.overlay, value: expanded)
        .onAppear { expanded = true }
        .onExitCommand { store.cancelPendingDeletion() }
        .accessibilityAddTraits(.isModal)
    }

    private var card: some View {
        ConfirmationCard(tint: tint) {
            preview
                .frame(height: 104)
                .padding(.bottom, 16)

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)

            if !kindText.isEmpty {
                ConfirmationChip(text: kindText, tint: tint)
                    .padding(.top, 7)
            }

            ConfirmationDetail(text: detail)
                .padding(.top, 10)

            HStack(spacing: 10) {
                Button("取消") {
                    store.cancelPendingDeletion()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .modifier(DefaultShortcut(enabled: request.isIrreversible))
                .help("取消本次删除")

                Button {
                    store.performPendingDeletion()
                } label: {
                    Label(confirmTitle, systemImage: confirmIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 104)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(tint)
                .modifier(DefaultShortcut(enabled: !request.isIrreversible))
                .help(confirmTitle)
            }
            .padding(.top, 20)
        }
    }

    // MARK: - 扇形缩略图

    private var preview: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: 160, height: 160)
                .blur(radius: 44)

            ForEach(Array(previewPhotos.enumerated()), id: \.element.id) { index, photo in
                let layout = fanLayout[index]
                PhotoThumbnailView(photo: photo)
                    .frame(width: 74, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: settings.smallCoverRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: settings.smallCoverRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.55), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
                    .rotationEffect(.degrees(expanded ? layout.rotation : 0))
                    .offset(x: expanded ? layout.x : 0, y: expanded ? layout.y : 0)
                    .scaleEffect(expanded ? layout.scale : 0.9)
                    .zIndex(Double(10 - abs(index - previewPhotos.count / 2)))
            }

            if previewPhotos.isEmpty {
                Image(systemName: confirmIcon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(tint)
            }

            Image(systemName: confirmIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.8) }
                .shadow(color: tint.opacity(0.4), radius: 6, y: 2)
                .offset(x: 40, y: 38)
        }
        .frame(width: 240)
    }

    private var previewPhotos: [PhotoItem] {
        summary.preview
    }

    /// 按数量排布成一把扇形：单张正放，多张向外展开。
    private var fanLayout: [(x: CGFloat, y: CGFloat, rotation: Double, scale: CGFloat)] {
        switch previewPhotos.count {
        case 0: return []
        case 1: return [(0, 0, -2, 1)]
        case 2: return [(-18, 5, -9, 0.94), (18, 5, 9, 0.94)]
        case 3: return [(-36, 9, -12, 0.9), (0, 0, 0, 1), (36, 9, 12, 0.9)]
        default: return [(-50, 11, -14, 0.86), (-17, 2, -5, 0.95),
                         (17, 2, 5, 0.95), (50, 11, 14, 0.86)]
        }
    }
}

/// 断开系统图库 / 网络存储前的确认卡片：来源图标 + 名称 + 影响范围说明。
/// 两种断开都不会丢失原始数据，因此用强调色，并允许回车确认。
struct DisconnectConfirmOverlay: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    let request: LibraryStore.DisconnectRequest

    @State private var expanded = false

    private var tint: Color { .accentColor }

    private var icon: String {
        switch request.target {
        case .appLibrary(_, _, let isCurrent):
            return isCurrent ? "rectangle.portrait.and.arrow.right" : "photo.stack"
        case .systemLibrary: return "photo.stack"
        case .cloudMount(_, _, let kind): return kind.symbolName
        }
    }

    private var name: String {
        switch request.target {
        case .appLibrary(_, let name, _): return name
        case .systemLibrary(_, let name): return name
        case .cloudMount(_, let name, _): return name
        }
    }

    private var chip: String {
        switch request.target {
        case .appLibrary(_, _, let isCurrent):
            return isCurrent ? "当前图库 · 退出后回到选择窗口" : "图库 · 仅移除列表记录"
        case .systemLibrary: return "系统图库 · 只读浏览"
        case .cloudMount(_, _, let kind): return kind.title
        }
    }

    private var detail: String {
        switch request.target {
        case .appLibrary(_, _, let isCurrent):
            return isCurrent
                ? "会退出当前图库并回到「创建或打开图库」界面；磁盘上的图库文件与照片不会被删除，之后可以重新打开。"
                : "只会从「全部图库」里移除这条记录，不会删除磁盘上的图库文件，之后可以重新打开。"
        case .systemLibrary:
            return "只会移除侧边栏里的连接，不会删除该图库的任何照片或元数据；之后可以随时重新连接。"
        case .cloudMount:
            return "会移除挂载并清理本机缓存的缩略图与收藏记录；网盘上的文件不受影响，随时可以重新接入。"
        }
    }

    /// 退出当前图库与断开一条记录是两件事：文案与主按钮要跟着变。
    private var isExitingCurrentLibrary: Bool {
        if case .appLibrary(_, _, let isCurrent) = request.target { return isCurrent }
        return false
    }

    private var cardTitle: String {
        isExitingCurrentLibrary ? "退出「\(name)」？" : "断开「\(name)」？"
    }

    private var actionTitle: String {
        isExitingCurrentLibrary ? "退出图库" : "断开连接"
    }

    private var actionSymbol: String {
        isExitingCurrentLibrary ? "rectangle.portrait.and.arrow.right" : "minus.circle"
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.24))
                .ignoresSafeArea()
                .onTapGesture { store.cancelPendingDisconnect() }

            card
                .scaleEffect(expanded ? 1 : 0.94)
                .opacity(expanded ? 1 : 0)
        }
        .animation(settings.motion.overlay, value: expanded)
        .onAppear { expanded = true }
        .onExitCommand { store.cancelPendingDisconnect() }
        .accessibilityAddTraits(.isModal)
    }

    private var card: some View {
        ConfirmationCard(tint: tint) {
            badge
                .frame(height: 104)
                .padding(.bottom, 16)

            Text(cardTitle)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)

            ConfirmationChip(text: chip, tint: tint)
                .padding(.top, 7)

            ConfirmationDetail(text: detail)
                .padding(.top, 10)

            HStack(spacing: 10) {
                Button("取消") {
                    store.cancelPendingDisconnect()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .help("保留这条连接")

                Button {
                    store.performPendingDisconnect()
                } label: {
                    Label(actionTitle, systemImage: actionSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 104)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(tint)
                .keyboardShortcut(.defaultAction)
                .help(actionTitle)
            }
            .padding(.top, 20)
        }
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: 160, height: 160)
                .blur(radius: 44)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.thinMaterial)
                .frame(width: 78, height: 78)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(tint)
                }
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                .scaleEffect(expanded ? 1 : 0.9)

            Image(systemName: "minus.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint.gradient, in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.8) }
                .shadow(color: tint.opacity(0.4), radius: 6, y: 2)
                .offset(x: 34, y: 34)
        }
        .frame(width: 240)
    }
}

/// 卡片里的胶囊标签（数量 / 类型）。
private struct ConfirmationChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// 卡片里的说明文字。
private struct ConfirmationDetail: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 320)
    }
}

/// 不可撤销的确认卡片里把「取消」设为默认按钮，避免回车误删。
private struct DefaultShortcut: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}
