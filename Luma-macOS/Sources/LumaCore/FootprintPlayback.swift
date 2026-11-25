import Foundation

/// 足迹回放的纯编排逻辑：把「带位置的照片」压成站点序列，并为每一段算出
/// 镜头高度、俯仰角与停留时长。不依赖 MapKit / SwiftUI，便于单测。
///
/// 关键点：镜头高度跟着「本段距离」缩放，所以百米级的近距离移动也会被放到
/// 满屏可见的尺度，而不是永远停在整条路线的全览视野里看不出在动。

public struct FootprintPoint: Equatable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && abs(latitude) <= 90 && abs(longitude) <= 180
            && !(abs(latitude) < 0.0001 && abs(longitude) < 0.0001)
    }
}

public struct FootprintSample: Equatable {
    public var time: Date
    public var point: FootprintPoint
    /// 地点唯一键（同城同区县视为同一键），用于把同一地点的连拍合并成一站。
    public var placeKey: String
    /// 展示用地点名。
    public var placeName: String

    public init(time: Date, point: FootprintPoint, placeKey: String, placeName: String) {
        self.time = time
        self.point = point
        self.placeKey = placeKey
        self.placeName = placeName
    }
}

public struct FootprintStop: Equatable {
    /// 站点重心坐标。
    public var point: FootprintPoint
    public var name: String
    public var firstTime: Date
    public var lastTime: Date
    public var photoCount: Int
    /// 该站在原始样本数组中的闭区间（含首尾）。
    public var sampleRange: ClosedRange<Int>
}

public struct FootprintLeg: Equatable {
    /// 本段真实距离（米）。
    public var distance: Double
    /// 镜头到画面中心的高度（米），越小越贴近地面。
    public var cameraDistance: Double
    /// 镜头俯仰角（度）。
    public var pitch: Double
    /// 镜头朝向（度，0 = 正北），长距离航段朝向前进方向。
    public var heading: Double
    /// 行进时长（秒，丝滑巡航速度）。
    public var duration: Double
    /// 抵达后在该站的停留时长（秒）。
    public var dwell: Double
    /// 人类可读的距离描述，例如「就在附近 · 60 米」。
    public var caption: String
}

public struct FootprintPlan: Equatable {
    public var stops: [FootprintStop] = []
    public var legs: [FootprintLeg] = []
    /// 抵达每一站时的累计里程，长度与 `stops` 相同。
    public var distanceToStop: [Double] = []
    /// 按出现顺序去重的地点名。
    public var places: [String] = []
    public var firstTime: Date?
    public var lastTime: Date?
    public var totalDistance: Double { distanceToStop.last ?? 0 }
    public var isEmpty: Bool { stops.isEmpty }
}

/// 连续巡航中的一帧。光点与镜头共用同一条时间轴，避免两套动画各自起停。
public struct FootprintCruiseFrame: Equatable {
    public var stopIndex: Int
    public var legFraction: Double
    public var head: FootprintPoint
    /// 镜头看向路线前方的一点，而不是固定在每段的中点。
    public var cameraCenter: FootprintPoint
    public var cameraDistance: Double
    public var pitch: Double
    public var heading: Double
    public var isDwelling: Bool
    public var dwellFraction: Double
    public var isComplete: Bool
}

/// 把行程段与旅拍停留编成一条可拖动、可暂停的连续时间轴。
/// 行进段的比例始终线性，平滑只作用于镜头参数，因此不会每站刹停再启动。
public struct FootprintCruiseTimeline {
    public let plan: FootprintPlan
    public let totalDuration: TimeInterval
    private let legStarts: [TimeInterval]

    public init(plan: FootprintPlan) {
        self.plan = plan
        var starts: [TimeInterval] = []
        var cursor = 0.0
        for leg in plan.legs {
            starts.append(cursor)
            cursor += max(0, leg.duration) + max(0, leg.dwell)
        }
        legStarts = starts
        totalDuration = cursor
    }

    /// 返回时间轴上某一时刻的光点、镜头与停留状态。
    public func frame(at elapsed: TimeInterval) -> FootprintCruiseFrame {
        guard let first = plan.stops.first else {
            let point = FootprintPoint(latitude: 0, longitude: 0)
            return FootprintCruiseFrame(stopIndex: 0, legFraction: 0, head: point,
                                        cameraCenter: point, cameraDistance: 600, pitch: 0,
                                        heading: 0, isDwelling: false, dwellFraction: 0,
                                        isComplete: true)
        }
        guard !plan.legs.isEmpty else {
            return FootprintCruiseFrame(stopIndex: 0, legFraction: 0, head: first.point,
                                        cameraCenter: first.point, cameraDistance: 900, pitch: 36,
                                        heading: 0, isDwelling: false, dwellFraction: 0,
                                        isComplete: true)
        }

        let time = min(max(0, elapsed), totalDuration)
        if time >= totalDuration {
            let index = plan.legs.count - 1
            let frame = travelingFrame(legIndex: index, fraction: 1)
            return FootprintCruiseFrame(stopIndex: plan.stops.count - 1,
                                        legFraction: 0,
                                        head: plan.stops[plan.stops.count - 1].point,
                                        cameraCenter: frame.cameraCenter,
                                        cameraDistance: frame.cameraDistance,
                                        pitch: frame.pitch,
                                        heading: frame.heading,
                                        isDwelling: false,
                                        dwellFraction: 1,
                                        isComplete: true)
        }

        let index = legIndex(at: time)
        let leg = plan.legs[index]
        let duration = max(0, leg.duration)
        let dwell = max(0, leg.dwell)
        let local = max(0, time - legStarts[index])
        if local >= duration, dwell > 0 {
            let destination = index + 1
            let frame = travelingFrame(legIndex: index, fraction: 1)
            return FootprintCruiseFrame(stopIndex: destination,
                                        legFraction: 0,
                                        head: plan.stops[destination].point,
                                        cameraCenter: frame.cameraCenter,
                                        cameraDistance: frame.cameraDistance,
                                        pitch: frame.pitch,
                                        heading: frame.heading,
                                        isDwelling: true,
                                        dwellFraction: min(1, max(0, (local - duration) / dwell)),
                                        isComplete: false)
        }

        let fraction = min(1, max(0, local / max(0.001, duration)))
        return travelingFrame(legIndex: index, fraction: fraction)
    }

    /// 拖动到某站时，落在该站准备出发的时刻；终点则落在抵达后的旅拍停留。
    public func time(atStop index: Int) -> TimeInterval {
        guard !plan.stops.isEmpty else { return 0 }
        let station = min(max(0, index), plan.stops.count - 1)
        if station < legStarts.count { return legStarts[station] }
        guard let last = plan.legs.last else { return 0 }
        return max(0, totalDuration - max(0, last.dwell))
    }

    private func legIndex(at time: TimeInterval) -> Int {
        var low = 0
        var high = plan.legs.count - 1
        while low < high {
            let middle = (low + high) / 2
            let leg = plan.legs[middle]
            let end = legStarts[middle] + max(0, leg.duration) + max(0, leg.dwell)
            if time < end {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    private func travelingFrame(legIndex index: Int, fraction: Double) -> FootprintCruiseFrame {
        let from = plan.stops[index].point
        let to = plan.stops[index + 1].point
        let head = FootprintPlanner.interpolate(from: from, to: to, fraction: fraction)
        let ahead = lookAhead(legIndex: index, fraction: fraction)
        let center = FootprintPlanner.interpolate(from: head, to: ahead, fraction: 0.36)
        let pose = cameraPose(legIndex: index, fraction: fraction)
        return FootprintCruiseFrame(stopIndex: index,
                                    legFraction: fraction,
                                    head: head,
                                    cameraCenter: center,
                                    cameraDistance: pose.distance,
                                    pitch: pose.pitch,
                                    heading: pose.heading,
                                    isDwelling: false,
                                    dwellFraction: 0,
                                    isComplete: false)
    }

    /// 镜头提前看路线 18% 的位置；跨过站点时接上下一段，位置不会在段边界跳变。
    private func lookAhead(legIndex index: Int, fraction: Double) -> FootprintPoint {
        let lead = 0.18
        let from = plan.stops[index].point
        let to = plan.stops[index + 1].point
        if index == plan.legs.count - 1 || fraction < 1 - lead {
            return FootprintPlanner.interpolate(from: from, to: to, fraction: min(1, fraction + lead))
        }
        let next = index + 1
        let nextFraction = min(lead, max(0, fraction - (1 - lead)))
        return FootprintPlanner.interpolate(from: plan.stops[next].point,
                                            to: plan.stops[next + 1].point,
                                            fraction: nextFraction)
    }

    /// 只给镜头做平滑，光点仍使用原始线性比例；段边界两端使用同一个镜头姿态。
    private func cameraPose(legIndex index: Int,
                            fraction: Double) -> (distance: Double, pitch: Double, heading: Double) {
        let current = plan.legs[index]
        let previous = index > 0 ? plan.legs[index - 1] : current
        let t = min(1, max(0, fraction))
        let blend = t * t * (3 - 2 * t)
        let fromDistance = max(1, previous.cameraDistance)
        let toDistance = max(1, current.cameraDistance)
        let distance = exp(log(fromDistance) + (log(toDistance) - log(fromDistance)) * blend)
        let pitch = previous.pitch + (current.pitch - previous.pitch) * blend
        let delta = (current.heading - previous.heading + 540)
            .truncatingRemainder(dividingBy: 360) - 180
        var heading = previous.heading + delta * blend
        if heading < 0 { heading += 360 }
        if heading >= 360 { heading -= 360 }
        return (distance, pitch, heading)
    }
}

public enum FootprintPlanner {
    /// 站点上限：再多就让视频过长，按时间均匀抽样。
    public static let maxStops = 150
    /// 同一地点键 + 几十米内 + 时间不中断时，连拍合并成一站。
    public static let placeMergeRadius = 60.0
    public static let placeMergeWindow: TimeInterval = 2 * 60 * 60
    /// 没有地名时，短时间内的近距离抖动也合并。
    public static let jitterRadius = 80.0
    public static let jitterWindow: TimeInterval = 30 * 60

    // MARK: - 编排

    public static func plan(samples input: [FootprintSample]) -> FootprintPlan {
        let sorted = input.filter { $0.point.isValid }.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return FootprintPlan() }

        var builders: [StopBuilder] = []
        for (index, sample) in sorted.enumerated() {
            if var last = builders.last {
                let distance = self.distance(from: last.point, to: sample.point)
                let gap = sample.time.timeIntervalSince(last.lastTime)
                let samePlace = !sample.placeKey.isEmpty && sample.placeKey == last.placeKey
                // 合并只发生在同一波连拍里：同一个院子隔天再拍必须拆成不同的站，
                // 否则几十张照片会被压成一站，回放一闪而过、只能看到一张图。
                let merge = (samePlace && distance <= placeMergeRadius && gap <= placeMergeWindow)
                    || (distance <= jitterRadius && gap <= jitterWindow)
                if merge {
                    last.latitudeSum += sample.point.latitude
                    last.longitudeSum += sample.point.longitude
                    last.count += 1
                    last.lastTime = sample.time
                    last.lastIndex = index
                    builders[builders.count - 1] = last
                    continue
                }
            }
            builders.append(StopBuilder(point: sample.point,
                                        name: sample.placeName,
                                        placeKey: sample.placeKey,
                                        time: sample.time,
                                        index: index))
        }

        var stops = builders.map(\.stop)
        if stops.count > maxStops {
            let step = Double(stops.count - 1) / Double(maxStops - 1)
            stops = (0..<maxStops).map { index in
                stops[min(stops.count - 1, Int((Double(index) * step).rounded()))]
            }
        }

        var legs: [FootprintLeg] = []
        var distanceToStop: [Double] = [0]
        var running = 0.0
        for index in 1..<max(1, stops.count) {
            let from = stops[index - 1]
            let to = stops[index]
            let distance = self.distance(from: from.point, to: to.point)
            running += distance
            distanceToStop.append(running)
            legs.append(leg(distance: distance, photoCount: to.photoCount, from: from.point, to: to.point))
        }

        var seen = Set<String>()
        let places = stops.compactMap { stop -> String? in
            let name = stop.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }

        return FootprintPlan(stops: stops,
                             legs: legs,
                             distanceToStop: distanceToStop,
                             places: places,
                             firstTime: stops.first?.firstTime,
                             lastTime: stops.last?.lastTime)
    }

    /// 单段镜头：距离决定高度与俯仰，短文案解释「这一段在动多少」。
    static func leg(distance: Double,
                    photoCount: Int,
                    from: FootprintPoint,
                    to: FootprintPoint) -> FootprintLeg {
        let cameraDistance = max(distance * 2.35, 180)
        let pitch: Double
        if distance < 1_500 {
            pitch = 50
        } else if distance < 40_000 {
            pitch = 42
        } else {
            pitch = 30
        }
        let heading = distance > 1 ? bearing(from: from, to: to) : 0
        // 统一的是画面中的前进感，而非现实车速：距离 / 镜头高度约等于
        // 本段跨越的屏幕尺度，因此街区和跨城段都以相同的视觉速率前进。
        // 极短段另设最短时长，避免百米内的移动一闪而过。
        let visibleDistance = distance / cameraDistance
        let duration = distance < 1 ? 0.45 : max(0.9, visibleDistance / 0.24)
        // 照片多的站点要停够时间翻看这一站的照片：每多一张略加，封顶 3.6 秒。
        let dwell = photoCount >= 2
            ? min(3.6, max(0.5, 0.3 + 0.045 * Double(photoCount)))
            : 0
        return FootprintLeg(distance: distance,
                            cameraDistance: cameraDistance,
                            pitch: pitch,
                            heading: heading,
                            duration: duration,
                            dwell: dwell,
                            caption: caption(for: distance))
    }

    public static func caption(for distance: Double) -> String {
        if distance < 1 { return "原地停留" }
        if distance < 1_000 {
            return "就在附近 · \(Int(distance.rounded())) 米"
        }
        if distance < 20_000 {
            return String(format: "穿城 %.1f 公里", distance / 1_000)
        }
        if distance < 1_000_000 {
            return "跨城 \(Int((distance / 1_000).rounded())) 公里"
        }
        return String(format: "远行 %.0f 公里", distance / 1_000)
    }

    // MARK: - 镜头总览

    /// 全览镜头高度：覆盖所有站点。
    public static func overviewDistance(of points: [FootprintPoint]) -> Double {
        let valid = points.filter(\.isValid)
        guard !valid.isEmpty else { return 600 }
        let center = FootprintPoint(latitude: valid.map(\.latitude).reduce(0, +) / Double(valid.count),
                                    longitude: valid.map(\.longitude).reduce(0, +) / Double(valid.count))
        let radius = valid.map { distance(from: center, to: $0) }.max() ?? 0
        return max(radius * 3.2, 600)
    }

    // MARK: - 几何

    /// 大圆距离（米）。
    public static func distance(from: FootprintPoint, to: FootprintPoint) -> Double {
        let earth = 6_371_000.0
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earth * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// 方位角（度，0 = 正北，顺时针）。
    public static func bearing(from: FootprintPoint, to: FootprintPoint) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// 沿大圆插值，`fraction` 会被夹到 0…1；起终点附近直接返回端点。
    public static func interpolate(from: FootprintPoint,
                                   to: FootprintPoint,
                                   fraction: Double) -> FootprintPoint {
        let f = min(1, max(0, fraction))
        if f <= 0 { return from }
        if f >= 1 { return to }
        if distance(from: from, to: to) < 1 { return from }

        let lat1 = from.latitude * .pi / 180
        let lon1 = from.longitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let lon2 = to.longitude * .pi / 180

        let x1 = cos(lat1) * cos(lon1)
        let y1 = cos(lat1) * sin(lon1)
        let z1 = sin(lat1)
        let x2 = cos(lat2) * cos(lon2)
        let y2 = cos(lat2) * sin(lon2)
        let z2 = sin(lat2)

        let dot = min(1, max(-1, x1 * x2 + y1 * y2 + z1 * z2))
        let omega = acos(dot)
        guard omega > 1e-9 else {
            return FootprintPoint(latitude: from.latitude + (to.latitude - from.latitude) * f,
                                  longitude: from.longitude + (to.longitude - from.longitude) * f)
        }
        let sinOmega = sin(omega)
        let a = sin((1 - f) * omega) / sinOmega
        let b = sin(f * omega) / sinOmega
        let x = a * x1 + b * x2
        let y = a * y1 + b * y2
        let z = a * z1 + b * z2
        return FootprintPoint(latitude: atan2(z, sqrt(x * x + y * y)) * 180 / .pi,
                              longitude: atan2(y, x) * 180 / .pi)
    }

    // MARK: - 内部

    private struct StopBuilder {
        var latitudeSum: Double
        var longitudeSum: Double
        var name: String
        var placeKey: String
        var firstTime: Date
        var lastTime: Date
        var count = 1
        var firstIndex: Int
        var lastIndex: Int

        init(point: FootprintPoint, name: String, placeKey: String, time: Date, index: Int) {
            latitudeSum = point.latitude
            longitudeSum = point.longitude
            self.name = name
            self.placeKey = placeKey
            firstTime = time
            lastTime = time
            firstIndex = index
            lastIndex = index
        }

        var point: FootprintPoint {
            FootprintPoint(latitude: latitudeSum / Double(count),
                           longitude: longitudeSum / Double(count))
        }

        var stop: FootprintStop {
            FootprintStop(point: point,
                          name: name,
                          firstTime: firstTime,
                          lastTime: lastTime,
                          photoCount: count,
                          sampleRange: firstIndex...max(firstIndex, lastIndex))
        }
    }
}
