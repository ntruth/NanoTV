import Foundation
import LumaCore
import PlaybackCore

/// 命令行环境没有 XCTest，这里用最小断言集跑纯逻辑检查：
/// `swift run LumaCoreChecks`，任一断言失败即以非零码退出。
private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS  \(message)")
    } else {
        failures += 1
        print("FAIL  \(message)")
    }
}

private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    expect(lhs == rhs, "\(message)（实际 \(lhs)，期望 \(rhs)）")
}

private func expectClose(_ lhs: CGFloat, _ rhs: CGFloat, accuracy: CGFloat, _ message: String) {
    expect(abs(lhs - rhs) <= accuracy, "\(message)（实际 \(lhs)，期望 \(rhs)）")
}

// MARK: - ThumbnailSizing

expectEqual(ThumbnailSizing.bucket(for: 1), 128, "最小档位为 128")
expectEqual(ThumbnailSizing.bucket(for: 128), 128, "128 命中自身档位")
expectEqual(ThumbnailSizing.bucket(for: 129), 192, "129 向上取整到 192")
expectEqual(ThumbnailSizing.bucket(for: 480), 512, "480 向上取整到 512")
expectEqual(ThumbnailSizing.bucket(for: 5_000), 1024, "超出上限收敛到 1024")
expectEqual(ThumbnailSizing.quickPixel, 192, "快速层固定 192")

// MARK: - GridLayout

expectEqual(GridLayout.columns(contentWidth: 1000, targetSize: 200, spacing: 4), 4, "正方形网格列数")
expectClose(GridLayout.squareCellWidth(contentWidth: 1000, columns: 4, spacing: 4), 247,
            accuracy: 0.01, "正方形格子边长")
expectEqual(GridLayout.columns(contentWidth: 10, targetSize: 200, spacing: 4), 1, "窄容器至少一列")

let filled = GridLayout.justifiedRows(aspects: [1.5, 1.5],
                                      width: 1000,
                                      targetHeight: 500,
                                      spacing: 4)
expectEqual(filled.count, 1, "两张横图排成一行")
if let row = filled.first {
    let total = row.reduce(0) { $0 + $1.width } + CGFloat(max(0, row.count - 1)) * 4
    expectClose(total, 1000, accuracy: 0.5, "已填满的行宽度等于容器")
    expectEqual(row.map(\.index), [0, 1], "保持原始顺序")
}

let single = GridLayout.justifiedRows(aspects: [4], width: 400, targetHeight: 300, spacing: 4)
expectEqual(single.count, 1, "单张照片一行")
if let item = single.first?.first {
    expectClose(item.width, 400, accuracy: 0.5, "单张超宽照片不越界")
    expectClose(item.height, 100, accuracy: 0.5, "高度按宽高比收敛")
}

expect(GridLayout.justifiedRows(aspects: [], width: 800, targetHeight: 200, spacing: 4).isEmpty,
       "空输入不产生行")

let longRun = GridLayout.justifiedRows(aspects: Array(repeating: 4, count: 20),
                                       width: 4000, targetHeight: 10, spacing: 0)
expect(longRun.allSatisfy { $0.count <= 8 }, "单行最多 8 张")

// MARK: - 瀑布流

let masonry = GridLayout.masonryColumns(aspects: [1, 2, 0.5, 1.5, 1, 1], columns: 3)
expectEqual(masonry.count, 3, "瀑布流列数")
expectEqual(masonry.flatMap { $0 }.sorted(), Array(0..<6), "每张照片只落进一列")
expectEqual(masonry[0], [0, 4], "每次都落到当前最矮的列")
expect(GridLayout.masonryColumns(aspects: [], columns: 3).allSatisfy(\.isEmpty),
       "空输入不产生照片")
expectEqual(GridLayout.masonryColumns(aspects: [1, 2], columns: 1), [[0, 1]],
            "单列时保持原始顺序")

// MARK: - 行程分段

let consecutive = TripSegmentation.spans(placeKeys: ["a", "a", "a"],
                                         dayOrdinals: [100, 101, 102])
expectEqual(consecutive.count, 1, "同地点连续日期合并为一段")

let gap = TripSegmentation.spans(placeKeys: ["a", "a", "a"],
                                 dayOrdinals: [100, 102, 103])
expectEqual(gap, [0...0, 1...2], "隔天即另起一段")

let moved = TripSegmentation.spans(placeKeys: ["a", "b", "b"],
                                   dayOrdinals: [100, 101, 102])
expectEqual(moved, [0...0, 1...2], "地点变化即分段")

expectEqual(TripSegmentation.spans(placeKeys: [], dayOrdinals: []), [], "空输入不产生行程段")
expectEqual(TripSegmentation.spans(placeKeys: ["a"], dayOrdinals: [1]), [0...0], "单张照片单独成段")

// MARK: - 智能美化

let darkPhoto = BeautyAdvisor.advise(BeautyStats(luma: 0.18, lumaSpread: 0.2, saturation: 0.35,
                                                red: 0.20, green: 0.18, blue: 0.17,
                                                highlightClip: 0, shadowClip: 0.12,
                                                sharpness: 130))
expect(darkPhoto.exposure > 0.3, "偏暗画面提亮")
expect(darkPhoto.shadows > 0.05, "暗部补光")
expect(darkPhoto.score > BeautyAdvisor.recommendThreshold, "偏暗照片进入推荐")
expect(darkPhoto.reasons.contains { $0.contains("偏暗") }, "理由包含偏暗")

let brightPhoto = BeautyAdvisor.advise(BeautyStats(luma: 0.86, lumaSpread: 0.3, saturation: 0.4,
                                                  red: 0.90, green: 0.86, blue: 0.82,
                                                  highlightClip: 0.18, shadowClip: 0,
                                                  sharpness: 130))
expect(brightPhoto.exposure < 0, "过亮画面压暗")
expect(brightPhoto.reasons.contains { $0.contains("偏亮") }, "理由包含偏亮")

let warmPhoto = BeautyAdvisor.advise(BeautyStats(luma: 0.45, lumaSpread: 0.24, saturation: 0.4,
                                                red: 0.52, green: 0.45, blue: 0.36,
                                                highlightClip: 0, shadowClip: 0,
                                                sharpness: 130))
expect(warmPhoto.warmth < 0, "偏暖画面回正色温")
expect(warmPhoto.reasons.contains { $0.contains("偏暖") }, "理由包含偏暖")

let coldPhoto = BeautyAdvisor.advise(BeautyStats(luma: 0.45, lumaSpread: 0.24, saturation: 0.4,
                                                red: 0.36, green: 0.45, blue: 0.52,
                                                highlightClip: 0, shadowClip: 0,
                                                sharpness: 130))
expect(coldPhoto.warmth > 0, "偏冷画面回正色温")

let flatPhoto = BeautyAdvisor.advise(BeautyStats(luma: 0.46, lumaSpread: 0.08, saturation: 0.12,
                                                red: 0.46, green: 0.46, blue: 0.46,
                                                highlightClip: 0, shadowClip: 0,
                                                sharpness: 130))
expect(flatPhoto.contrast > 0.05, "低对比画面提升对比度")
expect(flatPhoto.saturation > 0.05, "低饱和画面提升饱和度")

let softPhoto = BeautyAdvisor.advise(BeautyStats(luma: 0.5, lumaSpread: 0.25, saturation: 0.4,
                                                red: 0.5, green: 0.5, blue: 0.5,
                                                highlightClip: 0, shadowClip: 0,
                                                sharpness: 20))
expect(softPhoto.sharpness > 0.1, "偏软画面提升锐度")

let cleanPhoto = BeautyAdvisor.advise(BeautyStats.neutral)
expect(cleanPhoto.score < BeautyAdvisor.recommendThreshold, "正常照片不进入推荐")
expectEqual(cleanPhoto.sharpness, 0, "无需调整时不加锐化")
expectEqual(cleanPhoto.exposure, 0, "正常曝光不调整")
expect(cleanPhoto.reasons.isEmpty, "正常照片没有理由文案")

// MARK: - JPEGMetadataStripper

// 合成一个包含 APP0 / APP1 / COM 的最小 JPEG 段结构，只用于验证字节级重建。
var jpegWithMetadata: [UInt8] = [0xFF, 0xD8]
jpegWithMetadata += [0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00]              // APP0
jpegWithMetadata += [0xFF, 0xE1, 0x00, 0x08, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00] // APP1 EXIF
jpegWithMetadata += [0xFF, 0xFE, 0x00, 0x04, 0x41, 0x42]              // COM
jpegWithMetadata += [0xFF, 0xDB, 0x00, 0x04, 0x00, 0x01]              // DQT
jpegWithMetadata += [0xFF, 0xDA, 0x00, 0x02]                          // SOS
jpegWithMetadata += [0x12, 0x34, 0x56, 0xFF, 0xD9]                    // 熵数据 + EOI

var expectedStripped: [UInt8] = [0xFF, 0xD8]
expectedStripped += [0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00]
expectedStripped += [0xFF, 0xDB, 0x00, 0x04, 0x00, 0x01]
expectedStripped += [0xFF, 0xDA, 0x00, 0x02]
expectedStripped += [0x12, 0x34, 0x56, 0xFF, 0xD9]

let stripped = JPEGMetadataStripper.strip(Data(jpegWithMetadata))
expectEqual(stripped ?? Data(), Data(expectedStripped), "无损剥离只移除 APP1 与 COM，保留图像段与压缩数据")
expectEqual(stripped?.count ?? -1, jpegWithMetadata.count - 16, "无损剥离后体积减小且像素段不变")
expectEqual(JPEGMetadataStripper.strip(Data(expectedStripped)) ?? Data(), Data(expectedStripped),
            "没有可移除元数据时字节完全不变")
expect(JPEGMetadataStripper.strip(Data([0x00, 0x01, 0x02])) == nil, "非 JPEG 数据返回 nil")
expect(JPEGMetadataStripper.strip(Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00])) == nil, "段长度不完整返回 nil")

// MARK: - 足迹回放编排

let baseTime = Date(timeIntervalSince1970: 1_800_000_000)

func sample(_ seconds: Double, _ latitude: Double, _ longitude: Double,
            _ key: String = "a", _ name: String = "杭州") -> FootprintSample {
    FootprintSample(time: baseTime.addingTimeInterval(seconds),
                    point: FootprintPoint(latitude: latitude, longitude: longitude),
                    placeKey: key,
                    placeName: name)
}

let merged = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300),
    sample(60, 30.2600, 120.1300),
    sample(120, 30.2601, 120.1301)
])
expectEqual(merged.stops.count, 1, "同一位置的连拍合并成一站")
expectEqual(merged.stops.first?.photoCount, 3, "合并后保留照片数")

let nearby = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300),
    sample(600, 30.2610, 120.1300)
])
expectEqual(nearby.stops.count, 2, "相隔约 110 米的照片仍是两站")
expectEqual(nearby.legs.count, 1, "两站之间有一段行程")
if let leg = nearby.legs.first {
    expect(leg.distance > 90 && leg.distance < 130, "近距离行程按实际米数计算")
    expect(leg.cameraDistance < 500, "近距离行程把镜头压到街区尺度")
    expect(leg.pitch >= 45, "街区行程使用大俯仰角")
    expect(leg.caption.contains("米"), "近距离行程给出米级文案")
    expect(leg.duration >= 1.5 && leg.duration <= 2.0, "近距离行程保留可辨认的移动过程")
    expectClose(CGFloat(leg.distance / leg.cameraDistance / leg.duration), 0.24,
                accuracy: 0.001, "近距离行程使用统一视觉速度")
}

let flight = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300),
    sample(3600, 39.9042, 116.4074, "b", "北京")
])
if let leg = flight.legs.first {
    expect(leg.distance > 1_000_000, "跨城距离为千米级")
    expect(leg.cameraDistance > leg.distance, "长距离航段镜头升到更高处")
    expect(leg.pitch <= 35, "长距离航段压低俯仰角")
    expect(leg.heading > 300 || leg.heading < 20, "北京在杭州北方，朝向接近正北")
    expect(leg.duration <= 2.5, "长距离航段有最长时长上限")
    expectClose(CGFloat(leg.distance / leg.cameraDistance / leg.duration), 0.24,
                accuracy: 0.001, "跨城与街区保持一致的画面速度")
}

let samePlaceLongStay = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300),
    sample(3_000, 30.2604, 120.1300),
    sample(6_000, 30.2604, 120.1301)
])
expectEqual(samePlaceLongStay.stops.count, 1, "同地点数十米内合并为一站，避免原地抖动")

let placeChange = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300, "a", "杭州"),
    sample(600, 30.2700, 120.1300, "west", "西湖")
])
expectEqual(placeChange.stops.count, 2, "地点键变化时另起一站")
expectEqual(placeChange.places, ["杭州", "西湖"], "地点名按出现顺序去重")

let monotonic = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300),
    sample(600, 30.2700, 120.1300),
    sample(1200, 30.2800, 120.1300)
])
expectEqual(monotonic.distanceToStop.count, monotonic.stops.count, "累计里程与站点数一致")
expect(monotonic.distanceToStop == monotonic.distanceToStop.sorted(), "累计里程单调递增")
expectClose(CGFloat(monotonic.totalDistance), CGFloat(monotonic.distanceToStop.last ?? 0),
            accuracy: 0.001, "总里程取最后一站的累计值")

let far = FootprintPlanner.distance(from: FootprintPoint(latitude: 0, longitude: 0),
                                    to: FootprintPoint(latitude: 1, longitude: 0))
expectClose(CGFloat(far), 111_195, accuracy: 500, "一度纬度约 111 公里")

let midpoint = FootprintPlanner.interpolate(from: FootprintPoint(latitude: 10, longitude: 20),
                                            to: FootprintPoint(latitude: 30, longitude: 40),
                                            fraction: 0.5)
expectClose(CGFloat(midpoint.latitude), 20.28, accuracy: 0.2, "大圆插值中点纬度")
expectClose(CGFloat(midpoint.longitude), 29.35, accuracy: 0.3, "大圆插值中点经度")
expect(FootprintPlanner.interpolate(from: FootprintPoint(latitude: 10, longitude: 20),
                                    to: FootprintPoint(latitude: 30, longitude: 40),
                                    fraction: -1) == FootprintPoint(latitude: 10, longitude: 20),
       "插值比例夹到 0")
expect(FootprintPlanner.interpolate(from: FootprintPoint(latitude: 10, longitude: 20),
                                    to: FootprintPoint(latitude: 30, longitude: 40),
                                    fraction: 2) == FootprintPoint(latitude: 30, longitude: 40),
       "插值比例夹到 1")

var manySamples: [FootprintSample] = []
for index in 0..<400 {
    let offset = Double(index) * 0.002
    manySamples.append(sample(Double(index) * 60, 30.0 + offset, 120.0 + offset))
}
let capped = FootprintPlanner.plan(samples: manySamples)
expect(capped.stops.count <= FootprintPlanner.maxStops, "站点数收敛到上限")
expectEqual(capped.stops.first?.point, manySamples.first?.point, "抽样保留首站")
expect(capped.stops.last?.point.latitude ?? 0 > 30.7, "抽样保留尾站")

let oneDegree = FootprintPlanner.overviewDistance(of: [
    FootprintPoint(latitude: 30, longitude: 120),
    FootprintPoint(latitude: 31, longitude: 121)
])
expect(oneDegree > 150_000, "全览镜头覆盖整段范围")

expect(FootprintPlanner.plan(samples: []).isEmpty, "没有样本时返回空计划")

// MARK: - 连续巡航时间轴

let veryShort = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300, "a", "起点"),
    sample(2_000, 30.26036, 120.1300, "b", "附近")
])
expectEqual(veryShort.stops.count, 2, "约四十米且时间断开的照片保留为两站")
expect(veryShort.legs.first?.duration ?? 0 >= 0.85, "极短行程也有最短可辨认时长")

let cruisePlan = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300, "a", "第一站"),
    sample(600, 30.2620, 120.1300, "b", "第二站"),
    sample(660, 30.2620, 120.1300, "b", "第二站"),
    sample(1_500, 30.2640, 120.1300, "c", "第三站"),
    sample(1_560, 30.2640, 120.1300, "c", "第三站")
])
let cruise = FootprintCruiseTimeline(plan: cruisePlan)
let expectedDuration = cruisePlan.legs.reduce(0) { $0 + $1.duration + $1.dwell }
expectClose(CGFloat(cruise.totalDuration), CGFloat(expectedDuration),
            accuracy: 0.0001, "总时长包含所有行进与旅拍停留")

if let firstLeg = cruisePlan.legs.first {
    let middle = cruise.frame(at: firstLeg.duration * 0.5)
    expectClose(CGFloat(middle.legFraction), 0.5, accuracy: 0.0001,
                "行进段中点使用未经缓动的线性比例")
    expectEqual(middle.head,
                FootprintPlanner.interpolate(from: cruisePlan.stops[0].point,
                                             to: cruisePlan.stops[1].point,
                                             fraction: 0.5),
                "光点与线性行程比例同步")

    let arrival = cruise.frame(at: firstLeg.duration)
    let dwelling = cruise.frame(at: firstLeg.duration + firstLeg.dwell * 0.5)
    expect(arrival.isDwelling, "抵达照片较多的站点后进入旅拍停留")
    expectEqual(dwelling.head, cruisePlan.stops[1].point, "停留期间光点保持不动")
    expectClose(CGFloat(dwelling.dwellFraction), 0.5, accuracy: 0.0001,
                "停留进度也在统一时间轴中")

    let departure = cruise.frame(at: cruise.time(atStop: 1))
    expectEqual(arrival.cameraCenter, departure.cameraCenter, "跨段时镜头中心不跳变")
    expectClose(CGFloat(arrival.cameraDistance), CGFloat(departure.cameraDistance),
                accuracy: 0.0001, "跨段时镜头高度连续")
    expectClose(CGFloat(arrival.pitch), CGFloat(departure.pitch),
                accuracy: 0.0001, "跨段时俯仰角连续")
    expectClose(CGFloat(arrival.heading), CGFloat(departure.heading),
                accuracy: 0.0001, "跨段时航向连续")
    expectEqual(arrival.head, departure.head, "跨段时光点位置连续")
    expect(!departure.isDwelling, "停留结束后直接进入下一段行进")
}

expectClose(CGFloat(cruise.time(atStop: 0)), 0, accuracy: 0.0001,
            "首站映射到时间轴起点")
if let lastLeg = cruisePlan.legs.last {
    expectClose(CGFloat(cruise.time(atStop: cruisePlan.stops.count - 1)),
                CGFloat(cruise.totalDuration - lastLeg.dwell),
                accuracy: 0.0001, "末站映射到抵达时刻而非整个时间轴末尾")
    let finalDwell = cruise.frame(at: cruise.totalDuration - lastLeg.dwell * 0.5)
    expect(finalDwell.isDwelling, "末尾旅拍停留不会提前结束旅程")
}
let completed = cruise.frame(at: cruise.totalDuration)
expect(completed.isComplete, "时间轴末尾返回完成状态")
expectEqual(completed.head, cruisePlan.stops.last?.point, "完成时光点停在最后一站")

let wrapPlan = FootprintPlanner.plan(samples: [
    sample(0, 30.0, 120.0, "a", "起点"),
    sample(600, 30.01, 119.999, "b", "西北"),
    sample(1_200, 30.02, 120.0, "c", "东北")
])
let wrapCruise = FootprintCruiseTimeline(plan: wrapPlan)
if wrapPlan.legs.count == 2 {
    let middle = wrapCruise.frame(at: wrapCruise.time(atStop: 1) + wrapPlan.legs[1].duration * 0.5)
    expect(middle.heading > 350 || middle.heading < 10, "跨段航向走最短圆弧，不从三百五十度反转半圈")
}

let emptyCruise = FootprintCruiseTimeline(plan: FootprintPlanner.plan(samples: []))
expectEqual(emptyCruise.totalDuration, 0, "空计划时间轴为零时长")
expect(emptyCruise.frame(at: 0).isComplete, "空计划直接完成")
let singleCruise = FootprintCruiseTimeline(plan: merged)
expectEqual(singleCruise.totalDuration, 0, "单站计划没有行进时长")
expect(singleCruise.frame(at: 0).isComplete, "单站计划直接完成")
expectEqual(singleCruise.frame(at: 0).head, merged.stops.first?.point, "单站光点固定在唯一站点")

// MARK: - 票据 / 证件文字判定

expect(DocumentText.isValidChineseID("11010519491231002X"), "合法 18 位身份证号（校验位 X）")
expect(!DocumentText.isValidChineseID("110105194912310021"), "校验位错误时不算合法")
expect(!DocumentText.isValidChineseID("11010519491231002"), "位数不足不算合法")
expect(!DocumentText.isValidChineseID("11010519491331002X"), "出生月份非法不算合法")
expect(DocumentText.isValidChineseID("１１０１０５１９４９１２３１００２Ｘ"), "全角数字先归一化成 ASCII 再校验")

expect(DocumentText.looksLikeIDCard("姓名 张三\n公民身份号码 11010519491231002X\n签发机关 北京市公安局"),
       "身份证字段名 + 合法号码")
expect(DocumentText.looksLikeIDCard("居民身份证"), "只出现证件标题也判定为证件")
expect(!DocumentText.looksLikeIDCard("请把身份证拍照发我"), "聊天截图里的「身份证」不算证件")

expect(DocumentText.looksLikeInvoice("增值税电子普通发票\n发票代码 011002100311\n价税合计 ¥99.00"),
       "发票强特征词命中")
expect(!DocumentText.looksLikeInvoice("今天去景区买了门票，收据放在包里"), "普通票据不算发票")
expect(!DocumentText.looksLikeInvoice(""), "空文本不算发票")

// MARK: - 地标表

expectEqual(LandmarkCatalog.nearest(latitude: 39.9163, longitude: 116.3972)?.name, "故宫",
            "坐标命中故宫")
expectEqual(LandmarkCatalog.nearest(latitude: 30.2431, longitude: 120.1487)?.name, "西湖",
            "坐标命中西湖")
expect(LandmarkCatalog.nearest(latitude: 0, longitude: 0) == nil, "没有地标的海域返回 nil")
expect(LandmarkCatalog.nearest(latitude: 30.0, longitude: 120.0) == nil,
       "距离西湖约 27 公里超过半径不算命中")
expectEqual(LandmarkCatalog.match(placeText: "浙江省杭州市西湖风景名胜区")?.name, "西湖",
            "POI 文字命中西湖")
expectEqual(LandmarkCatalog.match(placeText: "台北故宫博物院")?.name, "台北故宫博物院",
            "同时含「故宫」时取最长命中")
expectEqual(LandmarkCatalog.match(placeText: "北京市东城区景山前街4号 故宫")?.name, "故宫",
            "地址里的故宫可命中")
expect(LandmarkCatalog.match(placeText: "浦东新区张江路") == nil, "普通地址不命中地标")
if let palace = LandmarkCatalog.match(placeText: "故宫") {
    expect(LandmarkCatalog.distance(latitude: 39.9163, longitude: 116.3972, to: palace) < 1,
           "与地标同坐标时距离为 0")
}

// MARK: - 感知哈希

let flatGray = Array(repeating: UInt8(128), count: 9 * 8)
expectEqual(PerceptualHash.dHash(grayscale: flatGray), 0, "纯色图 dHash 为 0")

var decreasing: [UInt8] = []
var increasing: [UInt8] = []
for index in 0..<(9 * 8) {
    let column = index % 9
    decreasing.append(UInt8(255 - column * 20))
    increasing.append(UInt8(column * 20))
}
expectEqual(PerceptualHash.dHash(grayscale: decreasing), Int64(bitPattern: UInt64.max),
            "每行从左到右递减时 64 位全为 1")
expectEqual(PerceptualHash.dHash(grayscale: increasing), 0, "每行从左到右递增时 64 位全为 0")
expectEqual(PerceptualHash.hammingDistance(0, 0), 0, "相同哈希距离为 0")
expectEqual(PerceptualHash.hammingDistance(0, Int64(bitPattern: UInt64.max)), 64,
            "全 0 与全 1 距离为 64")
expect(PerceptualHash.isSimilar(0, 0b1111111111), "10 位以内视为相似")
expect(!PerceptualHash.isSimilar(0, Int64(bitPattern: 0b11111111111)), "超过阈值不相似")
expect(PerceptualHash.dHash(grayscale: [0, 1, 2]) == nil, "灰度数据不足返回 nil")

// MARK: - 转码档位（像素率降档）

let uhd24 = TranscodeProfile.make(sourceSize: CGSize(width: 3840, height: 2160), frameRate: 23.976)
expect(uhd24.outputSize == nil, "4K24 像素率够低，保持原分辨率")
expectEqual(uhd24.bitrate, 20_000_000, "4K 档位码率 20M")

let uhd60 = TranscodeProfile.make(sourceSize: CGSize(width: 3840, height: 2160), frameRate: 60)
expectEqual(uhd60.outputSize, CGSize(width: 2560, height: 1440), "4K60 降到 1440p")
expectEqual(uhd60.bitrate, 12_000_000, "1440p 档位码率 12M")

let scope60 = TranscodeProfile.make(sourceSize: CGSize(width: 3840, height: 1608), frameRate: 60)
expectEqual(scope60.outputSize, CGSize(width: 2866, height: 1200), "4K 宽银幕 60fps 降到 1200p")

let hd60 = TranscodeProfile.make(sourceSize: CGSize(width: 1920, height: 1080), frameRate: 60)
expect(hd60.outputSize == nil, "1080p60 不降档")
expectEqual(hd60.bitrate, 8_000_000, "1080p 档位码率 8M")

expectEqual(TranscodeProfile.make(sourceSize: .zero, frameRate: 60).bitrate, 8_000_000,
            "尺寸未知时退到 1080p 档位")

// MARK: - 色调映射链

let scaledChain = PlaybackFilters.toneMapChain(dolbyVision: true, supportsLibplacebo: true,
                                               outputWidth: 2560, outputHeight: 1440) ?? ""
expect(scaledChain.contains("w=2560") && scaledChain.contains("h=1440"),
       "libplacebo 链内联输出尺寸")
expect(scaledChain.contains("apply_dolbyvision=1"), "libplacebo 链应用 DOVI RPU")
expect(PlaybackFilters.toneMapChain(dolbyVision: true, supportsLibplacebo: false) == nil,
       "杜比视界没有 libplacebo 时返回 nil，不烘错颜色")
let zscaleChain = PlaybackFilters.toneMapChain(dolbyVision: false, supportsLibplacebo: false,
                                               outputHeight: 1440) ?? ""
expect(zscaleChain.hasPrefix("scale=-2:1440,"), "zscale 路径前置缩放")
let hdrColor = VideoColorInfo(primaries: "bt2020", transfer: "smpte2084",
                              matrix: "bt2020nc", range: "tv")
let coloredChain = PlaybackFilters.toneMapChain(dolbyVision: false, supportsLibplacebo: false,
                                                outputHeight: 1440, inputColor: hdrColor) ?? ""
expect(coloredChain.hasPrefix("setparams=color_primaries=bt2020:color_trc=smpte2084:"
                              + "colorspace=bt2020nc:range=tv,scale=-2:1440,"),
       "zscale 前用 setparams 写回帧色彩元数据")

// MARK: - 蓝光原盘

let discRoot = URL(fileURLWithPath: "/Volumes/BDMV_DISC")
let bdmvFile = discRoot.appendingPathComponent("BDMV/STREAM/00001.m2ts")
expectEqual(BluraySource.discRoot(containing: bdmvFile)?.path, discRoot.path,
            "BDMV 内的 m2ts 折叠成盘根目录")
expect(BluraySource.discRoot(containing: URL(fileURLWithPath: "/Volumes/Movie.mkv")) == nil,
       "普通视频不当作蓝光")
let isoURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("luma-check-\(UUID().uuidString).iso")
FileManager.default.createFile(atPath: isoURL.path, contents: Data())
expectEqual(BluraySource.ffmpegInput(for: isoURL), "bluray:" + isoURL.path,
            "ISO 生成 bluray 协议输入")
try? FileManager.default.removeItem(at: isoURL)

// MARK: - 蓝光/图形字幕相关的参数计划

func baseRequest(mode: StreamMode = .remux,
                 audioCodec: String? = "AC3",
                 burnSubtitleStream: Int? = nil,
                 audioPassthrough: Bool = true,
                 isRemote: Bool = false,
                 bufferProfile: BufferProfile = .smooth) -> StreamRequest {
    StreamRequest(input: "bluray:/Volumes/DISC",
                  isRemote: isRemote,
                  mode: mode,
                  startOffset: 0,
                  sessionStart: 0,
                  isHEVC: true,
                  isHDR: false,
                  supportsToneMapping: true,
                  supportsLibplacebo: true,
                  color: VideoColorInfo(),
                  sourceSize: CGSize(width: 1920, height: 1080),
                  frameRate: 23.976,
                  audioIndex: 0,
                  audioChannels: 6,
                  audioCodec: audioCodec,
                  audioPassthrough: audioPassthrough,
                  bufferProfile: bufferProfile,
                  burnSubtitle: nil,
                  burnSubtitleStream: burnSubtitleStream,
                  outputDirectory: URL(fileURLWithPath: "/tmp/out"))
}

let remuxArgs = StreamPlanner.arguments(for: baseRequest())
expect(remuxArgs.contains("copy"), "HEVC 蓝光走视频拷贝")
expect(remuxArgs.joined(separator: " ").contains("-c:a copy"), "AC-3 音轨直通")

// seek 起流：实测去掉 copyts 后时间轴仍从 0 起，首片快约 2.7×。
var seekRequest = baseRequest()
seekRequest.startOffset = 300
seekRequest.sessionStart = 297
let seekJoinedArgs = StreamPlanner.arguments(for: seekRequest).joined(separator: " ")
expect(seekJoinedArgs.contains("-noaccurate_seek -ss 300.000"),
       "seek 起流不精确 seek，音频与视频落在同一关键帧")
expect(!seekJoinedArgs.contains("-copyts"),
       "seek 起流不再保留原始时间戳（首片快约 2.7×）")
expect(seekJoinedArgs.contains("-avoid_negative_ts make_zero"), "落点前的负时间戳统一平移")

// MARK: - 网络缓冲档位

expectEqual(BufferProfile.defaultProfile, .smooth, "默认缓冲档为流畅")
expectEqual(BufferProfile.thrifty.forwardBufferDuration, 4, "省流档缓冲 4 秒")
expectEqual(BufferProfile.smooth.forwardBufferDuration, 16, "流畅档缓冲 16 秒")
expectEqual(BufferProfile.smooth.remoteReadRate, 10, "流畅档远端 10×")
let thriftyRemote = StreamPlanner.arguments(for: baseRequest(isRemote: true, bufferProfile: .thrifty))
    .joined(separator: " ")
expect(thriftyRemote.contains("-readrate 3"), "省流档远端 readrate 3")
let smoothRemote = StreamPlanner.arguments(for: baseRequest(isRemote: true, bufferProfile: .smooth))
    .joined(separator: " ")
expect(smoothRemote.contains("-readrate 10"), "流畅档远端 readrate 10")

// MARK: - 网络缓冲自适应

var adaptation = BufferAdaptationState(cooldown: 20)
let t0 = Date(timeIntervalSince1970: 1_000)
func adapt(_ current: BufferProfile, _ ceiling: BufferProfile, throughput: Double,
           required: Double, lead: Double, at offset: TimeInterval) -> BufferProfile? {
    adaptation.evaluate(current: current, ceiling: ceiling,
                        throughputBps: throughput, requiredBps: required,
                        leadSeconds: lead, now: t0.addingTimeInterval(offset))
}
expect(adapt(.smooth, .smooth, throughput: 5_000_000, required: 20_000_000,
             lead: 2, at: 0) == nil, "首次低吞吐只累计、不立刻降档")
expect(adapt(.smooth, .smooth, throughput: 5_000_000, required: 20_000_000,
             lead: 2, at: 1) == .balanced, "连续两次低吞吐降一档")
expect(adapt(.balanced, .smooth, throughput: 5_000_000, required: 20_000_000,
             lead: 2, at: 2) == nil, "冷却期内不再降档")
expect(adapt(.balanced, .smooth, throughput: 80_000_000, required: 20_000_000,
             lead: 300, at: 21) == nil, "升档需要连续三次高吞吐")
expect(adapt(.balanced, .smooth, throughput: 80_000_000, required: 20_000_000,
             lead: 300, at: 22) == nil, "第二次高吞吐仍不升档")
expect(adapt(.balanced, .smooth, throughput: 80_000_000, required: 20_000_000,
             lead: 300, at: 23) == .smooth, "连续三次高吞吐回到上限档")

var cappedAdaptation = BufferAdaptationState(cooldown: 20)
let cappedT0 = Date(timeIntervalSince1970: 2_000)
for offset in [0.0, 1.0, 2.0] {
    let result = cappedAdaptation.evaluate(current: .thrifty, ceiling: .thrifty,
                                          throughputBps: 80_000_000, requiredBps: 20_000_000,
                                          leadSeconds: 300, now: cappedT0.addingTimeInterval(offset))
    expect(result == nil, "省流档不会被自适应升到更高档（\(Int(offset))）")
}
expect(adapt(.thrifty, .thrifty, throughput: 1_000_000, required: 20_000_000,
             lead: 2, at: 30) == nil, "省流档已经最低，不能再降")

let adaptiveRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("luma-adaptive-\(UUID().uuidString)", isDirectory: true)
let adaptiveOff = PlaybackEnvironment(
    cache: PlaybackCache(root: adaptiveRoot, limitBytes: { 0 }),
    ffmpeg: nil, ffmpegForToneMap: nil, ffprobe: nil,
    supportsToneMapping: false,
    adaptiveBuffering: { false },
    record: { _ in })
expect(!adaptiveOff.adaptiveBuffering, "关闭弱网自适应后不再按网络降档")
let adaptiveDefault = PlaybackEnvironment(
    cache: PlaybackCache(root: adaptiveRoot, limitBytes: { 0 }),
    ffmpeg: nil, ffmpegForToneMap: nil, ffprobe: nil,
    supportsToneMapping: false,
    record: { _ in })
expect(!adaptiveDefault.adaptiveBuffering, "未注入时自适应默认关闭（默认固定流畅档）")
let adaptiveOn = PlaybackEnvironment(
    cache: PlaybackCache(root: adaptiveRoot, limitBytes: { 0 }),
    ffmpeg: nil, ffmpegForToneMap: nil, ffprobe: nil,
    supportsToneMapping: false,
    adaptiveBuffering: { true },
    record: { _ in })
expect(adaptiveOn.adaptiveBuffering, "选择自适应后按网络降档")

let pgssubArgs = StreamPlanner.arguments(for: baseRequest(burnSubtitleStream: 1))
let pgsJoined = pgssubArgs.joined(separator: " ")
expect(!pgsJoined.contains("-c:v copy"), "图形字幕烧录强制重编码")
expect(pgsJoined.contains("-filter_complex"), "图形字幕走 filter_complex")
expect(pgsJoined.contains("[0:s:1]overlay"), "按字幕轨序号 overlay")
expect(pgsJoined.contains("-canvas_size 1920x1080"), "字幕画布按源尺寸")
expect(!StreamPlanner.copiesVideo(mode: .remux, burnSubtitle: nil, burnSubtitleStream: 1),
       "烧录图形字幕时不能拷贝视频")

// MARK: - 音频直通 / DTS→E-AC-3 / 直通兜底

let dtsJoined = StreamPlanner.arguments(for: baseRequest(audioCodec: "DTS")).joined(separator: " ")
expect(dtsJoined.contains("-c:a eac3"), "DTS 5.1 重编码成 E-AC-3")
expect(dtsJoined.contains("-ac 6"), "E-AC-3 下混到 5.1")
expect(dtsJoined.contains("-b:a 1536k"), "E-AC-3 码率 1536k（高音质）")

let fallbackJoined = StreamPlanner.arguments(for: baseRequest(audioPassthrough: false))
    .joined(separator: " ")
expect(!fallbackJoined.contains("-c:a copy"), "直通兜底会话不拷贝音频")
expect(fallbackJoined.contains("-c:a aac"), "直通兜底会话重编码为 AAC")

// ALAC 5.1 实测：remux 后 AVPlayer 的 item.tracks 里有 soun:alac 且起播 rate=1，
// 因此 6 声道不能成为拒绝直通的理由（白名单按 codec 判定，不按声道数）。
let alacJoined = StreamPlanner.arguments(for: baseRequest(audioCodec: "ALAC"))
    .joined(separator: " ")
expect(alacJoined.contains("-c:a copy"), "ALAC 6 声道可以直通 fMP4 HLS")

var multiAudioRequest = baseRequest()
multiAudioRequest.audioTracks = [
    AudioTrackInfo(ordinal: 0, codec: "AC3", channels: 6, language: "eng", title: nil),
    AudioTrackInfo(ordinal: 1, codec: "EAC3", channels: 6, language: "jpn", title: nil)
]
expect(StreamPlanner.usesMultipleAudioTracks(for: multiAudioRequest),
       "AC-3 / E-AC-3 多音轨一次装进同一会话")
let multiNames = StreamPlanner.arguments(for: multiAudioRequest).joined(separator: " ")
expect(multiNames.contains("name:eng-1") && multiNames.contains("name:jpn-2"),
       "多音轨的分片名带序号，避免 %v 冲突")
expect(multiNames.contains("language:eng") && multiNames.contains("language:jpn"),
       "多音轨写入 LANGUAGE，AVPlayer 菜单才显示语言名而不是 Unknown / audio_2")

var sameLanguageRequest = baseRequest()
sameLanguageRequest.audioTracks = [
    AudioTrackInfo(ordinal: 0, codec: "AAC", channels: 2, language: "chi", title: nil),
    AudioTrackInfo(ordinal: 1, codec: "EAC3", channels: 6, language: "chi", title: nil)
]
let sameLanguageNames = StreamPlanner.arguments(for: sameLanguageRequest).joined(separator: " ")
expect(sameLanguageNames.contains("name:chi-1") && sameLanguageNames.contains("name:chi-2"),
       "同语言多音轨也生成互不覆盖的分片名")
multiAudioRequest.audioPassthrough = false
expect(!StreamPlanner.usesMultipleAudioTracks(for: multiAudioRequest),
       "直通兜底会话退回单音轨重编码")
multiAudioRequest.audioPassthrough = true
multiAudioRequest.isHDR = true
expect(!StreamPlanner.usesMultipleAudioTracks(for: multiAudioRequest),
       "HDR 片源退回单音轨：多音轨 master 没有 VIDEO-RANGE，AVPlayer 会报 -12927")

expect(StreamPlanner.prefersEAC3(codec: "TRUEHD", channels: 8), "TrueHD 7.1 转 E-AC-3 5.1")
expect(StreamPlanner.prefersEAC3(codec: "dts", channels: 6), "DTS 5.1 转 E-AC-3 5.1")
expect(!StreamPlanner.prefersEAC3(codec: "DTS", channels: 2), "双声道 DTS 保持 AAC")

// MARK: - 完整 HLS 缓存清单

let cacheManifest = StreamCacheManifest(
    isMultiAudio: true,
    audioTracks: [
        AudioTrackInfo(ordinal: 0, codec: "aac", channels: 2, language: "chi", title: nil),
        AudioTrackInfo(ordinal: 1, codec: "ac3", channels: 6, language: "eng", title: nil)
    ],
    cacheSignature: "v2-am-keephdr",
    isHDR: true,
    isDolbyVision: true)
if let data = try? JSONEncoder().encode(cacheManifest),
   let decoded = try? JSONDecoder().decode(StreamCacheManifest.self, from: data) {
    expect(decoded == cacheManifest, "缓存清单可完整往返音轨结构与 HDR 标记")
} else {
    expect(false, "缓存清单编解码失败")
}

// MARK: - 缓存键策略签名

let policyRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("luma-policy-\(UUID().uuidString)", isDirectory: true)
let policyEnvironment = PlaybackEnvironment(
    cache: PlaybackCache(root: policyRoot, limitBytes: { 0 }),
    ffmpeg: nil, ffmpegForToneMap: nil, ffprobe: nil,
    supportsToneMapping: true,
    supportsLibplacebo: false,
    record: { _ in })
let policyPhoto = UUID()
let hdrSignature = "v4-am-automatic"
let sdrSignature = "v4-am-tonemapsdr"

/// 造一份「播放列表完整」的缓存目录；manifest 为 false 时模拟旧版本没有清单。
func makeCachedDirectory(photoID: UUID, signature: String,
                         isHDR: Bool, isDolbyVision: Bool = false,
                         withManifest: Bool) -> URL {
    let name = signature.isEmpty ? "\(photoID.uuidString).hls"
                                 : "\(photoID.uuidString)-\(signature).hls"
    let directory = policyRoot.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8)
        .write(to: directory.appendingPathComponent("live.m3u8"))
    if withManifest {
        let info = StreamCacheManifest(isMultiAudio: false, audioTracks: [],
                                       cacheSignature: signature, isHDR: isHDR,
                                       isDolbyVision: isDolbyVision)
        if let data = try? JSONEncoder().encode(info) {
            try? data.write(to: directory.appendingPathComponent("manifest.json"))
        }
    }
    return directory
}

let hdrCacheDirectory = makeCachedDirectory(photoID: policyPhoto, signature: hdrSignature,
                                            isHDR: true, withManifest: true)
expect(VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                           photoID: policyPhoto, cacheSignature: hdrSignature),
       "策略签名一致时命中完整缓存")
expect(!VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                            photoID: policyPhoto, cacheSignature: sdrSignature),
       "换策略签名不会命中别的策略生成的缓存")
expect(!VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                            photoID: policyPhoto, cacheSignature: ""),
       "空签名不会把带签名的缓存当成命中")
expect(!VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                            photoID: policyPhoto, cacheSignature: hdrSignature,
                                            requiresSDR: true),
       "需要 SDR 时不命中 HDR remux 缓存")
let dvSignature = "v4-am-dolbyvision"
_ = makeCachedDirectory(photoID: policyPhoto, signature: dvSignature,
                        isHDR: true, isDolbyVision: true, withManifest: true)
expect(VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                           photoID: policyPhoto, cacheSignature: dvSignature,
                                           requiresSDR: true, supportsLibplacebo: false),
       "没有 libplacebo 时杜比视界无法映射，HDR 缓存仍可复用")
expect(!VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                            photoID: policyPhoto, cacheSignature: dvSignature,
                                            requiresSDR: true, supportsLibplacebo: true),
       "有 libplacebo 时要求映射，不能再复用 HDR 缓存")
expect(VideoStreamSession.cachedManifest(environment: policyEnvironment, photoID: policyPhoto,
                                         cacheSignature: hdrSignature)?.isHDR == true,
       "命中缓存能读回 HDR 标记")
expect(VideoStreamSession.cachedManifest(environment: policyEnvironment, photoID: policyPhoto,
                                         cacheSignature: sdrSignature) == nil,
       "签名不一致读不到别人的缓存清单")

// 旧版本目录没有清单：即使播放列表完整，也不能被当前策略命中。
_ = makeCachedDirectory(photoID: policyPhoto, signature: "v4-as-automatic",
                        isHDR: false, withManifest: false)
expect(!VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                            photoID: policyPhoto, cacheSignature: "v4-as-automatic"),
       "缺少策略清单的旧缓存不算命中")

// 无签名目录（`<photoID>.hls`）不再命中，启动清理会把它删掉。
let legacyCacheDirectory = makeCachedDirectory(photoID: policyPhoto, signature: "",
                                               isHDR: false, withManifest: true)
let legacyTranscodeFile = policyRoot.appendingPathComponent("\(policyPhoto.uuidString).mp4")
FileManager.default.createFile(atPath: legacyTranscodeFile.path,
                               contents: Data(repeating: 0x41, count: 64))
expect(!VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                            photoID: policyPhoto, cacheSignature: ""),
       "旧的无签名缓存目录不再命中")
policyEnvironment.cache.cleanupOrphans(maxAge: 0)
expect(!FileManager.default.fileExists(atPath: legacyCacheDirectory.path),
       "启动清理删除无策略签名的旧缓存")
expect(!FileManager.default.fileExists(atPath: legacyTranscodeFile.path),
       "启动清理删除旧版整片转码 mp4")
expect(FileManager.default.fileExists(atPath: hdrCacheDirectory.path),
       "启动清理保留带策略签名的新缓存")
try? FileManager.default.removeItem(at: policyRoot)

// MARK: - 播放失败分类 / 隔行转码

let unloadableFailure = PlaybackFailure(
    error: NSError(domain: "AVFoundationErrorDomain", code: -11829),
    fallback: "-")
expect(unloadableFailure.isIncompatibleAsset, "媒体数据加载失败也走兼容转码兜底")
expect(unloadableFailure.message.contains("11829"), "失败文案带具体错误码")
let incompatibleFailure = PlaybackFailure(
    error: NSError(domain: "CoreMediaErrorDomain", code: -12927),
    fallback: "-")
expect(incompatibleFailure.isIncompatibleAsset, "CoreMedia -12927 识别为不兼容码流")

var deinterlaceRequest = baseRequest(mode: .transcode)
deinterlaceRequest.isInterlaced = true
let deinterlaceArgs = StreamPlanner.arguments(for: deinterlaceRequest).joined(separator: " ")
expect(deinterlaceArgs.contains("bwdif=mode=send_frame"), "隔行源重编码时插入去隔行滤镜")

// MARK: - 原生直读判定 / HTTP 字节区间

expect(VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                       codec: "HEVC", containerExtension: "mp4"),
       "hev1 的 HEVC MP4 实际可播，不能被 isPlayable=false 判死")
expect(!VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                        codec: "ProRes", containerExtension: "mov"),
       "ProRes 的 isPlayable=false 视为真实失败，不盲目放宽")
expect(!VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                        codec: "HEVC", containerExtension: "mp4",
                                        audioDecodable: false),
       "音轨不可解码时不放宽原生直读，避免有画面没声音")
expect(!VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                        codec: "HEVC", containerExtension: "mkv"),
       "MKV 不因 hev1 放宽原生直读")
expect(!VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                        codec: "AV1", containerExtension: "mp4"),
       "AV1 即使容器是 MP4 也不放宽")
expect(!VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: false,
                                        codec: "HEVC", containerExtension: "mp4"),
       "没有视频轨时不允许直读")

expectEqual(HTTPByteRange.parse("bytes=100-199", total: 1000),
            HTTPByteRange(start: 100, end: 199), "普通闭区间")
expectEqual(HTTPByteRange.parse("Range: bytes=900-", total: 1000),
            HTTPByteRange(start: 900, end: nil), "开放式区间")
expectEqual(HTTPByteRange.parse("bytes=-100", total: 1000),
            HTTPByteRange(start: 900, end: 999, isSuffix: true), "后缀区间取最后 N 字节")
expectEqual(HTTPByteRange.parse("bytes=900-5000", total: 1000),
            HTTPByteRange(start: 900, end: 999), "终点越界收敛到文件末尾")
expect(HTTPByteRange.parse("bytes=1000-", total: 1000) == nil, "起点越界返回 nil")
expect(HTTPByteRange.parse("bytes=200-100", total: 1000) == nil, "倒置区间返回 nil")
expect(HTTPByteRange.parse("bytes=0-1,5-6", total: 1000) == HTTPByteRange(start: 0, end: 1),
       "多段 Range 只取第一段")

// MARK: - 缓存清理不能删正在播放的目录

let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("luma-cache-\(UUID().uuidString)", isDirectory: true)
let activeCache = cacheRoot.appendingPathComponent("\(UUID().uuidString).hls", isDirectory: true)
try? FileManager.default.createDirectory(at: activeCache, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: activeCache.appendingPathComponent("live.m3u8").path,
                               contents: Data(repeating: 0x41, count: 4096))
let cache = PlaybackCache(root: cacheRoot, limitBytes: { 1 })
cache.markActive(activeCache)
cache.trimIfNeeded()
expect(FileManager.default.fileExists(atPath: activeCache.path),
       "正在播放的完整缓存不会被容量清理删除")
cache.markInactive(activeCache)
cache.trimIfNeeded()
expect(!FileManager.default.fileExists(atPath: activeCache.path),
       "取消使用标记后重新参与清理")
try? FileManager.default.removeItem(at: cacheRoot)

// MARK: - 蓝光章节（MPLS 播放列表）

func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
func be32(_ value: Int) -> [UInt8] {
    [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

/// 造一个单播放项的 MPLS：播放项时长 durationTicks（45kHz），带章节标记与角度数。
func makeMPLS(durationTicks: Int, chapterTicks: [Int], angleCount: Int = 1) -> Data {
    var item: [UInt8] = []
    item += [0x30, 0x30, 0x30, 0x30, 0x30]   // clip name "00000"
    item += [0x4D, 0x32, 0x54, 0x53]         // "M2TS"
    // flags 第 4 位是 multi_angle（位于长度字段之后的第 9、10 字节）。
    item += be16(angleCount > 1 ? 0x0010 : 0)
    item += [0]                               // stc id
    item += be32(0)                           // in_time
    item += be32(durationTicks)               // out_time
    item += [UInt8](repeating: 0, count: 8)   // UO mask
    item += [0, 0]                            // random_access_flag + still_mode
    item += be16(0)                           // still_time
    if angleCount > 1 {
        item += [UInt8(angleCount)]           // angle_count
        item += [0]                           // angle flags
    }

    var playlist: [UInt8] = []
    playlist += be16(0)                       // reserved
    playlist += be16(1)                       // 播放项数
    playlist += be16(0)                       // 子路径数
    playlist += be16(item.count) + item

    var marks: [UInt8] = []
    marks += be16(chapterTicks.count)
    for ticks in chapterTicks {
        marks += be16(0)                      // reserved
        marks += [1]                          // mark type = 章节
        marks += be16(1)                      // 播放项序号（1 起）
        marks += be32(ticks)                  // 时间戳
        marks += be16(0)                      // pid
        marks += be32(0)                      // duration
    }

    let playlistStart = 20
    let markStart = playlistStart + 4 + playlist.count
    var data: [UInt8] = Array("MPLS".utf8) + Array("0200".utf8)
    data += be32(playlistStart)
    data += be32(markStart)
    data += be32(0)
    data += be32(playlist.count) + playlist
    data += be32(marks.count) + marks
    return Data(data)
}

let disc = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("luma-bd-\(UUID().uuidString)", isDirectory: true)
let playlistDirectory = disc.appendingPathComponent("BDMV/PLAYLIST", isDirectory: true)
try? FileManager.default.createDirectory(at: playlistDirectory, withIntermediateDirectories: true)
let minute = 45_000 * 60
try? makeMPLS(durationTicks: minute * 40, chapterTicks: [0, minute * 10, minute * 25])
    .write(to: playlistDirectory.appendingPathComponent("00000.mpls"))
let discChapters = BluraySource.chapters(for: disc)
expectEqual(discChapters.count, 3, "MPLS 章节标记解析出 3 段")
if discChapters.count == 3 {
    expectClose(CGFloat(discChapters[1].start), 600, accuracy: 1, "第二章起点 10 分钟")
    expectClose(CGFloat(discChapters[2].start), 1500, accuracy: 1, "第三章起点 25 分钟")
    expectClose(CGFloat(discChapters[2].end), 2400, accuracy: 1, "最后一章到片尾")
}
try? FileManager.default.removeItem(at: disc)

// MARK: - 蓝光多角度 / 字幕语言偏好

let angleDisc = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("luma-bd-angle-\(UUID().uuidString)", isDirectory: true)
let anglePlaylistDirectory = angleDisc.appendingPathComponent("BDMV/PLAYLIST", isDirectory: true)
try? FileManager.default.createDirectory(at: anglePlaylistDirectory, withIntermediateDirectories: true)
try? makeMPLS(durationTicks: minute * 40, chapterTicks: [0, minute * 20], angleCount: 3)
    .write(to: anglePlaylistDirectory.appendingPathComponent("00000.mpls"))
expectEqual(BluraySource.angleCount(for: angleDisc), 3, "MPLS 多角度数量解析")
expect(BluraySource.playlistInfo(for: angleDisc)?.chapters.count == 2, "多角度播放列表仍解析章节")
try? FileManager.default.removeItem(at: angleDisc)

var angleRequest = baseRequest()
angleRequest.angle = 2
let angleJoined = StreamPlanner.arguments(for: angleRequest).joined(separator: " ")
expect(angleJoined.contains("-angle 2 -i bluray:"), "角度写在 -i 之前（demuxer 输入选项）")
var fileAngleRequest = baseRequest()
fileAngleRequest.input = "/tmp/luma-movie.mkv"
fileAngleRequest.angle = 2
expect(!StreamPlanner.arguments(for: fileAngleRequest).joined(separator: " ").contains("-angle"),
       "普通文件忽略角度参数")

expectEqual(SubtitlePreference.rank(language: "zh-cn"), 0, "简体中文最优先")
expectEqual(SubtitlePreference.rank(language: "chs"), 0, "chs 视为简体中文")
expectEqual(SubtitlePreference.rank(language: "zh-hant"), 1, "繁体中文次之")
expectEqual(SubtitlePreference.rank(language: "chi"), 2, "通用中文语言码")
expectEqual(SubtitlePreference.rank(language: nil, title: "中文字幕"), 2, "轨道名带中文也算中文")
expectEqual(SubtitlePreference.rank(language: "en"), 4, "英语排在中文之后")
expectEqual(SubtitlePreference.rank(language: "jpn"), 5, "其他已知语言")
expectEqual(SubtitlePreference.rank(language: "und"), 6, "未知语言最后")
expectEqual(SubtitlePreference.bestIndex(languages: ["eng", "zh-tw", "zh-cn"]), 2,
            "自动挂载挑简体中文轨")
expectEqual(SubtitlePreference.rank(externalFileName: "movie.zh-Hans.srt", baseName: "movie"), 0,
            "外挂字幕简体优先")
expectEqual(SubtitlePreference.rank(externalFileName: "movie.cht.srt", baseName: "movie"), 1,
            "外挂字幕繁体次之")
expectEqual(SubtitlePreference.rank(externalFileName: "movie.zh.srt", baseName: "movie"), 2,
            "外挂字幕通用中文")
expectEqual(SubtitlePreference.rank(externalFileName: "movie.srt", baseName: "movie"), 3,
            "无语言标记的外挂字幕居中")
expectEqual(SubtitlePreference.rank(externalFileName: "movie.en.srt", baseName: "movie"), 4,
            "外挂英文字幕排在中文之后")
expectEqual(SubtitlePreference.searchLanguageList, "zh-cn,zh-tw,en",
            "在线字幕按偏好顺序请求语言")

// MARK: - 逐轨音频策略 / 降混 / 转码编码

expectEqual(AudioPlaybackPlan.action(codec: "aac", channels: 2, downmix: .source,
                                     allowPassthrough: true, copiesVideo: true), .copy,
            "AAC 立体声直通")
expectEqual(AudioPlaybackPlan.action(codec: "ac3", channels: 6, downmix: .source,
                                     allowPassthrough: true, copiesVideo: true), .copy,
            "AC-3 5.1 直通")
expectEqual(AudioPlaybackPlan.action(codec: "dts", channels: 6, downmix: .source,
                                     allowPassthrough: true, copiesVideo: true), .eac3,
            "DTS 5.1 转 E-AC-3")
expectEqual(AudioPlaybackPlan.action(codec: "dts", channels: 6, downmix: .stereo,
                                     allowPassthrough: true, copiesVideo: true), .aac,
            "强制立体声时必须重编码")
expectEqual(AudioPlaybackPlan.action(codec: "flac", channels: 2, downmix: .source,
                                     allowPassthrough: true, copiesVideo: true), .aac,
            "FLAC 转 AAC")
expectEqual(AudioPlaybackPlan.action(codec: "ac3", channels: 6, downmix: .source,
                                     allowPassthrough: false, copiesVideo: true), .aac,
            "关闭直通后一律 AAC")

var mixedRequest = baseRequest()
mixedRequest.audioTracks = [
    AudioTrackInfo(ordinal: 0, codec: "AC3", channels: 6, language: "eng", title: nil),
    AudioTrackInfo(ordinal: 1, codec: "DTS", channels: 6, language: "chi", title: nil)
]
let mixedJoined = StreamPlanner.arguments(for: mixedRequest).joined(separator: " ")
expect(StreamPlanner.usesMultipleAudioTracks(for: mixedRequest), "混合编码也走多音轨会话")
expect(mixedJoined.contains("-c:a:0 copy"), "第一条可直通音轨仍拷贝")
expect(mixedJoined.contains("-c:a:1 eac3"), "第二条 DTS 单独转 E-AC-3")
expect(mixedJoined.contains("-ac:a:1 6"), "DTS 转 E-AC-3 固定 6 声道")
expect(mixedJoined.contains("-var_stream_map"), "混合编码仍生成多音轨 master")

var stereoRequest = baseRequest(audioCodec: "AAC")
stereoRequest.audioDownmix = .stereo
let stereoJoined = StreamPlanner.arguments(for: stereoRequest).joined(separator: " ")
expect(stereoJoined.contains("-c:a aac"), "强制立体声的多声道 AAC 必须重编码")
expect(stereoJoined.contains("-ac 2"), "强制立体声输出 2 声道")
expect(!stereoJoined.contains("-c:a copy"), "强制立体声不能走拷贝")

var efficiencyRequest = baseRequest(mode: .transcode)
efficiencyRequest.transcodeMode = .efficiency
let efficiencyJoined = StreamPlanner.arguments(for: efficiencyRequest).joined(separator: " ")
expect(efficiencyJoined.contains("-c:v hevc_videotoolbox"), "高效档使用 HEVC 编码")
expect(efficiencyJoined.contains("-tag:v hvc1"), "HEVC 输出写 hvc1 标签")
expect(efficiencyJoined.contains("-pix_fmt p010le"), "HEVC 输出 10-bit 像素格式")
expect(!efficiencyJoined.contains("-pix_fmt yuv420p"), "HEVC 输出不能退回 8-bit")

var lowPowerRequest = baseRequest(mode: .transcode)
lowPowerRequest.transcodeMode = .lowPower
let lowPowerJoined = StreamPlanner.arguments(for: lowPowerRequest).joined(separator: " ")
expect(lowPowerJoined.contains("-power_efficient 1 -prio_speed 1"), "低功耗档开启省电编码")

var compatibilityRequest = baseRequest(mode: .transcode)
compatibilityRequest.transcodeMode = .compatibility
let compatibilityJoined = StreamPlanner.arguments(for: compatibilityRequest).joined(separator: " ")
expect(compatibilityJoined.contains("-c:v h264_videotoolbox"), "兼容档仍使用 H.264")
expect(compatibilityJoined.contains("-pix_fmt yuv420p"), "H.264 输出 8-bit 4:2:0")
expectEqual(TranscodeProfile.make(sourceSize: CGSize(width: 1920, height: 1080),
                                  frameRate: 60,
                                  transcodeMode: .efficiency).codec, .hevc,
            "高效档的转码档位带 HEVC")

// MARK: - 画面比例 / 显示方式（只改显示层）

let fitLayout = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 1000),
                                            naturalSize: CGSize(width: 1600, height: 900),
                                            quarterTurns: 0,
                                            mode: .fit,
                                            preset: .source,
                                            pan: .zero)
expectClose(fitLayout.boxSize.width, 1000, accuracy: 0.01, "源比例裁剪框就是舞台")
expectClose(fitLayout.preRotationContentSize.width, 1000, accuracy: 0.01, "适应模式宽度撑满")
expectClose(fitLayout.preRotationContentSize.height, 562.5, accuracy: 0.01, "适应模式高度按片源比例")
expectClose(fitLayout.panOffset.width, 0, accuracy: 0.01, "适应模式没有可平移的余量")

let fillLayout = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 1000),
                                             naturalSize: CGSize(width: 1600, height: 900),
                                             quarterTurns: 0,
                                             mode: .fill,
                                             preset: .source,
                                             pan: CGSize(width: 1, height: 0))
expectClose(fillLayout.preRotationContentSize.height, 1000, accuracy: 0.01, "填充模式高度撑满")
expectClose(fillLayout.preRotationContentSize.width, 1777.78, accuracy: 0.05, "填充模式按比例放大")
expectClose(fillLayout.panOffset.width, 388.89, accuracy: 0.05, "右移画面用满左右余量")

let stretchLayout = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 800),
                                                naturalSize: CGSize(width: 1600, height: 900),
                                                quarterTurns: 0,
                                                mode: .stretch,
                                                preset: .source,
                                                pan: .zero)
expectClose(stretchLayout.preRotationContentSize.width, 1000, accuracy: 0.01, "拉伸模式宽度等于舞台")
expectClose(stretchLayout.preRotationContentSize.height, 800, accuracy: 0.01, "拉伸模式高度等于舞台")

let actualLayout = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 800),
                                               naturalSize: CGSize(width: 1600, height: 900),
                                               quarterTurns: 0,
                                               mode: .actualSize,
                                               preset: .source,
                                               pan: CGSize(width: 1, height: 1))
expectClose(actualLayout.preRotationContentSize.width, 1600, accuracy: 0.01, "原始像素保持片源宽度")
expectClose(actualLayout.preRotationContentSize.height, 900, accuracy: 0.01, "原始像素保持片源高度")
expectClose(actualLayout.panOffset.width, 300, accuracy: 0.01, "原始像素可左右平移超出部分")
expectClose(actualLayout.panOffset.height, 50, accuracy: 0.01, "原始像素可上下平移超出部分")

let widePreset = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 1000),
                                             naturalSize: CGSize(width: 1600, height: 900),
                                             quarterTurns: 0,
                                             mode: .fit,
                                             preset: .widescreen,
                                             pan: .zero)
expectClose(widePreset.boxSize.width, 1000, accuracy: 0.01, "16:9 裁剪框宽度")
expectClose(widePreset.boxSize.height, 562.5, accuracy: 0.01, "16:9 裁剪框高度")

let classicPreset = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 800),
                                                naturalSize: CGSize(width: 1600, height: 900),
                                                quarterTurns: 0,
                                                mode: .fit,
                                                preset: .classic,
                                                pan: .zero)
expectClose(classicPreset.boxSize.width, 1000, accuracy: 0.01, "4:3 裁剪框宽度")
expectClose(classicPreset.boxSize.height, 750, accuracy: 0.01, "4:3 裁剪框高度")

let rotatedLayout = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 600),
                                                naturalSize: CGSize(width: 1920, height: 1080),
                                                quarterTurns: 1,
                                                mode: .fit,
                                                preset: .source,
                                                pan: .zero)
expectClose(rotatedLayout.preRotationContentSize.width, 600, accuracy: 0.01, "旋转 90° 后预旋转宽度取屏幕高度")
expectClose(rotatedLayout.preRotationContentSize.height, 337.5, accuracy: 0.01, "旋转 90° 后预旋转高度按竖屏比例")

let clampedPan = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 1000),
                                             naturalSize: CGSize(width: 1600, height: 900),
                                             quarterTurns: 0,
                                             mode: .fill,
                                             preset: .source,
                                             pan: CGSize(width: 5, height: -5))
expectClose(clampedPan.panOffset.width, 388.89, accuracy: 0.05, "平移量上限收敛到 1")
expectClose(clampedPan.panOffset.height, 0, accuracy: 0.01, "没有纵向余量时纵向不平移")

expectEqual(VideoFramingMode.fill.gravity, .resizeAspectFill, "填充模式用 AVPlayerLayer 填充重力")
expectEqual(VideoFramingMode.stretch.gravity, .resize, "拉伸模式用 AVPlayerLayer 拉伸重力")
expectEqual(VideoFramingMode.actualSize.gravity, .resizeAspect, "原始像素仍按比例缩放后再由布局定尺寸")

// MARK: - 结果

if failures > 0 {
    print("\n\(failures) 项检查失败")
    exit(1)
}
print("\n全部检查通过")
