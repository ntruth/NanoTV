import AppKit
import SwiftUI

/// 内置女优 / 模特 / 机构资料库，以现代美术馆 / 大型展会的方式陈列：
/// 一条主视觉、一条展区导览、一排轻量入口，然后把空间留给展商卡本身。
/// 数据全部来自 `Resources/Catalog/catalog.sqlite`，随 App 离线可查。
struct CatalogTalentLibraryView: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel

    @State private var mode: Mode = .people
    @State private var query = ""
    @State private var region: String?
    @State private var kind: KindFilter = .all
    @State private var sort: SortOrder = .works
    @State private var onlyFollowed = false
    @State private var visibleCount = 240
    @State private var target: Target?
    @FocusState private var searchFocused: Bool

    private enum Mode: String, CaseIterable, Identifiable {
        case people = "人物"
        case studios = "机构"
        var id: String { rawValue }
        var title: String { rawValue }

        var en: String {
            switch self {
            case .people: return "EXHIBITORS"
            case .studios: return "BOOTHS"
            }
        }

        var symbol: String {
            switch self {
            case .people: return "person.2.fill"
            case .studios: return "building.2.fill"
            }
        }
    }

    private enum KindFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case actress = "女优"
        case model = "模特"
        var id: String { rawValue }
        var title: String { rawValue }
    }

    private enum SortOrder: String, CaseIterable, Identifiable {
        case works = "收录数"
        case name = "名字"
        case birth = "出生"
        var id: String { rawValue }
        var title: String { rawValue }
    }

    private struct Target: Identifiable {
        var name: String
        var role: String
        var id: String { "\(role)|\(name)" }
    }

    private struct RegionOption: Identifiable {
        var id: String
        var title: String
        var index: Int
    }

    private static let regions: [RegionOption] = [
        RegionOption(id: "japan", title: "日本", index: 1),
        RegionOption(id: "china", title: "中国大陆", index: 2),
        RegionOption(id: "korea", title: "韩国", index: 3),
        RegionOption(id: "taiwan", title: "台湾", index: 4),
        RegionOption(id: "hongkong", title: "香港", index: 5),
        RegionOption(id: "western", title: "欧美", index: 6),
    ]
    private static let pageSize = 240

    // MARK: - 静态索引

    /// SQLite 已按收录数倒序返回，直接复用，省掉每次进页面的一次大排序。
    private static let peopleByWorks = CatalogNameDictionary.allActresses
    private static let peopleByName = peopleByWorks.sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    private static let peopleByBirth = peopleByWorks.sorted {
        let left = $0.birthDate ?? "9999-99-99"
        let right = $1.birthDate ?? "9999-99-99"
        if left != right { return left < right }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    private static let studiosByWorks = CatalogNameDictionary.allStudios
    private static let studiosByName = studiosByWorks.sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }

    private static let peopleRegionCounts = Dictionary(grouping: peopleByWorks,
                                                       by: \.region).mapValues(\.count)
    private static let studioRegionCounts = Dictionary(grouping: studiosByWorks,
                                                       by: \.region).mapValues(\.count)

    /// 各展区门头用的代表肖像：优先头部、有头像的人。
    private static let regionPosters: [String: [CatalogActressRecord]] = {
        var result: [String: [CatalogActressRecord]] = [:]
        for region in regions.map(\.id) {
            result[region] = Array(peopleByWorks.lazy
                .filter { $0.region == region && !($0.avatarBase64 ?? "").isEmpty }
                .prefix(3))
        }
        return result
    }()

    /// 主展厅背景的人物拼贴。
    private static let hallMosaic: [CatalogActressRecord] = Array(
        peopleByWorks.lazy.filter { !($0.avatarBase64 ?? "").isEmpty }.prefix(6))

    /// 已归档的头像与生辰记录：告诉用户这些资料是真的存在本机。
    private static let portraitCount = peopleByWorks.reduce(0) {
        $0 + (($1.avatarBase64 ?? "").isEmpty ? 0 : 1)
    }
    private static let birthdayCount = peopleByWorks.reduce(0) {
        $0 + ((($1.birthDate ?? "").count >= 10) ? 1 : 0)
    }

    private static let actressSearchKeys: [Int64: [String]] = Dictionary(
        uniqueKeysWithValues: CatalogNameDictionary.allActresses.map { record in
            (record.id, record.allNames.map(CatalogNameParser.normalize))
        }
    )
    private static let studioSearchKeys: [Int64: [String]] = Dictionary(
        uniqueKeysWithValues: CatalogNameDictionary.allStudios.map { record in
            (record.id, record.allNames.map(CatalogNameParser.normalize))
        }
    )

    private static let birthdayLabel: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        return formatter.string(from: Date())
    }()

    private static let todayBirthdays: [CatalogActressRecord] = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd"
        let today = formatter.string(from: Date())
        return peopleByWorks
            .filter { record in
                guard let birth = record.birthDate, birth.count >= 10 else { return false }
                return String(birth.suffix(5)) == today
            }
            .sorted { ($0.workCount ?? 0) > ($1.workCount ?? 0) }
    }()

    /// 今日展品：按日期从带头像的头部人物里轮换，天天不一样。
    private static let featured: [CatalogActressRecord] = {
        let pool = peopleByWorks.filter { ($0.avatarBase64 ?? "").isEmpty == false }
        guard !pool.isEmpty else { return [] }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        var picks: [CatalogActressRecord] = []
        var index = (day * 13) % pool.count
        while picks.count < 3 && picks.count < pool.count {
            picks.append(pool[index])
            index = (index + 97) % pool.count
        }
        return picks
    }()

    // MARK: - Body

    var body: some View {
        ZStack {
            LumaAmbientBackground(intensity: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    halls
                    if showsBirthdayStrip { birthdayStrip }
                    catalogHeader
                    toolbar
                    results
                }
                .padding(.horizontal, 26)
                .padding(.top, 16)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.automatic)
        }
        .overlay {
            if let target {
                CatalogPersonProfileView(name: target.name,
                                         role: target.role,
                                         sourceID: catalog.enabledResourceSources.first?.id
                                            ?? catalog.resourceSources.first?.id ?? UUID(),
                                         onClose: {
                                             withAnimation(.easeOut(duration: 0.18)) {
                                                 self.target = nil
                                             }
                                         },
                                         backTitle: "返回资料库",
                                         loadsWorks: false)
                    .environmentObject(catalog)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: target?.id)
        .onChange(of: filterKey) { _, _ in
            if visibleCount != Self.pageSize { visibleCount = Self.pageSize }
        }
        .onChange(of: followFilterCount) { _, count in
            if count == 0 { onlyFollowed = false }
        }
    }

    // MARK: - 主视觉

    private var hero: some View {
        ZStack {
            heroBackground

            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 8) {
                        Text("THE LUMA COLLECTION")
                            .font(.system(size: 8.5, weight: .semibold))
                            .tracking(2.6)
                            .foregroundStyle(.white.opacity(0.45))
                        Rectangle()
                            .fill(.white.opacity(0.16))
                            .frame(width: 1, height: 10)
                        Text("馆藏")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("2026")
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.accentColor.opacity(0.9))
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Self.peopleByWorks.count.formatted())
                            .font(.system(size: 54, weight: .light, design: .serif))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                        VStack(alignment: .leading, spacing: 3) {
                            Text("位人物档案")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.78))
                            Text("\(Self.studiosByWorks.count) 个机构全宗 · \(Self.regions.count) 个地区")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .padding(.bottom, 5)
                    }

                    Text("头像 \(Self.portraitCount.formatted()) 份 · 生辰 \(Self.birthdayCount.formatted()) 条 · 全部离线存档")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))

                    HStack(spacing: 14) {
                        heroLink("我的关注", value: catalog.followedPeople.count,
                                 badge: catalog.newFollowCount) {
                            catalog.setHubTab(.following)
                        }
                        separatorDot
                        heroLink("今日更新", value: todayCalendarCount) {
                            catalog.setHubTab(.calendar)
                        }
                        separatorDot
                        heroLink("最近浏览", value: catalog.resourceContinueWatching.count) {
                            catalog.setHubTab(.history)
                        }
                    }
                    .padding(.top, 2)
                }
                .layoutPriority(1)

                Spacer(minLength: 10)
                posterStack
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .frame(minHeight: 252)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 10)
    }

    private var heroBackground: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.095, green: 0.105, blue: 0.135),
                                    Color(red: 0.035, green: 0.04, blue: 0.055)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            RadialGradient(colors: [Color.accentColor.opacity(0.32), .clear],
                           center: .topLeading, startRadius: 10, endRadius: 430)

            // 极细的展览网格：只作为空间背景，不抢人物。
            Canvas { context, size in
                for x in stride(from: 0.0, to: size.width, by: 56) {
                    var path = Path()
                    path.addRect(CGRect(x: x, y: 0, width: 0.6, height: size.height))
                    context.fill(path, with: .color(.white.opacity(0.018)))
                }
                for y in stride(from: 0.0, to: size.height, by: 56) {
                    var path = Path()
                    path.addRect(CGRect(x: 0, y: y, width: size.width, height: 0.6))
                    context.fill(path, with: .color(.white.opacity(0.014)))
                }
            }

            LinearGradient(colors: [.clear, .black.opacity(0.35)],
                           startPoint: .center, endPoint: .bottom)
        }
        .overlay {
            // 顶部射灯：一条从天花板打到海报墙上的柔光。
            GeometryReader { proxy in
                Path { path in
                    path.move(to: CGPoint(x: proxy.size.width * 0.74, y: 0))
                    path.addLine(to: CGPoint(x: proxy.size.width * 0.86, y: 0))
                    path.addLine(to: CGPoint(x: proxy.size.width * 0.99, y: proxy.size.height))
                    path.addLine(to: CGPoint(x: proxy.size.width * 0.64, y: proxy.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [.white.opacity(0.07), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .blur(radius: 16)
            }
        }
    }

    private var separatorDot: some View {
        Circle()
            .fill(.white.opacity(0.18))
            .frame(width: 3, height: 3)
    }

    private func heroLink(_ title: String, value: Int, badge: Int = 0,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                Text("\(value)")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if badge > 0 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// 三张叠放的展商海报：今日推荐，点开即档案。
    private var posterStack: some View {
        ZStack(alignment: .bottom) {
            Ellipse()
                .fill(Color.white.opacity(0.07))
                .frame(width: 300, height: 26)
                .blur(radius: 14)
                .offset(y: 12)

            if Self.featured.count > 2 {
                expoPoster(Self.featured[2], width: 176, height: 220)
                    .rotationEffect(.degrees(6.5))
                    .offset(x: 112, y: 8)
                    .opacity(0.3)
            }
            if Self.featured.count > 1 {
                expoPoster(Self.featured[1], width: 184, height: 230)
                    .rotationEffect(.degrees(3.5))
                    .offset(x: 58, y: 4)
                    .opacity(0.6)
            }
            if let first = Self.featured.first {
                expoPoster(first, width: 194, height: 244)
                    .rotationEffect(.degrees(-2))
            }
        }
        .frame(width: 348, height: 254, alignment: .bottom)
    }

    private func expoPoster(_ person: CatalogActressRecord, width: CGFloat,
                            height: CGFloat) -> some View {
        let tint = ExpoStyle.regionTint(person.region)
        let code = ExpoStyle.regionCode(person.region)
        return Button {
            target = Target(name: person.name, role: person.isModel ? "模特" : "女优")
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    LinearGradient(colors: [tint.opacity(0.85),
                                            Color(red: 0.07, green: 0.08, blue: 0.11)],
                                   startPoint: .topLeading, endPoint: .bottom)
                    Text(code)
                        .font(.system(size: 72, weight: .bold, design: .serif))
                        .foregroundStyle(.white.opacity(0.10))
                        .offset(x: 24, y: 18)
                    CatalogAvatarView(name: person.name,
                                      base64: person.avatarBase64,
                                      size: 76,
                                      ringColor: .white.opacity(0.5))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                }
                .frame(width: width, height: height - 54)
                .clipped()

                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(person.regionTitle) · \(person.workCount ?? 0) 部")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(width: width, height: 54, alignment: .leading)
                .background(Color.white.opacity(0.05))
            }
            .frame(width: width, height: height)
            .background(Color(red: 0.09, green: 0.10, blue: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
        }
        .buttonStyle(.plain)
        .help("调阅 \(person.name) 的档案")
    }

    // MARK: - 展馆导览

    private var halls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ExpoSectionLabel(title: "展馆导览",
                             en: "HALLS",
                             detail: mode == .people ? "进入地区展台" : "按机构所在地区进入展台")

            HStack(alignment: .top, spacing: 12) {
                mainHallCard
                    .frame(width: 336, height: 212)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    ForEach(Self.regions) { item in
                        ExpoHallCard(title: item.title,
                                     index: item.index,
                                     count: regionCount(for: item.id),
                                     tint: ExpoStyle.regionTint(item.id),
                                     active: region == item.id,
                                     poster: Self.regionPosters[item.id]?.first) {
                            withAnimation(.easeOut(duration: 0.16)) { region = item.id }
                        }
                        .frame(height: 100)
                    }
                }
            }
        }
    }

    /// 主展厅：六张头像拼贴成门头，下面是总馆藏。
    private var mainHallCard: some View {
        let active = region == nil
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { region = nil }
        } label: {
            ZStack(alignment: .bottomLeading) {
                mosaicBackdrop

                LinearGradient(colors: [.black.opacity(0.28), .black.opacity(0.84)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("MAIN HALL")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer(minLength: 0)
                        Text("01")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                    }

                    Spacer(minLength: 0)

                    Text(Self.peopleByWorks.count.formatted())
                        .font(.system(size: 30, weight: .light, design: .serif))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    Text("全部馆藏")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                    Text("\(Self.studiosByWorks.count) 个机构全宗 · \(Self.regions.count) 个地区")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))

                    HStack(spacing: 4) {
                        Text("进入主展厅")
                            .font(.system(size: 9.5, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.08, green: 0.09, blue: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(active ? Color.accentColor.opacity(0.7) : .white.opacity(0.1),
                                  lineWidth: active ? 1.2 : 0.7)
            }
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("查看全部馆藏")
    }

    private var mosaicBackdrop: some View {
        let mosaic = Array(Self.hallMosaic.prefix(6))
        return VStack(spacing: 5) {
            HStack(spacing: 5) {
                ForEach(Array(mosaic.prefix(3))) { person in
                    CatalogAvatarView(name: person.name,
                                      base64: person.avatarBase64,
                                      size: 96,
                                      ringColor: .white.opacity(0.22))
                }
            }
            HStack(spacing: 5) {
                ForEach(Array(mosaic.dropFirst(3))) { person in
                    CatalogAvatarView(name: person.name,
                                      base64: person.avatarBase64,
                                      size: 96,
                                      ringColor: .white.opacity(0.22))
                }
            }
        }
        .blur(radius: 5)
        .opacity(0.75)
        .scaleEffect(1.08)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: - 生日一栏

    private var showsBirthdayStrip: Bool {
        mode == .people
            && !onlyFollowed
            && region == nil
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !Self.todayBirthdays.isEmpty
    }

    private var birthdayStrip: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("今日寿星")
                        .font(.system(size: 11, weight: .semibold))
                    Text(Self.birthdayLabel)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.todayBirthdays.prefix(12)) { record in
                        Button {
                            target = Target(name: record.name,
                                            role: record.isModel ? "模特" : "女优")
                        } label: {
                            HStack(spacing: 6) {
                                CatalogAvatarView(name: record.name,
                                                  base64: record.avatarBase64,
                                                  size: 24,
                                                  ringColor: .primary.opacity(0.12))
                                Text(record.name)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(Color.primary.opacity(0.045),
                                        in: Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("调阅 \(record.name) 的档案")
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollClipDisabled()

            Spacer(minLength: 0)

            Text("\(Self.todayBirthdays.count) 位")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(ExpoStyle.card,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ExpoStyle.hairline, lineWidth: 0.7)
        }
    }

    // MARK: - 目录头与工具条

    private var catalogHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(mode == .people ? "人物档案" : "机构全宗")
                .font(.system(size: 14, weight: .semibold))
            Text(mode.en)
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(.tertiary)
            Text("\(resultCount.formatted()) \(resultUnit)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 10)
            modeTabs
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 2) {
            modeTab(.people, count: Self.peopleByWorks.count)
            modeTab(.studios, count: Self.studiosByWorks.count)
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(ExpoStyle.hairline, lineWidth: 0.6)
        }
    }

    private func modeTab(_ item: Mode, count: Int) -> some View {
        let active = mode == item
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                mode = item
                if item == .studios && sort == .birth { sort = .works }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: item.symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(count.formatted())
                    .font(.system(size: 9, design: .monospaced))
                    .monospacedDigit()
                    .opacity(0.62)
            }
            .foregroundStyle(active ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background {
                if active {
                    Capsule(style: .continuous).fill(Color.primary)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            searchField
            if mode == .people { kindPicker }
            if followFilterCount > 0 { followToggle }
            sortMenu
            Spacer(minLength: 0)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(searchFocused ? Color.accentColor : Color.secondary)
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text(mode == .people ? "搜索姓名 / 别名" : "搜索机构 / 别名")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($searchFocused)
            }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .frame(maxWidth: 344)
        .background(ExpoStyle.card,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.5) : ExpoStyle.hairline,
                              lineWidth: searchFocused ? 1 : 0.7)
        }
    }

    private var kindPicker: some View {
        HStack(spacing: 2) {
            ForEach(KindFilter.allCases) { item in
                let active = kind == item
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { kind = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(active ? Color(nsColor: .windowBackgroundColor)
                                                : Color.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background {
                            if active {
                                Capsule(style: .continuous).fill(Color.primary)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(ExpoStyle.hairline, lineWidth: 0.6)
        }
    }

    private var followToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) { onlyFollowed.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: onlyFollowed ? "star.fill" : "star")
                    .font(.system(size: 9, weight: .semibold))
                Text("已关注 \(followFilterCount)")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(onlyFollowed ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(onlyFollowed ? Color.accentColor.opacity(0.12) : ExpoStyle.card,
                        in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(onlyFollowed ? Color.accentColor.opacity(0.3) : ExpoStyle.hairline,
                                  lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
        .help("只看已经关注的人 / 机构")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(availableSorts) { order in
                Button {
                    sort = order
                } label: {
                    if sort == order {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(sort.title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(ExpoStyle.card, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(ExpoStyle.hairline, lineWidth: 0.6)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var availableSorts: [SortOrder] {
        mode == .people ? SortOrder.allCases : [.works, .name]
    }

    // MARK: - 结果

    @ViewBuilder
    private var results: some View {
        if mode == .people {
            let list = people
            let followed = followedPersonKeys
            if list.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: resultColumns, alignment: .leading, spacing: 14) {
                    ForEach(Array(list.prefix(visibleCount))) { record in
                        ExpoPersonCard(record: record,
                                       following: followed.contains(record.name),
                                       onOpen: {
                                           target = Target(name: record.name,
                                                           role: record.isModel ? "模特" : "女优")
                                       },
                                       onToggleFollow: {
                                           catalog.toggleFollowPerson(
                                              name: record.name,
                                              role: record.isModel ? "模特" : "女优",
                                              sourceID: catalog.enabledResourceSources.first?.id
                                                 ?? catalog.resourceSources.first?.id ?? UUID())
                                       },
                                       onSearchWorks: {
                                           searchWorks(for: record.name)
                                       })
                    }
                }
                if list.count > visibleCount {
                    loadMoreTag(remaining: list.count - visibleCount)
                }
            }
        } else {
            let list = studios
            let followed = followedStudioKeys
            if list.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: resultColumns, alignment: .leading, spacing: 14) {
                    ForEach(Array(list.prefix(visibleCount))) { record in
                        ExpoStudioCard(record: record,
                                       following: followed.contains(record.name),
                                       onOpen: {
                                           target = Target(name: record.name, role: "片商")
                                       },
                                       onToggleFollow: {
                                           catalog.toggleFollowPerson(
                                              name: record.name,
                                              role: "片商",
                                              sourceID: catalog.enabledResourceSources.first?.id
                                                 ?? catalog.resourceSources.first?.id ?? UUID())
                                       },
                                       onSearchWorks: {
                                           searchWorks(for: record.name)
                                       })
                    }
                }
                if list.count > visibleCount {
                    loadMoreTag(remaining: list.count - visibleCount)
                }
            }
        }
    }

    private var resultColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 248, maximum: 324), spacing: 14)]
    }

    private func loadMoreTag(remaining: Int) -> some View {
        HStack {
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    visibleCount += Self.pageSize
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("加载更多")
                        .font(.system(size: 11, weight: .semibold))
                    Text("剩余 \(remaining.formatted()) \(resultUnit)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Color.accentColor.opacity(0.09), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.7)
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有匹配的展项")
                .font(.system(size: 14, weight: .semibold))
            Text(emptyDetail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("清空筛选") {
                    query = ""
                    region = nil
                    kind = .all
                    sort = .works
                    onlyFollowed = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Color.primary, in: Capsule(style: .continuous))

                Button("随便看一位") {
                    openRandomPerson()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Color.accentColor.opacity(0.1), in: Capsule(style: .continuous))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(ExpoStyle.card,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(ExpoStyle.hairline, lineWidth: 0.7)
        }
    }

    private var emptyDetail: String {
        if onlyFollowed { return "关注列表里没有匹配的展项。" }
        return "换个关键字、地区或类型，或直接随机看一位。"
    }

    // MARK: - 筛选结果

    private var filterKey: String {
        "\(mode.rawValue)|\(query)|\(region ?? "")|\(kind.rawValue)|\(sort.rawValue)|\(onlyFollowed)"
    }

    private var followedPerformers: [CatalogFollowedPerson] {
        catalog.followedPeople.filter { $0.role != "片商" }
    }

    private var followedStudios: [CatalogFollowedPerson] {
        catalog.followedPeople.filter { $0.role == "片商" }
    }

    private var followedPersonKeys: Set<String> {
        Set(followedPerformers.map(\.name))
    }

    private var followedStudioKeys: Set<String> {
        Set(followedStudios.map(\.name))
    }

    private var followFilterCount: Int {
        mode == .people ? followedPerformers.count : followedStudios.count
    }

    private var resultCount: Int {
        mode == .people ? people.count : studios.count
    }

    private var resultUnit: String {
        mode == .people ? "位" : "个"
    }

    private func regionCount(for id: String) -> Int {
        mode == .people ? (Self.peopleRegionCounts[id] ?? 0)
                        : (Self.studioRegionCounts[id] ?? 0)
    }

    private var people: [CatalogActressRecord] {
        var list: [CatalogActressRecord]
        switch sort {
        case .works: list = Self.peopleByWorks
        case .name: list = Self.peopleByName
        case .birth: list = Self.peopleByBirth
        }
        if let region {
            list = list.filter { $0.region == region }
        }
        switch kind {
        case .all: break
        case .actress: list = list.filter { !$0.isModel }
        case .model: list = list.filter { $0.isModel }
        }
        if onlyFollowed {
            let names = followedPersonKeys
            list = list.filter { names.contains($0.name) }
        }
        let keyword = CatalogNameParser.normalize(query)
        if !keyword.isEmpty {
            list = list.filter { record in
                Self.actressSearchKeys[record.id]?.contains { $0.contains(keyword) } == true
            }
        }
        return list
    }

    private var studios: [CatalogStudioRecord] {
        var list = sort == .name ? Self.studiosByName : Self.studiosByWorks
        if let region {
            list = list.filter { $0.region == region }
        }
        if onlyFollowed {
            let names = followedStudioKeys
            list = list.filter { names.contains($0.name) }
        }
        let keyword = CatalogNameParser.normalize(query)
        if !keyword.isEmpty {
            list = list.filter { record in
                Self.studioSearchKeys[record.id]?.contains { $0.contains(keyword) } == true
            }
        }
        return list
    }

    private var todayCalendarCount: Int {
        let calendar = Calendar.current
        let ids = catalog.resourceSourceIDs
        return catalog.calendarItems
            .filter { ids.contains($0.sourceID) && calendar.isDateInToday($0.firstSeen) }
            .count
    }

    // MARK: - 动作

    private func openRandomPerson() {
        guard let pick = Self.peopleByWorks.randomElement() else { return }
        target = Target(name: pick.name, role: pick.isModel ? "模特" : "女优")
    }

    /// 与资源页打通：带上名字跳到「资源」，由跨源搜索直接找作品。
    private func searchWorks(for name: String) {
        catalog.globalQuery = name
        catalog.setHubTab(.browse)
    }
}

// MARK: - 区块标题

private struct ExpoSectionLabel: View {
    let title: String
    let en: String
    var detail: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(en)
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(.tertiary)
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Rectangle()
                .fill(ExpoStyle.hairline)
                .frame(height: 1)
        }
    }
}

// MARK: - 展馆门头卡

private struct ExpoHallCard: View {
    let title: String
    let index: Int
    let count: Int
    let tint: Color
    let active: Bool
    let poster: CatalogActressRecord?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                if let poster {
                    CatalogAvatarView(name: poster.name,
                                      base64: poster.avatarBase64,
                                      size: 170,
                                      ringColor: .clear)
                        .blur(radius: 16)
                        .opacity(0.55)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .offset(x: 28)
                }

                LinearGradient(colors: [Color.black.opacity(0.82),
                                        tint.opacity(0.38),
                                        Color.black.opacity(0.22)],
                               startPoint: .leading, endPoint: .trailing)

                Rectangle()
                    .fill(tint)
                    .frame(width: 3)
                    .opacity(active ? 1 : 0.55)

                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("HALL \(String(format: "%02d", index))")
                            .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(.white.opacity(0.45))
                        Text(title)
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 3) {
                            Text(count.formatted())
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.9))
                            Text("位")
                                .font(.system(size: 8))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(hovering || active ? 0.9 : 0.25))
                        .padding(.bottom, 2)
                }
                .padding(.leading, 12)
                .padding(.trailing, 11)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.08, green: 0.09, blue: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(active ? tint.opacity(0.85)
                                         : (hovering ? tint.opacity(0.4) : .white.opacity(0.08)),
                                  lineWidth: active ? 1.2 : 0.7)
            }
            .shadow(color: .black.opacity(hovering ? 0.3 : 0.2), radius: 8, y: 4)
            .scaleEffect(hovering ? 1.01 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovering = inside }
        }
        .help("只看\(title)（\(count)）")
    }
}

// MARK: - 人物展商卡

private struct ExpoPersonCard: View {
    let record: CatalogActressRecord
    let following: Bool
    let onOpen: () -> Void
    let onToggleFollow: () -> Void
    let onSearchWorks: () -> Void

    @State private var hovering = false

    private var tint: Color { ExpoStyle.regionTint(record.region) }
    private var role: String { record.isModel ? "模特" : "女优" }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                poster

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(record.name)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if record.isModel {
                            Text("模特")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor.opacity(0.1),
                                            in: Capsule(style: .continuous))
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 5) {
                        Circle().fill(tint).frame(width: 4, height: 4)
                        Text(record.regionTitle)
                        Text("·")
                        Text(role)
                        if let cup = record.cup, !cup.isEmpty {
                            Text("·")
                            Text("\(cup) 罩杯")
                        }
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)

                    Text(stats)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !record.tags.isEmpty {
                        Text(record.tags.prefix(4).joined(separator: " · "))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 5) {
                        Text(worksLine)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                        HStack(spacing: 3) {
                            Text("调阅")
                                .font(.system(size: 9.5, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 7.5, weight: .bold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .opacity(hovering ? 1 : 0.4)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? ExpoStyle.cardHover : ExpoStyle.card,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.38) : ExpoStyle.hairline,
                                  lineWidth: hovering ? 1 : 0.7)
            }
            .shadow(color: .black.opacity(hovering ? 0.14 : 0), radius: 12, y: 5)
            .scaleEffect(hovering ? 1.01 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: onToggleFollow) {
                Image(systemName: following ? "star.fill" : "star")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(following ? Color.orange
                                               : Color.white.opacity(hovering ? 0.95 : 0.6))
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.32), in: Circle())
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(11)
            .help(following ? "取消关注" : "关注，有新作品时在关注页提醒")
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovering = inside }
        }
        .contextMenu {
            Button(following ? "取消关注" : "关注") { onToggleFollow() }
            Button("在资源中搜索作品") { onSearchWorks() }
        }
        .help("调阅 \(record.name) 的档案")
    }

    /// 展位海报：模糊肖像铺底 + 清晰头像居中，像展馆里的灯箱。
    private var poster: some View {
        ZStack {
            CatalogAvatarView(name: record.name,
                              base64: record.avatarBase64,
                              size: 240,
                              ringColor: .clear)
                .blur(radius: 22)
                .opacity(0.6)
                .offset(y: 10)

            LinearGradient(colors: [tint.opacity(0.55), Color.black.opacity(0.9)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            Text(ExpoStyle.regionCode(record.region))
                .font(.system(size: 64, weight: .bold, design: .serif))
                .foregroundStyle(.white.opacity(0.09))
                .offset(x: 56, y: 8)

            CatalogAvatarView(name: record.name,
                              base64: record.avatarBase64,
                              size: 56,
                              ringColor: .white.opacity(0.55))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

            VStack {
                HStack {
                    Text("BOOTH \(ExpoStyle.regionCode(record.region))-\(String(format: "%04d", Int(record.id)))")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .frame(height: 118)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(0.8))
                .frame(height: 1.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.7)
        }
        .padding(8)
    }

    private var stats: String {
        var parts: [String] = []
        if let birth = record.birthDate, birth.count >= 4,
           let year = Int(birth.prefix(4)), year > 1900 {
            parts.append(String(year))
        } else if let age = record.age {
            parts.append("\(age) 岁")
        }
        if let height = record.heightCM { parts.append("\(height)cm") }
        return parts.joined(separator: " · ")
    }

    private var worksLine: String {
        guard let works = record.workCount, works > 0 else { return "收录数未记录" }
        let unit = record.isModel ? "套" : "部"
        return "收录 \(works > 999 ? "999+" : "\(works)") \(unit)"
    }
}

// MARK: - 机构展位卡

private struct ExpoStudioCard: View {
    let record: CatalogStudioRecord
    let following: Bool
    let onOpen: () -> Void
    let onToggleFollow: () -> Void
    let onSearchWorks: () -> Void

    @State private var hovering = false

    private var tint: Color { ExpoStyle.kindTint(record.kind) }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                poster

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Circle().fill(tint).frame(width: 4, height: 4)
                        Text(record.regionTitle)
                        Text("·")
                        Text(record.kindTitle)
                        Text("·")
                        Text("收录 \(record.workCount ?? 0) \(record.kind == "photo" ? "套" : "部")")
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)

                    if let summary = record.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !record.aliases.isEmpty {
                        Text(record.aliases.prefix(3).joined(separator: "、"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 5) {
                        if record.website?.isEmpty == false {
                            HStack(spacing: 3) {
                                Image(systemName: "globe")
                                    .font(.system(size: 7.5, weight: .bold))
                                Text("官网")
                                    .font(.system(size: 8.5, weight: .medium))
                            }
                            .foregroundStyle(Color.accentColor)
                        } else {
                            Text("机构档案")
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 3) {
                            Text("调阅")
                                .font(.system(size: 9.5, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 7.5, weight: .bold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .opacity(hovering ? 1 : 0.4)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? ExpoStyle.cardHover : ExpoStyle.card,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.38) : ExpoStyle.hairline,
                                  lineWidth: hovering ? 1 : 0.7)
            }
            .shadow(color: .black.opacity(hovering ? 0.14 : 0), radius: 12, y: 5)
            .scaleEffect(hovering ? 1.01 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: onToggleFollow) {
                Image(systemName: following ? "star.fill" : "star")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(following ? Color.orange
                                               : Color.white.opacity(hovering ? 0.95 : 0.6))
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.32), in: Circle())
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(11)
            .help(following ? "取消关注" : "关注，有新作品时在关注页提醒")
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovering = inside }
        }
        .contextMenu {
            Button(following ? "取消关注" : "关注") { onToggleFollow() }
            if let website = record.website, let url = URL(string: website) {
                Button("打开官网") { NSWorkspace.shared.open(url) }
            }
            Button("在资源中搜索作品") { onSearchWorks() }
        }
        .help("调阅 \(record.name) 的档案")
    }

    /// 机构展位海报：机构首字/图标铺底，清晰的展位牌居中。
    private var poster: some View {
        ZStack {
            CatalogAvatarView(name: record.name,
                              base64: record.avatarBase64,
                              size: 220,
                              ringColor: .clear)
                .blur(radius: 20)
                .opacity(0.55)
                .offset(y: 8)

            LinearGradient(colors: [tint.opacity(0.5), Color.black.opacity(0.9)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            Text(ExpoStyle.kindCode(record.kind))
                .font(.system(size: 60, weight: .bold, design: .serif))
                .foregroundStyle(.white.opacity(0.1))
                .offset(x: 56, y: 6)

            CatalogAvatarView(name: record.name,
                              base64: record.avatarBase64,
                              size: 50,
                              ringColor: .white.opacity(0.5))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

            VStack {
                HStack {
                    Text("BOOTH \(ExpoStyle.kindCode(record.kind))-\(String(format: "%04d", Int(record.id)))")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .frame(height: 104)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(0.8))
                .frame(height: 1.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.7)
        }
        .padding(8)
    }
}

// MARK: - 配色

private enum ExpoStyle {
    static let card = Color.primary.opacity(0.035)
    static let cardHover = Color.primary.opacity(0.065)
    static let hairline = Color.primary.opacity(0.08)

    static func regionTint(_ region: String) -> Color {
        switch region {
        case "japan": return Color(red: 0.92, green: 0.45, blue: 0.48)
        case "china": return Color(red: 0.93, green: 0.66, blue: 0.32)
        case "korea": return Color(red: 0.38, green: 0.68, blue: 0.93)
        case "taiwan": return Color(red: 0.33, green: 0.78, blue: 0.68)
        case "hongkong": return Color(red: 0.74, green: 0.50, blue: 0.92)
        case "western": return Color(red: 0.52, green: 0.60, blue: 1.0)
        default: return Color.accentColor
        }
    }

    static func regionCode(_ region: String) -> String {
        switch region {
        case "japan": return "JP"
        case "china": return "CN"
        case "korea": return "KR"
        case "taiwan": return "TW"
        case "hongkong": return "HK"
        case "western": return "US"
        default: return "XX"
        }
    }

    static func kindTint(_ kind: String) -> Color {
        switch kind {
        case "photo": return Color(red: 0.74, green: 0.50, blue: 0.92)
        case "platform": return Color(red: 0.38, green: 0.68, blue: 0.93)
        default: return Color.accentColor
        }
    }

    static func kindCode(_ kind: String) -> String {
        switch kind {
        case "photo": return "PH"
        case "platform": return "PL"
        default: return "ST"
        }
    }
}
