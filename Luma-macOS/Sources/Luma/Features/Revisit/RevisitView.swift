import SwiftUI
import AppKit
import Foundation

/// 「值得重看」：先按人物 / 地点 / 场景 / 年份把旧照片拆成主体，
/// 再用一张「今日重看」大图开场，进入某个主体后可以按时间正序 / 倒序重看。
struct RevisitView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var insight: RevisitInsight?
    @State private var onlyUnseen = false
    @State private var kind: RevisitSubjectKind = .people
    @State private var selectedSubject: RevisitInsight.Subject?
    @State private var heroIndex = 0
    @State private var heroSeeded = false
    @State private var refreshToken = 0

    private var reloadKey: String {
        "\(store.visibleStateKey)|\(onlyUnseen)|\(refreshToken)"
    }

    var body: some View {
        Group {
            if let subject = selectedSubject {
                RevisitSubjectDetailView(subject: subject,
                                         onBack: {
                                             withAnimation(settings.motion.layout) {
                                                 selectedSubject = nil
                                             }
                                         })
                    .id(subject.id)
            } else if let insight {
                if insight.totalCount == 0 {
                    emptyState
                } else {
                    overview(insight)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在整理值得重看的照片…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: reloadKey) {
            let value = store.revisitInsight(onlyUnseen: onlyUnseen)
            insight = value
            if value.subjects(for: kind).isEmpty {
                kind = value.initialKind
            }
            if !heroSeeded || heroIndex >= value.forgottenPhotos.count {
                let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
                heroIndex = value.forgottenPhotos.isEmpty ? 0 : day % value.forgottenPhotos.count
                heroSeeded = true
            }
        }
        .onChange(of: onlyUnseen) { _, _ in
            selectedSubject = nil
        }
        .onChange(of: store.viewerID) { _, newValue in
            // 关闭查看器后刷新一次：刚才那张照片的「上次打开」与未读状态已经变化。
            guard newValue == nil else { return }
            heroSeeded = false
            refreshToken &+= 1
        }
    }

    // MARK: - 总览

    private func overview(_ insight: RevisitInsight) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summaryRow(insight)
                        .padding(.horizontal, 26)
                        .padding(.top, 16)

                    if !insight.forgottenPhotos.isEmpty {
                        heroCard(insight)
                            .padding(.horizontal, 20)
                    }

                    controls(insight)
                        .padding(.horizontal, 26)

                    subjects(insight)
                        .padding(.horizontal, 26)

                    allPreview(insight, width: proxy.size.width)

                    footnote
                        .padding(.horizontal, 26)
                }
                .padding(.bottom, 60)
            }
        }
    }

    private func summaryRow(_ insight: RevisitInsight) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(insight.summaryText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
    }

    // MARK: 今日重看

    private func heroCard(_ insight: RevisitInsight) -> some View {
        let candidates = insight.forgottenPhotos
        let index = min(heroIndex, max(0, candidates.count - 1))
        let photo = candidates[index]
        let year = Calendar.current.component(.year, from: photo.capturedAt)
        let yearSubject = insight.subjects(for: .years).first { $0.id == "year-\(year)" }

        return ZStack(alignment: .bottomLeading) {
            PhotoHeroCover(photo: photo)
                .id(photo.id)
                .transition(.opacity)

            LinearGradient(colors: [Color.black.opacity(0.40),
                                    Color.black.opacity(0.06),
                                    Color.black.opacity(0.78)],
                           startPoint: .topLeading,
                           endPoint: .bottom)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("今日重看")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .heroGlass(Capsule())
                    Spacer()
                    Text("\(index + 1) / \(candidates.count)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                }

                Spacer(minLength: 8)

                Text("\(max(1, Calendar.current.component(.year, from: Date()) - year)) 年前")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)

                Text(heroMeta(photo))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)

                Text(openedText(photo))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.top, 2)

                HStack(spacing: 8) {
                    Button {
                        store.openViewer(photo.id)
                    } label: {
                        Label("翻开这张", systemImage: "photo")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if candidates.count > 1 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                heroIndex = (index + 1) % candidates.count
                            }
                        } label: {
                            Label("换一张", systemImage: "shuffle")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .heroGlass(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("换一张最久没有翻开的照片")
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, 12)

                if let yearSubject {
                    Button {
                        withAnimation(settings.motion.layout) {
                            selectedSubject = yearSubject
                        }
                    } label: {
                        Text("看这一年的 \(yearSubject.count) 张旧照片 →")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 7)
                }
            }
            .padding(18)
        }
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    private func heroMeta(_ photo: PhotoItem) -> String {
        let month = DateText.monthFormatter.string(from: photo.capturedAt)
        if let place = photo.placePOI ?? photo.placeCity ?? photo.placeDistrict, !place.isEmpty {
            return "\(month) · \(place)"
        }
        return month
    }

    private func openedText(_ photo: PhotoItem) -> String {
        guard let viewedAt = photo.viewedAt else {
            return "这张照片还没有在拾光里打开过"
        }
        let days = max(1, Int(Date().timeIntervalSince(viewedAt) / 86_400))
        return "上次打开是 \(days.formatted()) 天前"
    }

    // MARK: 主体切换

    private func controls(_ insight: RevisitInsight) -> some View {
        let available = RevisitSubjectKind.allCases.filter {
            !insight.subjects(for: $0).isEmpty
        }

        return HStack(spacing: 8) {
            ForEach(available) { item in
                let count = insight.subjects(for: item).count
                Button {
                    withAnimation(settings.motion.layout) { kind = item }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 11.5, weight: .medium))
                        Text("\(count)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .opacity(0.7)
                    }
                    .foregroundStyle(kind == item ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background {
                        Capsule().fill(kind == item
                                       ? Color.accentColor.opacity(0.16)
                                       : Color.primary.opacity(0.05))
                    }
                    .overlay {
                        Capsule().strokeBorder(kind == item
                                               ? Color.accentColor.opacity(0.35)
                                               : Color.primary.opacity(0.08),
                                               lineWidth: 0.7)
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("按\(item.title)重看")
            }

            Spacer(minLength: 6)

            Button {
                withAnimation(settings.motion.layout) { onlyUnseen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: onlyUnseen ? "eye.slash.fill" : "eye.slash")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("只看未打开")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(onlyUnseen ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    Capsule().fill(onlyUnseen
                                   ? Color.accentColor.opacity(0.16)
                                   : Color.primary.opacity(0.05))
                }
                .overlay {
                    Capsule().strokeBorder(onlyUnseen
                                           ? Color.accentColor.opacity(0.35)
                                           : Color.primary.opacity(0.08),
                                           lineWidth: 0.7)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("只保留从未在拾光里打开过的照片")
        }
    }

    @ViewBuilder
    private func subjects(_ insight: RevisitInsight) -> some View {
        let items = insight.subjects(for: kind)
        if items.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text(kind.emptyHint)
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.vertical, 16)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(items) { subject in
                        RevisitSubjectCard(subject: subject) {
                            withAnimation(settings.motion.layout) {
                                selectedSubject = subject
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 时光碎片

    @ViewBuilder
    private func allPreview(_ insight: RevisitInsight, width: CGFloat) -> some View {
        if !insight.forgottenPhotos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("时光碎片")
                        .font(.system(size: 15, weight: .semibold))
                    Text("最久没有翻开的照片")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let all = insight.allSubject() {
                        Button {
                            withAnimation(settings.motion.layout) {
                                selectedSubject = all
                            }
                        } label: {
                            Text("全部 \(insight.totalCount.formatted()) 张 →")
                                .font(.system(size: 11.5))
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.horizontal, 26)

                MasonryPhotoGrid(photos: insight.forgottenPhotos,
                                 availableWidth: width,
                                 targetWidth: CGFloat(store.thumbSize) * 1.25)
                    .padding(.horizontal, 20)
            }
        }
    }

    private var footnote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
            Text("只收录拍摄超过两年、且一年以上没有打开过的照片；所有整理都在本机完成。")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 92, height: 92)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text("还没有值得重看的照片")
                .font(.system(size: 18, weight: .semibold))
            Text("这里会收录拍摄超过两年、且一年以上没有打开过的照片。\n照片多起来以后，会自动按人物、地点、场景与年份整理。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

// MARK: - 主体卡片

private struct RevisitSubjectCard: View {
    @EnvironmentObject private var settings: AppSettings

    let subject: RevisitInsight.Subject
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let cover = subject.cover {
                        PhotoThumbnailView(photo: cover, purpose: .cover(340), contentMode: .fill)
                    } else {
                        LinearGradient(colors: [Color.accentColor.opacity(0.35),
                                                Color.accentColor.opacity(0.12)],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                    }
                }
                .frame(width: 212, height: 238)
                .clipped()

                LinearGradient(colors: [Color.black.opacity(0.18),
                                        Color.black.opacity(0.04),
                                        Color.black.opacity(0.72)],
                               startPoint: .top,
                               endPoint: .bottom)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: subject.icon)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 24, height: 24)
                            .heroGlass(Circle(), strokeWidth: 0.7)
                        Spacer()
                        Text("\(subject.count)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.32), in: Capsule())
                    }

                    Spacer(minLength: 6)

                    HStack(alignment: .center, spacing: 8) {
                        if subject.kind == .people {
                            CompanionAvatar(companion: PhotoCompanion(id: subject.id,
                                                                      name: subject.title,
                                                                      count: subject.count,
                                                                      coverPhotoID: subject.cover?.id,
                                                                      coverData: subject.coverData),
                                            size: 32)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(subject.title)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(subject.subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.9))
                            .opacity(isHovering ? 1 : 0)
                    }
                }
                .padding(13)
            }
            .frame(width: 212, height: 238)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(isHovering ? 0.28 : 0.14),
                    radius: isHovering ? 14 : 8,
                    y: isHovering ? 7 : 4)
            .scaleEffect(isHovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(settings.motion.hover, value: isHovering)
        .help("重看 \(subject.title)")
    }
}

// MARK: - 主体详情

private struct RevisitSubjectDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    let subject: RevisitInsight.Subject
    let onBack: () -> Void

    @State private var ascending = true
    @State private var yearFilter: Int?

    private var basePhotos: [PhotoItem] {
        if let yearFilter { return subject.photosByYear[yearFilter] ?? [] }
        return subject.photos
    }

    private var sortedPhotos: [PhotoItem] {
        ascending ? basePhotos : Array(basePhotos.reversed())
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        banner
                        yearChips
                        MasonryPhotoGrid(photos: sortedPhotos,
                                         availableWidth: proxy.size.width,
                                         targetWidth: CGFloat(store.thumbSize) * 1.25)
                            .photoMarqueeSelection(fillHeight: proxy.size.height)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 50)
                }
            }
        }
    }

    // MARK: 封面叙事条

    @ViewBuilder
    private var banner: some View {
        if let cover = subject.cover {
            ZStack(alignment: .bottomLeading) {
                PhotoHeroCover(photo: cover)

                LinearGradient(colors: [Color.black.opacity(0.10),
                                        Color.black.opacity(0.02),
                                        Color.black.opacity(0.66)],
                               startPoint: .top,
                               endPoint: .bottom)

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(firstCaption)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                        Text(subject.narrative.isEmpty ? subject.subtitle : subject.narrative)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if subject.kind != .people {
                        Text("\(subject.count.formatted()) 张")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.34), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7))
                    }
                }
                .padding(14)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
            }
        }
    }

    private var firstCaption: String {
        guard let cover = subject.cover else { return "最早的一张" }
        let day = DateText.monthFormatter.string(from: cover.capturedAt)
        let place = cover.placePOI ?? cover.placeCity ?? cover.placeDistrict
        if let place, !place.isEmpty {
            return "最早的一张 · \(day) · \(place)"
        }
        return "最早的一张 · \(day)"
    }

    // MARK: 年份分层

    @ViewBuilder
    private var yearChips: some View {
        if subject.yearCounts.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    chip(title: "全部", count: subject.count, year: nil)
                    ForEach(subject.yearCounts) { item in
                        chip(title: "\(item.year)", count: item.count, year: item.year)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func chip(title: String, count: Int, year: Int?) -> some View {
        let selected = yearFilter == year
        return Button {
            withAnimation(settings.motion.layout) { yearFilter = year }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .opacity(0.65)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(selected ? Color.accentColor.opacity(0.16)
                                        : Color.primary.opacity(0.05))
            }
            .overlay {
                Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.35)
                                                : Color.primary.opacity(0.08),
                                       lineWidth: 0.7)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(year == nil ? "显示所有年份" : "只看 \(title) 年的照片")
    }

    // MARK: 页头

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.07), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("返回值得重看")

            subjectBadge

            VStack(alignment: .leading, spacing: 2) {
                Text(subject.title)
                    .font(.system(size: 21, weight: .bold))
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Button {
                withAnimation(settings.motion.layout) { ascending.toggle() }
            } label: {
                Label(ascending ? "最早优先" : "最近优先",
                      systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(ascending ? "改为最近优先" : "改为最早优先")
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var headerSubtitle: String {
        var parts: [String] = []
        if let yearFilter {
            parts.append("\(yearFilter) 年")
            parts.append("\((subject.photosByYear[yearFilter] ?? []).count.formatted()) 张")
        } else {
            parts.append("\(subject.count.formatted()) 张")
            if let first = subject.firstYear, let last = subject.lastYear {
                parts.append(first == last ? "\(first) 年" : "\(first) – \(last)")
            }
            if subject.placeCount > 0 { parts.append("\(subject.placeCount) 个地点") }
        }
        if subject.unseenCount > 0 { parts.append("\(subject.unseenCount) 张从未打开") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var subjectBadge: some View {
        if subject.kind == .people {
            CompanionAvatar(companion: PhotoCompanion(id: subject.id,
                                                      name: subject.title,
                                                      count: subject.count,
                                                      coverPhotoID: subject.cover?.id,
                                                      coverData: subject.coverData),
                            size: 42)
        } else if let cover = subject.cover {
            PhotoThumbnailView(photo: cover, purpose: .cover(42))
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: subject.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))
        }
    }
}
