import SwiftUI

/// 窗口标题右侧的模块读数：每个总览分页最值得看的几个数字。
/// 数据只在工具栏展示，内容区不再重复统计卡片。
extension GalleryView {
    var moduleReadoutItems: [ModuleReadoutItem] {
        let items = fullReadoutItems
        // 窗口变窄时只留最前面的两项，避免顶栏被读数撑到溢出。
        return toolbarCompact ? Array(items.prefix(2)) : items
    }

    private var fullReadoutItems: [ModuleReadoutItem] {
        if isNetworkCinemaScope { return cinemaReadoutItems }
        if isTVHubScope { return tvReadoutItems }
        if isLibraryHubScope { return libraryReadoutItems }
        if isCatalogHubScope { return catalogReadoutItems }
        if isCloudStoragesHubScope { return cloudReadoutItems }
        return []
    }

    var moduleReadoutAccent: Color {
        if isTVHubScope { return TVBrand.wave }
        if isNetworkCinemaScope { return LumaBrand.violet }
        return .accentColor
    }

    /// 只有总览分页显示读数；影院详情页让位给详情标题条。
    var showsModuleReadout: Bool {
        if isNetworkCinemaScope { return store.networkCinemaDetail == nil }
        return isTVHubScope || isLibraryHubScope || isCatalogHubScope || isCloudStoragesHubScope
    }

    /// 五个总览模块：分页胶囊与读数合成一组，固定在标题栏最左侧。
    var isHubBarScope: Bool {
        isLibraryHubScope || isCatalogHubScope || isCloudStoragesHubScope
            || isNetworkCinemaScope || isTVHubScope
    }

    // MARK: - 图库总览

    private var libraryReadoutItems: [ModuleReadoutItem] {
        let libraries = libraryAggregate.summaries.count
        let tab = LibraryHubTab(rawValue: libraryHubTabRaw) ?? .resources
        switch tab {
        case .resources:
            let photos = libraryAggregate.summaries.reduce(0) { $0 + $1.photos }
            let videos = libraryAggregate.summaries.reduce(0) { $0 + $1.videos }
            return [
                ModuleReadoutItem("libraries", symbol: "books.vertical.fill",
                                  value: "\(libraries) 个", caption: "图库",
                                  tint: LumaBrand.violet),
                ModuleReadoutItem("photos", symbol: "photo.fill",
                                  value: photos.formatted(), caption: "照片",
                                  tint: LumaBrand.amber),
                ModuleReadoutItem("videos", symbol: "video.fill",
                                  value: videos.formatted(), caption: "视频",
                                  tint: LumaBrand.cyan)
            ]
        case .photos:
            return [
                ModuleReadoutItem("libraries", symbol: "books.vertical.fill",
                                  value: "\(libraries) 个", caption: "图库",
                                  tint: LumaBrand.violet),
                ModuleReadoutItem("photos", symbol: "photo.stack",
                                  value: libraryAggregate.items.count.formatted(), caption: "照片",
                                  tint: LumaBrand.amber)
            ]
        case .favorites:
            return [
                ModuleReadoutItem("libraries", symbol: "books.vertical.fill",
                                  value: "\(libraries) 个", caption: "图库",
                                  tint: LumaBrand.violet),
                ModuleReadoutItem("favorites", symbol: "heart.fill",
                                  value: libraryAggregate.favorites.count.formatted(), caption: "收藏",
                                  tint: LumaBrand.coral)
            ]
        }
    }

    // MARK: - 网络资源

    private var catalogReadoutItems: [ModuleReadoutItem] {
        // 网络资源的读数只统计网页资源站，影视源归网络影院。
        let sources = catalog.resourceSources
        switch catalog.hubTab {
        case .browse:
            return [
                ModuleReadoutItem("sources", symbol: "antenna.radiowaves.left.and.right",
                                  value: "\(sources.count) 个", caption: "资源站点",
                                  tint: .accentColor),
                ModuleReadoutItem("enabled", symbol: "checkmark.circle.fill",
                                  value: "\(sources.filter(\.isEnabled).count) 个", caption: "已启用",
                                  tint: LumaBrand.mint),
                ModuleReadoutItem("favorites", symbol: "star.circle.fill",
                                  value: "\(catalog.resourceFavorites.count) 部", caption: "收藏",
                                  tint: LumaBrand.amber)
            ]
        case .following:
            return [
                ModuleReadoutItem("people", symbol: "person.2.fill",
                                  value: "\(catalog.followedPeople.count) 位", caption: "关注人物",
                                  tint: LumaBrand.violet),
                ModuleReadoutItem("categories", symbol: "tag.fill",
                                  value: "\(catalog.followedCategories.count) 个", caption: "关注分类",
                                  tint: LumaBrand.cyan)
            ]
        case .playlists:
            return [
                ModuleReadoutItem("playlists", symbol: "rectangle.stack.fill",
                                  value: "\(catalog.playlists.count) 个", caption: "片单",
                                  tint: LumaBrand.amber),
                ModuleReadoutItem("smart", symbol: "sparkles",
                                  value: "\(catalog.smartPlaylists.count) 个", caption: "智能片单",
                                  tint: LumaBrand.violet)
            ]
        case .ranking:
            let ids = catalog.resourceSourceIDs
            let entries = catalog.currentSpotlight
            let today = catalog.todaySpotlight.filter { ids.contains($0.sourceID) }.count
            return [
                ModuleReadoutItem("entries", symbol: "chart.line.uptrend.xyaxis",
                                  value: "\(entries.count) 条", caption: "当前榜单",
                                  tint: LumaBrand.violet),
                ModuleReadoutItem("sources", symbol: "antenna.radiowaves.left.and.right",
                                  value: "\(Set(entries.map(\.sourceID)).count) 个", caption: "上榜来源",
                                  tint: LumaBrand.cyan),
                ModuleReadoutItem("today", symbol: "sun.max.fill",
                                  value: "\(today) 条", caption: "今天更新",
                                  tint: LumaBrand.amber),
                ModuleReadoutItem("week", symbol: "calendar",
                                  value: "\(catalogCalendarCount(days: 7)) 条", caption: "近 7 天更新",
                                  tint: LumaBrand.mint)
            ]
        case .calendar:
            let active = Set(catalog.calendarItems
                .filter { catalog.resourceSourceIDs.contains($0.sourceID) }
                .map(\.sourceID)).count
            return [
                ModuleReadoutItem("month", symbol: "calendar.badge.clock",
                                  value: "\(catalogCalendarMonthCount()) 条", caption: "本月新增",
                                  tint: LumaBrand.violet),
                ModuleReadoutItem("active", symbol: "antenna.radiowaves.left.and.right",
                                  value: "\(active) 个", caption: "更新来源",
                                  tint: LumaBrand.cyan),
                ModuleReadoutItem("today", symbol: "sun.max.fill",
                                  value: "\(catalogCalendarTodayCount()) 条", caption: "今天新增",
                                  tint: LumaBrand.amber)
            ]
        case .history:
            let records = catalog.resourceContinueWatching
            let weekStart = Calendar.current.date(byAdding: .day, value: -6,
                                                  to: Calendar.current.startOfDay(for: Date())) ?? Date()
            let week = records.filter { $0.updatedAt >= weekStart }.count
            let total = records.reduce(0.0) { $0 + max(0, $1.seconds) }
            return [
                ModuleReadoutItem("total", symbol: "clock.arrow.circlepath",
                                  value: durationText(total), caption: "累计观看",
                                  tint: LumaBrand.amber),
                ModuleReadoutItem("week", symbol: "calendar",
                                  value: "\(week) 部", caption: "本周播放",
                                  tint: LumaBrand.cyan),
                ModuleReadoutItem("records", symbol: "film.stack.fill",
                                  value: "\(records.count) 部", caption: "本机记录",
                                  tint: LumaBrand.violet)
            ]
        }
    }

    private func catalogCalendarCount(days: Int) -> Int {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1),
                                  to: calendar.startOfDay(for: Date())) ?? Date()
        let ids = catalog.resourceSourceIDs
        return catalog.calendarItems
            .filter { ids.contains($0.sourceID) && $0.firstSeen >= start }
            .count
    }

    private func catalogCalendarTodayCount() -> Int {
        let calendar = Calendar.current
        let ids = catalog.resourceSourceIDs
        return catalog.calendarItems
            .filter { ids.contains($0.sourceID) && calendar.isDateInToday($0.firstSeen) }
            .count
    }

    private func catalogCalendarMonthCount() -> Int {
        let interval = Calendar.current.dateInterval(of: .month, for: Date())
        let ids = catalog.resourceSourceIDs
        return catalog.calendarItems
            .filter { ids.contains($0.sourceID) && (interval?.contains($0.firstSeen) ?? false) }
            .count
    }

    // MARK: - 网络存储

    private var cloudReadoutItems: [ModuleReadoutItem] {
        let mounts = cloud.mounts
        guard !mounts.isEmpty else { return [] }
        let writable = mounts.filter { $0.kind.supportsWrite }.count
        let scoped = mounts.filter { !$0.scopeRoots.isEmpty || !$0.excludedRoots.isEmpty }.count
        let checked = cloud.mountHealth.values.filter { $0.state != .checking && $0.checkedAt != nil }
        let online = checked.filter { $0.state == .healthy }.count
        let resume = store.cloudMountContinueRecords

        switch cloud.storagesTab {
        case .storages:
            var items = [
                ModuleReadoutItem("mounts", symbol: "externaldrive.connected.to.line.below",
                                  value: "\(mounts.count) 个", caption: "已接入存储",
                                  tint: .accentColor),
                ModuleReadoutItem("writable", symbol: "pencil",
                                  value: "\(writable) 个", caption: "支持写入",
                                  tint: LumaBrand.mint),
                ModuleReadoutItem("scoped", symbol: "scope",
                                  value: "\(scoped) 个", caption: "限定扫描范围",
                                  tint: LumaBrand.violet)
            ]
            if !checked.isEmpty {
                items.append(ModuleReadoutItem("online", symbol: "wifi",
                                               value: "\(online) / \(checked.count)", caption: "在线 / 已检测",
                                               tint: online == checked.count ? LumaBrand.mint : LumaBrand.amber))
            }
            return items
        case .photos:
            var items = [
                ModuleReadoutItem("mounts", symbol: "externaldrive.connected.to.line.below",
                                  value: "\(mounts.count) 个", caption: "存储",
                                  tint: .accentColor),
                ModuleReadoutItem("writable", symbol: "pencil",
                                  value: "\(writable) 个", caption: "可写",
                                  tint: LumaBrand.mint)
            ]
            if !checked.isEmpty {
                items.append(ModuleReadoutItem("online", symbol: "wifi",
                                               value: "\(online) / \(checked.count)", caption: "在线 / 已检测",
                                               tint: online == checked.count ? LumaBrand.mint : LumaBrand.amber))
            }
            return items
        case .cinema:
            return [
                ModuleReadoutItem("mounts", symbol: "externaldrive.connected.to.line.below",
                                  value: "\(mounts.count) 个", caption: "存储",
                                  tint: .accentColor),
                ModuleReadoutItem("resume", symbol: "play.circle.fill",
                                  value: "\(resume.count) 条", caption: "待续播",
                                  tint: LumaBrand.coral),
                ModuleReadoutItem("finished", symbol: "checkmark.circle.fill",
                                  value: "\(store.cloudMountFinishedRecords.count) 条", caption: "已看完",
                                  tint: LumaBrand.mint)
            ]
        case .resume:
            let remaining = resume.reduce(0) { $0 + $1.remainingSeconds }
            return [
                ModuleReadoutItem("resume", symbol: "play.circle.fill",
                                  value: "\(resume.count) 条", caption: "未看完",
                                  tint: LumaBrand.coral),
                ModuleReadoutItem("remaining", symbol: "hourglass",
                                  value: "\(CloudHubFormat.hours(remaining)) 小时", caption: "剩余时长",
                                  tint: LumaBrand.amber),
                ModuleReadoutItem("storages", symbol: "externaldrive.fill.badge.icloud",
                                  value: "\(Set(resume.compactMap(\.mountID)).count) 个", caption: "涉及存储",
                                  tint: LumaBrand.violet),
                ModuleReadoutItem("latest", symbol: "clock.arrow.circlepath",
                                  value: resume.first.map { CloudHubFormat.relative($0.updatedAt) } ?? "—",
                                  caption: "最近观看",
                                  tint: LumaBrand.cyan)
            ]
        }
    }

    // MARK: - 网络影院

    private var cinemaReadoutItems: [ModuleReadoutItem] {
        guard store.networkCinemaDetail == nil else { return [] }
        let all = catalog.cinemaSources
        guard !all.isEmpty else { return [] }
        let enabled = all.filter(\.isEnabled)
        let ids = Set(all.map(\.id))
        let model = store.networkCinemaModel
        let tab = store.networkCinemaTab

        if store.networkCinemaSourceID != nil {
            // 点开具体源后顶部不再显示聚合读数：分类与内容都在页面里。
            return []
        }

        switch tab {
        case .movies, .shows:
            return [
                ModuleReadoutItem("sources", symbol: "popcorn.fill",
                                  value: "\(enabled.count) 个", caption: "已启用影视源",
                                  tint: LumaBrand.violet),
                ModuleReadoutItem("items", symbol: "film.stack.fill",
                                  value: "\(model.items.count) 部", caption: tab.title,
                                  tint: LumaBrand.cyan),
                ModuleReadoutItem("meta", symbol: "sparkles",
                                  value: "\(model.enrichments.count) 部", caption: "资料已补全",
                                  tint: LumaBrand.amber)
            ]
        case .manage:
            return [
                ModuleReadoutItem("sources", symbol: "popcorn.fill",
                                  value: "\(enabled.count) / \(all.count)", caption: "影视源 · 启用 / 全部",
                                  tint: LumaBrand.violet),
                ModuleReadoutItem("items", symbol: "film.stack.fill",
                                  value: "\(model.items.count) 部", caption: "在架内容",
                                  tint: LumaBrand.cyan),
                ModuleReadoutItem("meta", symbol: "sparkles",
                                  value: "\(model.enrichments.count) 部", caption: "资料已补全",
                                  tint: LumaBrand.amber)
            ]
        case .ranking:
            let entries = catalog.currentSpotlight(in: .networkCinema)
            let today = catalog.todaySpotlight.filter { ids.contains($0.sourceID) }.count
            return [
                ModuleReadoutItem("entries", symbol: "chart.line.uptrend.xyaxis",
                                  value: "\(entries.count) 条", caption: "当前榜单",
                                  tint: LumaBrand.violet),
                ModuleReadoutItem("sources", symbol: "antenna.radiowaves.left.and.right",
                                  value: "\(Set(entries.map(\.sourceID)).count) 个", caption: "上榜来源",
                                  tint: LumaBrand.cyan),
                ModuleReadoutItem("today", symbol: "sun.max.fill",
                                  value: "\(today) 条", caption: "今天更新",
                                  tint: LumaBrand.amber),
                ModuleReadoutItem("week", symbol: "calendar",
                                  value: "\(cinemaCalendarCount(days: 7, ids: ids)) 条", caption: "近 7 天更新",
                                  tint: LumaBrand.mint)
            ]
        case .calendar:
            let active = Set(catalog.calendarItems.filter { ids.contains($0.sourceID) }
                .map(\.sourceID)).count
            return [
                ModuleReadoutItem("month", symbol: "calendar.badge.clock",
                                  value: "\(cinemaCalendarMonthCount(ids: ids)) 条", caption: "本月新增",
                                  tint: LumaBrand.violet),
                ModuleReadoutItem("active", symbol: "antenna.radiowaves.left.and.right",
                                  value: "\(active) 个", caption: "本周更新来源",
                                  tint: LumaBrand.cyan),
                ModuleReadoutItem("today", symbol: "sun.max.fill",
                                  value: "\(cinemaCalendarTodayCount(ids: ids)) 条", caption: "今天新增",
                                  tint: LumaBrand.amber)
            ]
        case .history:
            let records = catalog.allContinueWatching.filter { ids.contains($0.sourceID) }
            let weekStart = Calendar.current.date(byAdding: .day, value: -6,
                                                  to: Calendar.current.startOfDay(for: Date())) ?? Date()
            let week = records.filter { $0.updatedAt >= weekStart }.count
            let total = records.reduce(0.0) { $0 + max(0, $1.seconds) }
            return [
                ModuleReadoutItem("total", symbol: "clock.arrow.circlepath",
                                  value: durationText(total), caption: "累计观看",
                                  tint: LumaBrand.amber),
                ModuleReadoutItem("week", symbol: "calendar",
                                  value: "\(week) 部", caption: "本周播放",
                                  tint: LumaBrand.cyan),
                ModuleReadoutItem("records", symbol: "film.stack.fill",
                                  value: "\(records.count) 部", caption: "本机观看记录",
                                  tint: LumaBrand.violet)
            ]
        case .following:
            let favorites = favoriteCount(in: ids)
            let watching = catalog.allContinueWatching.filter {
                ids.contains($0.sourceID) && $0.fraction < 0.97
            }.count
            return [
                ModuleReadoutItem("fav", symbol: "star.circle.fill",
                                  value: "\(favorites) 部", caption: "收藏",
                                  tint: LumaBrand.amber),
                ModuleReadoutItem("watching", symbol: "play.circle.fill",
                                  value: "\(watching) 部", caption: "在追",
                                  tint: LumaBrand.coral),
                ModuleReadoutItem("week", symbol: "calendar",
                                  value: "\(cinemaCalendarCount(days: 7, ids: ids)) 条", caption: "近 7 天更新",
                                  tint: LumaBrand.cyan)
            ]
        }
    }

    private func favoriteCount(in ids: Set<UUID>) -> Int {
        catalog.allFavorites.filter { ids.contains($0.sourceID) }.count
    }

    private func cinemaCalendarCount(days: Int, ids: Set<UUID>) -> Int {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1),
                                  to: calendar.startOfDay(for: Date())) ?? Date()
        return catalog.calendarItems.filter {
            ids.contains($0.sourceID) && $0.firstSeen >= start
        }.count
    }

    private func cinemaCalendarTodayCount(ids: Set<UUID>) -> Int {
        let calendar = Calendar.current
        return catalog.calendarItems.filter {
            ids.contains($0.sourceID) && calendar.isDateInToday($0.firstSeen)
        }.count
    }

    private func cinemaCalendarMonthCount(ids: Set<UUID>) -> Int {
        let interval = Calendar.current.dateInterval(of: .month, for: Date())
        return catalog.calendarItems.filter {
            guard ids.contains($0.sourceID) else { return false }
            return interval?.contains($0.firstSeen) ?? false
        }.count
    }

    private func durationText(_ seconds: Double) -> String {
        guard seconds >= 60 else { return seconds > 0 ? "不到 1 分钟" : "—" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    // MARK: - 网络电视

    private var tvReadoutItems: [ModuleReadoutItem] {
        let tv = store.tvModel
        guard !tv.playlists.isEmpty else { return [] }
        let enabled = tv.playlists.filter(\.isEnabled).count

        switch tv.hubTab {
        case .channels:
            var items = [
                ModuleReadoutItem("channels", symbol: "tv",
                                  value: "\(tv.visibleChannels.count) 个", caption: "全部频道",
                                  tint: TVBrand.wave),
                ModuleReadoutItem("sources", symbol: "antenna.radiowaves.left.and.right",
                                  value: "\(enabled) 个", caption: "已启用电视源",
                                  tint: TVBrand.gold)
            ]
            if let updated = tv.refreshedAt {
                items.append(ModuleReadoutItem("updated", symbol: "clock.arrow.circlepath",
                                               value: updated.formatted(date: .omitted, time: .shortened),
                                               caption: "最近刷新",
                                               tint: TVBrand.success))
            }
            return items
        case .tonight:
            return [
                ModuleReadoutItem("channels", symbol: "tv",
                                  value: "\(tv.visibleChannels.count) 个", caption: "今晚有节目",
                                  tint: TVBrand.wave),
                ModuleReadoutItem("prime", symbol: "moon.stars.fill",
                                  value: "19:30–23:30", caption: "黄金时段",
                                  tint: TVBrand.gold),
                ModuleReadoutItem("subs", symbol: "bookmark.fill",
                                  value: "\(tv.subscriptions.count) 个", caption: "追剧提醒",
                                  tint: TVBrand.signal)
            ]
        case .guide:
            return [
                ModuleReadoutItem("channels", symbol: "tv",
                                  value: "\(tv.visibleChannels.count) 个", caption: "频道节目单",
                                  tint: TVBrand.wave),
                ModuleReadoutItem("catchup", symbol: "arrow.uturn.backward.circle.fill",
                                  value: "\(tv.catchupChannelCount) 个", caption: "可回看频道",
                                  tint: TVBrand.gold),
                ModuleReadoutItem("subs", symbol: "bookmark.fill",
                                  value: "\(tv.subscriptions.count) 个", caption: "追剧提醒",
                                  tint: TVBrand.signal)
            ]
        case .status:
            let ok = tv.probeReports.values.filter(\.isSuccess).count
            let bad = tv.probeReports.count - ok
            return [
                ModuleReadoutItem("probed", symbol: "waveform.path.ecg",
                                  value: "\(tv.probeReports.count) / \(tv.channelsForFocusedSource.count)",
                                  caption: "已探测 / 全部",
                                  tint: TVBrand.wave),
                ModuleReadoutItem("ok", symbol: "checkmark.circle.fill",
                                  value: "\(ok) 个", caption: "信号正常",
                                  tint: TVBrand.success),
                ModuleReadoutItem("bad", symbol: "exclamationmark.triangle.fill",
                                  value: "\(bad) 个", caption: "需要留意",
                                  tint: bad > 0 ? TVBrand.warning : TVBrand.success)
            ]
        case .overview:
            let errors = tv.playlists.filter { !($0.lastError ?? "").isEmpty }.count
            let epg = tv.playlists.filter {
                $0.isEnabled && !($0.epgURLString ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }.count
            return [
                ModuleReadoutItem("sources", symbol: "antenna.radiowaves.left.and.right",
                                  value: "\(enabled) / \(tv.playlists.count)", caption: "电视源 · 启用 / 全部",
                                  tint: TVBrand.wave),
                ModuleReadoutItem("channels", symbol: "tv",
                                  value: "\(tv.aggregateChannelCount) 个", caption: "聚合频道",
                                  tint: TVBrand.gold),
                ModuleReadoutItem("epg", symbol: "list.bullet.rectangle",
                                  value: "\(epg) 个", caption: "带 EPG 节目单",
                                  tint: TVBrand.success),
                ModuleReadoutItem("errors", symbol: "exclamationmark.triangle.fill",
                                  value: "\(errors) 个", caption: "异常源",
                                  tint: errors > 0 ? TVBrand.warning : TVBrand.success)
            ]
        }
    }
}
