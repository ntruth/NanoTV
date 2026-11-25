import Foundation
import CoreLocation

/// 旅行中的一天。
struct TripDay: Identifiable, Hashable {
    let date: Date
    let photos: [PhotoItem]

    var id: Date { date }
}

/// 由时间与地点自动识别的一次出行。
struct TripStory: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let startDate: Date
    let endDate: Date
    let photos: [PhotoItem]
    let dayCount: Int
    let placeCount: Int

    /// 按天分组，用于故事线详情。
    var days: [TripDay] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: photos) { calendar.startOfDay(for: $0.capturedAt) }
        return grouped.keys.sorted().map { day in
            TripDay(date: day,
                    photos: (grouped[day] ?? []).sorted { $0.capturedAt < $1.capturedAt })
        }
    }
}

/// 从带定位的照片里切分出旅行：时间间隔过大或移动距离过远就视为新的一次出行。
enum TripBuilder {
    static func build(from photos: [PhotoItem], limit: Int = 12) -> [TripStory] {
        let calendar = Calendar.current
        let candidates = photos.filter { $0.deletedAt == nil && !$0.isHidden }
        let located = candidates
            .filter { $0.hasLocation && $0.latitude != nil && $0.longitude != nil }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard located.count >= 5 else { return [] }

        var clusters: [[PhotoItem]] = []
        var current: [PhotoItem] = []
        var previous: PhotoItem?
        for photo in located {
            if let previous, breaksTrip(from: previous, to: photo, clusterStart: current.first) {
                if current.count >= 4 { clusters.append(current) }
                current = []
            }
            current.append(photo)
            previous = photo
        }
        if current.count >= 4 { clusters.append(current) }

        var trips: [TripStory] = []
        for cluster in clusters {
            guard let first = cluster.first, let last = cluster.last else { continue }
            let start = first.capturedAt.addingTimeInterval(-2 * 3600)
            let end = last.capturedAt.addingTimeInterval(2 * 3600)
            let spanDays = calendar.dateComponents([.day],
                                                   from: calendar.startOfDay(for: first.capturedAt),
                                                   to: calendar.startOfDay(for: last.capturedAt)).day ?? 0
            guard spanDays >= 1 || cluster.count >= 6 else { continue }

            let windowPhotos = candidates
                .filter { $0.capturedAt >= start && $0.capturedAt <= end }
                .sorted { $0.capturedAt < $1.capturedAt }
            guard windowPhotos.count >= 4 else { continue }

            let places = placeNames(in: cluster)
            let title: String
            if places.isEmpty {
                title = "一次出行"
            } else if places.count == 1 {
                title = "\(places[0])之行"
            } else {
                title = places.prefix(2).joined(separator: " · ") + "之行"
            }

            trips.append(TripStory(
                id: "trip-\(Int(first.capturedAt.timeIntervalSince1970))",
                title: title,
                subtitle: "\(rangeText(from: first.capturedAt, to: last.capturedAt, calendar: calendar)) · \(windowPhotos.count) 项",
                startDate: first.capturedAt,
                endDate: last.capturedAt,
                photos: windowPhotos,
                dayCount: spanDays + 1,
                placeCount: places.count
            ))
        }

        // 去掉时间上高度重叠的重复识别，保留照片更多的一条。
        var kept: [TripStory] = []
        for trip in trips.sorted(by: { $0.photos.count > $1.photos.count }) {
            let overlaps = kept.contains { other in
                other.startDate < trip.endDate && trip.startDate < other.endDate
            }
            if !overlaps { kept.append(trip) }
        }
        return Array(kept.sorted { $0.startDate > $1.startDate }.prefix(limit))
    }

    private static func breaksTrip(from previous: PhotoItem,
                                   to photo: PhotoItem,
                                   clusterStart: PhotoItem?) -> Bool {
        let gap = photo.capturedAt.timeIntervalSince(previous.capturedAt)
        if gap > 20 * 3600 { return true }
        guard let previousLat = previous.latitude, let previousLon = previous.longitude,
              let lat = photo.latitude, let lon = photo.longitude else { return false }
        if distanceKm(previousLat, previousLon, lat, lon) > 120 { return true }
        // 前半段一直在附近活动，突然隔了较长时间出现在 250km 外，也视为新的一次出行。
        if let start = clusterStart, gap > 8 * 3600,
           let startLat = start.latitude, let startLon = start.longitude,
           distanceKm(startLat, startLon, lat, lon) > 250 {
            return true
        }
        return false
    }

    /// 按出现次数排列城市名，标题取前两个。
    private static func placeNames(in photos: [PhotoItem]) -> [String] {
        var counts: [String: Int] = [:]
        for photo in photos {
            guard let name = photo.placeCity ?? photo.placeProvince, !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    private static func rangeText(from start: Date, to end: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        let startText = formatter.string(from: start)
        if calendar.isDate(start, inSameDayAs: end) { return startText }
        if calendar.component(.year, from: start) == calendar.component(.year, from: end) {
            formatter.dateFormat = "M月d日"
        }
        return "\(startText) – \(formatter.string(from: end))"
    }

    private static func distanceKm(_ lat1: Double, _ lon1: Double,
                                   _ lat2: Double, _ lon2: Double) -> Double {
        let from = CLLocation(latitude: lat1, longitude: lon1)
        let to = CLLocation(latitude: lat2, longitude: lon2)
        return from.distance(from: to) / 1000
    }
}
