import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 演职员详情页与演员面板。

/// 演职员页：作为影院详情里的二级页铺满内容区（不弹窗），
/// 版式和「剧集档案」同一套：深色玻璃卡 + 琥珀渐变描边 + 大头像作视觉锚点。
struct CinemaPersonDetailView: View {
    let member: CinemaCastMember
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }
    var onPlay: (CinemaEntry) -> Void = { _ in }

    @EnvironmentObject private var store: LibraryStore

    enum Lane: String, CaseIterable, Identifiable {
        case library = "本库已有"
        case all = "全部作品"
        var id: String { rawValue }
    }

    @State private var lane: Lane = .library
    @State private var profile: CinemaPersonProfile?
    @State private var loading = true
    @State private var bioExpanded = false
    /// 悬停作品：key 是本库条目 UUID 或 TMDB credit id。
    @State private var hoveredWorkKey: String?
    @State private var workHoverHeight: CGFloat = 300
    /// 未入库作品悬停时按需补的 TMDB 详情（简介 / 评分 / 类型 / 片长）。
    @State private var creditDetails: [String: CinemaDetails] = [:]
    @State private var creditDetailLoading: Set<String> = []

    /// 默认按最新排序：年份新的在前，没有年份的排最后。
    var works: [CinemaEntry] {
        store.cinemaPersonWorks(named: member.name)
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    var credits: [CinemaPersonCredit] {
        (profile?.credits ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    var body: some View {
        // 和剧集 / 影片详情同一套结构：底图挂 background，不参与页面尺寸推导。
        GeometryReader { proxy in
            let horizontal: CGFloat = 24
            let width = max(320, proxy.size.width - horizontal * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    profileCard
                    worksSection(width: width)
                }
                .padding(.horizontal, horizontal)
                .padding(.bottom, 36)
                // 只填满可视宽度：固定 width 会变成窗口最小宽度，缩下去就回不来。
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .background(alignment: .top) { ambient }
        // 悬停作品档案：挂在页面最上层，贴着卡片显示，又不会被滚动区裁掉。
        .overlayPreferenceValue(CinemaWorkAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let key = hoveredWorkKey, let anchor = anchors[key] {
                    let rect = proxy[anchor]
                    let margin: CGFloat = 12
                    let gap: CGFloat = 14
                    let width = min(340, max(240, proxy.size.width - margin * 2))
                    let onRight = rect.maxX + gap + width + margin <= proxy.size.width
                    let rawX = onRight ? rect.maxX + gap : rect.minX - gap - width
                    let x = min(max(margin, rawX), max(margin, proxy.size.width - width - margin))
                    let y = min(max(margin, rect.minY),
                                max(margin, proxy.size.height - workHoverHeight - margin))
                    workHoverCard(key)
                        .frame(width: width)
                        // GeometryReader 会把整个浮层高度提给子视图，卡片必须按内容自适应，
                        // 否则里面的 Spacer 会把简介顶到面板底部，中间空出一大块。
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { workHoverHeight = geo.size.height }
                                    .onChange(of: geo.size.height) { _, height in
                                        workHoverHeight = height
                                    }
                            }
                        }
                        .offset(x: x, y: y)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: hoveredWorkKey)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CinemaDetailTone.page)
        .task {
            if member.tmdbID != nil {
                profile = await store.cinemaPersonProfile(for: member)
            }
            loading = false
        }
    }

    /// 用本库作品的海报虚化铺底：和影院其他详情页一致的氛围层。
    var ambient: some View {
        ZStack(alignment: .top) {
            CinemaDetailTone.page
            CinemaArtwork(urlString: works.first?.backdropURL ?? works.first?.posterURL,
                          contentMode: .fill)
                .frame(height: 720)
                .blur(radius: 90, opaque: true)
                .opacity(0.16)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.72), location: 0.34),
                        .init(color: .black.opacity(0.22), location: 0.70),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }


    // MARK: 档案卡

    /// 大头像 + 姓名 / 角色 / 生卒地 / 简介：和「剧集档案」同一张玻璃卡。
    var profileCard: some View {
        HStack(alignment: .top, spacing: 26) {
            avatarColumn
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("演职员档案")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(CinemaDetailTone.accent.opacity(0.92))
                    Rectangle()
                        .fill(LumaBrand.amber.opacity(0.35))
                        .frame(width: 24, height: 0.8)
                    Text(departmentText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(member.name)
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundStyle(CinemaDetailTone.ink)
                    .textSelection(.enabled)

                if let character = member.character, !character.isEmpty {
                    Text("饰 \(character)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                }

                chipRow

                Button {
                    store.searchOnlineCinema(member.name)
                } label: {
                    Label("在网络影院搜索 TA 的作品", systemImage: "play.tv.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(LumaBrand.amber.opacity(0.14), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(LumaBrand.amber.opacity(0.35), lineWidth: 0.8)
                        }
                }
                .buttonStyle(.plain)
                .help("切到网络影院，用 TA 的名字搜索")

                bioBlock
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [CinemaDetailTone.ink.opacity(0.062),
                                              CinemaDetailTone.ink.opacity(0.022)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    RadialGradient(colors: [LumaBrand.amber.opacity(0.10), .clear],
                                   center: .topLeading, startRadius: 0, endRadius: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [LumaBrand.amber.opacity(0.30),
                                            CinemaDetailTone.ink.opacity(0.06),
                                            Color.clear],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    lineWidth: 0.8
                )
        }
    }

    /// 头像 + 本库作品数：圆形头像带琥珀细环和外圈留白，像一张档案照。
    var avatarColumn: some View {
        VStack(spacing: 12) {
            ZStack {
                if let url = profile?.profileURL ?? member.profileURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else {
                    Circle().fill(CinemaDetailTone.ink.opacity(0.06))
                    Image(systemName: "person.fill")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.35))
                }
            }
            .frame(width: 172, height: 172)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(LumaBrand.amber.opacity(0.30), lineWidth: 1.2)
            }
            .overlay {
                Circle().strokeBorder(CinemaDetailTone.ink.opacity(0.06), lineWidth: 0.8)
                    .padding(-7)
            }
            .shadow(color: LumaBrand.amber.opacity(0.16), radius: 26, y: 12)

            HStack(spacing: 5) {
                Image(systemName: "film.stack")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                Text("本库 \(works.count) 部")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.80))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(CinemaDetailTone.ink.opacity(0.07), in: Capsule())
            .overlay {
                Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
            }
        }
        .frame(width: 172, alignment: .top)
    }

    var chipRow: some View {
        HStack(spacing: 7) {
            chip("本库 \(works.count) 部", highlight: true)
            chip("全部 \(credits.isEmpty ? "—" : "\(credits.count)") 部")
            if let birthday = profile?.birthday, !birthday.isEmpty {
                chip(birthday)
            }
            if let place = profile?.placeOfBirth, !place.isEmpty {
                chip(place)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    var bioBlock: some View {
        if let bio = profile?.biography, !bio.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(bio)
                    .font(.system(size: 12.5))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.76))
                    .lineSpacing(6)
                    .lineLimit(bioExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if bio.count > 160 {
                    Button(bioExpanded ? "收起" : "展开全文") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            bioExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                }
            }
        } else if loading {
            ProgressView().controlSize(.mini)
        } else {
            Text(works.isEmpty
                 ? "本库还没有这位参与的作品，重新刮削后可看到更多资料。"
                 : "本库已收录 \(works.count) 部，可直接播放。")
                .font(.system(size: 11.5))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.5))
        }
    }

    var departmentText: String {
        guard let department = profile?.department, !department.isEmpty else { return "演职员" }
        switch department {
        case "Acting": return "演员"
        case "Directing": return "导演"
        case "Writing": return "编剧"
        case "Production": return "制片"
        case "Camera": return "摄影"
        case "Art": return "美术"
        case "Sound": return "音效"
        case "Editing": return "剪辑"
        case "Costume & Make-Up": return "造型"
        case "Visual Effects": return "视效"
        default: return department
        }
    }

    func chip(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(highlight ? LumaBrand.amber : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(highlight ? LumaBrand.amber.opacity(0.12)
                                                 : Color.primary.opacity(0.06)))
            .overlay {
                Capsule().strokeBorder(highlight ? LumaBrand.amber.opacity(0.30)
                                                 : Color.primary.opacity(0.08), lineWidth: 0.6)
            }
    }

    /// 作品区：标题行 + 本库 / 全部切换 + 海报网格。
    func worksSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("作品")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(lane == .library ? works.count : credits.count) 部")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                Spacer(minLength: 0)
                laneSwitch
            }
            content(width: width)
        }
    }

    var laneSwitch: some View {
        HStack(spacing: 4) {
            ForEach(Lane.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.16)) { lane = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(lane == item ? LumaBrand.amber.opacity(0.16)
                                                   : CinemaDetailTone.ink.opacity(0.05))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(lane == item ? LumaBrand.amber.opacity(0.35)
                                                           : CinemaDetailTone.ink.opacity(0.07),
                                              lineWidth: 0.7)
                        }
                        .foregroundStyle(lane == item ? LumaBrand.amber
                                                      : CinemaDetailTone.ink.opacity(0.62))
                }
                .buttonStyle(.plain)
            }
            if loading {
                ProgressView().controlSize(.mini).padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    func content(width: CGFloat) -> some View {
        switch lane {
        case .library:
            if works.isEmpty {
                emptyHint("本库暂时没有这位参与的作品",
                          detail: "到海报墙右键影片重新刮削，补全演职员后这里会自动出现。")
            } else {
                grid(width: width) {
                    ForEach(works) { entry in
                        workTile(entry)
                            .anchorPreference(key: CinemaWorkAnchorKey.self, value: .bounds) {
                                [entry.id.uuidString: $0]
                            }
                    }
                }
            }
        case .all:
            if loading {
                ProgressView("正在读取 TMDB 作品…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if profile == nil {
                emptyHint("没有可用的 TMDB 人物资料",
                          detail: "重新刮削这部影片后会补上人物 ID，就能看到全部作品。")
            } else if credits.isEmpty {
                emptyHint("TMDB 没有收录这位的作品", detail: "可以试试搜索片名或导演。")
            } else {
                grid(width: width) {
                    ForEach(credits) { credit in
                        creditTile(credit)
                            .anchorPreference(key: CinemaWorkAnchorKey.self, value: .bounds) {
                                [credit.id: $0]
                            }
                    }
                }
            }
        }
    }

    /// 海报列数按内容列宽推导：窗口变宽就多排一列，卡片宽度平分剩余空间。
    func workColumns(width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 16
        let width = width > 0 ? width : 900
        let count = max(2, GridLayout.columns(contentWidth: width, targetSize: 190, spacing: spacing))
        return Array(repeating: GridItem(.flexible(minimum: 150), spacing: spacing), count: count)
    }

    func grid<Content: View>(width: CGFloat,
                                     @ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: workColumns(width: width),
                  alignment: .leading, spacing: 18) {
            content()
        }
    }

    func workTile(_ entry: CinemaEntry) -> some View {
        Button {
            play(entry)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                poster(url: entry.artworkURL, photo: entry.file.photoItem)
                    .overlay(alignment: .topLeading) {
                        ownedBadge
                    }
                Text(entry.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(entry.kind == .tv ? "剧集 · \(entry.year.map(String.init) ?? "—")"
                                       : (entry.year.map(String.init) ?? "—"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("查看详情") { openDetail(entry) }
            Button("直接播放") { play(entry) }
        }
        .onHover { hovering in
            if hovering {
                hoveredWorkKey = entry.id.uuidString
            } else if hoveredWorkKey == entry.id.uuidString {
                hoveredWorkKey = nil
            }
        }
        .animation(.easeOut(duration: 0.14), value: hoveredWorkKey)
        .help("点击播放")
    }

    func creditTile(_ credit: CinemaPersonCredit) -> some View {
        let owned = store.cinemaEntry(forCredit: credit)
        return Button {
            if let owned {
                play(owned)
            } else {
                // 本库没有这部：直接去网络影院按片名找，两个模块在这里打通。
                store.searchOnlineCinema(credit.title)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                poster(url: credit.posterURL, photo: nil)
                    .overlay(alignment: .topLeading) {
                        if owned != nil { ownedBadge }
                    }
                Text(credit.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle(for: credit))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 未入库的卡片整体压暗，鼠标移上来恢复原色。
            .opacity(owned == nil && hoveredWorkKey != credit.id ? 0.55 : 1)
            .animation(.easeOut(duration: 0.16), value: hoveredWorkKey)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredWorkKey = credit.id
                Task { await loadCreditDetails(credit) }
            } else if hoveredWorkKey == credit.id {
                hoveredWorkKey = nil
            }
        }
        .help(owned == nil ? "点击在网络影院搜索这部" : "点击播放")
        .contextMenu {
            if owned != nil {
                Button("查看详情") { openDetail(owned!) }
                Button("直接播放") { play(owned!) }
                Divider()
            }
            Button("在网络影院搜索") { store.searchOnlineCinema(credit.title) }
        }
    }

    /// 悬停时按需补一次 TMDB 详情，失败就保持基础信息。
    func loadCreditDetails(_ credit: CinemaPersonCredit) async {
        guard creditDetails[credit.id] == nil, !creditDetailLoading.contains(credit.id) else { return }
        creditDetailLoading.insert(credit.id)
        if let details = await store.cinemaCreditDetails(for: credit) {
            creditDetails[credit.id] = details
        }
        creditDetailLoading.remove(credit.id)
    }

    func subtitle(for credit: CinemaPersonCredit) -> String {
        var parts: [String] = []
        parts.append(credit.isTV ? "剧集" : "电影")
        if let year = credit.year { parts.append(String(year)) }
        if let job = credit.job, !job.isEmpty { parts.append(job) }
        else if let character = credit.character, !character.isEmpty { parts.append(character) }
        return parts.joined(separator: " · ")
    }

    // MARK: 作品悬停档案

    @ViewBuilder
    func workHoverCard(_ key: String) -> some View {
        if let entry = works.first(where: { $0.id.uuidString == key }) {
            workHoverCard(entry: entry)
        } else if let credit = credits.first(where: { $0.id == key }) {
            workHoverCard(credit: credit)
        }
    }

    /// 本库作品：海报 + 评分 / 类型 + 简介 + 规格与观看进度。
    func workHoverCard(entry: CinemaEntry) -> some View {
        let tags = cinemaBadgeTags(entry.file, limit: 4)
        let progress = store.cinemaProgress[entry.id]
        let overview = entry.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hoverShell {
            HStack(alignment: .top, spacing: 12) {
                hoverPoster(url: entry.artworkURL, photo: entry.file.photoItem)
                VStack(alignment: .leading, spacing: 7) {
                    Text(entry.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(CinemaDetailTone.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let rating = entry.rating, rating > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                            if let votes = entry.voteCount, votes > 0 {
                                Text("· \(voteText(votes))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.42))
                            }
                        }
                        .foregroundStyle(LumaBrand.amber)
                    }
                    Text(entryMeta(entry))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                        .lineLimit(2)
                    hoverLibraryChip(inLibrary: true)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(14)

            if !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 12))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.88))
                    .lineSpacing(5.5)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }

            if !tags.isEmpty {
                CinemaSpecBadges(tags: tags, fontSize: 9, tint: CinemaDetailTone.ink,
                                 background: CinemaDetailTone.ink.opacity(0.10))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }

            if let progress, progress.fraction > 0.01 {
                HStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(CinemaDetailTone.ink.opacity(0.14))
                            Capsule()
                                .fill(LumaBrand.amber)
                                .frame(width: max(3, geo.size.width * progress.fraction))
                        }
                    }
                    .frame(height: 3)
                    Text(progress.isFinished ? "已看完" : "已看 \(Int(progress.fraction * 100))%")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LumaBrand.amber)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            hoverFooter("点击播放 · 右键查看详情")
        }
    }

    /// 未入库作品：基础资料 + 悬停时补来的 TMDB 简介 / 评分 / 类型 / 片长。
    func workHoverCard(credit: CinemaPersonCredit) -> some View {
        let owned = store.cinemaEntry(forCredit: credit)
        let details = creditDetails[credit.id]
        let loadingDetails = creditDetailLoading.contains(credit.id)
        let role = credit.character.flatMap { $0.isEmpty ? nil : $0 } ?? credit.job
        let overview = details?.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hoverShell {
            HStack(alignment: .top, spacing: 12) {
                hoverPoster(url: credit.posterURL, photo: nil)
                VStack(alignment: .leading, spacing: 7) {
                    Text(credit.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(CinemaDetailTone.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let rating = details?.rating, rating > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                            if let votes = details?.voteCount, votes > 0 {
                                Text("· \(voteText(votes))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.42))
                            }
                        }
                        .foregroundStyle(LumaBrand.amber)
                    }

                    Text(creditMeta(credit, details: details))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                        .lineLimit(2)

                    if let role, !role.isEmpty {
                        Text(role)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.72))
                            .lineLimit(2)
                    }

                    if let genres = details?.genres, !genres.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(genres.prefix(3), id: \.self) { genre in
                                Text(genre)
                                    .font(.system(size: 9))
                                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.76))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(CinemaDetailTone.ink.opacity(0.10), in: Capsule())
                            }
                        }
                    }

                    hoverLibraryChip(inLibrary: owned != nil)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(14)

            if !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 12))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.88))
                    .lineSpacing(5.5)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else if loadingDetails {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在读取简介…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.5))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            if owned == nil {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("TMDB 收录的作品，本库暂未收录；点击可以到网络影院按片名找。")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.62))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            hoverFooter(owned == nil ? "点击在网络影院搜索" : "点击播放")
        }
    }

    /// 未入库作品的元信息：类型 / 年份 / 片长或季集 / 上映日期。
    func creditMeta(_ credit: CinemaPersonCredit, details: CinemaDetails?) -> String {
        var parts: [String] = [credit.isTV ? "剧集" : "电影"]
        if let year = credit.year { parts.append(String(year)) }
        if let details {
            if let runtime = details.runtime, runtime > 0 {
                parts.append(credit.isTV ? "每集 \(runtime) 分钟" : "\(runtime) 分钟")
            }
            if credit.isTV,
               let seasons = details.seasonCount,
               let episodes = details.episodeCount {
                parts.append("\(seasons) 季 · \(episodes) 集")
            }
            if let release = details.releaseDate, !release.isEmpty {
                parts.append(credit.isTV ? "首播 \(release)" : "上映 \(release)")
            }
        }
        return parts.joined(separator: " · ")
    }

    func hoverShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(CinemaDetailTone.plate)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.26), lineWidth: 0.8)
        }
        .shadow(color: CinemaDetailTone.shadow(0.58), radius: 26, y: 13)
    }

    func hoverPoster(url: String?, photo: PhotoItem?) -> some View {
        Group {
            if let url {
                CinemaArtwork(urlString: url, contentMode: .fill)
            } else if let photo {
                PhotoThumbnailView(photo: photo, purpose: .cover(200))
            } else {
                CinemaDetailTone.ink.opacity(0.06)
            }
        }
        .frame(width: 74, height: 111)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CinemaDetailTone.ink.opacity(0.10), lineWidth: 0.6)
        }
    }

    func hoverLibraryChip(inLibrary: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(inLibrary ? LumaBrand.amber : CinemaDetailTone.ink.opacity(0.35))
                .frame(width: 4, height: 4)
            Text(inLibrary ? "在库 · 可直接播放" : "未入库 · 可搜索")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(inLibrary ? LumaBrand.amber
                                           : CinemaDetailTone.ink.opacity(0.58))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((inLibrary ? LumaBrand.amber : CinemaDetailTone.ink)
                        .opacity(inLibrary ? 0.14 : 0.08),
                    in: Capsule())
    }

    func hoverFooter(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.tap")
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10))
            Spacer(minLength: 0)
        }
        .foregroundStyle(CinemaDetailTone.ink.opacity(0.48))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(CinemaDetailTone.ink.opacity(0.035))
    }

    func entryMeta(_ entry: CinemaEntry) -> String {
        var parts: [String] = [entry.kind == .tv ? "剧集" : "电影"]
        if let year = entry.year { parts.append(String(year)) }
        if let genres = entry.genres, !genres.isEmpty {
            parts.append(genres.prefix(3).joined(separator: " / "))
        }
        return parts.joined(separator: " · ")
    }

    func voteText(_ count: Int) -> String {
        if count >= 10000 { return String(format: "%.1f 万", Double(count) / 10000) }
        return "\(count)"
    }

    var ownedBadge: some View {
        Text("在库")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(LumaBrand.amber)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.62)))
            .padding(6)
    }

    /// 作品海报：宽度由网格列宽决定，高度按 2:3 海报比例跟随，窗口变化时不变形。
    func poster(url: String?, photo: PhotoItem?) -> some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                ZStack {
                    if let url {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else if let photo {
                        PhotoThumbnailView(photo: photo, purpose: .cover(240))
                    } else {
                        Rectangle().fill(CinemaDetailTone.ink.opacity(0.06))
                        Image(systemName: "film")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(CinemaDetailTone.ink.opacity(0.10), lineWidth: 0.6)
            }
    }

    func emptyHint(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    func play(_ entry: CinemaEntry) {
        onPlay(entry)
    }

    func openDetail(_ entry: CinemaEntry) {
        onOpenEntry(entry)
    }
}

/// 搜索面板本身是 sheet：里面点开人物仍用弹窗承载同一套人物页。
struct CinemaPersonSheet: View {
    let member: CinemaCastMember
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CinemaPersonDetailView(
            member: member,
            onOpenEntry: { entry in
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onOpenEntry(entry) }
            },
            onPlay: { entry in
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.openCinema(entry) }
            }
        )
        .frame(width: min(1220, cinemaDetailWindowSize.width),
               height: min(880, cinemaDetailWindowSize.height))
        .preferredColorScheme(.dark)
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(14)
            .keyboardShortcut(.cancelAction)
        }
    }
}
