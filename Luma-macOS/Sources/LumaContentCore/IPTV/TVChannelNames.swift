import Foundation

/// 频道名本地化：公开 M3U 列表基本是英文台名，展示时统一翻成中文。
/// 优先按 `tvg-id` 精确匹配（同频道不同画质也能对上），其次按台名规则翻译，
/// 实在认不出的保留原名，避免显示空白。
public enum TVChannelNames {
    public static func chinese(name: String, key: String) -> String {
        let cleaned = stripSuffixes(name)
        let baseKey = key.split(separator: ".").first.map(String.init)?.lowercased() ?? key.lowercased()
        if let mapped = keyMap[baseKey] { return mapped }
        if let mapped = nameMap[normalize(cleaned)] { return mapped }
        if let mapped = cctvName(cleaned) { return mapped }
        if let mapped = satelliteName(cleaned) { return mapped }
        if let mapped = localChannelName(cleaned) { return mapped }

        // 国际频道：先剥掉「(Japan) / (UK) / UK」这类国家后缀，再按品牌表翻译。
        let split = splitCountrySuffix(cleaned)
        let base = normalize(split.base)
        if split.country == "新加坡", base.hasPrefix("channel ") {
            return "新加坡\(split.base.dropFirst("channel ".count))台"
        }
        // 美国 TBS 与日本 TBS 同名不同台，按国家区分。
        if base == "tbs" {
            return split.country == "日本" ? "TBS 电视台" : "TBS"
        }
        if let mapped = nameMap[base] ?? brandMap[base] {
            return split.country.map { "\(mapped)（\($0)）" } ?? mapped
        }
        if let country = split.country {
            return "\(split.base)（\(country)）"
        }
        return cleaned
    }

    // MARK: - 清洗

    private static func stripSuffixes(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespaces)
        for suffix in [" HD", " SD", " FHD", " UHD"] {
            if value.hasSuffix(suffix) {
                value = String(value.dropLast(suffix.count))
            }
        }
        // 日本 / 韩国频道常带呼号（JOJG-DTV、HLAJ-DTV），展示时去掉。
        if let range = value.range(of: #"\s+[A-Z]{3,5}-DTV$"#, options: .regularExpression) {
            value.removeSubrange(range)
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func normalize(_ name: String) -> String {
        var value = name
        for token in [" Asia Taiwan", " (Taiwan)", " (Hong Kong)", "(Taiwan)", "(Hong Kong)"] {
            value = value.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
        }
        return value.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - 精确映射（tvg-id 去掉国家后缀）

    private static let keyMap: [String: String] = [
        // 央视
        "cctv1": "央视一套（综合）",
        "cctv2": "央视二套（财经）",
        "cctv3": "央视三套（综艺）",
        "cctv4": "央视四套（中文国际）",
        "cctv5": "央视五套（体育）",
        "cctv5plus": "央视五套+（体育赛事）",
        "cctv6": "央视六套（电影）",
        "cctv7": "央视七套（国防军事）",
        "cctv8": "央视八套（电视剧）",
        "cctv9": "央视九套（纪录）",
        "cctv10": "央视十套（科教）",
        "cctv11": "央视十一套（戏曲）",
        "cctv12": "央视十二套（社会与法）",
        "cctv13": "央视十三套（新闻）",
        "cctv14": "央视十四套（少儿）",
        "cctv15": "央视十五套（音乐）",
        "cctv16": "央视十六套（奥林匹克）",
        "cctv17": "央视十七套（农业农村）",
        "cctv4k": "央视4K超高清",
        "cctv8k": "央视8K超高清",
        "cctvbilliards": "央视台球",
        "cctvgolfandtennis": "央视高尔夫网球",
        "cctvhealth": "央视卫生健康",
        "cctvnostalgiateater": "央视怀旧剧场",
        "cctvstormfootball": "央视风云足球",
        "cctvstormmusic": "央视风云音乐",
        "cctvstormtheater": "央视风云剧场",
        "cctvthefirsttheater": "央视第一剧场",
        "cctvweapontechnology": "央视兵器科技",
        "cctvwomensfashion": "央视女性时尚",
        "cctvworldgeography": "央视世界地理",
        "cctvcultureofquality": "央视文化精品",
        "cctvplus1": "央视国际视通 1",
        "cctvplus2": "央视国际视通 2",
        "cetv1": "中国教育一台",
        "cetv2": "中国教育二台",
        // 卫视 / 省级主频道：主要由下面的「省份 + Satellite/TV」规则翻译，
        // 这里只保留台名与 tvg-id 不一致的特殊项。
        "dragontvinternational": "东方卫视国际",
        // 其他常驻频道
        "brtvkakuchildrenschannel": "卡酷少儿",
        "goldeneaglecartoon": "金鹰卡通",
        "fujiancomprehensivechannel": "福建综合频道",
        "guangxivarietytravelchannel": "广西综艺旅游频道",
        // 香港
        "jade": "翡翠台",
        "goldenjade": "黄金翡翠台",
        "rthktv31": "港台电视31",
        "rthktv32": "港台电视32",
        "rthktv33": "港台电视33",
        "rthktv34": "港台电视34",
        "rthktv35": "港台电视35",
        "hoytv": "HOY TV（奇妙电视）",
        "hoyinfotainment": "HOY 资讯台",
        "hongkonginternationalbusinesschannel": "香港国际财经台",
        "viutv": "ViuTV",
        "phoenixchinesechannel": "凤凰卫视中文台",
        "phoenixinfonewschannel": "凤凰卫视资讯台",
        "celestialmovies": "天映频道",
        "meiahmoviechannel": "美亚电影台",
        "asiandrama": "亚洲剧集台",
        "bstv": "BSTV",
        "petclubtv": "宠物频道",
        // 台湾
        "cts": "华视",
        "ctsnews": "华视新闻",
        "ttv": "台视",
        "ttvnews": "台视新闻",
        "ftv": "民视",
        "ftvone": "民视第一台",
        "ctivariety": "中天综合台",
        "tvbsnews": "TVBS 新闻",
        "tvbsasia": "TVBS 亚洲台",
        "ebcnews": "东森新闻",
        "ebcfinancialnews": "东森财经新闻",
        "ebcforeignmovie": "东森洋片台",
        "daai1": "大爱一台",
        "daai2": "大爱二台",
        "hakkertv": "客家电视台",
        "pts3": "公视三台",
        "setnews": "三立新闻",
        "momotv": "MOMO 亲子台",
        "indigenoustv": "原住民族电视台",
        "taiwanindigenoustv": "原住民族电视台",
        "ntdtvasiapacific": "新唐人亚太台",
        "goodtv": "好消息电视台",
        "good2": "好消息二台",
        "dalitv": "大立电视台",
        "sjtv": "世界卫视",
        "wxtv": "唯心电视台",
        "cgtvchinese": "好消息卫星电视台",
        "animaxasia": "Animax 动漫台",
        "axnasia": "AXN",
        "cinemaxasia": "Cinemax",
        "hboasia": "HBO",
        "discoveryasiataiwan": "Discovery 探索频道"
    ]

    /// 按台名精确映射（已去掉画质 / 地区后缀）。
    private static let nameMap: [String: String] = [
        "anhui tv": "安徽卫视",
        "dragon tv international": "东方卫视国际",
        "fengshang shopping channel": "风尚购物",
        "documentary humanities channel": "纪实人文频道",
        "china weather channel": "中国气象频道",
        "cctv+ 1": "央视国际视通 1",
        "cctv+ 2": "央视国际视通 2",
        "cctv+1": "央视国际视通 1",
        "cctv+2": "央视国际视通 2",
        "brtv kaku childrens channel": "卡酷少儿",
        "golden eagle cartoon": "金鹰卡通",
        "fujian comprehensive channel": "福建综合频道",
        "guangxi variety & travel channel": "广西综艺旅游频道",
        "homeplus": "HomePlus 购物",
        "high channel tv": "高清频道",
        "jade": "翡翠台",
        "hoy tv": "HOY TV（奇妙电视）",
        "hoy infotainment": "HOY 资讯台",
        "phoenix chinese channel": "凤凰卫视中文台",
        "phoenix infonews channel": "凤凰卫视资讯台",
        "celestial movies": "天映频道",
        "mei ah movie channel": "美亚电影台",
        "asian drama": "亚洲剧集台",
        "pet club tv": "宠物频道",
        "cts": "华视",
        "cts news": "华视新闻",
        "ttv": "台视",
        "ttv news": "台视新闻",
        "ftv": "民视",
        "ftv one": "民视第一台",
        "cti variety": "中天综合台",
        "tvbs news": "TVBS 新闻",
        "tvbs-asia": "TVBS 亚洲台",
        "ebc news": "东森新闻",
        "ebc financial news": "东森财经新闻",
        "ebc foreign movie": "东森洋片台",
        "daai 1": "大爱一台",
        "daai 2": "大爱二台",
        "hakka tv": "客家电视台",
        "pts 3": "公视三台",
        "set news": "三立新闻",
        "momo tv": "MOMO 亲子台",
        "indigenous tv": "原住民族电视台",
        "taiwan indigenous tv": "原住民族电视台",
        "ntd tv asia-pacific": "新唐人亚太台",
        "good tv": "好消息电视台",
        "good 2": "好消息二台",
        "dali tv": "大立电视台",
        "cgtv chinese": "好消息卫星电视台",
        "animax asia": "Animax 动漫台",
        "axn asia": "AXN",
        "cinemax asia": "Cinemax",
        "hbo asia": "HBO",
        "discovery asia": "Discovery 探索频道"
    ]

    // MARK: - 国际频道品牌表

    /// 欧美日韩新常见频道。键为小写台名（已去掉国家后缀）。
    private static let brandMap: [String: String] = [
        // 美国
        "abc": "ABC 美国广播公司",
        "nbc": "NBC 全国广播公司",
        "cbs": "CBS 哥伦比亚广播",
        "fox": "FOX 福克斯",
        "pbs": "PBS 公共电视",
        "cw": "CW 电视台",
        "cnn": "CNN 新闻",
        "msnbc": "MSNBC 新闻",
        "cnbc": "CNBC 财经",
        "fox news": "福克斯新闻",
        "fox business": "福克斯财经",
        "espn": "ESPN 体育",
        "espn2": "ESPN2 体育",
        "hbo": "HBO",
        "showtime": "Showtime",
        "starz": "Starz",
        "amc": "AMC",
        "tnt": "TNT",
        "usa network": "USA 电视网",
        "syfy": "Syfy 科幻台",
        "bravo": "Bravo",
        "comedy central": "喜剧中心",
        "cartoon network": "卡通频道",
        "disney channel": "迪士尼频道",
        "disney junior": "迪士尼幼儿台",
        "nickelodeon": "尼克儿童台",
        "nick jr": "尼克幼儿台",
        "discovery channel": "探索频道",
        "discovery": "探索频道",
        "history": "历史频道",
        "national geographic": "国家地理",
        "animal planet": "动物星球",
        "food network": "美食频道",
        "hgtv": "HGTV 家居台",
        "travel channel": "旅游频道",
        "the weather channel": "天气频道",
        "bloomberg television": "彭博财经",
        "cspan": "C-SPAN 国会台",
        "c-span": "C-SPAN 国会台",
        "pbs kids": "PBS 儿童台",
        "freeform": "Freeform",
        "fx": "FX",
        "fxx": "FXX",
        "paramount network": "派拉蒙电视网",
        "bet": "BET 黑人娱乐台",
        "mtv": "MTV 音乐台",
        "vh1": "VH1 音乐台",
        "e!": "E! 娱乐台",
        "tlc": "TLC 生活台",
        "a&e": "A&E 罪案纪实",
        "lifetime": "Lifetime",
        "hallmark channel": "Hallmark 家庭台",
        "telemundo": "Telemundo 西班牙语台",
        "univision": "Univision 西班牙语台",
        "cbs news": "CBS 新闻",
        "nbc news": "NBC 新闻",
        "abc news": "ABC 新闻",
        "newsmax": "Newsmax 新闻",
        "oan": "OAN 新闻",
        // 英国
        "bbc one": "BBC 第一台",
        "bbc two": "BBC 第二台",
        "bbc three": "BBC 第三台",
        "bbc four": "BBC 第四台",
        "bbc news": "BBC 新闻台",
        "bbc world news": "BBC 世界新闻",
        "cbbc": "CBBC 儿童台",
        "cbeebies": "CBeebies 幼儿台",
        "bbc alba": "BBC 阿尔巴台",
        "bbc parliament": "BBC 议会台",
        "itv 1": "ITV 一台",
        "itv1": "ITV 一台",
        "itv 2": "ITV 二台",
        "itv 3": "ITV 三台",
        "itv 4": "ITV 四台",
        "itvbe": "ITVBe",
        "channel 4": "第四频道",
        "channel 5": "第五频道",
        "5usa": "5USA",
        "sky news": "天空新闻",
        "sky sports": "天空体育",
        "sky cinema": "天空影院",
        "dave": "Dave 喜剧台",
        "dmax": "DMAX",
        "quest": "Quest",
        "really": "Really",
        "yesterday": "Yesterday 历史台",
        "film4": "Film4 电影台",
        "e4": "E4",
        "more4": "More4",
        "4seven": "4seven",
        // 法国
        "tf1": "TF1 一台",
        "tfx": "TFX",
        "france 2": "法国二台",
        "france 3": "法国三台",
        "france 4": "法国四台",
        "france 5": "法国五台",
        "franceinfo": "法国资讯台",
        "m6": "M6 电视台",
        "w9": "W9",
        "6ter": "6ter",
        "canal+": "Canal+",
        "canal+ sport": "Canal+ 体育",
        "bfm tv": "BFM 新闻台",
        "bfmtv": "BFM 新闻台",
        "cnews": "CNews 新闻台",
        "c news": "CNews 新闻台",
        "lci": "LCI 新闻台",
        "arte": "ARTE 德法文化台",
        "france 24": "法国24台",
        "rmc story": "RMC Story",
        "rmc decouverte": "RMC 探索台",
        "paris premiere": "巴黎首映台",
        "tv5 monde": "TV5 法语世界台",
        // 德国
        "das erste": "德国一台（ARD）",
        "zdf": "德国二台（ZDF）",
        "zdfneo": "ZDFneo",
        "zdf info": "ZDF 资讯台",
        "3sat": "3sat 文化台",
        "rtl": "RTL 电视台",
        "rtl ii": "RTL II",
        "sat.1": "Sat.1",
        "prosieben": "ProSieben",
        "prosieben maxx": "ProSieben Maxx",
        "vox": "VOX",
        "kabel eins": "Kabel Eins",
        "sixx": "sixx",
        "n-tv": "n-tv 新闻台",
        "welt": "WELT 新闻台",
        "phoenix": "德国凤凰台",
        "tagesschau24": "每日新闻24台",
        "ard-alpha": "ARD-alpha 教育台",
        "br fernsehen": "巴伐利亚电视台",
        "mdr": "中德广播电视台",
        "ndr": "北德广播电视台",
        "swr": "西南广播电视台",
        "wdr": "西德广播电视台",
        // 意大利
        "rai 1": "RAI 一台",
        "rai 2": "RAI 二台",
        "rai 3": "RAI 三台",
        "rai 4": "RAI 四台",
        "rai 5": "RAI 五台",
        "rai news 24": "RAI 新闻24",
        "rai sport": "RAI 体育",
        "rete 4": "Rete 4",
        "canale 5": "Canale 5",
        "italia 1": "Italia 1",
        "la7": "La7",
        "tv8": "TV8",
        "nove": "Nove",
        "cielo": "Cielo",
        "focus": "Focus 纪实台",
        "real time": "Real Time 生活台",
        "k2": "K2 儿童台",
        "frisbee": "Frisbee 儿童台",
        "boing": "Boing 儿童台",
        "sky tg24": "天空 TG24 新闻",
        "tgcom24": "TGCOM24 新闻",
        // 日本
        "nhk general tv": "NHK 综合台",
        "nhk educational tv": "NHK 教育台",
        "nhk world": "NHK 世界台",
        "nippon tv": "日本电视台",
        "tv asahi": "朝日电视台",
        "tv tokyo": "东京电视台",
        "fuji tv": "富士电视台",
        "tokyo mx": "TOKYO MX",
        "weathernews": "Weathernews 气象台",
        "cartoon network japan": "卡通频道（日本）",
        "disney channel japan": "迪士尼频道（日本）",
        // 韩国
        "kbs1": "KBS 1台",
        "kbs 1tv": "KBS 1台",
        "kbs2": "KBS 2台",
        "kbs 2tv": "KBS 2台",
        "mbc": "MBC 文化广播",
        "sbs": "SBS 电视台",
        "ebs 1tv": "EBS 1台",
        "ebs 2tv": "EBS 2台",
        "ebs english": "EBS 英语台",
        "ebs kids": "EBS 儿童台",
        "ebs plus 1": "EBS Plus 1",
        "ebs plus 2": "EBS Plus 2",
        "jtbc": "JTBC",
        "mbn": "MBN 新闻台",
        "channel a": "频道 A",
        "tv chosun": "TV 朝鲜",
        "ytn": "YTN 新闻台",
        "yonhapnews tv": "韩联社新闻台",
        "arirang tv": "阿里郎电视台",
        "arirang radio": "阿里郎广播",
        "gugak tv": "国乐电视台",
        // 新加坡
        "channel 8": "新加坡八台",
        "channel u": "新加坡 U 台",
        "cna": "亚洲新闻台",
        "cna originals": "亚洲新闻台原创",
        "suria": "Suria 马来语台",
        "vasantham": "Vasantham 泰米尔语台",
        "mewatch live 1": "meWATCH 直播 1",
        "techstorm": "TechStorm 科技台"
    ]

    /// 把「(Japan) / (UK) / 结尾 UK」拆成台名主体 + 中文国家名。
    private static func splitCountrySuffix(_ name: String) -> (base: String, country: String?) {
        let countries: [String: String] = [
            "united states": "美国", "usa": "美国", "us": "美国",
            "japan": "日本", "south korea": "韩国", "korea": "韩国",
            "united kingdom": "英国", "uk": "英国", "great britain": "英国",
            "france": "法国", "germany": "德国", "italy": "意大利",
            "singapore": "新加坡", "canada": "加拿大", "australia": "澳大利亚",
            "india": "印度", "spain": "西班牙", "netherlands": "荷兰"
        ]
        if let open = name.lastIndex(of: "("), name.hasSuffix(")") {
            let inner = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
            if let country = countries[inner.trimmingCharacters(in: .whitespaces).lowercased()] {
                let base = String(name[..<open]).trimmingCharacters(in: .whitespaces)
                return (base, country)
            }
        }
        let lower = name.lowercased()
        for token in [" uk", " us"] {
            if lower.hasSuffix(token) {
                let base = String(name.dropLast(token.count)).trimmingCharacters(in: .whitespaces)
                if !base.isEmpty, let country = countries[token.trimmingCharacters(in: .whitespaces)] {
                    return (base, country)
                }
            }
        }
        return (name, nil)
    }

    // MARK: - 规则翻译

    private static let cctvNames: [String: String] = [
        "1": "央视一套（综合）",
        "2": "央视二套（财经）",
        "3": "央视三套（综艺）",
        "4": "央视四套（中文国际）",
        "5": "央视五套（体育）",
        "6": "央视六套（电影）",
        "7": "央视七套（国防军事）",
        "8": "央视八套（电视剧）",
        "9": "央视九套（纪录）",
        "10": "央视十套（科教）",
        "11": "央视十一套（戏曲）",
        "12": "央视十二套（社会与法）",
        "13": "央视十三套（新闻）",
        "14": "央视十四套（少儿）",
        "15": "央视十五套（音乐）",
        "16": "央视十六套（奥林匹克）",
        "17": "央视十七套（农业农村）"
    ]

    private static let cctvThemes: [String: String] = [
        "billiards": "台球",
        "golf & tennis": "高尔夫网球",
        "health": "卫生健康",
        "nostalgia theater": "怀旧剧场",
        "storm football": "风云足球",
        "storm music": "风云音乐",
        "storm theater": "风云剧场",
        "the first theater": "第一剧场",
        "weapon & technology": "兵器科技",
        "women's fashion": "女性时尚",
        "world geography": "世界地理",
        "culture of quality": "文化精品"
    ]

    private static func cctvName(_ name: String) -> String? {
        let upper = name.uppercased()
        guard upper.hasPrefix("CCTV") else { return nil }
        let rest = String(name.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        if rest.uppercased() == "4K" { return "央视4K超高清" }
        if rest.uppercased() == "8K" { return "央视8K超高清" }
        if rest.hasPrefix("5+") { return "央视五套+（体育赛事）" }
        if let number = Int(rest), let mapped = cctvNames[String(number)] { return mapped }
        if let theme = cctvThemes[rest.lowercased()] { return "央视\(theme)" }
        return nil
    }

    /// 省份 / 城市名 → 中文。
    private static let places: [String: String] = [
        "beijing": "北京", "shanghai": "上海", "tianjin": "天津", "chongqing": "重庆",
        "hebei": "河北", "shanxi": "山西", "liaoning": "辽宁", "jilin": "吉林",
        "heilongjiang": "黑龙江", "jiangsu": "江苏", "zhejiang": "浙江", "anhui": "安徽",
        "fujian": "福建", "jiangxi": "江西", "shandong": "山东", "henan": "河南",
        "hubei": "湖北", "hunan": "湖南", "guangdong": "广东", "hainan": "海南",
        "sichuan": "四川", "guizhou": "贵州", "yunnan": "云南", "shaanxi": "陕西",
        "gansu": "甘肃", "qinghai": "青海", "ningxia": "宁夏", "xinjiang": "新疆",
        "tibet": "西藏", "guangxi": "广西", "neimenggu": "内蒙古", "inner mongolia": "内蒙古",
        "bingtuan": "兵团", "xiamen": "厦门", "shenzhen": "深圳", "guangzhou": "广州",
        "hangzhou": "杭州", "nanjing": "南京", "chengdu": "成都", "wuhan": "武汉",
        "changsha": "长沙", "zhengzhou": "郑州", "jinan": "济南", "shenyang": "沈阳",
        "harbin": "哈尔滨", "changchun": "长春", "xian": "西安", "kunming": "昆明",
        "nanning": "南宁", "haikou": "海口", "nanchang": "南昌", "hefei": "合肥",
        "fuzhou": "福州", "taiyuan": "太原", "shijiazhuang": "石家庄", "hohhot": "呼和浩特",
        "lanzhou": "兰州", "xining": "西宁", "yinchuan": "银川", "urumqi": "乌鲁木齐",
        "lhasa": "拉萨", "guiyang": "贵阳", "anshun": "安顺", "baicheng": "白城",
        "chaozhou": "潮州", "chifeng": "赤峰", "chuxiong": "楚雄", "chuzhou": "滁州",
        "dongguan": "东莞", "dunhuang": "敦煌", "hebi": "鹤壁", "hezheng": "和政",
        "huizhou": "惠州", "jiaxing": "嘉兴", "kaifeng": "开封", "luoyang": "洛阳",
        "mianyang": "绵阳", "ningbo": "宁波", "qingdao": "青岛", "quanzhou": "泉州",
        "suzhou": "苏州", "wenzhou": "温州", "wuxi": "无锡", "xuzhou": "徐州",
        "yantai": "烟台", "zhongshan": "中山", "zhuhai": "珠海", "zibo": "淄博"
    ]

    /// 省级行政区：名字后面跟 `TV` 时按「卫视」翻译。
    private static let provinces: Set<String> = [
        "beijing", "shanghai", "tianjin", "chongqing", "hebei", "shanxi", "liaoning",
        "jilin", "heilongjiang", "jiangsu", "zhejiang", "anhui", "fujian", "jiangxi",
        "shandong", "henan", "hubei", "hunan", "guangdong", "hainan", "sichuan",
        "guizhou", "yunnan", "shaanxi", "gansu", "qinghai", "ningxia", "xinjiang",
        "tibet", "guangxi", "neimenggu", "inner mongolia", "bingtuan"
    ]

    private static func satelliteName(_ name: String) -> String? {
        let suffixes = [" Satellite TV", " Satellite Channel"]
        let lower = name.lowercased()
        for suffix in suffixes where lower.hasSuffix(suffix.lowercased()) {
            let base = String(name.dropLast(suffix.count)).lowercased()
            guard let place = places[base] else { continue }
            if place == "上海" { return "东方卫视" }
            return "\(place)卫视"
        }
        return nil
    }

    private static func localChannelName(_ name: String) -> String? {
        let suffixes: [(String, String)] = [
            (" Comprehensive News Channel", "综合新闻频道"),
            (" Comprehensive News Chanel", "综合新闻频道"),
            (" Comprehensive Channel", "综合频道"),
            (" News Channel", "新闻频道"),
            (" Public Channel", "公共频道"),
            (" Movie Channel", "电影频道"),
            (" Science & Education Channel", "科教频道"),
            (" Economy Channel", "经视频道"),
            (" Variety & Travel Channel", "综艺旅游频道"),
            (" TV", "电视台")
        ]
        let lower = name.lowercased()
        for (suffix, chinese) in suffixes where lower.hasSuffix(suffix.lowercased()) {
            let base = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            let baseKey = base.lowercased()
            guard let place = places[baseKey] else { continue }
            // 省级主频道通常是卫视；城市台保留「电视台」。
            if suffix == " TV", provinces.contains(baseKey) {
                return place == "上海" ? "东方卫视" : "\(place)卫视"
            }
            return "\(place)\(chinese)"
        }
        return nil
    }
}
