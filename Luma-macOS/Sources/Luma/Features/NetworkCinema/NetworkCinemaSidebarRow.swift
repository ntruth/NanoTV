import SwiftUI

/// 网络影院侧边栏里的一个影视源：与「网络资源」一样只展示一级源行。
/// 点开即在网络影院页只看这一家，分页（影院管理 / 榜单 / 电影 / 电视剧 / 日历 / 足迹 / 关注）由页面工具栏切换。
struct NetworkCinemaSidebarRow: View {
    let source: CatalogSource
    var isDropTarget: Bool = false

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var catalog: CatalogBrowserModel

    @State private var editingSource: CatalogSource?

    private var isCurrent: Bool {
        store.sidebarItem == .networkCinema && store.networkCinemaSourceID == source.id
    }

    var body: some View {
        SourceSidebarRow(
            model: SourceRowModel(
                title: source.name,
                subtitle: nil,
                badge: nil,
                countText: nil,
                isCurrent: isCurrent,
                isEnabled: source.isEnabled,
                isLoading: false,
                showsNewBadge: false
            ),
            isDropTarget: isDropTarget,
            onOpen: { open() },
            onRetry: { open() },
            onReauthorize: { store.openCatalogSourceInBrowser(source) },
            dragProvider: {
                catalogSourceDragProvider(source.id)
            }
        ) { hovered in
            CatalogSourceCover(source: source, hovered: hovered)
        } menu: {
            Button("打开") { open() }
            Button("在浏览器打开站点") {
                store.openCatalogSourceInBrowser(source)
            }
            Divider()
            Button(source.isEnabled ? "停用" : "启用") {
                catalog.setEnabled(source.id, enabled: !source.isEnabled)
            }
            Button("编辑…") { editingSource = source }
            Divider()
            Button("移除资源", role: .destructive) {
                catalog.remove(source.id)
            }
        }
        .sheet(item: $editingSource) { source in
            CatalogSourceEditorSheet(source: source) { catalog.updateSource($0) }
        }
    }

    private func open() {
        store.networkCinemaSourceID = source.id
        // 管理 / 榜单 / 日历 / 足迹 / 关注里点源，先回到能看内容的「电影」页。
        if !store.networkCinemaTab.browsesContent {
            store.networkCinemaTab = .movies
        }
        store.navigate(to: .networkCinema)
    }
}
