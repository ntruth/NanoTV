import AppKit
import SwiftUI

/// 「个人收藏」汇总：顶栏切换维度，每一屏只展示该维度的分类卡片，点卡片下钻。
struct FavoritesDigestView: View {
    @EnvironmentObject private var store: LibraryStore
    /// 骨架阶段按年份取到的真实封面（汇总算完后由正式数据接管）。
    @State private var quickCovers: [String: [PhotoItem]] = [:]

    var body: some View {
        Group {
            if let digest = store.favoritesDigest, digest.hasContent {
                dimensionView(digest)
            } else if store.favoritesViewMode == .years, !store.favoritesQuickYearBuckets.isEmpty {
                quickYearsWall
            } else if store.isLoadingFavoritesDigest || store.favoritesDigest == nil {
                skeletonState
            } else {
                emptyState
            }
        }
        .task(id: store.favoritesDigestToken) {
            store.loadFavoritesDigestIfNeeded()
        }
        .animation(.snappy(duration: 0.22), value: store.favoritesViewMode)
    }

    // MARK: - 骨架（占位优先）

    /// 正式汇总要读上万条收藏，先把已有的计数快照画出来：
    /// 年份与数量是准确的，封面与其余维度随汇总到达填入，避免整屏只有转圈。
    @ViewBuilder
    private var skeletonState: some View {
        switch store.favoritesViewMode {
        case .all, .years:
            yearsSkeleton
        case .kinds, .places, .cameras, .people:
            genericSkeleton(store.favoritesViewMode)
        }
    }

    private var yearsSkeleton: some View {
        let buckets = store.favoritesQuickYearBuckets
        let subtitle: String
        if let total = store.favoritesQuickTotal, !buckets.isEmpty {
            subtitle = "\(buckets.count) 个年份 · \(total.formatted()) 项收藏"
        } else {
            subtitle = "正在汇总收藏…"
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(mode: .years, subtitle: subtitle, highlight: nil, covers: [])
                if buckets.isEmpty {
                    DigestYearSkeletonCard(year: nil, count: nil, photos: [],
                                           height: 246, featured: true)
                    skeletonGrid(minimum: 210, maximum: 330, height: 158, spacing: 16)
                } else {
                    if let first = buckets.first {
                        DigestYearSkeletonCard(year: first.year,
                                               count: first.count,
                                               photos: quickCovers[first.year] ?? [],
                                               height: 246,
                                               featured: true)
                    }
                    let rest = Array(buckets.dropFirst())
                    if !rest.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 330),
                                                     spacing: 16)],
                                  alignment: .leading,
                                  spacing: 16) {
                            ForEach(rest, id: \.year) { bucket in
                                DigestYearSkeletonCard(year: bucket.year,
                                                       count: bucket.count,
                                                       photos: quickCovers[bucket.year] ?? [],
                                                       height: 158,
                                                       featured: false)
                            }
                        }
                    }
                }
                loadingHint
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 70)
        }
        .background { wallBackdrop }
        .task(id: coverTaskKey(buckets.map(\.year))) {
            guard quickCovers.isEmpty, !buckets.isEmpty else { return }
            let loaded = await store.favoritesQuickYearCovers(years: buckets.map(\.year))
            guard !loaded.isEmpty else { return }
            quickCovers = loaded
        }
    }

    /// 封面预取的触发条件：年份集合或图库签名变化时重新取一次。
    private func coverTaskKey(_ years: [String]) -> String {
        years.joined(separator: ",") + "#" + store.systemIndexSignature
    }

    private func genericSkeleton(_ mode: FavoritesViewMode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(mode: mode, subtitle: "正在汇总收藏…", highlight: nil, covers: [])
                skeletonGrid(minimum: mode == .people ? 118 : 230,
                             maximum: mode == .people ? 160 : 360,
                             height: mode == .people ? 150 : 176,
                             spacing: 14)
                loadingHint
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 70)
        }
        .background { wallBackdrop }
    }

    private func skeletonGrid(minimum: CGFloat,
                              maximum: CGFloat,
                              height: CGFloat,
                              spacing: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: maximum),
                                     spacing: spacing)],
                  alignment: .leading,
                  spacing: spacing) {
            ForEach(0..<8, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.10),
                                                  Color.primary.opacity(0.04)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(height: height)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                    }
            }
        }
    }

    private var loadingHint: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("正在汇总收藏…")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func dimensionView(_ digest: FavoritesDigest) -> some View {
        switch store.favoritesViewMode {
        case .all, .years:
            yearsWall(digest)
        case .kinds:
            kindsWall(digest)
        case .places:
            placesWall(digest)
        case .cameras:
            camerasWall(digest)
        case .people:
            peopleWall(digest)
        }
    }

    // MARK: - 年份（快速版，正式汇总未完成时）

    /// 用后台计数快照 + 每年少量封面直接画出可点击的年份墙。
    /// 上万条收藏的正式汇总要读几秒，这里让用户一进来就能看到最近年份并点进去。
    @ViewBuilder
    private var quickYearsWall: some View {
        let buckets = quickYearBuckets
        let total = store.favoritesQuickTotal ?? buckets.reduce(0) { $0 + $1.count }
        if buckets.isEmpty {
            skeletonState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(mode: .years,
                           subtitle: "\(buckets.count) 个年份 · \(total.formatted()) 项收藏",
                           highlight: buckets.first.map {
                               "最近 \($0.selection.key) 年 · \($0.count.formatted()) 张"
                           },
                           covers: buckets.compactMap { $0.photos.first })
                    if let featured = buckets.first {
                        DigestYearFeatureCard(bucket: featured) {
                            store.selectFavoritesBucket(featured.selection)
                        }
                    }
                    let rest = Array(buckets.dropFirst())
                    if !rest.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 330),
                                                     spacing: 16)],
                                  alignment: .leading,
                                  spacing: 16) {
                            ForEach(rest) { bucket in
                                DigestYearCard(bucket: bucket) {
                                    store.selectFavoritesBucket(bucket.selection)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 18)
                .padding(.bottom, 70)
            }
            .background { wallBackdrop }
            .task(id: coverTaskKey(buckets.map { $0.selection.key })) {
                guard quickCovers.isEmpty else { return }
                quickCovers = await store.favoritesQuickYearCovers(years: buckets.map { $0.selection.key })
            }
        }
    }

    /// 用计数快照拼出与正式汇总同构的年份卡片：数量准确，封面随后补齐。
    private var quickYearBuckets: [FavoritesDigestBucket] {
        store.favoritesQuickYearBuckets.map { item in
            FavoritesDigestBucket(
                selection: FavoritesBucketSelection(dimension: .year,
                                                   key: item.year,
                                                   title: "\(item.year) 年",
                                                   subtitle: nil),
                count: item.count,
                photos: quickCovers[item.year] ?? []
            )
        }
    }

    // MARK: - 年份

    @ViewBuilder
    private func yearsWall(_ digest: FavoritesDigest) -> some View {
        if digest.years.isEmpty {
            dimensionEmpty(.years)
        } else {
            wall(digest,
                 mode: .years,
                 subtitle: "\(digest.years.count) 个年份 · \(yearSpan(digest))",
                 highlight: digest.years.first.map { "最近 \($0.selection.key) 年 · \($0.count.formatted()) 张" },
                 covers: digest.years.compactMap { $0.photos.first }) {
                if let featured = digest.years.first {
                    DigestYearFeatureCard(bucket: featured) {
                        store.selectFavoritesBucket(featured.selection)
                    }
                }
                let rest = Array(digest.years.dropFirst())
                if !rest.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 330), spacing: 16)],
                              alignment: .leading,
                              spacing: 16) {
                        ForEach(rest) { bucket in
                            DigestYearCard(bucket: bucket) {
                                store.selectFavoritesBucket(bucket.selection)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 类型

    @ViewBuilder
    private func kindsWall(_ digest: FavoritesDigest) -> some View {
        if digest.kinds.isEmpty {
            dimensionEmpty(.kinds)
        } else {
            wall(digest,
                 mode: .kinds,
                 subtitle: "\(digest.kinds.count) 类 · \(digest.total.formatted()) 项收藏",
                 highlight: digest.kinds.first.map {
                     "\($0.selection.title)占 \(sharePercent($0.count, of: digest.total))%"
                 },
                 covers: digest.kinds.compactMap { $0.photos.first }) {
                if let featured = digest.kinds.first {
                    DigestKindFeatureCard(bucket: featured, total: digest.total) {
                        store.selectFavoritesBucket(featured.selection)
                    }
                }
                let rest = Array(digest.kinds.dropFirst())
                if !rest.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 14)],
                              alignment: .leading,
                              spacing: 14) {
                        ForEach(rest) { bucket in
                            DigestKindTile(bucket: bucket, total: digest.total) {
                                store.selectFavoritesBucket(bucket.selection)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 地点

    @ViewBuilder
    private func placesWall(_ digest: FavoritesDigest) -> some View {
        if digest.places.isEmpty {
            dimensionEmpty(.places)
        } else {
            wall(digest,
                 mode: .places,
                 subtitle: "\(digest.places.count) 个城市 · 点开只看这里的收藏",
                 highlight: digest.places.first.map { "最常出现：\($0.selection.title) · \($0.count.formatted()) 张" },
                 covers: digest.places.compactMap { $0.photos.first }) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 370), spacing: 16)],
                          alignment: .leading,
                          spacing: 16) {
                    ForEach(digest.places) { bucket in
                        DigestPlaceCard(bucket: bucket) {
                            store.selectFavoritesBucket(bucket.selection)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 相机

    @ViewBuilder
    private func camerasWall(_ digest: FavoritesDigest) -> some View {
        if digest.cameras.isEmpty {
            dimensionEmpty(.cameras)
        } else {
            wall(digest,
                 mode: .cameras,
                 subtitle: "\(digest.cameras.count) 个品牌 · 相机与手机",
                 highlight: digest.cameras.first.map { "主力设备：\($0.selection.title) · \($0.count.formatted()) 张" },
                 covers: digest.cameras.compactMap { $0.photos.first }) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 430), spacing: 16)],
                          alignment: .leading,
                          spacing: 16) {
                    ForEach(digest.cameras) { bucket in
                        DigestBrandCard(bucket: bucket) {
                            store.selectFavoritesBucket(bucket.selection)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 人物

    @ViewBuilder
    private func peopleWall(_ digest: FavoritesDigest) -> some View {
        if digest.people.isEmpty {
            dimensionEmpty(.people)
        } else {
            wall(digest,
                 mode: .people,
                 subtitle: "\(digest.people.count) 位人物 · 只统计已命名",
                 highlight: digest.people.first.map { "出现最多：\($0.selection.title) · \($0.count.formatted()) 张" },
                 covers: digest.people.compactMap { $0.photos.first }) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 160), spacing: 14)],
                          alignment: .leading,
                          spacing: 14) {
                    ForEach(digest.people) { bucket in
                        DigestPersonCard(bucket: bucket) {
                            store.selectFavoritesBucket(bucket.selection)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 维度页骨架

    private func wall<Content: View>(_ digest: FavoritesDigest,
                                     mode: FavoritesViewMode,
                                     subtitle: String,
                                     highlight: String?,
                                     covers: [PhotoItem],
                                     @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(mode: mode, subtitle: subtitle, highlight: highlight, covers: covers)
                content()
                if digest.isLimited {
                    Text("收藏数量超过 \(LibraryStore.favoritesDigestLimit.formatted()) 项，这里的分类只统计最近一批。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 70)
        }
        .background { wallBackdrop }
    }

    /// 维度页与骨架页共用的背景。
    private var wallBackdrop: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.09), Color.clear],
                           startPoint: .topLeading,
                           endPoint: .center)
            Circle()
                .fill(Color.accentColor.opacity(0.10))
                .frame(width: 540, height: 540)
                .blur(radius: 100)
                .offset(x: -280, y: -220)
            Circle()
                .fill(Color.purple.opacity(0.06))
                .frame(width: 460, height: 460)
                .blur(radius: 90)
                .offset(x: 320, y: 180)
        }
        .ignoresSafeArea()
    }

    private func header(mode: FavoritesViewMode,
                        subtitle: String,
                        highlight: String?,
                        covers: [PhotoItem]) -> some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor,
                                                  Color.accentColor.opacity(0.55)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                         startPoint: .topLeading,
                                         endPoint: .center))
                Image(systemName: mode.icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .shadow(color: Color.accentColor.opacity(0.32), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(wallTitle(mode))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                HStack(spacing: 8) {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    if let highlight {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(highlight)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.10), in: Capsule())
                    }
                }
            }

            Spacer(minLength: 12)

            if !covers.isEmpty {
                coverFan(covers)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.06), .clear],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    private func sharePercent(_ count: Int, of total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(count) / Double(total) * 100).rounded())
    }

    private func wallTitle(_ mode: FavoritesViewMode) -> String {
        switch mode {
        case .all: return "全部收藏"
        case .years: return "按年份"
        case .kinds: return "按类型"
        case .places: return "按地点"
        case .cameras: return "按相机与手机"
        case .people: return "收藏里的人"
        }
    }

    private func coverFan(_ covers: [PhotoItem]) -> some View {
        HStack(spacing: -14) {
            ForEach(Array(covers.prefix(4).enumerated()), id: \.offset) { index, photo in
                PhotoThumbnailView(photo: photo, purpose: .cover(80))
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 3)
                    .rotationEffect(.degrees(Double(index - 1) * 2.2))
            }
        }
        .padding(.trailing, 6)
    }

    private func yearSpan(_ digest: FavoritesDigest) -> String {
        guard let earliest = digest.earliest, let latest = digest.latest else { return "—" }
        let calendar = Calendar.current
        let first = calendar.component(.year, from: earliest)
        let last = calendar.component(.year, from: latest)
        return first == last ? "\(first) 年" : "\(first) — \(last)"
    }

    // MARK: - 状态

    private func dimensionEmpty(_ mode: FavoritesViewMode) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 88, height: 88)
                Image(systemName: mode.icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text("暂时没有\(mode.title)数据")
                .font(.system(size: 18, weight: .semibold))
            Text(mode == .people
                 ? "先在人物页完成命名或连接官方「照片」图库，收藏里的人会出现在这里。"
                 : "收藏还不够多，或对应的照片元数据（相机 / 地点）尚未读取。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 50)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 96, height: 96)
                Image(systemName: "heart.slash")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text("还没有收藏")
                .font(.system(size: 22, weight: .semibold))
            Text("在任意照片或视频上按 F，或点工具栏的心形按钮，收藏就会出现在这里。")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 50)
    }
}

// MARK: - 年份卡片

private struct DigestYearFeatureCard: View {
    let bucket: FavoritesDigestBucket
    let action: () -> Void
    @State private var hovered = false

    private var year: String { bucket.selection.key }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                DigestMosaic(photos: bucket.photos)
                    .frame(maxWidth: .infinity)
                    .frame(height: 246)

                LinearGradient(colors: [.black.opacity(0.84),
                                        .black.opacity(0.30),
                                        .clear],
                               startPoint: .bottom,
                               endPoint: .top)
                LinearGradient(colors: [Color.accentColor.opacity(0.26), .clear],
                               startPoint: .bottomLeading,
                               endPoint: .topTrailing)
                    .blendMode(.softLight)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                        Text("最近一年")
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(1.1)
                    }
                    .foregroundStyle(.white.opacity(0.72))

                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(year)
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text("年")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.68))
                        Spacer()
                        Text("\(bucket.count.formatted()) 张收藏")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.86))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                }
                .padding(20)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(hovered ? 0.28 : 0.12), lineWidth: 0.9)
            }
            .scaleEffect(hovered ? 1.012 : 1)
            .shadow(color: .black.opacity(hovered ? 0.30 : 0.16),
                    radius: hovered ? 16 : 8,
                    y: hovered ? 9 : 4)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.snappy(duration: 0.18), value: hovered)
        .help("只看 \(year) 年的收藏")
    }
}

// MARK: - 年份骨架卡片

/// 汇总未就绪时的年份卡片占位：年份与数量来自后台计数快照，封面留空。
private struct DigestYearSkeletonCard: View {
    let year: String?
    let count: Int?
    let photos: [PhotoItem]
    let height: CGFloat
    let featured: Bool

    private var hasPhotos: Bool { !photos.isEmpty }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if hasPhotos {
                DigestMosaic(photos: photos)
                LinearGradient(colors: [.black.opacity(0.82),
                                        .black.opacity(0.22),
                                        .clear],
                               startPoint: .bottom,
                               endPoint: .top)
            } else {
                LinearGradient(colors: [Color.accentColor.opacity(0.16),
                                        Color.primary.opacity(0.05)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            }

            VStack(alignment: .leading, spacing: featured ? 6 : 3) {
                Text(year ?? "—")
                    .font(.system(size: featured ? 48 : 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(hasPhotos
                                     ? Color.white
                                     : Color.secondary.opacity(year == nil ? 0.25 : 0.62))
                Text(count.map { "\($0.formatted()) 张收藏" } ?? "正在统计…")
                    .font(.system(size: featured ? 12 : 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(hasPhotos ? Color.white.opacity(0.82)
                                               : Color.secondary.opacity(0.7))
            }
            .padding(featured ? 20 : 14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: featured ? 18 : 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: featured ? 18 : 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(hasPhotos ? 0.12 : 0.08), lineWidth: 0.8)
        }
    }
}

private struct DigestYearCard: View {
    let bucket: FavoritesDigestBucket
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                DigestMosaic(photos: bucket.photos)
                    .frame(maxWidth: .infinity)
                    .frame(height: 158)

                LinearGradient(colors: [.black.opacity(0.80),
                                        .black.opacity(0.22),
                                        .clear],
                               startPoint: .bottom,
                               endPoint: .top)

                VStack(alignment: .leading, spacing: 2) {
                    Text(bucket.selection.key)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("\(bucket.count.formatted()) 张收藏")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.78))
                }
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(hovered ? 0.26 : 0.10), lineWidth: 0.8)
            }
            .scaleEffect(hovered ? 1.02 : 1)
            .shadow(color: .black.opacity(hovered ? 0.28 : 0.14),
                    radius: hovered ? 12 : 6,
                    y: hovered ? 7 : 3)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.snappy(duration: 0.18), value: hovered)
        .help("只看 \(bucket.selection.key) 年的收藏")
    }
}

// MARK: - 类型卡片

private struct DigestKindFeatureCard: View {
    let bucket: FavoritesDigestBucket
    let total: Int
    let action: () -> Void
    @State private var hovered = false

    private var kind: FavoriteKindBucket? {
        FavoriteKindBucket(rawValue: bucket.selection.key)
    }

    private var share: Double {
        total > 0 ? min(1, Double(bucket.count) / Double(total)) : 0
    }

    private var tint: Color {
        guard let kind else { return .accentColor }
        switch kind {
        case .photos: return .blue
        case .videos: return .purple
        case .livePhotos: return .teal
        case .screenshots: return .orange
        case .selfies: return .pink
        case .panoramas: return .indigo
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                DigestMosaic(photos: bucket.photos)
                    .frame(maxWidth: .infinity)
                    .frame(height: 252)

                LinearGradient(colors: [.black.opacity(0.86),
                                        .black.opacity(0.26),
                                        .clear],
                               startPoint: .bottom,
                               endPoint: .top)
                LinearGradient(colors: [tint.opacity(0.34), .clear],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                    .blendMode(.softLight)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        ZStack {
                            Circle().fill(.white.opacity(0.16))
                            Image(systemName: kind?.icon ?? "photo.stack")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 42, height: 42)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.8)
                        }

                        Spacer()

                        Text("\(Int((share * 100).rounded()))% 的收藏")
                            .font(.system(size: 10.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.14), in: Capsule())
                    }

                    Spacer()

                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bucket.selection.title)
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("\(bucket.count.formatted()) 项收藏")
                                .font(.system(size: 11.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.78))
                        }

                        Spacer()

                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.20))
                            Capsule()
                                .fill(.white.opacity(0.82))
                                .frame(width: max(4, 170 * share))
                        }
                        .frame(width: 170, height: 5)
                    }
                }
                .padding(20)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(hovered ? 0.28 : 0.12), lineWidth: 0.9)
            }
            .scaleEffect(hovered ? 1.012 : 1)
            .shadow(color: .black.opacity(hovered ? 0.30 : 0.16),
                    radius: hovered ? 16 : 8,
                    y: hovered ? 9 : 4)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.snappy(duration: 0.18), value: hovered)
        .help("只看\(bucket.selection.title)收藏")
    }
}

private struct DigestKindTile: View {
    let bucket: FavoritesDigestBucket
    let total: Int
    let action: () -> Void
    @State private var hovered = false

    private var kind: FavoriteKindBucket? {
        FavoriteKindBucket(rawValue: bucket.selection.key)
    }

    private var share: Double {
        total > 0 ? min(1, Double(bucket.count) / Double(total)) : 0
    }

    private var tint: Color {
        guard let kind else { return .accentColor }
        switch kind {
        case .photos: return .blue
        case .videos: return .purple
        case .livePhotos: return .teal
        case .screenshots: return .orange
        case .selfies: return .pink
        case .panoramas: return .indigo
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                DigestMosaic(photos: bucket.photos)
                    .frame(maxWidth: .infinity)
                    .frame(height: 176)

                LinearGradient(colors: [.black.opacity(0.84),
                                        .black.opacity(0.26),
                                        .clear],
                               startPoint: .bottom,
                               endPoint: .top)
                LinearGradient(colors: [tint.opacity(0.26), .clear],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                    .blendMode(.softLight)

                VStack(alignment: .leading, spacing: 2) {
                    Text(bucket.selection.title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(bucket.count.formatted()) 项 · 占 \(Int((share * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.78))
                }
                .padding(14)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: kind?.icon ?? "photo.stack")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.62), in: Circle())
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.24), lineWidth: 0.7)
                    }
                    .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(hovered ? 0.28 : 0.10), lineWidth: 0.8)
            }
            .scaleEffect(hovered ? 1.02 : 1)
            .shadow(color: .black.opacity(hovered ? 0.26 : 0.12),
                    radius: hovered ? 12 : 6,
                    y: hovered ? 7 : 3)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.snappy(duration: 0.18), value: hovered)
        .help("只看\(bucket.selection.title)收藏")
    }
}

// MARK: - 地点卡片

private struct DigestPlaceCard: View {
    let bucket: FavoritesDigestBucket
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                DigestMosaic(photos: bucket.photos)
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)

                LinearGradient(colors: [.black.opacity(0.82),
                                        .black.opacity(0.30),
                                        .clear],
                               startPoint: .bottom,
                               endPoint: .top)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 10, weight: .semibold))
                        Text(bucket.selection.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)

                    if let subtitle = bucket.selection.subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.66))
                            .lineLimit(1)
                    }
                }
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Text("\(bucket.count.formatted()) 张")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.34), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                    }
                    .padding(10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(hovered ? 0.26 : 0.10), lineWidth: 0.8)
            }
            .scaleEffect(hovered ? 1.02 : 1)
            .shadow(color: .black.opacity(hovered ? 0.26 : 0.12),
                    radius: hovered ? 12 : 6,
                    y: hovered ? 7 : 3)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.snappy(duration: 0.18), value: hovered)
        .help("只看 \(bucket.selection.title) 的收藏")
    }
}

// MARK: - 相机 / 手机品牌卡片

private struct DigestBrandCard: View {
    let bucket: FavoritesDigestBucket
    let action: () -> Void
    @State private var hovered = false

    private var brand: CameraBrand {
        CameraBrand.detect(bucket.selection.title)
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [brand.brandColors[0].opacity(0.42),
                                        brand.brandColors[1].opacity(0.22),
                                        .clear],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)

                Circle()
                    .fill(brand.brandColors[0].opacity(0.30))
                    .frame(width: 190, height: 190)
                    .blur(radius: 46)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: 58, y: -76)

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.08), .clear],
                                         startPoint: .topLeading,
                                         endPoint: .center))

                BrandDeviceArt(brand: brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                    .opacity(hovered ? 1 : 0.92)
                    .scaleEffect(hovered ? 1.03 : 1, anchor: .topTrailing)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(brand.brandColors[0])
                            .frame(width: 7, height: 7)
                        Text(brand.wordmark)
                            .font(.system(size: 19, weight: .heavy))
                            .tracking(0.8)
                            .lineLimit(1)
                    }

                    if let subtitle = bucket.selection.subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Text("\(bucket.count.formatted()) 张收藏")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.trailing, 96)
            }
            .frame(height: 168)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(brand.brandColors[0].opacity(hovered ? 0.52 : 0.18),
                                  lineWidth: hovered ? 1.2 : 0.8)
            }
            .scaleEffect(hovered ? 1.015 : 1)
            .shadow(color: brand.brandColors[0].opacity(hovered ? 0.22 : 0.08),
                    radius: hovered ? 14 : 6,
                    y: hovered ? 8 : 3)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.snappy(duration: 0.18), value: hovered)
        .help("只看 \(bucket.selection.title) 拍摄的收藏")
    }
}

// MARK: - 品牌设备插画

private struct BrandDeviceArt: View {
    let brand: CameraBrand

    private var colors: [Color] { brand.brandColors }

    var body: some View {
        Group {
            if brand.isPhone {
                phone
            } else {
                camera
            }
        }
        .frame(width: 104, height: 76)
    }

    private var phone: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.30),
                                              .black.opacity(0.48)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: 50, height: 92)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(.white.opacity(0.24), lineWidth: 0.8)
                }

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [colors[0].opacity(0.62),
                                              .black.opacity(0.78)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: 43, height: 84)
                .overlay {
                    if brand == .apple {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                }
                .padding(.leading, 3.5)
                .padding(.top, 4)

            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.black.opacity(0.45))
                .frame(width: 22, height: 27)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 3) {
                        Circle().fill(.white.opacity(0.30)).frame(width: 7, height: 7)
                        Circle().fill(.white.opacity(0.20)).frame(width: 7, height: 7)
                    }
                    .padding(4)
                }
                .padding(.leading, 6)
                .padding(.top, 6)
        }
        .frame(width: 50, height: 92)
        .rotationEffect(.degrees(-4))
    }

    private var camera: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.black.opacity(0.32))
                .frame(width: 27, height: 11)
                .offset(x: -20, y: -24)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [colors[0].opacity(0.80),
                                              .black.opacity(0.65)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: 96, height: 62)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.20), lineWidth: 0.9)
                }

            Circle()
                .fill(.black.opacity(0.55))
                .frame(width: 44, height: 44)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.24), lineWidth: 1.4)
                }
            Circle()
                .fill(colors[1].opacity(0.75))
                .frame(width: 24, height: 24)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(.white.opacity(0.40))
                .frame(width: 14, height: 7)
                .offset(x: 30, y: -18)
        }
        .rotationEffect(.degrees(3))
    }
}

// MARK: - 人物卡片

private struct DigestPersonCard: View {
    let bucket: FavoritesDigestBucket
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.42),
                                                      Color.accentColor.opacity(0.18)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                    if let cover = bucket.photos.first {
                        PhotoThumbnailView(photo: cover, purpose: .cover(100))
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: 92, height: 92)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(hovered ? 0.45 : 0.18),
                                          lineWidth: hovered ? 2 : 1)
                }
                .shadow(color: .black.opacity(hovered ? 0.24 : 0.10),
                        radius: hovered ? 12 : 5,
                        y: hovered ? 7 : 3)

                Text(bucket.selection.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)

                Text("\(bucket.count) 张收藏")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(hovered ? 0.20 : 0.06), lineWidth: 0.8)
            }
            .scaleEffect(hovered ? 1.02 : 1)
            .shadow(color: .black.opacity(hovered ? 0.14 : 0.05),
                    radius: hovered ? 9 : 4,
                    y: hovered ? 5 : 2)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.snappy(duration: 0.18), value: hovered)
        .help("只看 \(bucket.selection.title) 的收藏")
    }
}

// MARK: - 封面拼图

private struct DigestMosaic: View {
    let photos: [PhotoItem]

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 1.5
            let size = proxy.size
            if photos.isEmpty {
                // 空封面交给外层语义色底，避免浅色外观下出现黑块。
                Color.clear
            } else if photos.count == 1, let only = photos.first {
                image(only, width: size.width, height: size.height)
            } else if photos.count == 2 {
                HStack(spacing: gap) {
                    image(photos[0], width: (size.width - gap) / 2, height: size.height)
                    image(photos[1], width: (size.width - gap) / 2, height: size.height)
                }
            } else if photos.count == 3 {
                let wide = (size.width - gap) * 0.58
                let narrow = size.width - gap - wide
                let cellHeight = (size.height - gap) / 2
                HStack(spacing: gap) {
                    image(photos[0], width: wide, height: size.height)
                    VStack(spacing: gap) {
                        image(photos[1], width: narrow, height: cellHeight)
                        image(photos[2], width: narrow, height: cellHeight)
                    }
                }
            } else {
                let cellWidth = max(1, (size.width - gap) / 2)
                let cellHeight = max(1, (size.height - gap) / 2)
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        image(photos[0], width: cellWidth, height: cellHeight)
                        image(photos[1], width: cellWidth, height: cellHeight)
                    }
                    HStack(spacing: gap) {
                        image(photos[2], width: cellWidth, height: cellHeight)
                        image(photos[3], width: cellWidth, height: cellHeight)
                    }
                }
            }
        }
        .background(Color.secondary.opacity(0.08))
    }

    private func image(_ photo: PhotoItem, width: CGFloat, height: CGFloat) -> some View {
        PhotoThumbnailView(photo: photo, purpose: .cover(max(width, height)))
            .frame(width: width, height: height)
    }
}

// MARK: - 品牌配色

private extension CameraBrand {
    var brandColors: [Color] {
        switch self {
        case .apple:
            return [Color(white: 0.78), Color(white: 0.20)]
        case .canon:
            return [Color(red: 0.92, green: 0.18, blue: 0.20), Color(red: 0.30, green: 0.04, blue: 0.06)]
        case .nikon:
            return [Color(red: 0.98, green: 0.80, blue: 0.18), Color(red: 0.32, green: 0.22, blue: 0.04)]
        case .sony:
            return [Color(red: 0.38, green: 0.56, blue: 0.82), Color(red: 0.06, green: 0.10, blue: 0.22)]
        case .fujifilm:
            return [Color(red: 0.16, green: 0.68, blue: 0.46), Color(red: 0.04, green: 0.20, blue: 0.14)]
        case .leica:
            return [Color(red: 0.88, green: 0.10, blue: 0.14), Color(red: 0.28, green: 0.02, blue: 0.04)]
        case .hasselblad:
            return [Color(red: 0.22, green: 0.46, blue: 0.34), Color(red: 0.05, green: 0.14, blue: 0.10)]
        case .dji:
            return [Color(white: 0.72), Color(white: 0.16)]
        case .gopro:
            return [Color(red: 0.14, green: 0.60, blue: 0.90), Color(red: 0.03, green: 0.12, blue: 0.22)]
        case .xiaomi:
            return [Color(red: 0.98, green: 0.52, blue: 0.14), Color(red: 0.32, green: 0.12, blue: 0.03)]
        case .huawei:
            return [Color(red: 0.88, green: 0.14, blue: 0.20), Color(red: 0.28, green: 0.02, blue: 0.05)]
        case .samsung:
            return [Color(red: 0.22, green: 0.46, blue: 0.84), Color(red: 0.05, green: 0.10, blue: 0.24)]
        case .google:
            return [Color(red: 0.28, green: 0.58, blue: 0.94), Color(red: 0.10, green: 0.36, blue: 0.24)]
        case .oppo:
            return [Color(red: 0.10, green: 0.66, blue: 0.44), Color(red: 0.02, green: 0.20, blue: 0.13)]
        case .vivo:
            return [Color(red: 0.20, green: 0.48, blue: 0.90), Color(red: 0.04, green: 0.12, blue: 0.26)]
        case .oneplus:
            return [Color(red: 0.92, green: 0.18, blue: 0.22), Color(red: 0.28, green: 0.02, blue: 0.05)]
        case .panasonic:
            return [Color(red: 0.20, green: 0.44, blue: 0.74), Color(red: 0.04, green: 0.10, blue: 0.20)]
        case .olympus:
            return [Color(red: 0.94, green: 0.66, blue: 0.20), Color(red: 0.26, green: 0.16, blue: 0.03)]
        case .pentax:
            return [Color(red: 0.82, green: 0.14, blue: 0.18), Color(red: 0.25, green: 0.02, blue: 0.04)]
        case .insta360:
            return [Color(red: 0.98, green: 0.76, blue: 0.14), Color(red: 0.30, green: 0.20, blue: 0.02)]
        case .other:
            return [Color.accentColor, Color.black.opacity(0.5)]
        }
    }

    var wordmark: String {
        self == .other ? "CAMERA" : title.uppercased()
    }
}
