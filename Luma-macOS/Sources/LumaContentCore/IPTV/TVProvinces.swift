import Foundation

/// 地方台的省份归类：把「北京卫视」「滁州新闻频道」「深圳都市」这类频道
/// 归到所在省份，供频道墙按省份聚合展示。
///
/// 判定顺序：央视 → 省名开头 → 卫视品牌别名 → 城市名 → 其他。
/// 纯字符串规则，不联网、不依赖 EPG，可以在检查用例里逐条断言。
public enum TVProvinces {
    public static let central = "央视"
    public static let other = "其他"

    /// 展示顺序按行政区划排列，央视置顶，未知归入「其他」。
    public static let ordered: [String] = [
        central,
        "北京", "天津", "河北", "山西", "内蒙古",
        "辽宁", "吉林", "黑龙江",
        "上海", "江苏", "浙江", "安徽", "福建", "江西", "山东",
        "河南", "湖北", "湖南", "广东", "广西", "海南",
        "重庆", "四川", "贵州", "云南", "西藏",
        "陕西", "甘肃", "青海", "宁夏", "新疆",
        "香港", "澳门", "台湾",
        other
    ]

    /// 央视与 CGTN：单独成一节，不按省份拆分。
    public static func isCentral(_ name: String) -> Bool {
        let value = normalize(name)
        guard !value.isEmpty else { return false }
        let upper = value.uppercased()
        if upper.hasPrefix("CCTV") || upper.hasPrefix("CGTN") { return true }
        return value.contains("央视") || value.contains("中央电视台")
    }

    /// 返回频道所属省级行政区；判定不出时返回 nil。
    public static func province(for name: String, key: String = "") -> String? {
        let value = normalize(name)
        guard !value.isEmpty, !isCentral(value) else { return nil }

        // 1. 省名直接开头：北京卫视、广东体育、浙江新闻…
        for province in provinceNamesByLength where value.hasPrefix(province) {
            return province
        }
        // 2. 省名出现在任意位置：中国教育电视台等前缀干扰时兜底。
        for province in provinceNamesByLength where value.contains(province) {
            return province
        }
        // 3. 卫视品牌字：东方卫视 / 东南卫视 / 大湾区卫视…
        if value.contains("卫视") {
            for (brand, province) in satelliteBrandsByLength where value.contains(brand) {
                return province
            }
        }
        // 4. 城市名：滁州新闻频道、深圳都市、苏州生活…
        for (city, province) in citiesByLength where value.contains(city) {
            return province
        }
        // 5. 常见地面频道品牌。
        for (brand, province) in channelBrandsByLength where value.contains(brand) {
            return province
        }
        return nil
    }

    /// 频道的聚合分区：央视 / 省份 / 其他。
    public static func section(for name: String, key: String = "") -> String {
        if isCentral(name) { return central }
        return province(for: name, key: key) ?? other
    }

    public static func rank(_ section: String) -> Int {
        ordered.firstIndex(of: section) ?? ordered.count
    }

    /// 省级卫视在省份内排前面：用户先看省台，再看城市台。
    public static func isSatellite(_ name: String) -> Bool {
        normalize(name).contains("卫视")
    }

    // MARK: - 规则数据

    private static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉译名后缀「（日本）」与画质标记，避免干扰省市匹配。
        if let bracket = value.firstIndex(where: { $0 == "（" || $0 == "(" }) {
            value = String(value[value.startIndex..<bracket])
        }
        for token in ["超高清", "高清", "标清", "4K", "8K", "HD", "UHD"] {
            value = value.replacingOccurrences(of: token, with: "")
        }
        return value.replacingOccurrences(of: " ", with: "")
    }

    private static let provinceNamesByLength: [String] = [
        "内蒙古", "黑龙江", "北京", "天津", "河北", "山西", "辽宁", "吉林",
        "上海", "江苏", "浙江", "安徽", "福建", "江西", "山东", "河南",
        "湖北", "湖南", "广东", "广西", "海南", "重庆", "四川", "贵州",
        "云南", "西藏", "陕西", "甘肃", "青海", "宁夏", "新疆",
        "香港", "澳门", "台湾"
    ].sorted { $0.count > $1.count }

    /// 不带省名的省级卫视品牌。
    private static let satelliteBrands: [String: String] = [
        "东方": "上海",
        "东南": "福建",
        "海峡": "福建",
        "南方": "广东",
        "大湾区": "广东",
        "深圳": "广东",
        "厦门": "福建",
        "延边": "吉林",
        "三沙": "海南",
        "康巴": "四川",
        "安多": "青海",
        "农林": "陕西",
        "兵团": "新疆"
    ]

    private static let satelliteBrandsByLength: [(String, String)] =
        satelliteBrands.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }

    /// 常见地面频道品牌（不含「卫视」字样）。
    private static let channelBrands: [String: String] = [
        "卡酷": "北京",
        "金鹰": "湖南",
        "优漫": "江苏",
        "嘉佳": "广东",
        "哈哈炫动": "上海",
        "炫动": "上海",
        "南方经视": "广东",
        "珠江": "广东",
        "大湾区": "广东"
    ]

    private static let channelBrandsByLength: [(String, String)] =
        channelBrands.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }

    private static let citiesByProvince: [String: [String]] = [
        "北京": [],
        "天津": [],
        "河北": ["石家庄", "唐山", "秦皇岛", "邯郸", "邢台", "保定", "张家口",
                "承德", "沧州", "廊坊", "衡水"],
        "山西": ["太原", "大同", "阳泉", "长治", "晋城", "朔州", "晋中", "运城",
                "忻州", "临汾", "吕梁"],
        "内蒙古": ["呼和浩特", "包头", "乌海", "赤峰", "通辽", "鄂尔多斯", "呼伦贝尔",
                 "巴彦淖尔", "乌兰察布", "兴安盟", "锡林郭勒", "阿拉善"],
        "辽宁": ["沈阳", "大连", "鞍山", "抚顺", "本溪", "丹东", "锦州", "营口",
                "阜新", "辽阳", "盘锦", "铁岭", "朝阳", "葫芦岛"],
        "吉林": ["长春", "吉林", "四平", "辽源", "通化", "白山", "松原", "白城", "延边"],
        "黑龙江": ["哈尔滨", "齐齐哈尔", "鸡西", "鹤岗", "双鸭山", "大庆", "伊春",
                 "佳木斯", "七台河", "牡丹江", "黑河", "绥化", "大兴安岭"],
        "上海": [],
        "江苏": ["南京", "无锡", "徐州", "常州", "苏州", "南通", "连云港", "淮安",
                "盐城", "扬州", "镇江", "泰州", "宿迁"],
        "浙江": ["杭州", "宁波", "温州", "嘉兴", "湖州", "绍兴", "金华", "衢州",
                "舟山", "台州", "丽水"],
        "安徽": ["合肥", "芜湖", "蚌埠", "淮南", "马鞍山", "淮北", "铜陵", "安庆",
                "黄山", "滁州", "阜阳", "宿州", "六安", "亳州", "池州", "宣城"],
        "福建": ["福州", "厦门", "莆田", "三明", "泉州", "漳州", "南平", "龙岩", "宁德"],
        "江西": ["南昌", "景德镇", "萍乡", "九江", "新余", "鹰潭", "赣州", "吉安",
                "宜春", "抚州", "上饶"],
        "山东": ["济南", "青岛", "淄博", "枣庄", "东营", "烟台", "潍坊", "济宁",
                "泰安", "威海", "日照", "临沂", "德州", "聊城", "滨州", "菏泽"],
        "河南": ["郑州", "开封", "洛阳", "平顶山", "安阳", "鹤壁", "新乡", "焦作",
                "濮阳", "许昌", "漯河", "三门峡", "南阳", "商丘", "信阳", "周口",
                "驻马店", "济源"],
        "湖北": ["武汉", "黄石", "十堰", "宜昌", "襄阳", "鄂州", "荆门", "孝感",
                "荆州", "黄冈", "咸宁", "随州", "恩施", "仙桃", "潜江", "天门", "神农架"],
        "湖南": ["长沙", "株洲", "湘潭", "衡阳", "邵阳", "岳阳", "常德", "张家界",
                "益阳", "郴州", "永州", "怀化", "娄底", "湘西"],
        "广东": ["广州", "韶关", "深圳", "珠海", "汕头", "佛山", "江门", "湛江",
                "茂名", "肇庆", "惠州", "梅州", "汕尾", "河源", "阳江", "清远",
                "东莞", "中山", "潮州", "揭阳", "云浮"],
        "广西": ["南宁", "柳州", "桂林", "梧州", "北海", "防城港", "钦州", "贵港",
                "玉林", "百色", "贺州", "河池", "来宾", "崇左"],
        "海南": ["海口", "三亚", "三沙", "儋州", "琼海", "文昌", "万宁", "五指山"],
        "重庆": [],
        "四川": ["成都", "自贡", "攀枝花", "泸州", "德阳", "绵阳", "广元", "遂宁",
                "内江", "乐山", "南充", "眉山", "宜宾", "广安", "达州", "雅安",
                "巴中", "资阳", "阿坝", "甘孜", "凉山"],
        "贵州": ["贵阳", "六盘水", "遵义", "安顺", "毕节", "铜仁", "黔西南", "黔东南", "黔南"],
        "云南": ["昆明", "曲靖", "玉溪", "保山", "昭通", "丽江", "普洱", "临沧",
                "楚雄", "红河", "文山", "西双版纳", "大理", "德宏", "怒江", "迪庆"],
        "西藏": ["拉萨", "日喀则", "昌都", "林芝", "山南", "那曲", "阿里"],
        "陕西": ["西安", "铜川", "宝鸡", "咸阳", "渭南", "延安", "汉中", "榆林",
                "安康", "商洛"],
        "甘肃": ["兰州", "嘉峪关", "金昌", "白银", "天水", "武威", "张掖", "平凉",
                "酒泉", "庆阳", "定西", "陇南", "临夏", "甘南"],
        "青海": ["西宁", "海东", "海北", "黄南", "果洛", "玉树", "海西"],
        "宁夏": ["银川", "石嘴山", "吴忠", "固原", "中卫"],
        "新疆": ["乌鲁木齐", "克拉玛依", "吐鲁番", "哈密", "昌吉", "博尔塔拉",
                "巴音郭楞", "阿克苏", "克孜勒苏", "喀什", "和田", "伊犁",
                "塔城", "阿勒泰", "石河子", "阿拉尔", "图木舒克", "五家渠"],
        "香港": [],
        "澳门": [],
        "台湾": []
    ]

    private static let citiesByLength: [(String, String)] = citiesByProvince
        .flatMap { province, cities in cities.map { ($0, province) } }
        .sorted { $0.0.count > $1.0.count }
}
