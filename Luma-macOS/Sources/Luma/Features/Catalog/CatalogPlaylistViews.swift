import SwiftUI

// MARK: - 片单详情

struct CatalogPlaylistDetailView: View {
    let playlistID: UUID
    /// 非空表示嵌在片单页里展示：左上角给「返回」，不再用弹窗。
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var catalog: CatalogBrowserModel
    @Environment(\.dismiss) private var dismiss

    @State private var nameDraft = ""
    @State private var isEditingName = false
    @State private var confirmDelete = false

    private var isEmbedded: Bool { onClose != nil }

    private var playlist: CatalogPlaylist? {
        catalog.playlists.first { $0.id == playlistID }
    }

    private var entries: [CatalogPlaylistEntry] { playlist?.entries ?? [] }

    /// 片单覆盖了多少个源：头部统计用。
    private var sourceCount: Int { Set(entries.map(\.sourceID)).count }

    private var covers: [(CatalogSource, String)] {
        entries.compactMap { entry in
            guard let source = catalog.sources.first(where: { $0.id == entry.sourceID }),
                  !entry.coverURL.isEmpty else { return nil }
            return (source, entry.coverURL)
        }
    }

    var body: some View {
        ZStack {
            LumaAmbientBackground(intensity: 0.6)

            VStack(alignment: .leading, spacing: 0) {
                hero
                if entries.isEmpty {
                    emptyState
                } else {
                    entryList
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !isEmbedded {
                closeButton.padding(16)
            }
        }
        .frame(width: isEmbedded ? nil : 720, height: isEmbedded ? nil : 620)
        .onAppear { nameDraft = playlist?.name ?? "" }
        .alert("删除这个片单？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                catalog.deletePlaylist(playlistID)
                if let onClose { onClose() } else { dismiss() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("片单里的条目不会从源里删除，只会移除这份收藏。")
        }
    }

    // MARK: 头部

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            // 首张封面重模糊铺底，片单也有自己的「封面墙」气质。
            Color.clear
                .frame(height: 176)
                .overlay {
                    if let first = covers.first {
                        CatalogArtworkImage(source: first.0, urlString: first.1, cornerRadius: 0)
                            .blur(radius: 34, opaque: true)
                            .opacity(0.55)
                            .scaleEffect(1.14)
                    }
                }
                .clipped()
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.16), .black.opacity(0.62)],
                                   startPoint: .top, endPoint: .bottom)
                }

            HStack(alignment: .bottom, spacing: 16) {
                coverFan

                VStack(alignment: .leading, spacing: 8) {
                    Text("片单")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(2.2)
                        .foregroundStyle(.white.opacity(0.55))
                    nameRow
                    HStack(spacing: 6) {
                        statChip(symbol: "rectangle.stack.fill", text: "\(entries.count) 部")
                        statChip(symbol: "antenna.radiowaves.left.and.right",
                                 text: "\(sourceCount) 个源")
                        statChip(symbol: "arrow.up.arrow.down", text: "拖拽排序")
                    }
                }

                Spacer(minLength: 12)

                actions
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .padding(.top, 26)
        }
    }

    private var nameRow: some View {
        Group {
            if isEditingName {
                TextField("片单名称", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 320)
                    .onSubmit(commitRename)
            } else {
                Text(playlist?.name ?? "片单")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .onTapGesture {
                        nameDraft = playlist?.name ?? ""
                        isEditingName = true
                    }
                    .help("点击重命名")
            }
        }
    }

    /// 最多三张封面斜贴成一摞：空片单时用渐变占位。
    private var coverFan: some View {
        ZStack {
            if covers.isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.8),
                                                  Color.accentColor.opacity(0.35)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 62)
                    .overlay {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
            } else {
                ForEach(Array(covers.prefix(3).indices), id: \.self) { index in
                    CatalogArtworkImage(source: covers[index].0,
                                        urlString: covers[index].1,
                                        cornerRadius: 8)
                        .frame(width: 46, height: 62)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.24), lineWidth: 0.6)
                        }
                        .rotationEffect(.degrees(Double(index - 1) * 7))
                        .offset(x: CGFloat(index) * 17 - 17)
                        .shadow(color: .black.opacity(0.32), radius: 8, y: 3)
                }
            }
        }
        .frame(width: 92, height: 68)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if isEditingName {
                Button("完成", action: commitRename)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button {
                    catalog.playPlaylist(playlistID)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(entries.isEmpty)

                Button {
                    nameDraft = playlist?.name ?? ""
                    isEditingName = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("重命名")

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("删除片单")
            }
        }
    }

    private func statChip(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.white.opacity(0.14), in: Capsule(style: .continuous))
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 条目

    private var entryList: some View {
        List {
            ForEach(entries) { entry in
                entryRow(entry, index: entryIndex(entry) + 1)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .onMove { source, destination in
                catalog.movePlaylistEntry(playlistID: playlistID,
                                          from: source, to: destination)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private func entryIndex(_ entry: CatalogPlaylistEntry) -> Int {
        entries.firstIndex(where: { $0.id == entry.id }) ?? 0
    }

    private func entryRow(_ entry: CatalogPlaylistEntry, index: Int) -> some View {
        let source = catalog.sources.first { $0.id == entry.sourceID }
        return HStack(spacing: 12) {
            Text("\(index)")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 20, alignment: .trailing)

            Color.clear
                .frame(width: 112, height: 63)
                .overlay {
                    if let source {
                        CatalogArtworkImage(source: source, urlString: entry.coverURL,
                                            cornerRadius: 8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let source {
                        Circle()
                            .fill(source.kind.sidebarTint)
                            .frame(width: 4.5, height: 4.5)
                        Text(source.name)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    if !entry.remark.isEmpty {
                        Text(entry.remark)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.05),
                                        in: Capsule(style: .continuous))
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                if let source {
                    catalog.playRemote(sourceID: source.id, item: entry.item)
                }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("播放这一部")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("设为片单封面") {
                catalog.setPlaylistCover(playlistID: playlistID, coverURL: entry.coverURL)
            }
            Button("播放这一部") {
                if let source {
                    catalog.playRemote(sourceID: source.id, item: entry.item)
                }
            }
            Divider()
            Button("从片单移除", role: .destructive) {
                catalog.removePlaylistEntry(playlistID: playlistID, entryID: entry.id)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.85))
            Text("片单还是空的")
                .font(.system(size: 14, weight: .semibold))
            Text("在任意源的卡片上右键「加入片单」，跨源收藏会汇总到这里。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Button("去资源里挑几部") {
                catalog.setHubTab(.browse)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func commitRename() {
        catalog.renamePlaylist(playlistID, to: nameDraft)
        isEditingName = false
    }
}

// MARK: - 加入片单菜单

/// 卡片 / 详情的右键菜单里复用：列出所有片单，勾选表示已加入。
struct CatalogPlaylistMenu: View {
    let source: CatalogSource
    let item: CatalogItem

    @EnvironmentObject private var catalog: CatalogBrowserModel

    var body: some View {
        Menu("加入片单") {
            ForEach(catalog.playlists) { playlist in
                Button {
                    catalog.addToPlaylist(playlist.id, source: source, item: item)
                } label: {
                    if catalog.isInPlaylist(playlist.id, sourceID: source.id, itemID: item.id) {
                        Label(playlist.name, systemImage: "checkmark")
                    } else {
                        Text(playlist.name)
                    }
                }
            }
            if !catalog.playlists.isEmpty { Divider() }
            Button("新建片单并加入") {
                let id = catalog.createPlaylist(name: "片单 \(catalog.playlists.count + 1)")
                catalog.addToPlaylist(id, source: source, item: item)
            }
        }
    }
}
