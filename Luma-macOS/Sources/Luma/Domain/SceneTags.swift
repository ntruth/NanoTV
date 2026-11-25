import Foundation
import LumaCore

/// 场景分类：由端侧识别标签聚合而来，用于侧边栏「场景」与语义搜索。
struct SceneCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    /// 旧版权威标签（Vision 英文标签），用于兼容历史分析结果。
    let labels: Set<String>
    /// 新模型的统一中文标准标签。
    var tags: Set<String> = []
    /// OCR 文字关键词：票据、证件、名胜这类没有分类标签的对象靠文字判定。
    var keywords: [String] = []
}

/// 端侧智能分析结果（场景标签 + OCR 文本），只保存在当前图库。
struct PhotoAnalysis: Hashable {
    let labels: Set<String>
    let text: String
    /// 预先拼好的小写检索串（标签 + 文字），搜索时直接 contains。
    let searchBlob: String

    /// 是否属于某个场景：命中标准标签 / 旧的 Vision 标签，或命中 OCR 关键词。
    func belongs(to category: SceneCategory) -> Bool {
        if !category.tags.isEmpty, !category.tags.isDisjoint(with: labels) { return true }
        if !category.labels.isDisjoint(with: labels) { return true }
        guard !category.keywords.isEmpty, !text.isEmpty else { return false }
        return category.keywords.contains { text.contains($0) }
    }
}

/// 「查找相似照片」的临时范围。
struct SimilarityScope: Equatable {
    let sourceID: UUID
    let title: String
    let ids: Set<UUID>
}

/// 场景目录与中英检索词表。
enum SceneCatalog {
    static let categories: [SceneCategory] = [
        SceneCategory(id: "people", title: "人物", icon: "person.crop.square", labels: [
            "person", "people", "human", "portrait", "selfie", "face", "crowd", "baby", "child"
        ], tags: [
            "人物", "自拍", "合影", "情侣", "全家福", "儿童", "婴儿", "老人", "人群",
            "单人肖像", "微笑", "婚纱", "运动人物", "脸部特写", "上半身", "全身", "背影", "侧脸"
        ]),
        SceneCategory(id: "animals", title: "动物", icon: "pawprint", labels: [
            "animal", "dog", "puppy", "cat", "kitten", "bird", "fish", "horse", "cattle",
            "pet", "wildlife", "mammal", "insect", "reptile", "zoo"
        ], tags: [
            "猫", "狗", "鸟", "鱼", "马", "牛", "羊", "猪", "鸡", "兔子", "仓鼠", "鹦鹉",
            "野生动物", "昆虫", "蝴蝶", "蜜蜂", "水母", "螃蟹", "熊猫", "猴子", "大象",
            "狮子", "老虎", "鹿", "松鼠", "企鹅"
        ]),
        SceneCategory(id: "pets", title: "宠物", icon: "cat", labels: [
            "cat", "kitten", "adult_cat", "dog", "puppy", "bulldog", "sheepdog", "rabbit",
            "hamster", "parrot", "pet"
        ], tags: ["猫", "狗", "兔子", "仓鼠", "鹦鹉"]),
        SceneCategory(id: "farm", title: "畜牧农场", icon: "hare", labels: [
            "cow", "cattle", "sheep", "goat", "pig", "horse", "chicken", "rooster", "duck",
            "donkey", "llama", "farm"
        ], tags: ["牛", "羊", "猪", "鸡", "马"]),
        SceneCategory(id: "birds", title: "鸟类", icon: "bird", labels: [
            "bird", "hummingbird", "parrot", "owl", "eagle", "seagull", "penguin", "flamingo",
            "swan", "duck", "birdhouse"
        ], tags: ["鸟", "鹦鹉", "企鹅"]),
        SceneCategory(id: "marine", title: "鱼与海洋生物", icon: "fish", labels: [
            "fish", "clownfish", "angelfish", "shark", "whale", "dolphin", "jellyfish",
            "octopus", "crab", "lobster", "seashell", "coral", "fishtank"
        ], tags: ["鱼", "水母", "螃蟹", "海鲜"]),
        SceneCategory(id: "plants", title: "植物花卉", icon: "camera.macro", labels: [
            "plant", "decorative_plant", "flower", "flower_arrangement", "sunflower", "tree",
            "oak_tree", "maple_tree", "palm_tree", "eucalyptus_tree", "christmas_tree",
            "cactus", "fern", "garden"
        ], tags: ["花", "树", "草地", "叶子", "仙人掌", "盆栽", "樱花", "向日葵"]),
        SceneCategory(id: "nature", title: "自然风景", icon: "leaf", labels: [
            "nature", "outdoor", "landscape", "scenery", "mountain", "hill", "tree", "forest",
            "plant", "grass", "flower", "sky", "cloud", "sunset", "sunrise", "beach", "seashore",
            "coast", "ocean", "sea", "water", "lake", "river", "waterfall", "snow", "desert",
            "garden", "park"
        ], tags: [
            "海边", "湖泊", "河流", "瀑布", "山脉", "森林", "草原", "沙漠", "雪景", "花园",
            "公园", "星空", "日落", "日出", "天空", "云朵", "彩虹", "雾", "雨", "乡村"
        ]),
        SceneCategory(id: "food", title: "食物", icon: "fork.knife", labels: [
            "food", "meal", "dish", "cuisine", "dessert", "cake", "bread", "fruit",
            "vegetable", "drink", "beverage", "coffee", "tea", "wine"
        ], tags: [
            "美食", "中餐", "火锅", "烧烤", "寿司", "披萨", "汉堡", "面条", "米饭", "饺子",
            "汤", "海鲜", "甜点", "蛋糕", "面包", "水果", "蔬菜", "沙拉", "冰淇淋",
            "咖啡", "茶", "饮料", "酒", "早餐", "零食"
        ]),
        SceneCategory(id: "architecture", title: "建筑", icon: "building.2", labels: [
            "building", "architecture", "house", "bridge", "tower", "skyscraper", "church",
            "temple", "castle", "city", "urban", "street"
        ], tags: [
            "建筑", "房屋", "桥梁", "寺庙", "教堂", "城堡", "塔", "城市", "街道", "古镇", "乡村"
        ]),
        SceneCategory(id: "transport", title: "交通", icon: "car.fill", labels: [
            "vehicle", "car", "automobile", "bicycle", "bike", "motorcycle", "train",
            "airplane", "aircraft", "boat", "ship", "truck", "bus", "road", "traffic"
        ], tags: ["自行车", "汽车", "摩托车", "飞机", "公交车", "火车", "船"]),
        SceneCategory(id: "indoor", title: "室内", icon: "sofa", labels: [
            "indoor", "room", "interior", "furniture", "table", "chair", "sofa", "bedroom",
            "bathroom", "kitchen", "office", "classroom", "store", "shop"
        ], tags: [
            "室内", "咖啡馆", "餐厅", "厨房", "卧室", "客厅", "办公室", "教室", "商场",
            "超市", "机场", "车站", "地铁", "酒店", "博物馆", "图书馆"
        ]),
        SceneCategory(id: "documents", title: "文档", icon: "doc.text", labels: [
            "document", "text", "paper", "book", "receipt", "whiteboard", "chart",
            "screenshot", "poster", "sign", "menu"
        ], tags: [
            "文档", "票据", "证件", "证件照", "二维码", "条码", "白板", "截图", "名片",
            "菜单", "海报", "书页", "书本"
        ]),
        SceneCategory(id: "receipts", title: "票据", icon: "doc.text.viewfinder",
                      labels: ["invoice", "receipt", "menu", "newspaper"],
                      tags: ["票据"],
                      keywords: [
                          "发票代码", "发票号码", "价税合计", "开票日期", "增值税", "电子发票",
                          "行程单", "登机牌", "火车票", "汽车票", "门票", "小票", "收据",
                          "付款凭证", "订单号", "实付金额"
                      ]),
        SceneCategory(id: "idcards", title: "证件", icon: "person.text.rectangle",
                      labels: ["idcard", "passport"],
                      tags: ["证件"],
                      keywords: [
                          "居民身份证", "公民身份号码", "签发机关", "有效期限", "身份证号",
                          "驾驶证", "行驶证", "社会保障卡", "护照号码", "统一社会信用代码",
                          "营业执照", "注册号"
                      ]),
        SceneCategory(id: "idphoto", title: "证件照", icon: "person.crop.rectangle",
                      labels: ["idphoto"], tags: ["证件照"]),
        SceneCategory(id: "codes", title: "二维码条码", icon: "qrcode",
                      labels: ["qrcode", "barcode"], tags: ["二维码", "条码"]),
        SceneCategory(id: "landmarks", title: "名胜古迹", icon: "building.columns",
                      labels: ["monument", "castle", "statue", "palace", "fountain", "ruins", "temple"],
                      tags: ["寺庙", "教堂", "城堡", "塔", "古镇"],
                      keywords: [
                          "景区", "古镇", "古城", "长城", "故宫", "天坛", "颐和园", "布达拉宫",
                          "兵马俑", "摩崖", "石刻", "石碑", "碑文", "题刻", "文物保护单位",
                          "游客中心", "观光", "景点"
                      ]),
        SceneCategory(id: "night", title: "夜景", icon: "moon.stars", labels: [
            "night", "dark", "lights", "fireworks", "illumination", "dusk"
        ], tags: ["夜景", "星空", "低光照片"]),
        SceneCategory(id: "activities", title: "活动", icon: "figure.run", labels: [
            "sport", "sports", "concert", "party", "celebration", "festival", "game",
            "performance", "dance", "wedding", "parade", "ceremony"
        ], tags: [
            "运动", "跑步", "骑行", "游泳", "登山", "露营", "野餐", "钓鱼", "滑雪",
            "派对", "节日庆祝", "毕业典礼", "旅游", "购物", "阅读", "做饭", "绘画",
            "舞蹈", "会议", "演讲", "演唱会现场", "婚礼现场"
        ]),
        SceneCategory(id: "style", title: "照片风格", icon: "camera.filters", labels: [],
                      tags: [
                          "黑白照片", "复古照片", "胶片质感", "逆光", "低光照片", "微距",
                          "航拍", "长曝光", "全景照片", "动态模糊", "高对比", "柔焦"
                      ]),
        SceneCategory(id: "weather", title: "天空与天气", icon: "cloud.sun", labels: [
            "sky", "cloud", "rain", "fog", "snow", "rainbow", "sunset", "sunrise"
        ], tags: ["天空", "云朵", "彩虹", "雾", "雨", "雪景", "日落", "日出", "星空"])
    ]

    static func category(id: String) -> SceneCategory? {
        categories.first { $0.id == id }
    }

    /// 场景命中：Vision 标签 / OCR 关键词；「名胜古迹」额外接受地理位置命中。
    static func matches(_ category: SceneCategory,
                        analysis: PhotoAnalysis,
                        photo: PhotoItem?) -> Bool {
        if analysis.belongs(to: category) { return true }
        guard category.id == "landmarks", let photo else { return false }
        return landmarkName(for: photo) != nil
    }

    /// 地标名：优先用 EXIF 坐标就近命中内置地标表，其次用 POI / 城市 / 区县文字匹配。
    /// 坐标来自拍摄时的 GPS，不联网、不上传。
    static func landmarkName(for photo: PhotoItem) -> String? {
        if let latitude = photo.latitude, let longitude = photo.longitude,
           let landmark = LandmarkCatalog.nearest(latitude: latitude, longitude: longitude) {
            return landmark.name
        }
        let place = [photo.placePOI, photo.placeDistrict, photo.placeCity, photo.placeProvince]
            .compactMap { $0 }
            .joined(separator: " ")
        return LandmarkCatalog.match(placeText: place)?.name
    }

    /// 中文（及常见英文）查询词 → 检索串里可能出现的标准标签。
    static func searchLabels(for token: String) -> [String] {
        var result = aliases[token] ?? []
        if let mapped = PhotoTagCatalog.shared?.searchTitles(for: token) {
            result.append(contentsOf: mapped)
        }
        // 英文查询直接用小写词本身。
        if result.isEmpty, token.unicodeScalars.allSatisfy({ $0.isASCII }) { return [] }
        return result
    }

    private static let aliases: [String: [String]] = [
        "自拍": ["selfie", "face", "portrait"],
        "人群": ["crowd", "people"],
        "小孩": ["child", "baby"],
        "宝宝": ["baby", "child"],
        "狗": ["dog", "puppy", "pet"],
        "小狗": ["dog", "puppy"],
        "宠物": ["pet", "dog", "cat", "rabbit", "hamster"],
        "猫": ["cat", "kitten"],
        "小猫": ["cat", "kitten"],
        "鸟": ["bird"],
        "鱼": ["fish"],
        "动物": ["animal", "wildlife", "mammal"],
        "海边": ["beach", "seashore", "coast", "ocean", "sea", "shore"],
        "海滩": ["beach", "seashore", "coast"],
        "沙滩": ["beach", "seashore"],
        "海": ["ocean", "sea", "beach"],
        "山": ["mountain", "hill"],
        "爬山": ["mountain", "hill"],
        "登山": ["mountain", "hill"],
        "森林": ["forest", "tree"],
        "树林": ["forest", "tree"],
        "树": ["tree"],
        "花": ["flower", "blossom", "petal"],
        "花朵": ["flower", "blossom"],
        "鲜花": ["flower", "blossom"],
        "植物": ["plant", "tree", "flower"],
        "天空": ["sky", "cloud"],
        "云": ["cloud", "sky"],
        "日落": ["sunset", "dusk"],
        "夕阳": ["sunset", "dusk"],
        "日出": ["sunrise"],
        "雪": ["snow"],
        "下雪": ["snow"],
        "湖": ["lake"],
        "河": ["river", "stream"],
        "溪": ["river", "stream"],
        "瀑布": ["waterfall"],
        "自然": ["nature", "outdoor", "landscape"],
        "风景": ["landscape", "scenery", "nature"],
        "户外": ["outdoor", "nature"],
        "公园": ["park", "garden"],
        "花园": ["garden"],
        "食物": ["food", "meal", "dish"],
        "美食": ["food", "meal", "dish", "cuisine"],
        "吃的": ["food", "meal"],
        "菜": ["food", "dish"],
        "甜点": ["dessert", "cake"],
        "蛋糕": ["cake", "dessert"],
        "面包": ["bread"],
        "水果": ["fruit"],
        "蔬菜": ["vegetable"],
        "咖啡": ["coffee"],
        "饮料": ["drink", "beverage"],
        "喝的": ["drink", "beverage"],
        "建筑": ["building", "architecture"],
        "房子": ["house", "building"],
        "房屋": ["house", "building"],
        "桥": ["bridge"],
        "城市": ["city", "urban"],
        "街道": ["street", "urban"],
        "室内": ["indoor", "room", "interior"],
        "房间": ["room", "indoor"],
        "家具": ["furniture"],
        "桌子": ["table", "furniture"],
        "椅子": ["chair", "furniture"],
        "沙发": ["sofa", "furniture"],
        "厨房": ["kitchen", "indoor"],
        "办公室": ["office", "indoor"],
        "文档": ["document", "paper", "text"],
        "文件": ["document", "paper"],
        "纸": ["paper", "document"],
        "书": ["book"],
        "书本": ["book"],
        "收据": ["receipt"],
        "发票": ["receipt"],
        "白板": ["whiteboard"],
        "屏幕": ["screenshot"],
        "截图": ["screenshot"],
        "夜景": ["night", "lights", "dark"],
        "夜晚": ["night", "dark"],
        "晚上": ["night", "dark"],
        "烟花": ["fireworks"],
        "车": ["car", "automobile", "vehicle"],
        "汽车": ["car", "automobile"],
        "自行车": ["bicycle", "bike"],
        "摩托车": ["motorcycle"],
        "火车": ["train"],
        "飞机": ["airplane", "aircraft"],
        "船": ["boat", "ship"],
        "运动": ["sport", "sports"],
        "演唱会": ["concert", "performance"],
        "聚会": ["party", "celebration"],
        "派对": ["party", "celebration"],
        "婚礼": ["wedding", "ceremony"],
        "节日": ["festival", "celebration"],
        "牛": ["cow", "cattle"],
        "奶牛": ["cow"],
        "羊": ["sheep", "goat"],
        "绵羊": ["sheep"],
        "山羊": ["goat"],
        "马": ["horse"],
        "猪": ["pig"],
        "鸡": ["chicken", "rooster"],
        "兔": ["rabbit"],
        "兔子": ["rabbit"],
        "花卉": ["flower", "flower_arrangement"],
        "盆栽": ["decorative_plant", "plant"],
        "二维码": ["qrcode"],
        "条码": ["barcode"],
        "条形码": ["barcode"],
        "证件照": ["idphoto"],
        "名胜": ["monument", "castle", "statue"],
        "景点": ["monument", "statue"],
        "古迹": ["monument", "ruins", "castle"]
    ]
}
