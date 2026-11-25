import AppKit
import SwiftUI

/// 女优 / 片商档案：跨源聚合同名作品，按年份排出时间线；关注后显示新片数量。
struct CatalogPersonProfileView: View {
    let name: String
    let role: String
    let sourceID: UUID
    /// 非空表示嵌在关注页里显示：左上角给「返回」，不再用弹窗。
    var onClose: (() -> Void)? = nil
    /// 返回按钮文案：从关注页进来是「返回关注」，从详情页进来是「返回详情」。
    var backTitle: String = "返回"
    /// 是否在内容区画返回按钮：关注页把返回放到窗口工具栏最左侧，这里就不重复画。
    var showsInlineBack: Bool = true
    /// 是否跨源检索作品。内置资料库入口设为 false，只显示本地档案。
    var loadsWorks: Bool = true

    @EnvironmentObject private var catalog: CatalogBrowserModel
    @Environment(\.dismiss) private var dismiss

    /// 内置资料库资料（简介 / 字段）：直接读 SQLite，不联网。
    @State private var wiki: CatalogPersonInfoService.Fetch?
    /// 资料库里的头像 URL 是外链（JavBus / JavRate），按需下载一次。
    @State private var remotePortrait: NSImage?
    @State private var loadedPortraitURL: String?
    @State private var showFullSummary = false
    /// 作品分组方式：默认按来源，方便一眼看出每个站各有多少。
    @State private var groupMode: GroupMode = .source

    private enum GroupMode: String, CaseIterable, Identifiable {
        case source = "按来源"
        case year = "按年份"

        var id: String { rawValue }
        var title: String { rawValue }

        var symbol: String {
            switch self {
            case .source: return "antenna.radiowaves.left.and.right"
            case .year: return "calendar"
            }
        }
    }

    private var isEmbedded: Bool { onClose != nil }

    /// 标题只显示主名，括号里的别名单独作为提示：
    /// 「高宫菜菜子 (高宫菜々子)」→ 标题「高宫菜菜子」。
    private var splitName: (primary: String, aliases: [String]) {
        CatalogNameParser.splitAliases(name)
    }

    private var displayName: String { splitName.primary }

    private var portrait: NSImage? {
        if let remotePortrait { return remotePortrait }
        // 数据库内置的 96×96 头像优先，省一次联网。
        if let base64 = wiki?.info.avatarBase64,
           let data = Data(base64Encoded: base64),
           let image = NSImage(data: data) {
            return image
        }
        guard let data = wiki?.image else { return nil }
        return NSImage(data: data)
    }

    /// 资料库头像是外链，按需下载；JavBus 图床要求带 Referer。
    private func loadPortraitIfNeeded() {
        // 内置 base64 头像已经够用，不再下载外链。
        guard wiki?.info.avatarBase64?.isEmpty != false else { return }
        guard let urlString = wiki?.info.imageURL, !urlString.isEmpty,
              urlString != loadedPortraitURL, let url = URL(string: urlString),
              let scheme = url.scheme, let host = url.host else { return }
        loadedPortraitURL = urlString

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                         + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        Task { @MainActor in
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let image = NSImage(data: data) else { return }
            remotePortrait = image
        }
    }

    private var profile: CatalogPersonProfile? {
        guard catalog.personProfile?.name == name, catalog.personProfile?.role == role else {
            return nil
        }
        return catalog.personProfile
    }

    private var following: Bool {
        catalog.isFollowingPerson(name: name, role: role)
    }

    /// 档案头图的来源：用时间线第一张封面做模糊背景。
    private var heroCover: (CatalogSource, String)? {
        guard let entry = profile?.timeline.first(where: { !$0.item.coverURL.isEmpty }),
              let source = catalog.resourceSources.first(where: { $0.id == entry.sourceID })
        else { return nil }
        return (source, entry.item.coverURL)
    }

    var body: some View {
        ZStack {
            LumaAmbientBackground(intensity: 0.85)

            VStack(alignment: .leading, spacing: 0) {
                header
                infoPanel
                content
            }
        }
        .overlay(alignment: .topLeading) {
            if isEmbedded, showsInlineBack {
                backButton
                    .padding(.leading, 22)
                    .padding(.top, 16)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !isEmbedded {
                closeButton
                    .padding(16)
            }
        }
        .frame(width: isEmbedded ? nil : 900, height: isEmbedded ? nil : 720)
        .onAppear {
            if loadsWorks, profile == nil {
                catalog.openPersonProfile(name: name, role: role, sourceID: sourceID)
            }
        }
        .task(id: "\(role)|\(name)") {
            remotePortrait = nil
            loadedPortraitURL = nil
            wiki = CatalogPersonInfoService.shared.cached(name: name, role: role)
            loadPortraitIfNeeded()
        }
        .onDisappear {
            if loadsWorks { catalog.closePersonProfile() }
        }
    }

    // MARK: - 内置资料

    @ViewBuilder
    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("内置资料")
                    .font(.system(size: 12, weight: .semibold))
                if let wiki {
                    Text(wiki.info.provider)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12),
                                    in: Capsule(style: .continuous))
                    // 模糊命中时把资料库里的标准名标出来，避免「名字对不上」的疑惑。
                    if CatalogNameParser.normalize(wiki.info.name)
                        != CatalogNameParser.normalize(displayName) {
                        Text("资料库：\(wiki.info.name)")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06),
                                        in: Capsule(style: .continuous))
                            .help("按别名 / 近似写法匹配到资料库记录")
                    }
                    if let description = wiki.info.description {
                        Text(description)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let urlString = wiki?.info.sourceURL, let url = URL(string: urlString) {
                    Button("查看出处") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }

            if let wiki {
                Text(wiki.info.summary)
                    .font(.system(size: 12))
                    .lineSpacing(3.5)
                    .foregroundStyle(Color.primary.opacity(0.86))
                    .lineLimit(showFullSummary ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if wiki.info.summary.count > 150 {
                    Button(showFullSummary ? "收起" : "展开全文") {
                        withAnimation(.easeInOut(duration: 0.2)) { showFullSummary.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
                if !wiki.info.facts.isEmpty {
                    CatalogFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(wiki.info.facts) { fact in
                            factChip(fact)
                        }
                    }
                }
            } else {
                Text("内置资料库没有收录这个人。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    /// 资料字段胶囊。「官网」这一项做成可点击，其余保持纯展示。
    @ViewBuilder
    private func factChip(_ fact: CatalogPersonFact) -> some View {
        if fact.label == "官网", let url = URL(string: fact.value) {
            Button { NSWorkspace.shared.open(url) } label: {
                HStack(spacing: 4) {
                    Text(fact.label)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    Text("打开")
                        .font(.system(size: 10.5, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.10),
                            in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help(fact.value)
        } else {
            HStack(spacing: 4) {
                Text(fact.label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Text(fact.value)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05),
                        in: Capsule(style: .continuous))
        }
    }

    private var backButton: some View {
        Button { onClose?() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                Text(backTitle)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(.black.opacity(0.34), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help(backTitle)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 头部

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            // 模糊封面做底：档案页不再是一块纯色，和详情页保持同一种气质。
            Color.clear
                .frame(height: 188)
                .overlay {
                    if let portrait {
                        // 有百科头像就用头像做底，没有就退回作品封面。
                        Image(nsImage: portrait)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 40, opaque: true)
                            .opacity(0.6)
                            .scaleEffect(1.15)
                    } else if let cover = heroCover {
                        CatalogArtworkImage(source: cover.0, urlString: cover.1, cornerRadius: 0)
                            .blur(radius: 36, opaque: true)
                            .opacity(0.55)
                            .scaleEffect(1.14)
                    }
                }
                .clipped()
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.18), .black.opacity(0.58)],
                                   startPoint: .top, endPoint: .bottom)
                }

            HStack(alignment: .bottom, spacing: 16) {
                avatar

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(displayName)
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(role)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.16), in: Capsule(style: .continuous))
                        if !splitName.aliases.isEmpty {
                            Text("又名 \(splitName.aliases.joined(separator: " / "))")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                        }
                        if loadsWorks, let profile, profile.newCount > 0 {
                            Text("新 \(profile.newCount) 部")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.red.opacity(0.85), in: Capsule(style: .continuous))
                                .shadow(color: Color.red.opacity(0.4), radius: 6, y: 2)
                        }
                    }

                    HStack(spacing: 6) {
                        if loadsWorks {
                            statChip(symbol: "film.stack",
                                     text: "\(profile?.totalCount ?? 0) 部")
                            statChip(symbol: "antenna.radiowaves.left.and.right",
                                     text: "\(profile?.groups.count ?? 0) 个源")
                            if let span = yearSpan {
                                statChip(symbol: "calendar", text: span)
                            }
                        } else {
                            statChip(symbol: "books.vertical.fill", text: "内置资料库")
                            if let region = localRegionTitle {
                                statChip(symbol: "mappin.and.ellipse", text: region)
                            }
                            if let works = localWorkCount, works > 0 {
                                statChip(symbol: "film.stack", text: "\(works) 部")
                            }
                        }
                    }
                }

                Spacer(minLength: 12)

                followButton
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .padding(.top, isEmbedded && showsInlineBack ? 52 : 28)
        }
    }

    private var avatar: some View {
        Color.clear
            .frame(width: 54, height: 54)
            .overlay {
                if let portrait {
                    Image(nsImage: portrait)
                        .resizable()
                        .scaledToFill()
                } else {
                    // 没有图时用同一个渐变字母头像，和列表卡片保持一致。
                    CatalogAvatarView(name: displayName,
                                      base64: nil,
                                      size: 54,
                                      ringColor: .white.opacity(0.32))
                }
            }
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(.white.opacity(0.32), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
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

    private var followButton: some View {
        Button {
            catalog.toggleFollowPerson(name: name, role: role, sourceID: sourceID)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: following ? "checkmark" : "plus")
                    .font(.system(size: 9.5, weight: .bold))
                Text(following ? "已关注" : "关注")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(following ? AnyShapeStyle(.white.opacity(0.16))
                                  : AnyShapeStyle(Color.accentColor),
                        in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.24), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
        .help(following ? "取消关注" : "关注后有新片会在关注页提示")
    }

    /// 作品年份跨度：时间线里最早与最晚的年份。
    private var yearSpan: String? {
        let years = (profile?.timeline ?? []).compactMap {
            CatalogQueryPlan.year(in: $0.item.title + " " + $0.item.remark)
        }
        guard let min = years.min(), let max = years.max() else { return nil }
        return min == max ? "\(min)" : "\(min)–\(max)"
    }

    // MARK: - 时间线

    private var localActress: CatalogActressRecord? {
        role.contains("片商") ? nil : CatalogNameDictionary.actress(matching: name)
    }

    private var localStudio: CatalogStudioRecord? {
        role.contains("片商") ? CatalogNameDictionary.studio(matching: name) : nil
    }

    private var localRegionTitle: String? {
        localActress?.regionTitle ?? localStudio?.regionTitle
    }

    private var localWorkCount: Int? {
        localActress?.workCount ?? localStudio?.workCount
    }

    /// 只读内置资料库：不跨源检索作品，展示标签、别名与机构简介。
    private var localOnlyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: role.contains("片商") ? "building.2.fill"
                                                            : "person.text.rectangle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(role.contains("片商") ? "内置机构档案" : "内置人物档案")
                            .font(.system(size: 15, weight: .semibold))
                        Text("资料随 App 内置，不会联网检索作品。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                // 与资源页打通：把名字带到跨源搜索，直接看这个人在各站的作品。
                Button {
                    catalog.globalQuery = displayName
                    catalog.setHubTab(.browse)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9, weight: .semibold))
                        Text(role.contains("片商") ? "在资源中搜机构作品" : "在资源中搜作品")
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 11)
                    .frame(height: 27)
                    .background(Color.accentColor.opacity(0.12),
                                in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.6)
                    }
                }
                .buttonStyle(.plain)
                .help("切到资源页，跨源搜索「\(displayName)」")

                if let actress = localActress {
                    if !actress.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("资料库标签")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            CatalogFlowLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(actress.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.1),
                                                    in: Capsule(style: .continuous))
                                }
                            }
                        }
                    }
                    if !actress.aliases.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("其他写法")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(actress.aliases.joined(separator: "、"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                } else if let studio = localStudio {
                    if !studio.aliases.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("其他写法")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(studio.aliases.joined(separator: "、"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if let summary = studio.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("机构简介")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(summary)
                                .font(.system(size: 12))
                                .lineSpacing(3)
                                .foregroundStyle(Color.primary.opacity(0.86))
                                .textSelection(.enabled)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !loadsWorks {
            localOnlyContent
        } else if catalog.isPersonLoading, profile?.totalCount ?? 0 == 0 {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在跨源检索…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let profile, !profile.timeline.isEmpty {
            let newIDs = Set(profile.newItemIDs)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    groupModeBar(profile)
                    switch groupMode {
                    case .source:
                        ForEach(sourceGroups(profile)) { group in
                            workSection(title: group.title,
                                        count: group.items.count,
                                        items: group.items,
                                        newIDs: newIDs)
                        }
                    case .year:
                        ForEach(yearGroups(profile, newIDs: newIDs)) { group in
                            workSection(title: group.year == 0 ? "年份未知" : "\(String(group.year))",
                                        count: group.items.count,
                                        items: group.items,
                                        newIDs: newIDs)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("没有找到相关作品")
                    .font(.system(size: 14, weight: .semibold))
                Text("有些站点不支持按名字检索，或该名字在标题里不出现。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 分组切换：来源 / 年份。默认按来源，和资源页的频道胶囊同一套语言。
    private func groupModeBar(_ profile: CatalogPersonProfile) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(GroupMode.allCases) { mode in
                    let active = groupMode == mode
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { groupMode = mode }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: mode.symbol)
                                .font(.system(size: 9, weight: .semibold))
                            Text(mode.title)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(active ? Color.white : Color.secondary)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background {
                            if active {
                                Capsule(style: .continuous).fill(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))

            Text("\(profile.totalCount) 部 · \(profile.groups.count) 个源")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            if catalog.isPersonLoading {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("同步新内容…")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            } else if !profile.newItemIDs.isEmpty {
                Text("\(profile.newItemIDs.count) 条新内容")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.86), in: Capsule(style: .continuous))
                    .shadow(color: Color.red.opacity(0.3), radius: 5, y: 1)
            }
            Spacer(minLength: 0)
        }
    }

    private func workSection(title: String, count: Int,
                             items: [CatalogSpotlightItem],
                             newIDs: Set<String>) -> some View {
        let freshCount = items.filter { newIDs.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("\(count) 部")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                if freshCount > 0 {
                    Text("新 \(freshCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.red.opacity(0.86), in: Capsule(style: .continuous))
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.8)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136, maximum: 180),
                                         spacing: 14)],
                      alignment: .leading, spacing: 16) {
                ForEach(items) { entry in
                    if let source = catalog.resourceSources.first(where: { $0.id == entry.sourceID }) {
                        personCell(entry, source: source, isNew: newIDs.contains(entry.id))
                    }
                }
            }
        }
    }

    private func personCell(_ entry: CatalogSpotlightItem, source: CatalogSource,
                            isNew: Bool = false) -> some View {
        Button {
            catalog.playRemote(sourceID: entry.sourceID, item: entry.item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(CGFloat(source.posterRatio), contentMode: .fit)
                    .overlay {
                        CatalogArtworkImage(source: source,
                                            urlString: entry.item.coverURL,
                                            cornerRadius: 10)
                    }
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(colors: [.clear, .black.opacity(0.62)],
                                       startPoint: .center, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 10,
                                                        style: .continuous))
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text(entry.sourceName)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 5)
                    }
                    .overlay(alignment: .topLeading) {
                        if isNew {
                            Text("新")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.red.opacity(0.9), in: Capsule(style: .continuous))
                                .shadow(color: Color.red.opacity(0.4), radius: 4, y: 1)
                                .padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isNew ? Color.red.opacity(0.55)
                                                : Color.primary.opacity(0.07),
                                          lineWidth: isNew ? 1.1 : 0.6)
                    }
                Text(entry.item.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isNew ? Color.primary.opacity(0.95)
                                           : Color.primary.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 30, alignment: .topLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.item.title)
    }

    private struct SourceGroup: Identifiable {
        var sourceID: UUID
        var title: String
        var items: [CatalogSpotlightItem]
        var id: UUID { sourceID }
    }

    private func sourceGroups(_ profile: CatalogPersonProfile) -> [SourceGroup] {
        // 分组的先后跟侧边栏里的源顺序一致：只按网络资源的源排序，影视源不参与。
        let sourceOrder = Dictionary(uniqueKeysWithValues:
            catalog.resourceSources.enumerated().map { ($0.element.id, $0.offset) })
        return profile.groups
            .filter { !$0.items.isEmpty }
            .enumerated()
            .map { index, group -> (index: Int, order: Int, group: SourceGroup) in
                let items = group.items.map {
                    CatalogSpotlightItem(sourceID: group.sourceID,
                                         sourceName: group.sourceName,
                                         item: $0)
                }
                return (index,
                        sourceOrder[group.sourceID] ?? Int.max,
                        SourceGroup(sourceID: group.sourceID,
                                    title: group.sourceName,
                                    items: items))
            }
            .sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.index < rhs.index
            }
            .map(\.group)
    }

    private struct YearGroup: Identifiable {
        var year: Int
        var items: [CatalogSpotlightItem]
        var id: Int { year }
    }

    private func yearGroups(_ profile: CatalogPersonProfile,
                            newIDs: Set<String>) -> [YearGroup] {
        let grouped = Dictionary(grouping: profile.timeline) { entry in
            CatalogQueryPlan.year(in: entry.item.title + " " + entry.item.remark) ?? 0
        }
        return grouped.keys.sorted(by: >).map { year in
            let items = grouped[year] ?? []
            // 同一年里新条目也排最前。
            let fresh = items.filter { newIDs.contains($0.id) }
            let old = items.filter { !newIDs.contains($0.id) }
            return YearGroup(year: year, items: fresh + old)
        }
    }
}
