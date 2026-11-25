import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 网络影院的演职员页：版式与影院里的演员页一致 ——
/// 大头像档案卡 + 全部作品网格；作品来自 TMDB，
/// 点一部作品直接回到网络影院按片名搜索，两个模块在这里打通。
struct NetworkCinemaPersonView: View {
    let member: CinemaCastMember
    let onBack: () -> Void

    @EnvironmentObject private var store: LibraryStore

    @State private var profile: CinemaPersonProfile?
    @State private var loading = true
    @State private var bioExpanded = false
    @State private var hoveredKey: String?
    @State private var hoverHeight: CGFloat = 300
    @State private var creditDetails: [String: CinemaDetails] = [:]
    @State private var detailLoading: Set<String> = []

    private var credits: [CinemaPersonCredit] {
        (profile?.credits ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    var body: some View {
        GeometryReader { proxy in
            let horizontal: CGFloat = 24
            let width = max(320, proxy.size.width - horizontal * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    profileCard
                    worksSection(width: width)
                }
                .padding(.horizontal, horizontal)
                .padding(.top, 58)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .overlayPreferenceValue(CinemaWorkAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let key = hoveredKey, let anchor = anchors[key] {
                    let rect = proxy[anchor]
                    let margin: CGFloat = 12
                    let gap: CGFloat = 14
                    let width = min(340, max(240, proxy.size.width - margin * 2))
                    let onRight = rect.maxX + gap + width + margin <= proxy.size.width
                    let rawX = onRight ? rect.maxX + gap : rect.minX - gap - width
                    let x = min(max(margin, rawX), max(margin, proxy.size.width - width - margin))
                    let y = min(max(margin, rect.minY),
                                max(margin, proxy.size.height - hoverHeight - margin))
                    hoverCard(for: key)
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { hoverHeight = geo.size.height }
                                    .onChange(of: geo.size.height) { _, value in
                                        hoverHeight = value
                                    }
                            }
                        }
                        .offset(x: x, y: y)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: hoveredKey)
        .background(LumaAmbientBackground(intensity: 0.55))
        .overlay(alignment: .topLeading) {
            backButton
        }
        .task {
            if member.tmdbID != nil {
                profile = await store.cinemaPersonProfile(for: member)
            }
            loading = false
        }
    }

    private var backButton: some View {
        Button {
            onBack()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7)
                }
        }
        .buttonStyle(.plain)
        .padding(.top, 18)
        .padding(.leading, 22)
        .help("返回影片详情")
    }

    // MARK: - 档案卡

    private var profileCard: some View {
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
                .help("用 TA 的名字在网络影院里搜索")

                bioBlock
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .background { plate }
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

    private var plate: some View {
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

    private var avatarColumn: some View {
        VStack(spacing: 12) {
            ZStack {
                if let url = profile?.profileURL ?? member.profileURL, !url.isEmpty {
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
                Text("全部 \(credits.isEmpty ? "—" : "\(credits.count)") 部")
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

    private var chipRow: some View {
        HStack(spacing: 7) {
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
    private var bioBlock: some View {
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
            Text("没有可用的 TMDB 人物资料；可以先在网络影院按名字搜索。")
                .font(.system(size: 11.5))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.50))
        }
    }

    private var departmentText: String {
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

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(CinemaDetailTone.ink.opacity(0.62))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(CinemaDetailTone.ink.opacity(0.06)))
            .overlay {
                Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
            }
    }

    // MARK: - 作品

    private func worksSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("全部作品")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                Text("\(credits.count) 部")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                Spacer(minLength: 0)
                if loading {
                    ProgressView().controlSize(.mini)
                }
            }

            if loading {
                ProgressView("正在读取 TMDB 作品…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if profile == nil {
                emptyHint("没有可用的 TMDB 人物资料",
                          detail: "这部影片的演职员还没匹配到 TMDB；可以先用 TA 的名字在网络影院搜索。")
            } else if credits.isEmpty {
                emptyHint("TMDB 没有收录这位的作品", detail: "可以试试按片名搜索。")
            } else {
                LazyVGrid(columns: workColumns(width: width),
                          alignment: .leading, spacing: 18) {
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

    private func workColumns(width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 16
        let count = max(2, GridLayout.columns(contentWidth: max(1, width),
                                              targetSize: 190,
                                              spacing: spacing))
        return Array(repeating: GridItem(.flexible(minimum: 150), spacing: spacing), count: count)
    }

    private func creditTile(_ credit: CinemaPersonCredit) -> some View {
        Button {
            store.searchOnlineCinema(credit.title)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if let poster = credit.posterURL, !poster.isEmpty {
                            CinemaArtwork(urlString: poster, contentMode: .fill)
                        } else {
                            LinearGradient(colors: [CinemaDetailTone.ink.opacity(0.10),
                                                    CinemaDetailTone.ink.opacity(0.04)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                                .overlay {
                                    Image(systemName: "film")
                                        .font(.system(size: 20, weight: .light))
                                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.35))
                                }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
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
            .opacity(hoveredKey == credit.id ? 1 : 0.62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredKey = credit.id
                Task { await loadDetails(credit) }
            } else if hoveredKey == credit.id {
                hoveredKey = nil
            }
        }
        .animation(.easeOut(duration: 0.16), value: hoveredKey)
        .help("在网络影院搜索《\(credit.title)》")
        .contextMenu {
            Button("在网络影院搜索") { store.searchOnlineCinema(credit.title) }
            Button("在 TMDB 打开") {
                let path = credit.isTV ? "tv" : "movie"
                if let url = URL(string: "https://www.themoviedb.org/\(path)/\(credit.tmdbID)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func subtitle(for credit: CinemaPersonCredit) -> String {
        var parts: [String] = [credit.isTV ? "剧集" : "电影"]
        if let year = credit.year { parts.append(String(year)) }
        if let job = credit.job, !job.isEmpty {
            parts.append(job)
        } else if let character = credit.character, !character.isEmpty {
            parts.append(character)
        }
        return parts.joined(separator: " · ")
    }

    private func loadDetails(_ credit: CinemaPersonCredit) async {
        guard creditDetails[credit.id] == nil, !detailLoading.contains(credit.id) else { return }
        detailLoading.insert(credit.id)
        if let details = await store.cinemaCreditDetails(for: credit) {
            creditDetails[credit.id] = details
        }
        detailLoading.remove(credit.id)
    }

    @ViewBuilder
    private func emptyHint(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.35))
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.72))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.48))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - 悬停档案

    private func hoverCard(for key: String) -> some View {
        let credit = credits.first { $0.id == key }
        let details = creditDetails[key]
        let role = credit?.character.flatMap { $0.isEmpty ? nil : $0 } ?? credit?.job
        let overview = details?.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let poster = credit?.posterURL, !poster.isEmpty {
                        CinemaArtwork(urlString: poster, contentMode: .fill)
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

                VStack(alignment: .leading, spacing: 7) {
                    Text(credit?.title ?? "")
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

                    if let credit {
                        Text(metaText(credit, details: details))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                            .lineLimit(2)
                    }

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

                    HStack(spacing: 4) {
                        Circle()
                            .fill(LumaBrand.amber)
                            .frame(width: 4, height: 4)
                        Text("可在网络影院搜索")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(LumaBrand.amber)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(LumaBrand.amber.opacity(0.14), in: Capsule())

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
            } else if detailLoading.contains(key) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在读取简介…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.5))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            HStack(spacing: 5) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 9, weight: .semibold))
                Text("点击在网络影院搜索")
                    .font(.system(size: 10))
                Spacer(minLength: 0)
            }
            .foregroundStyle(CinemaDetailTone.ink.opacity(0.48))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(CinemaDetailTone.ink.opacity(0.035))
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

    private func metaText(_ credit: CinemaPersonCredit, details: CinemaDetails?) -> String {
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

    private func voteText(_ count: Int) -> String {
        if count >= 10_000 { return String(format: "%.1f 万", Double(count) / 10_000) }
        return "\(count)"
    }
}
