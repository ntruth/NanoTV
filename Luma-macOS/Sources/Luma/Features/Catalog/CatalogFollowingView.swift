import SwiftUI

/// 我的关注：把关注的人物、片商与题材合成独立页面。
/// 顶部是关注总览和海报扇面，下面按「新内容 / 人物 / 片商 / 题材」分区。
struct CatalogFollowingView: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel
    @EnvironmentObject private var store: LibraryStore

    @State private var posters: [String: [FollowPoster]] = [:]

    private var performers: [CatalogFollowedPerson] {
        sorted(catalog.followedPeople.filter { $0.role != "片商" })
    }

    private var studios: [CatalogFollowedPerson] {
        sorted(catalog.followedPeople.filter { $0.role == "片商" })
    }

    private var newcomers: [CatalogFollowedPerson] {
        sorted(catalog.followedPeople.filter { $0.newCount > 0 })
    }

    private var isEmpty: Bool {
        catalog.followedPeople.isEmpty && catalog.followedCategories.isEmpty
    }

    var body: some View {
        Group {
            if let personTarget = catalog.followedProfile {
                // 档案不再弹窗：直接占据内容区，返回入口在窗口工具栏最左侧。
                CatalogPersonProfileView(name: personTarget.name,
                                         role: personTarget.role,
                                         sourceID: personTarget.sourceID,
                                         onClose: {
                                             withAnimation(.easeOut(duration: 0.18)) {
                                                 catalog.followedProfile = nil
                                             }
                                         },
                                         backTitle: "返回关注",
                                         showsInlineBack: false)
                    .environmentObject(catalog)
                    .transition(.opacity)
            } else {
                list
            }
        }
        .background(LumaAmbientBackground(intensity: 0.55))
        .task(id: refreshKey) {
            posters = buildPosters()
            catalog.refreshFollowedPeople()
            catalog.refreshFollowPosters()
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                if isEmpty {
                    emptyState
                } else {
                    if !newcomers.isEmpty { newSection }
                    if !performers.isEmpty {
                        peopleSection(title: "人物", detail: "\(performers.count) 位", list: performers)
                    }
                    if !studios.isEmpty {
                        peopleSection(title: "片商", detail: "\(studios.count) 家", list: studios)
                    }
                    if !catalog.followedCategories.isEmpty { categorySection }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 60)
        }
        .scrollIndicators(.automatic)
    }

    // MARK: - 总览

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("我的关注")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.55))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(totalFollows)")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("个关注")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.66))
                }
                Text(catalog.newFollowCount > 0
                     ? "有 \(catalog.newFollowCount) 条新内容等你"
                     : "关注的人物与题材会集中出现在这里")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.62))
                HStack(spacing: 7) {
                    heroChip("\(performers.count)", "人物")
                    heroChip("\(studios.count)", "片商")
                    heroChip("\(catalog.followedCategories.count)", "题材")
                }
                .padding(.top, 3)
            }
            Spacer(minLength: 12)
            posterFan
        }
        .padding(22)
        .frame(height: 172)
        .background {
            ZStack {
                if let first = heroPosters.first {
                    CatalogArtworkImage(source: first.source, urlString: first.cover, cornerRadius: 0)
                        .blur(radius: 30)
                        .scaleEffect(1.16)
                        .opacity(0.6)
                } else {
                    LumaBrand.gradient
                }
                LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.75)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.22), radius: 20, y: 9)
    }

    private var totalFollows: Int {
        catalog.followedPeople.count + catalog.followedCategories.count
    }

    private func heroChip(_ value: String, _ caption: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(caption)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.1), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.6)
        }
    }

    /// 海报扇面：关注的代表作叠成三张，比纯色块更有实体感。
    private var posterFan: some View {
        ZStack {
            ForEach(Array(heroPosters.prefix(3).enumerated()), id: \.element.id) { index, poster in
                CatalogArtworkImage(source: poster.source, urlString: poster.cover, cornerRadius: 9)
                    .frame(width: 76, height: 106)
                    .rotationEffect(.degrees(Double(index) * 7 - 7))
                    .offset(x: CGFloat(index) * 33 - 33, y: CGFloat(abs(index - 1)) * 5)
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
            }
        }
        .frame(width: 158, height: 126)
    }

    private var heroPosters: [FollowPoster] {
        var list: [FollowPoster] = []
        var seen = Set<String>()
        for person in sorted(catalog.followedPeople) {
            for poster in posters[person.id] ?? [] {
                guard seen.insert(poster.cover).inserted else { continue }
                list.append(poster)
                if list.count >= 3 { return list }
            }
        }
        return list
    }

    // MARK: - 新内容

    private var newSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("新内容", detail: "\(newcomers.count) 位有更新")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(newcomers) { person in
                        FollowNewCard(person: person,
                                      posters: posters[person.id] ?? [],
                                      accent: tint(person)) {
                            open(person)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - 人物 / 片商

    private func peopleSection(title: String, detail: String,
                               list: [CatalogFollowedPerson]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(title, detail: detail)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 232), spacing: 14)], spacing: 14) {
                ForEach(list) { person in
                    FollowPersonCard(person: person,
                                     posters: posters[person.id] ?? [],
                                     accent: tint(person),
                                     onOpen: { open(person) },
                                     onUnfollow: {
                                         catalog.toggleFollowPerson(name: person.name,
                                                                    role: person.role,
                                                                    sourceID: person.sourceID)
                                     })
                }
            }
        }
    }

    // MARK: - 题材

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("题材与分类", detail: "\(catalog.followedCategories.count) 个")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 268), spacing: 12)], spacing: 12) {
                ForEach(catalog.followedCategories) { followed in
                    FollowCategoryCard(followed: followed,
                                       source: source(followed.sourceID),
                                       cover: catalog.categoryThumb(sourceID: followed.sourceID,
                                                                    categoryID: followed.categoryID),
                                       onOpen: { openCategory(followed) },
                                       onUnfollow: { catalog.removeFollow(followed) })
                }
            }
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "star.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.85))
            Text("还没有关注")
                .font(.system(size: 14, weight: .semibold))
            Text("在详情页点演员 / 片商名字可以关注人物，分类菜单里可以关注题材。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    // MARK: - 通用

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LumaBrand.gradient)
                .frame(width: 3, height: 14)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }

    private func sorted(_ list: [CatalogFollowedPerson]) -> [CatalogFollowedPerson] {
        list.sorted { lhs, rhs in
            if lhs.newCount != rhs.newCount { return lhs.newCount > rhs.newCount }
            return lhs.addedAt > rhs.addedAt
        }
    }

    private func source(_ id: UUID) -> CatalogSource? {
        // 关注页只服务网络资源，影视源不出现在这里。
        catalog.resourceSources.first { $0.id == id }
    }

    private func tint(_ person: CatalogFollowedPerson) -> Color {
        source(person.sourceID)?.kind.sidebarTint ?? .accentColor
    }

    private func open(_ person: CatalogFollowedPerson) {
        catalog.followedProfile = person
    }

    private func openCategory(_ followed: CatalogFollowedCategory) {
        catalog.focus(followed.sourceID)
        if let category = catalog.category(withID: followed.categoryID) {
            catalog.openCategory(category)
        } else {
            catalog.openCategory(CatalogCategory(id: followed.categoryID, title: followed.title))
        }
        store.navigate(to: .catalogSource(followed.sourceID))
        catalog.setHubTab(.browse)
    }

    // MARK: - 封面

    /// 从本地日历里找标题含该人物名字的条目，拼成卡片的封面墙；不发任何请求。
    private var refreshKey: String {
        let cached = catalog.followPosters.values.reduce(0) { $0 + $1.count }
        let calendarCount = catalog.calendarItems
            .filter { catalog.resourceSourceIDs.contains($0.sourceID) }.count
        return "\(calendarCount)-\(catalog.followedPeople.count)-"
            + "\(catalog.followPosters.count)-\(cached)"
    }

    private func buildPosters() -> [String: [FollowPoster]] {
        var map: [String: [FollowPoster]] = [:]
        let people = catalog.followedPeople
        guard !people.isEmpty else { return map }

        // 1. 跨源聚合到的封面优先：打开过档案、或关注页后台查过一次，这里都有。
        for person in people {
            var list: [FollowPoster] = []
            var seen = Set<String>()
            for record in catalog.followPosters[person.id] ?? [] {
                guard let source = source(record.sourceID),
                      seen.insert(record.coverURL).inserted else { continue }
                list.append(FollowPoster(id: record.id, source: source, cover: record.coverURL))
                if list.count >= 4 { break }
            }
            if !list.isEmpty { map[person.id] = list }
        }

        // 2. 本地日历补充：还没凑齐 4 张的人，用标题命中的资源站条目补位。
        for entry in catalog.calendarItems
        where catalog.resourceSourceIDs.contains(entry.sourceID) {
            guard !entry.coverURL.isEmpty,
                  let source = source(entry.sourceID) else { continue }
            let text = entry.title + " " + entry.remark
            for person in people where (map[person.id]?.count ?? 0) < 4 {
                guard person.name.count >= 2,
                      text.localizedCaseInsensitiveContains(person.name) else { continue }
                var list = map[person.id] ?? []
                guard !list.contains(where: { $0.cover == entry.coverURL }) else { continue }
                list.append(FollowPoster(id: entry.id, source: source, cover: entry.coverURL))
                map[person.id] = list
            }
        }
        return map
    }
}

/// 关注页的一张封面：带着所属源，悬停预览与解密都靠它。
private struct FollowPoster: Identifiable, Hashable {
    var id: String
    var source: CatalogSource
    var cover: String
}

/// 2×2 封面墙；只有 1 张时退回单图，避免同一张重复贴。
/// 只有 2–3 张时空位用品牌色渐变补齐，保持「4 宫格」的形状。
private struct FollowMosaic: View {
    let posters: [FollowPoster]
    let accent: Color

    var body: some View {
        Group {
            if posters.count >= 2 {
                VStack(spacing: 1) {
                    HStack(spacing: 1) {
                        tile(0)
                        tile(1)
                    }
                    HStack(spacing: 1) {
                        tile(2)
                        tile(3)
                    }
                }
            } else if let first = posters.first {
                CatalogArtworkImage(source: first.source, urlString: first.cover, cornerRadius: 0)
            } else {
                ZStack {
                    LinearGradient(colors: [accent.opacity(0.55), .black.opacity(0.9)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.22))
                }
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func tile(_ index: Int) -> some View {
        if posters.indices.contains(index) {
            CatalogArtworkImage(source: posters[index].source,
                                urlString: posters[index].cover,
                                cornerRadius: 0)
        } else {
            LinearGradient(colors: [accent.opacity(0.34), .black.opacity(0.72)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(.white.opacity(0.16))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 横向「新内容」卡片：2×2 封面 + 名字 + 新增条数。
private struct FollowNewCard: View {
    let person: CatalogFollowedPerson
    let posters: [FollowPoster]
    let accent: Color
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 7) {
                FollowMosaic(posters: posters, accent: accent)
                    .frame(width: 196, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Text("新 \(person.newCount)")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.red.opacity(0.88), in: Capsule(style: .continuous))
                            .padding(7)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(hovering ? accent.opacity(0.8) : Color.primary.opacity(0.08),
                                          lineWidth: hovering ? 1.1 : 0.6)
                    }
                    .shadow(color: .black.opacity(hovering ? 0.24 : 0.12),
                            radius: hovering ? 10 : 4, y: 3)
                Text(CatalogNameParser.splitAliases(person.name).primary)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(hovering ? 1 : 0.88))
                    .lineLimit(1)
                    .frame(width: 196, alignment: .leading)
                Text("\(person.role) · \(person.newCount) 条新内容")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: 196, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("打开 \(person.name) 的档案")
    }
}

/// 关注人物卡片：封面墙 + 名字 + 新内容角标，悬停浮出「打开档案」。
private struct FollowPersonCard: View {
    let person: CatalogFollowedPerson
    let posters: [FollowPoster]
    let accent: Color
    let onOpen: () -> Void
    let onUnfollow: () -> Void

    @State private var hovering = false

    /// 关注记录只存名字与角色，头像回到内置资料库现查。
    private var avatarBase64: String? {
        if person.role == "片商" {
            return CatalogNameDictionary.studio(matching: person.name)?.avatarBase64
        }
        return CatalogNameDictionary.actress(matching: person.name)?.avatarBase64
    }

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                FollowMosaic(posters: posters, accent: accent)
                LinearGradient(colors: [.clear, .black.opacity(0.82)],
                               startPoint: .center, endPoint: .bottom)
                HStack(spacing: 8) {
                    CatalogAvatarView(name: CatalogNameParser.splitAliases(person.name).primary,
                                      base64: avatarBase64,
                                      size: 30,
                                      ringColor: .white.opacity(0.35))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(CatalogNameParser.splitAliases(person.name).primary)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(accent).frame(width: 4.5, height: 4.5)
                            Text(person.role)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.white.opacity(0.62))
                        }
                    }
                }
                .padding(12)
            }
            .frame(height: 148)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if person.newCount > 0 {
                    Text("新 \(person.newCount)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.red.opacity(0.88), in: Capsule(style: .continuous))
                        .padding(9)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("打开档案")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(.black.opacity(0.82))
                    .padding(.horizontal, 9)
                    .frame(height: 23)
                    .background(.white.opacity(0.92), in: Capsule(style: .continuous))
                    .padding(10)
                    .transition(.opacity)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering ? accent.opacity(0.8) : Color.primary.opacity(0.08),
                                  lineWidth: hovering ? 1.1 : 0.6)
            }
            .shadow(color: .black.opacity(hovering ? 0.26 : 0.14),
                    radius: hovering ? 12 : 5, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("取消关注", role: .destructive, action: onUnfollow)
        }
        .help("打开 \(person.name) 的档案")
    }
}

/// 关注分类：缩略图 + 名称 + 来源，点开直接进该分类。
private struct FollowCategoryCard: View {
    let followed: CatalogFollowedCategory
    let source: CatalogSource?
    let cover: String?
    let onOpen: () -> Void
    let onUnfollow: () -> Void

    @State private var hovering = false

    private var tint: Color { source?.kind.sidebarTint ?? .accentColor }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 11) {
                Group {
                    if let source, let cover, !cover.isEmpty {
                        CatalogArtworkImage(source: source, urlString: cover, cornerRadius: 8)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint.opacity(0.16))
                            .overlay {
                                Image(systemName: "square.grid.2x2")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(tint)
                            }
                    }
                }
                .frame(width: 78, height: 50)
                .clipped()

                VStack(alignment: .leading, spacing: 3) {
                    Text(followed.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.92))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(tint).frame(width: 4, height: 4)
                        Text(followed.sourceName)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .padding(10)
            .background(Color.primary.opacity(hovering ? 0.055 : 0.032),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? tint.opacity(0.5) : Color.primary.opacity(0.06),
                                  lineWidth: hovering ? 1 : 0.6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("取消关注", role: .destructive, action: onUnfollow)
        }
        .help("打开 \(followed.sourceName) · \(followed.title)")
    }
}
