import Foundation

/// 内置地标表：用于把「名胜古迹」场景与照片的地理位置结合起来判定。
///
/// 坐标是各地标的大致中心点，半径按景区实际范围放宽；数据只用于把照片归入
/// 「名胜古迹」并给出地标名，不做导航或精确距离展示，因此允许数公里级误差。
public struct Landmark: Hashable, Sendable {
    public let name: String
    /// 名称别名：地名、POI、OCR 文字里出现任意一个即认为命中。
    public let aliases: [String]
    public let latitude: Double
    public let longitude: Double
    /// 命中半径（米）。
    public let radius: Double

    public init(name: String, aliases: [String] = [],
                latitude: Double, longitude: Double, radius: Double) {
        self.name = name
        self.aliases = aliases
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }
}

public enum LandmarkCatalog {
    /// 按坐标就近匹配：落在任一圈内取最近的一个。
    public static func nearest(latitude: Double, longitude: Double) -> Landmark? {
        guard latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180,
              !(abs(latitude) < 0.0001 && abs(longitude) < 0.0001) else { return nil }
        var best: (landmark: Landmark, meters: Double)?
        for landmark in landmarks {
            // 先用经纬度差值做便宜筛选，绝大多数照片到这一步就被排除，不做三角函数。
            let allowance = landmark.radius / 111_000 + 0.01
            guard abs(landmark.latitude - latitude) <= allowance,
                  abs(landmark.longitude - longitude) <= allowance * 1.8 else { continue }
            let meters = distance(latitude: latitude, longitude: longitude,
                                  to: landmark)
            guard meters <= landmark.radius else { continue }
            if best == nil || meters < best!.meters {
                best = (landmark, meters)
            }
        }
        return best?.landmark
    }

    /// 按地名 / POI / 识别文字匹配：取最长的命中词，避免「台北故宫」被「故宫」抢走。
    public static func match(placeText: String) -> Landmark? {
        let text = placeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var best: (landmark: Landmark, length: Int)?
        for landmark in landmarks {
            for term in [landmark.name] + landmark.aliases where text.contains(term) {
                if best == nil || term.count > best!.length {
                    best = (landmark, term.count)
                }
            }
        }
        return best?.landmark
    }

    public static func distance(latitude: Double, longitude: Double, to landmark: Landmark) -> Double {
        distance(latitude: latitude, longitude: longitude,
                 latitude2: landmark.latitude, longitude2: landmark.longitude)
    }

    /// 球面距离（米）。
    public static func distance(latitude: Double, longitude: Double,
                                latitude2: Double, longitude2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = latitude2 * .pi / 180
        let deltaLat = lat2 - lat1
        let deltaLon = (longitude2 - longitude) * .pi / 180
        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    /// 地标表：国内主要名胜 + 少量海外地标；半径按景区范围放宽到数公里。
    public static let landmarks: [Landmark] = [
        // 北京
        Landmark(name: "故宫", aliases: ["紫禁城", "故宫博物院"], latitude: 39.9163, longitude: 116.3972, radius: 1_500),
        Landmark(name: "天安门", aliases: ["天安门广场"], latitude: 39.9055, longitude: 116.3976, radius: 900),
        Landmark(name: "八达岭长城", aliases: ["八达岭", "八达岭长城景区"], latitude: 40.3562, longitude: 116.0200, radius: 4_000),
        Landmark(name: "慕田峪长城", aliases: ["慕田峪"], latitude: 40.4319, longitude: 116.5704, radius: 3_000),
        Landmark(name: "颐和园", aliases: [], latitude: 39.9999, longitude: 116.2755, radius: 2_000),
        Landmark(name: "天坛", aliases: ["天坛公园"], latitude: 39.8822, longitude: 116.4066, radius: 1_500),
        Landmark(name: "圆明园", aliases: [], latitude: 40.0080, longitude: 116.2970, radius: 2_000),
        Landmark(name: "国家体育场", aliases: ["鸟巢"], latitude: 39.9929, longitude: 116.3964, radius: 800),
        Landmark(name: "什刹海", aliases: ["后海"], latitude: 39.9400, longitude: 116.3860, radius: 1_200),
        // 上海
        Landmark(name: "外滩", aliases: ["上海外滩"], latitude: 31.2397, longitude: 121.4900, radius: 1_500),
        Landmark(name: "东方明珠", aliases: ["东方明珠塔"], latitude: 31.2397, longitude: 121.4998, radius: 800),
        Landmark(name: "豫园", aliases: ["城隍庙"], latitude: 31.2270, longitude: 121.4921, radius: 900),
        Landmark(name: "上海迪士尼", aliases: ["迪士尼乐园"], latitude: 31.1434, longitude: 121.6575, radius: 3_000),
        Landmark(name: "朱家角", aliases: ["朱家角古镇"], latitude: 31.1070, longitude: 121.0530, radius: 2_000),
        // 浙江
        Landmark(name: "西湖", aliases: ["杭州西湖", "西湖景区", "苏堤", "白堤"], latitude: 30.2431, longitude: 120.1487, radius: 4_000),
        Landmark(name: "灵隐寺", aliases: [], latitude: 30.2408, longitude: 120.1029, radius: 1_500),
        Landmark(name: "雷峰塔", aliases: [], latitude: 30.2312, longitude: 120.1489, radius: 800),
        Landmark(name: "乌镇", aliases: ["乌镇古镇"], latitude: 30.7450, longitude: 120.4900, radius: 2_500),
        // 陕西
        Landmark(name: "秦始皇兵马俑", aliases: ["兵马俑", "秦始皇帝陵"], latitude: 34.3853, longitude: 109.2785, radius: 2_500),
        Landmark(name: "大雁塔", aliases: ["大慈恩寺"], latitude: 34.2186, longitude: 108.9640, radius: 1_000),
        Landmark(name: "西安城墙", aliases: [], latitude: 34.2597, longitude: 108.9421, radius: 2_000),
        Landmark(name: "华清宫", aliases: ["华清池"], latitude: 34.3660, longitude: 109.2150, radius: 2_000),
        Landmark(name: "华山", aliases: ["华山风景区"], latitude: 34.4833, longitude: 110.0833, radius: 6_000),
        // 西藏
        Landmark(name: "布达拉宫", aliases: ["布宫"], latitude: 29.6578, longitude: 91.1172, radius: 1_200),
        Landmark(name: "大昭寺", aliases: [], latitude: 29.6528, longitude: 91.1320, radius: 800),
        Landmark(name: "纳木错", aliases: ["纳木措"], latitude: 30.7000, longitude: 90.6000, radius: 15_000),
        // 四川
        Landmark(name: "九寨沟", aliases: ["九寨沟景区"], latitude: 33.2600, longitude: 103.9180, radius: 12_000),
        Landmark(name: "黄龙", aliases: ["黄龙景区"], latitude: 32.7550, longitude: 103.8200, radius: 10_000),
        Landmark(name: "峨眉山", aliases: ["峨眉山景区"], latitude: 29.5200, longitude: 103.3340, radius: 12_000),
        Landmark(name: "乐山大佛", aliases: [], latitude: 29.5450, longitude: 103.7710, radius: 2_000),
        Landmark(name: "都江堰", aliases: ["都江堰景区"], latitude: 31.0020, longitude: 103.6110, radius: 3_000),
        Landmark(name: "青城山", aliases: [], latitude: 30.9000, longitude: 103.5670, radius: 6_000),
        Landmark(name: "稻城亚丁", aliases: ["亚丁景区"], latitude: 28.4350, longitude: 100.3300, radius: 15_000),
        // 湖南
        Landmark(name: "张家界", aliases: ["武陵源", "张家界国家森林公园"], latitude: 29.3157, longitude: 110.4344, radius: 12_000),
        Landmark(name: "凤凰古城", aliases: ["凤凰古镇"], latitude: 27.9500, longitude: 109.5900, radius: 2_500),
        Landmark(name: "岳阳楼", aliases: [], latitude: 29.3570, longitude: 113.0950, radius: 1_000),
        // 广西
        Landmark(name: "漓江", aliases: ["桂林漓江"], latitude: 25.1000, longitude: 110.4000, radius: 20_000),
        Landmark(name: "象鼻山", aliases: [], latitude: 25.2670, longitude: 110.2960, radius: 1_200),
        Landmark(name: "阳朔西街", aliases: ["阳朔", "西街"], latitude: 24.7780, longitude: 110.4960, radius: 3_000),
        Landmark(name: "龙脊梯田", aliases: ["龙胜梯田"], latitude: 25.8000, longitude: 110.1200, radius: 10_000),
        // 云南
        Landmark(name: "丽江古城", aliases: ["大研古城"], latitude: 26.8721, longitude: 100.2299, radius: 2_500),
        Landmark(name: "玉龙雪山", aliases: [], latitude: 27.1000, longitude: 100.1800, radius: 10_000),
        Landmark(name: "大理古城", aliases: [], latitude: 25.6960, longitude: 100.1560, radius: 2_000),
        Landmark(name: "洱海", aliases: [], latitude: 25.7800, longitude: 100.1900, radius: 12_000),
        Landmark(name: "泸沽湖", aliases: [], latitude: 27.7000, longitude: 100.7900, radius: 10_000),
        Landmark(name: "普达措", aliases: ["普达措国家公园"], latitude: 27.9000, longitude: 99.9800, radius: 10_000),
        Landmark(name: "元阳梯田", aliases: [], latitude: 23.1000, longitude: 102.7500, radius: 15_000),
        // 贵州
        Landmark(name: "黄果树瀑布", aliases: ["黄果树"], latitude: 25.9917, longitude: 105.6670, radius: 4_000),
        Landmark(name: "荔波小七孔", aliases: ["小七孔"], latitude: 25.2600, longitude: 107.7000, radius: 6_000),
        // 福建
        Landmark(name: "鼓浪屿", aliases: ["厦门鼓浪屿"], latitude: 24.4470, longitude: 118.0670, radius: 2_000),
        Landmark(name: "武夷山", aliases: ["武夷山景区"], latitude: 27.7300, longitude: 117.6700, radius: 15_000),
        Landmark(name: "福建土楼", aliases: ["永定土楼", "南靖土楼", "土楼"], latitude: 24.6600, longitude: 117.0000, radius: 20_000),
        // 安徽
        Landmark(name: "黄山", aliases: ["黄山风景区"], latitude: 30.1340, longitude: 118.1610, radius: 12_000),
        Landmark(name: "宏村", aliases: [], latitude: 29.9990, longitude: 117.9880, radius: 2_500),
        Landmark(name: "西递", aliases: [], latitude: 29.9000, longitude: 117.9900, radius: 2_000),
        // 山东
        Landmark(name: "泰山", aliases: ["泰山风景区"], latitude: 36.2544, longitude: 117.1000, radius: 8_000),
        Landmark(name: "趵突泉", aliases: [], latitude: 36.6610, longitude: 117.0150, radius: 800),
        Landmark(name: "曲阜三孔", aliases: ["孔庙", "孔府", "孔林"], latitude: 35.5960, longitude: 116.9860, radius: 2_500),
        Landmark(name: "栈桥", aliases: ["青岛栈桥"], latitude: 36.0600, longitude: 120.3200, radius: 1_000),
        // 河南
        Landmark(name: "少林寺", aliases: ["嵩山少林寺"], latitude: 34.5070, longitude: 112.9350, radius: 3_000),
        Landmark(name: "龙门石窟", aliases: [], latitude: 34.5500, longitude: 112.4700, radius: 2_000),
        Landmark(name: "云台山", aliases: [], latitude: 35.4200, longitude: 113.4000, radius: 12_000),
        // 山西
        Landmark(name: "平遥古城", aliases: ["平遥"], latitude: 37.2000, longitude: 112.1700, radius: 3_000),
        Landmark(name: "云冈石窟", aliases: [], latitude: 40.1100, longitude: 113.1200, radius: 2_500),
        Landmark(name: "五台山", aliases: [], latitude: 39.0000, longitude: 113.5900, radius: 15_000),
        // 甘肃
        Landmark(name: "莫高窟", aliases: ["敦煌莫高窟", "千佛洞"], latitude: 40.0400, longitude: 94.8000, radius: 3_000),
        Landmark(name: "鸣沙山月牙泉", aliases: ["鸣沙山", "月牙泉"], latitude: 40.0900, longitude: 94.6700, radius: 5_000),
        Landmark(name: "嘉峪关", aliases: ["嘉峪关关城"], latitude: 39.8000, longitude: 98.2200, radius: 3_000),
        Landmark(name: "张掖丹霞", aliases: ["七彩丹霞"], latitude: 38.9300, longitude: 100.1300, radius: 8_000),
        // 新疆 / 青海
        Landmark(name: "天山天池", aliases: ["天池"], latitude: 43.8900, longitude: 88.1200, radius: 6_000),
        Landmark(name: "喀纳斯", aliases: ["喀纳斯湖"], latitude: 48.7000, longitude: 87.0000, radius: 20_000),
        Landmark(name: "青海湖", aliases: [], latitude: 36.9000, longitude: 100.2000, radius: 30_000),
        Landmark(name: "茶卡盐湖", aliases: ["茶卡"], latitude: 36.7000, longitude: 99.0800, radius: 10_000),
        // 海南 / 广东 / 港澳台
        Landmark(name: "亚龙湾", aliases: [], latitude: 18.2200, longitude: 109.6400, radius: 5_000),
        Landmark(name: "天涯海角", aliases: [], latitude: 18.2980, longitude: 109.3700, radius: 2_000),
        Landmark(name: "广州塔", aliases: ["小蛮腰"], latitude: 23.1066, longitude: 113.3246, radius: 1_000),
        Landmark(name: "世界之窗", aliases: ["深圳世界之窗"], latitude: 22.5350, longitude: 113.9730, radius: 1_000),
        Landmark(name: "珠海长隆", aliases: ["长隆海洋王国"], latitude: 22.0960, longitude: 113.5400, radius: 4_000),
        Landmark(name: "维多利亚港", aliases: ["维港"], latitude: 22.2930, longitude: 114.1690, radius: 2_000),
        Landmark(name: "香港迪士尼", aliases: ["香港迪士尼乐园"], latitude: 22.3130, longitude: 114.0410, radius: 2_500),
        Landmark(name: "大三巴牌坊", aliases: ["大三巴"], latitude: 22.1970, longitude: 113.5410, radius: 800),
        Landmark(name: "台北101", aliases: [], latitude: 25.0340, longitude: 121.5645, radius: 800),
        Landmark(name: "台北故宫博物院", aliases: ["台北故宫"], latitude: 25.1020, longitude: 121.5480, radius: 1_200),
        Landmark(name: "日月潭", aliases: [], latitude: 23.8650, longitude: 120.9100, radius: 5_000),
        Landmark(name: "阿里山", aliases: [], latitude: 23.5100, longitude: 120.8000, radius: 10_000),
        // 海外
        Landmark(name: "埃菲尔铁塔", aliases: ["Eiffel Tower"], latitude: 48.8584, longitude: 2.2945, radius: 700),
        Landmark(name: "卢浮宫", aliases: ["Louvre"], latitude: 48.8606, longitude: 2.3376, radius: 700),
        Landmark(name: "自由女神像", aliases: ["Statue of Liberty"], latitude: 40.6892, longitude: -74.0445, radius: 700),
        Landmark(name: "时代广场", aliases: ["Times Square"], latitude: 40.7580, longitude: -73.9855, radius: 500),
        Landmark(name: "金门大桥", aliases: ["Golden Gate Bridge"], latitude: 37.8199, longitude: -122.4783, radius: 1_500),
        Landmark(name: "大本钟", aliases: ["Big Ben"], latitude: 51.5007, longitude: -0.1246, radius: 500),
        Landmark(name: "伦敦塔桥", aliases: ["Tower Bridge"], latitude: 51.5055, longitude: -0.0754, radius: 500),
        Landmark(name: "罗马斗兽场", aliases: ["Colosseum"], latitude: 41.8902, longitude: 12.4922, radius: 600),
        Landmark(name: "圣家族大教堂", aliases: ["Sagrada Familia"], latitude: 41.4036, longitude: 2.1744, radius: 500),
        Landmark(name: "吉萨金字塔", aliases: ["Pyramids of Giza"], latitude: 29.9792, longitude: 31.1342, radius: 6_000),
        Landmark(name: "悉尼歌剧院", aliases: ["Sydney Opera House"], latitude: -33.8568, longitude: 151.2153, radius: 600),
        Landmark(name: "富士山", aliases: ["Mount Fuji"], latitude: 35.3606, longitude: 138.7274, radius: 20_000),
        Landmark(name: "清水寺", aliases: ["Kiyomizu-dera"], latitude: 34.9949, longitude: 135.7850, radius: 800),
        Landmark(name: "东京晴空塔", aliases: ["Tokyo Skytree"], latitude: 35.7101, longitude: 139.8107, radius: 800),
        Landmark(name: "哈利法塔", aliases: ["Burj Khalifa"], latitude: 25.1972, longitude: 55.2744, radius: 600),
        Landmark(name: "尼亚加拉瀑布", aliases: ["Niagara Falls"], latitude: 43.0799, longitude: -79.0747, radius: 4_000)
    ]
}
