import SwiftUI

/// 网络资源区：资源 / 榜单 / 日历 / 足迹 / 片单 / 关注六个分页。
/// 分页切换在窗口工具栏里（与标题同一行），内容区不再叠一条控制栏。
struct CatalogHubView: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel

    var body: some View {
        Group {
            switch catalog.hubTab {
            case .browse:
                CatalogSourcesOverviewView()
            case .following:
                CatalogFollowingView()
            case .ranking:
                CatalogRankingView(sourceScope: catalog.resourceSourceIDs, compact: true)
            case .history:
                CatalogHistoryView(sourceScope: catalog.resourceSourceIDs, compact: true)
            case .playlists:
                CatalogPlaylistsView()
            case .calendar:
                CatalogCalendarView(sourceScope: catalog.resourceSourceIDs, compact: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LumaAmbientBackground(intensity: 0.55))
        // 切分页 / 离开网络资源区时收起二级页：工具栏的返回按钮不会残留到别的页面。
        .onChange(of: catalog.hubTab) { _, _ in
            catalog.followedProfile = nil
            catalog.openPlaylistPage = nil
        }
        .onDisappear {
            catalog.followedProfile = nil
            catalog.openPlaylistPage = nil
        }
    }
}

/// 工具栏中区的分页胶囊：资源 / 榜单 / 日历 / 足迹 / 片单 / 关注。
struct CatalogHubTabs: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CatalogHubTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        // 工具栏变窄时宁可整体溢出，也不要把标签压成「…」、把角标折成两行。
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tabButton(_ tab: CatalogHubTab) -> some View {
        let active = catalog.hubTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                catalog.setHubTab(tab)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .fixedSize()
                Text(tab.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let badge = badge(for: tab), badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(active ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(active ? Color.white.opacity(0.92)
                                           : Color.primary.opacity(0.08),
                                    in: Capsule(style: .continuous))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if active {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "hub-tab", in: tabNamespace)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }

    private func badge(for tab: CatalogHubTab) -> Int? {
        switch tab {
        case .browse: return nil
        case .ranking: return catalog.currentSpotlight.count
        case .calendar: return catalog.todaySpotlight
                .filter { catalog.resourceSourceIDs.contains($0.sourceID) }.count
        case .history: return catalog.resourceContinueWatching.count
        case .playlists: return catalog.playlists.count + catalog.smartPlaylists.count
        case .following: return catalog.followedPeople.count + catalog.followedCategories.count
        }
    }
}
