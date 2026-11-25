import SwiftUI
import AppKit

/// 本地图库的端侧人物聚类页面。
struct LocalPeopleView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var renameTarget: LocalPerson?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var showResetConfirm = false
    @State private var pinchBase: Double?
    @State private var pairs: [PeoplePair] = []
    @State private var activePair: PeoplePair?
    @State private var detailMode: PersonDetailMode = .summary
    @State private var insight: PersonInsight?
    @State private var heroAvatar: NSImage?
    @State private var collapseProgress: CGFloat = 0

    /// 只展示还有可见照片的人物：照片全部删除 / 隐藏后人物自动消失，恢复后回来。
    private var people: [LocalPerson] { store.visibleLocalPeople }

    /// 人物集合或照片数变化时重新计算同框关系。
    private var pairSignature: Int {
        var hasher = Hasher()
        for person in people {
            hasher.combine(person.id)
            hasher.combine(person.assetIDs.count)
        }
        return hasher.finalize()
    }

    /// 人物卡片尺寸跟随工具栏缩放（56…360 → 72…300）。
    private var cardSize: CGFloat {
        min(300, max(72, CGFloat(store.thumbSize)))
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchBase == nil { pinchBase = store.thumbSize }
                guard let base = pinchBase else { return }
                store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound,
                                        max(LibraryStore.thumbSizeRange.lowerBound, base * value.magnification))
            }
            .onEnded { _ in pinchBase = nil }
    }

    var body: some View {
        Group {
            if let pair = activePair,
               people.contains(where: { $0.id == pair.a }),
               people.contains(where: { $0.id == pair.b }) {
                pairDetail(pair)
            } else if let id = store.selectedLocalPersonID,
               let person = people.first(where: { $0.id == id }) {
                personDetail(person)
            } else {
                overview
            }
        }
        .onAppear {
            store.loadFaceDataIfNeeded()
        }
        .onChange(of: store.selectedLocalPersonID) { _, _ in
            detailMode = .summary
            collapseProgress = 0
            insight = nil
        }
        .task(id: pairSignature) {
            pairs = store.peoplePairs()
            if let pair = activePair,
               !people.contains(where: { $0.id == pair.a || $0.id == pair.b }) {
                activePair = nil
            }
        }
        .alert("重命名人物", isPresented: $showRename) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let target = renameTarget {
                    store.renameLocalPerson(target.id, to: renameText)
                }
            }
        }
        .confirmationDialog("重新识别全部照片？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("清空结果并重新识别", role: .destructive) {
                store.resetFaceAnalysis()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清空已扫描记录与人物聚类（包含已命名的人物），再从头分析当前图库的全部照片。")
        }
    }

    // MARK: - 总览

    private var overview: some View {
        VStack(spacing: 0) {
            if let progress = store.faceClusterProgress, store.isClusteringFaces {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("正在分析 \(progress.processed.formatted()) / \(progress.total.formatted()) 张")
                        Text("· 已识别 \(progress.faces.formatted()) 张脸 · \(progress.people) 位人物")
                        Spacer()
                        Button("停止") { store.cancelFaceClustering() }
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }

            if !store.isClusteringFaces, !people.isEmpty {
                scanActionsBar
            }

            if people.isEmpty {
                emptyState
            } else if filteredPeople.isEmpty {
                filterEmptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !pairs.isEmpty, store.peopleFilter == .all {
                            pairsSection
                                .padding(.horizontal, 26)
                                .padding(.top, 14)
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.35),
                                                     spacing: cardSize * 0.16, alignment: .top)],
                                  alignment: .leading,
                                  spacing: cardSize * 0.2) {
                            ForEach(filteredPeople) { person in
                                personCard(person)
                            }
                        }
                        .padding(.horizontal, 26)
                        .padding(.top, pairs.isEmpty ? 14 : 0)
                        .padding(.bottom, 56)
                    }
                }
                .simultaneousGesture(pinchGesture)
            }
        }
    }

    /// 按当前聚合筛选得到的人物；本机聚类不区分宠物，宠物筛选为空。
    /// 「全部」时平铺展示，不再按命名状态分节；只有选了筛选才收窄集合。
    private var filteredPeople: [LocalPerson] {
        switch store.peopleFilter {
        case .all: return people
        case .named: return people.filter { !$0.isUnnamed }
        case .unnamed: return people.filter(\.isUnnamed)
        case .pets: return []
        }
    }

    /// 当前聚合筛选没有结果时的占位；与「图库为空」区分开。
    private var filterEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: store.peopleFilter.icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(store.peopleFilter.emptyTitle)
                .font(.system(size: 16, weight: .semibold))
            Text(store.peopleFilter.emptyHint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    // MARK: - 常一起出现

    private var pairsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("常一起出现")
                    .font(.system(size: 15, weight: .semibold))
                Text("按同框次数排序")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(pairs) { pair in
                        if let first = person(pair.a), let second = person(pair.b) {
                            pairCard(first, second, pair: pair)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func pairCard(_ first: LocalPerson, _ second: LocalPerson, pair: PeoplePair) -> some View {
        Button {
            activePair = pair
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    LocalPersonAvatar(person: first, size: 34)
                    LocalPersonAvatar(person: second, size: 34)
                        .offset(x: 22)
                        .overlay {
                            Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                        }
                }
                .frame(width: 58, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(first.name) 与 \(second.name)")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("同框 \(pair.count) 次")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("查看两人同框的照片")
    }

    private func pairDetail(_ pair: PeoplePair) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        activePair = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.07), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("返回人物")

                    if let first = person(pair.a), let second = person(pair.b) {
                        ZStack(alignment: .leading) {
                            LocalPersonAvatar(person: first, size: 40)
                            LocalPersonAvatar(person: second, size: 40)
                                .offset(x: 26)
                                .overlay {
                                    Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                                }
                        }
                        .frame(width: 70, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(first.name) 与 \(second.name)")
                                .font(.system(size: 21, weight: .bold))
                            Text("同框 \(pair.count) 次 · \(store.photos(for: pair).count.formatted()) 张照片")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)

                ScrollView {
                    SquarePhotoGrid(photos: store.photos(for: pair),
                                    availableWidth: proxy.size.width)
                        .padding(.bottom, 50)
                        .photoMarqueeSelection(fillHeight: proxy.size.height)
                }
            }
        }
    }

    private func person(_ id: UUID) -> LocalPerson? {
        people.first { $0.id == id }
    }

    /// 人物总览顶部的识别入口：增量继续 + 从头重来。
    private var scanActionsBar: some View {
        HStack(spacing: 10) {
            let pending = store.pendingFacePhotoCount
            Button {
                store.startFaceClustering()
            } label: {
                Label(pending > 0 ? "继续识别（剩余 \(pending.formatted()) 张）" : "全部照片已识别",
                      systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(pending == 0)
            .help("只分析还没处理过的照片，已有聚类与命名都会保留")

            Button {
                showResetConfirm = true
            } label: {
                Label("重新识别…", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("清空已扫描记录与人物聚类，从头再分析一遍")

            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.top, 10)
    }

    /// 空状态主按钮：没扫过就「开始分析」，扫过但还有新增就「继续分析」，全部扫完则允许重来。
    private var emptyStateActionTitle: String {
        let pending = store.pendingFacePhotoCount
        if store.scannedFaceIDs.isEmpty { return "开始分析" }
        if pending > 0 { return "继续分析（剩余 \(pending.formatted()) 张）" }
        return "重新分析全部照片"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 96, height: 96)
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text("端侧人物聚类")
                .font(.system(size: 22, weight: .semibold))
            Text("使用本机 Vision 检测照片中的人脸并聚类为人物。\n分析结果只保存在当前图库，不会上传任何照片。")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                if store.pendingFacePhotoCount > 0 {
                    store.startFaceClustering()
                } else {
                    showResetConfirm = true
                }
            } label: {
                Label(emptyStateActionTitle, systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
            .disabled(store.isClusteringFaces)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    private func personCard(_ person: LocalPerson) -> some View {
        Button {
            store.selectedLocalPersonID = person.id
        } label: {
            PeoplePersonCardShell(name: person.name, count: person.assetIDs.count) {
                LocalPersonAvatar(person: person, size: cardSize * 0.94, style: store.peopleDisplayStyle)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("重命名…") {
                renameTarget = person
                renameText = person.name
                showRename = true
            }
            Button("从人物中移除", role: .destructive) {
                store.deleteLocalPerson(person.id)
            }
        }
        .help(person.name)
    }

    // MARK: - 人物详情

    private func personDetail(_ person: LocalPerson) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                PersonDetailHero(name: person.name,
                                 subtitle: insight?.subtitle ?? "正在整理这段影像…",
                                 avatar: heroAvatar,
                                 isPet: false,
                                 cover: insight?.coverPhoto,
                                 mode: detailMode,
                                 collapse: detailMode == .map ? 1 : collapseProgress,
                                 onBack: { store.closeLocalPerson() },
                                 onModeChange: { newMode in
                                     withAnimation(.snappy(duration: 0.26)) { detailMode = newMode }
                                 },
                                 onRename: {
                                     renameTarget = person
                                     renameText = person.name
                                     showRename = true
                                 })

                if detailMode == .map {
                    // 地图档：页头收成一条紧凑栏，剩下的空间全部交给地图。
                    PersonMapPanel(source: .local(person), name: person.name)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            PersonScrollTracker(coordinateSpace: "localPersonScroll")
                            if detailMode == .summary {
                                if let insight {
                                    PersonInsightSummaryView(insight: insight, name: person.name)
                                } else {
                                    insightLoading.frame(height: 360)
                                }
                            } else {
                                allPhotos(store.photos(for: person),
                                          availableWidth: proxy.size.width,
                                          fillHeight: proxy.size.height)
                            }
                        }
                        .id(detailMode)
                    }
                    .coordinateSpace(name: "localPersonScroll")
                    .onPreferenceChange(PersonScrollOffsetKey.self) { offset in
                        let value = min(1, max(0, offset / 180))
                        if abs(value - collapseProgress) > 0.004 {
                            collapseProgress = value
                        }
                    }
                }
            }
        }
        .task(id: "\(person.id.uuidString)|\(person.assetIDs.count)") {
            collapseProgress = 0
            insight = nil
            let request = PersonAvatarLoader.request(for: person, size: 84)
            heroAvatar = PersonAvatarLoader.cached(request)
            if heroAvatar == nil {
                heroAvatar = await PersonAvatarLoader.load(request, store: store)
            }
            insight = store.localPersonInsight(for: person)
        }
    }

    private var insightLoading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在整理这段影像故事…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 「全部」：按年份分段的瀑布流拼贴，年份用渐变大字做时间节点。
    private func allPhotos(_ photos: [PhotoItem], availableWidth: CGFloat,
                           fillHeight: CGFloat) -> some View {
        let groups = Dictionary(grouping: photos) {
            Calendar.current.component(.year, from: $0.capturedAt)
        }
        let years = groups.keys.sorted(by: >)
        return LazyVStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("全部影像")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(photos.count.formatted()) 张 · 按年份回看")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 26)

            ForEach(years, id: \.self) { year in
                VStack(alignment: .leading, spacing: 12) {
                    yearHeader(year: year, count: groups[year]?.count ?? 0)
                    MasonryPhotoGrid(photos: groups[year] ?? [],
                                     availableWidth: availableWidth,
                                     targetWidth: CGFloat(store.thumbSize) * 1.25)
                }
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 56)
        .photoMarqueeSelection(fillHeight: fillHeight)
    }

    private func yearHeader(year: Int, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(year))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LinearGradient(colors: [Color.accentColor,
                                                         Color.accentColor.opacity(0.5)],
                                                startPoint: .top,
                                                endPoint: .bottom))
            Text("\(count) 张")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.32), Color.clear],
                                     startPoint: .leading,
                                     endPoint: .trailing))
                .frame(height: 0.8)
        }
        .padding(.horizontal, 26)
    }
}

/// 本地人物头像：后台解码 + 内存缓存，避免在 body 里同步解码裁切图或缩略图。
/// 头像形状随「人物」总览的显示偏好（圆形 / 圆角方形）。
struct LocalPersonAvatar: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    let person: LocalPerson
    let size: CGFloat
    /// 头像形状：圆形或圆角方形；默认圆形（同框小头像等场景沿用圆形）。
    var style: PeopleDisplayStyle = .circle

    @State private var image: NSImage?

    private var request: PersonAvatarRequest {
        PersonAvatarLoader.request(for: person, size: size)
    }

    /// 裁切形状：圆角方形沿用全局卡片圆角设置。
    private var shape: AnyShape {
        switch style {
        case .circle: AnyShape(Circle())
        case .roundedSquare: AnyShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
        }
    }

    var body: some View {
        ZStack {
            shape
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.4), Color.accentColor.opacity(0.22)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay {
            shape.stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        }
        .task(id: request) {
            if let cached = PersonAvatarLoader.cached(request) {
                image = cached
                return
            }
            image = await PersonAvatarLoader.load(request, store: store)
        }
    }
}
