import Foundation
import CoreLocation

// MARK: - 坐标有效性

enum CoordinateValidator {
    /// 官方图库对没有位置的照片会写入 (-180, -180) 之类的哨兵值，需要过滤。
    static func isValid(latitude: Double?, longitude: Double?) -> Bool {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite else { return false }
        guard abs(latitude) <= 90, abs(longitude) <= 180 else { return false }
        if abs(latitude) < 0.0001, abs(longitude) < 0.0001 { return false }
        return true
    }
}

// MARK: - 地点信息

/// 一张照片对应的地点信息，来自官方图库的反向地理编码数据，或本地逆地理编码。
struct PlaceInfo: Codable, Hashable {
    var country: String?
    var province: String?
    var city: String?
    var district: String?
    var poi: String?

    var isEmpty: Bool {
        country == nil && province == nil && city == nil && district == nil && poi == nil
    }

    /// 展示名称：优先「城市，区县」。
    var displayName: String? {
        var parts: [String] = []
        if let city, !city.isEmpty { parts.append(city) }
        if let district, !district.isEmpty, district != city { parts.append(district) }
        if !parts.isEmpty { return parts.joined(separator: "，") }
        if let poi, !poi.isEmpty { return poi }
        if let province, !province.isEmpty { return province }
        if let country, !country.isEmpty { return country }
        return nil
    }

    /// 统计分组：中国大陆 / 其他国家或地区。
    var regionGroup: String {
        guard let country, !country.isEmpty else { return "其他地点" }
        if country.contains("中国"),
           !country.contains("香港"),
           !country.contains("澳门"),
           !country.contains("台湾") {
            return "中国大陆"
        }
        return country
    }
}

// MARK: - 聚合层级

/// 「位置」页的地点聚合层级：省 / 市 / 区县 / 街道。
/// 层级只影响聚类与标题，不改变照片本身的地名数据。
enum PlaceGranularity: String, CaseIterable, Identifiable {
    case province
    case city
    case district
    case street

    var id: String { rawValue }

    /// 切换控件上的短标签。
    var shortTitle: String {
        switch self {
        case .province: return "省"
        case .city: return "市"
        case .district: return "区"
        case .street: return "街道"
        }
    }

    /// 完整名称，用于提示文案。
    var title: String {
        switch self {
        case .province: return "省份"
        case .city: return "城市"
        case .district: return "区县"
        case .street: return "街道"
        }
    }
}

// MARK: - 地点聚类

struct PlaceCluster: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let group: String
    let photos: [PhotoItem]
    let latitude: Double
    let longitude: Double
    /// 照片经纬度包围盒：视野统计先按簇整体剔除，避免每次平移都逐张检查全部照片。
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    var count: Int { photos.count }
    var cover: PhotoItem? { photos.first }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum PlaceClusterBuilder {
    static func key(for photo: PhotoItem,
                    granularity: PlaceGranularity = .district) -> (id: String, title: String, subtitle: String?, group: String) {
        let country = clean(photo.placeCountry)
        let province = clean(photo.placeProvince)
        let city = clean(photo.placeCity)
        let district = clean(photo.placeDistrict)
        let poi = clean(photo.placePOI)

        // 省级 / 市级缺数据时逐级回退；街道级允许只有街道名。
        // 只有国家（如海上 / 景区坐标）也算有地名：至少能显示国家或地区，不退回坐标。
        let hasNamedLevel = country != nil || city != nil || district != nil || province != nil
            || (granularity == .street && poi != nil)
        if hasNamedLevel {
            let title: String
            let subtitle: String?
            switch granularity {
            case .province:
                title = province ?? city ?? country ?? "未知地点"
                subtitle = country.flatMap { $0 == title ? nil : $0 }
            case .city:
                title = city ?? province ?? country ?? "未知地点"
                subtitle = (province ?? country).flatMap { $0 == title ? nil : $0 }
            case .district:
                title = joined([city, district == city ? nil : district])
                    ?? province ?? country ?? "未知地点"
                subtitle = province.flatMap { $0 == title ? nil : $0 }
            case .street:
                title = poi ?? district ?? city ?? province ?? country ?? "未知地点"
                subtitle = joined([city == title ? nil : city,
                                   district == title ? nil : district])
            }
            let group = PlaceInfo(country: country,
                                  province: province,
                                  city: city,
                                  district: district,
                                  poi: poi).regionGroup
            // id 只包含当前层级以上的路径，保证同一街道 / 城市能被聚到同一个桶里。
            let path: [String?]
            switch granularity {
            case .province:
                path = [country, province ?? city]
            case .city:
                path = [country, province, city ?? province]
            case .district:
                path = [country, province, city, district]
            case .street:
                path = [country, province, city, district, poi]
            }
            let id = ([granularity.rawValue] + path.map { $0 ?? "" }).joined(separator: "|")
            return (id, title, subtitle, group)
        }

        // 没有地名：用约 11 公里的网格聚合，标题显示坐标。
        // 网格不能太细：十万级图库里没有地名的照片可能很多，1 公里一格会拆出上千张卡片把页面拖死。
        let lat = photo.latitude ?? 0
        let lon = photo.longitude ?? 0
        let id = String(format: "geo|%.1f|%.1f", lat, lon)
        let title = String(format: "%.1f°%@, %.1f°%@",
                           abs(lat), lat >= 0 ? "N" : "S",
                           abs(lon), lon >= 0 ? "E" : "W")
        return (id, title, "未命名地点", "其他地点")
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func joined(_ parts: [String?]) -> String? {
        let values = parts.compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: "，")
    }

    static func clusters(from photos: [PhotoItem],
                         granularity: PlaceGranularity = .district) -> [PlaceCluster] {
        // 用引用类型的桶就地累加：值类型桶每次 append 都要整份拷出再写回，
        // 大图库（上万张带定位照片）会明显拖慢地图页打开速度。
        var buckets: [String: PlaceBucket] = [:]
        buckets.reserveCapacity(32)
        for photo in photos {
            guard let lat = photo.latitude, let lon = photo.longitude,
                  CoordinateValidator.isValid(latitude: lat, longitude: lon) else { continue }
            let key = key(for: photo, granularity: granularity)
            let bucket: PlaceBucket
            if let existing = buckets[key.id] {
                bucket = existing
            } else {
                let created = PlaceBucket(key: key)
                buckets[key.id] = created
                bucket = created
            }
            bucket.photos.append(photo)
            bucket.latitudeSum += lat
            bucket.longitudeSum += lon
            bucket.minLatitude = min(bucket.minLatitude, lat)
            bucket.maxLatitude = max(bucket.maxLatitude, lat)
            bucket.minLongitude = min(bucket.minLongitude, lon)
            bucket.maxLongitude = max(bucket.maxLongitude, lon)
        }

        return buckets.map { id, bucket in
            bucket.photos.sort { $0.capturedAt > $1.capturedAt }
            let count = Double(max(1, bucket.photos.count))
            return PlaceCluster(id: id,
                                title: bucket.title,
                                subtitle: bucket.subtitle,
                                group: bucket.group,
                                photos: bucket.photos,
                                latitude: bucket.latitudeSum / count,
                                longitude: bucket.longitudeSum / count,
                                minLatitude: bucket.minLatitude,
                                maxLatitude: bucket.maxLatitude,
                                minLongitude: bucket.minLongitude,
                                maxLongitude: bucket.maxLongitude)
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

/// 地点文案：查看器顶栏、信息面板与网格地点标签共用同一套层级与回退顺序，
/// 避免同一个地点在不同位置显示成不同的名字。
extension PhotoItem {
    /// 统一的地点标题：街道 → 城市 → 区县 → 省份 → 国家。
    var placeTitle: String? {
        if let poi = photoPlaceText(placePOI) { return poi }
        return photoPlaceText(placeCity)
            ?? photoPlaceText(placeDistrict)
            ?? photoPlaceText(placeProvince)
            ?? photoPlaceText(placeCountry)
    }

    /// 地点副行：标题是街道时补「城市 · 区县」，否则补下一级行政区。
    var placeSubtitle: String? {
        let city = photoPlaceText(placeCity)
        let district = photoPlaceText(placeDistrict)
        if photoPlaceText(placePOI) != nil {
            let parts = [city, district].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        let title = placeTitle
        for candidate in [district, photoPlaceText(placeProvince), photoPlaceText(placeCountry)] {
            if let candidate, candidate != title { return candidate }
        }
        return nil
    }

    private func photoPlaceText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// 地点聚类过程中的累加桶（引用类型，避免结构体写回时的整份拷贝）。
private final class PlaceBucket {
    let title: String
    let subtitle: String?
    let group: String
    var photos: [PhotoItem] = []
    var latitudeSum = 0.0
    var longitudeSum = 0.0
    var minLatitude = Double.infinity
    var maxLatitude = -Double.infinity
    var minLongitude = Double.infinity
    var maxLongitude = -Double.infinity

    init(key: (id: String, title: String, subtitle: String?, group: String)) {
        title = key.title
        subtitle = key.subtitle
        group = key.group
    }
}

// MARK: - 官方图库反向地理位置解码

/// 解析 `ZREVERSELOCATIONDATA`（NSKeyedArchiver 二进制 plist）。
/// 其中包含 `CNPostalAddress`（国家/省/市/区/街道），无需联网即可得到官方地名。
enum ReverseGeoArchive {
    private static let uidValueFunction: ((CFTypeRef) -> UInt32)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW),
              let symbol = dlsym(handle, "_CFKeyedArchiverUIDGetValue") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CFTypeRef) -> UInt32).self)
    }()

    private static let uidTypeIDFunction: (() -> CFTypeID)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW),
              let symbol = dlsym(handle, "_CFKeyedArchiverUIDGetTypeID") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> CFTypeID).self)
    }()

    static func decode(_ data: Data) -> PlaceInfo? {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let objects = root["$objects"] as? [Any] else { return nil }

        func uidIndex(_ value: Any) -> Int {
            if let function = uidValueFunction, let typeFunction = uidTypeIDFunction,
               CFGetTypeID(value as CFTypeRef) == typeFunction() {
                return Int(function(value as CFTypeRef))
            }
            let description = String(describing: value)
            guard let range = description.range(of: "value = ") else { return -1 }
            let digits = description[range.upperBound...].prefix { $0.isNumber }
            return Int(digits) ?? -1
        }

        func string(_ value: Any?) -> String? {
            guard let value else { return nil }
            let index = uidIndex(value)
            guard index > 0, index < objects.count, let text = objects[index] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func integer(_ value: Any?) -> Int? {
            guard let value else { return nil }
            let index = uidIndex(value)
            guard index > 0, index < objects.count else { return nil }
            if let number = objects[index] as? Int { return number }
            if let number = objects[index] as? NSNumber { return number.intValue }
            return nil
        }

        for object in objects {
            guard let dict = object as? [String: Any] else { continue }
            guard dict["_city"] != nil || dict["_subLocality"] != nil || dict["_country"] != nil else { continue }
            let info = PlaceInfo(country: string(dict["_country"]),
                                 province: string(dict["_state"]),
                                 city: string(dict["_city"]),
                                 district: string(dict["_subLocality"]),
                                 poi: string(dict["_street"]))
            if !info.isEmpty { return info }
        }

        // 兜底：从 sortedPlaceInfos 的层级名称里取城市 / 区县。
        var fallback = PlaceInfo()
        for object in objects {
            guard let dict = object as? [String: Any], dict["name"] != nil else { continue }
            guard let type = integer(dict["placeType"]), let name = string(dict["name"]) else { continue }
            switch type {
            case 1: fallback.country = fallback.country ?? name
            case 2: fallback.province = fallback.province ?? name
            case 4: fallback.city = fallback.city ?? name
            case 6: fallback.district = fallback.district ?? name
            default: break
            }
        }
        return fallback.isEmpty ? nil : fallback
    }
}

// MARK: - 坐标系纠偏

/// WGS-84 / GCJ-02 / BD-09 之间的转换，用于高德、百度底图对齐。
enum CoordinateShift {
    private static let axis = 6378245.0
    private static let eccentricity = 0.00669342162296594323
    private static let xPi = Double.pi * 3000.0 / 180.0

    static func isOutOfChina(latitude: Double, longitude: Double) -> Bool {
        longitude < 72.004 || longitude > 137.8347 || latitude < 0.8293 || latitude > 55.8271
    }

    static func wgs84ToGcj02(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        guard !isOutOfChina(latitude: latitude, longitude: longitude) else {
            return (latitude, longitude)
        }
        var deltaLat = transformLatitude(longitude - 105.0, latitude - 35.0)
        var deltaLon = transformLongitude(longitude - 105.0, latitude - 35.0)
        let radLat = latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - eccentricity * magic * magic
        let sqrtMagic = sqrt(magic)
        deltaLat = (deltaLat * 180.0) / ((axis * (1 - eccentricity)) / (magic * sqrtMagic) * .pi)
        deltaLon = (deltaLon * 180.0) / (axis / sqrtMagic * cos(radLat) * .pi)
        return (latitude + deltaLat, longitude + deltaLon)
    }

    static func gcj02ToBd09(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        let z = sqrt(longitude * longitude + latitude * latitude) + 0.00002 * sin(latitude * xPi)
        let theta = atan2(latitude, longitude) + 0.000003 * cos(longitude * xPi)
        return (z * sin(theta) + 0.006, z * cos(theta) + 0.0065)
    }

    static func wgs84ToBd09(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        let gcj = wgs84ToGcj02(latitude: latitude, longitude: longitude)
        return gcj02ToBd09(latitude: gcj.latitude, longitude: gcj.longitude)
    }

    // MARK: 百度墨卡托

    private static let mcBands: [Double] = [12890594.86, 8362377.87, 5591021, 3481989.83, 1678043.12, 0]
    private static let ll2mc: [[Double]] = [
        [-0.0015702102444, 111320.7020616939, 1704480524535203, -10338987376042340,
         26112667856603880, -35149669176653700, 26595700718403920, -10725012454188240,
         1800819912950474, 82.5],
        [0.0008277824516172526, 111320.7020463578, 647795574.6671607, -4082003173.641316,
         10774905663.51142, -15171875531.51559, 12053065338.62167, -5124939663.577472,
         913311935.9512032, 67.5],
        [0.00337398766765, 111320.7020202162, 4481351.045890365, -23393751.19931662,
         79682215.47186455, -115964993.2797253, 97236711.15602145, -43661946.33752821,
         8477230.501135234, 52.5],
        [0.00220636496208, 111320.7020209128, 51751.86112841131, 3796837.749470245,
         992013.7397791013, -1221952.21711287, 1340652.697009075, -620943.6990984312,
         144416.9293806241, 37.5],
        [-0.0003441963504368392, 111320.7020576856, 278.2353980772752, 2485758.690035394,
         6070.750963243378, 54821.18345352118, 9540.606633304236, -2710.55326746645,
         1405.483844121726, 22.5],
        [-0.0003218135878613132, 111320.7020701615, 0.00369383431289, 823725.6402795718,
         0.46104986909093, 2351.343141331292, 1.58060784298199, 8.77738589078284,
         0.37238884252424, 7.45]
    ]

    /// BD-09 经纬度 → 百度墨卡托（米）。
    static func bd09ToMercator(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        let absLon = abs(longitude)
        let absLat = abs(latitude)
        var coefficient: [Double]?
        for (index, band) in mcBands.enumerated() where absLat >= band {
            coefficient = ll2mc[index]
            break
        }
        guard let c = coefficient else { return (0, 0) }
        let x = c[0] + c[1] * absLon
        let unit = absLat / c[9]
        var y = c[2]
        var power = unit
        for index in 3...8 {
            y += c[index] * power
            power *= unit
        }
        return (longitude < 0 ? -x : x, latitude < 0 ? -y : y)
    }

    /// 百度瓦片编号（256px）。
    static func baiduTile(latitude: Double, longitude: Double, zoom: Int) -> (x: Int, y: Int) {
        let bd = wgs84ToBd09(latitude: latitude, longitude: longitude)
        let mc = bd09ToMercator(latitude: bd.latitude, longitude: bd.longitude)
        let resolution = 0.597164283559817 * pow(2.0, Double(18 - zoom))
        let world = 20037726.37
        let x = Int(floor((mc.x + world) / (256.0 * resolution)))
        let y = Int(floor((world - mc.y) / (256.0 * resolution)))
        return (x, y)
    }

    private static func transformLatitude(_ x: Double, _ y: Double) -> Double {
        var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        result += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return result
    }

    private static func transformLongitude(_ x: Double, _ y: Double) -> Double {
        var result = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        result += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return result
    }
}
