import SwiftUI
import AppKit

/// 旅行故事线：按天展开一次出行的照片，可直接播放成电影风格回忆。
struct TripStoryView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    let trip: TripStory

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { store.activeTrip = nil }

            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        hero
                        ForEach(trip.days) { day in
                            daySection(day)
                        }
                    }
                    .padding(26)
                }
            }
            .frame(maxWidth: 940, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 34, y: 16)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
        }
        .onExitCommand { store.activeTrip = nil }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(trip.title)
                    .font(.system(size: 22, weight: .bold))
                Text(trip.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.playTripMemory(trip)
            } label: {
                Label("播放回忆", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("把这次旅行播放成回忆影片")

            Button {
                store.activeTrip = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoMosaicView(photos: Array(trip.photos.prefix(4)))
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .center, endPoint: .bottom)
            HStack(spacing: 8) {
                statChip(icon: "calendar", text: "\(trip.dayCount) 天")
                if trip.placeCount > 0 {
                    statChip(icon: "mappin.and.ellipse", text: "\(trip.placeCount) 个地点")
                }
                statChip(icon: "photo.on.rectangle", text: "\(trip.photos.count) 项")
            }
            .padding(14)
        }
        .frame(height: 218)
        .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
    }

    private func statChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.38), in: Capsule())
    }

    private func daySection(_ day: TripDay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(dayTitle(day.date))
                    .font(.system(size: 14.5, weight: .semibold))
                Text("\(day.photos.count) 项")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 168), spacing: 6)],
                      spacing: 6) {
                ForEach(day.photos) { photo in
                    Button {
                        store.activeTrip = nil
                        store.openViewer(photo.id)
                    } label: {
                        PhotoThumbnailView(photo: photo, purpose: .cover(168))
                            .frame(maxWidth: .infinity)
                            .frame(height: 118)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(photo.displayTitle)
                }
            }
        }
    }

    private func dayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }
}
