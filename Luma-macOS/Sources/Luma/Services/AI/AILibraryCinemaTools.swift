import Foundation

/// 影院模块的智能助手工具：浏览、检索、播放、收藏 / 想看 / 评分、清单、
/// 忽略、元数据刷新、跳过片头与观看记录。写操作统一走 LibraryStore 现有方法。
extension AILibraryTools {
    /// 影院写操作：与其它工具一样，执行前需要用户确认。
    static let cinemaWriteToolNames: Set<String> = [
        "update_cinema_state", "manage_cinema_list",
        "ignore_cinema", "restore_cinema_ignored",
        "refresh_cinema_metadata", "set_cinema_intro_skip",
        "manage_cinema_progress"
    ]

    static var cinemaToolDefinitions: [AIRequestTool] {
        [searchCinemaLibrary, listCinemaSeries, listCinemaActivity, listCinemaLists,
         navigateCinema, playCinema,
         updateCinemaState, manageCinemaList,
         ignoreCinema, restoreCinemaIgnored,
         refreshCinemaMetadata, setCinemaIntroSkip, manageCinemaProgress]
    }

    // MARK: - 读

    private static var searchCinemaLibrary: AIRequestTool {
        AIRequestTool(
            name: "search_cinema_library",
            description: "在当前影院里检索本库影片（不联网）：按片名、原名、文件名、类型、演员、导演或剧情关键词查找，也可只列收藏 / 想看 / 已评分 / 未识别。返回影片与剧集的 id、剧集 id、季集、年份、评分、收藏与观看状态。要操作具体影片或剧集时先调用它。",
            parameters: objectSchema([
                "query": stringSchema("搜索词，例如「沙丘」「诺兰」「科幻」；留空则按 filter 列出"),
                "filter": enumSchema(["all", "favorites", "watchlist", "rated", "unmatched"],
                                     "all 全部已识别；favorites 影院收藏；watchlist 想看；rated 已评分；unmatched 未识别"),
                "genre": stringSchema("类型标签，例如「科幻」「悬疑」，可省略"),
                "year": integerSchema("年份，例如 2024；0 表示不限",
                                      minimum: 0, maximum: 2100),
                "kind": enumSchema(["all", "movie", "tv"], "只看电影或只看剧集，默认 all"),
                "watch_state": enumSchema(["unwatched", "inProgress", "finished"],
                                          "观看状态，可省略"),
                "limit": integerSchema("最多返回多少条，默认 200，最大 1000", minimum: 1, maximum: 1000)
            ])
        )
    }

    private static var listCinemaSeries: AIRequestTool {
        AIRequestTool(
            name: "list_cinema_series",
            description: "列出当前影院聚合后的剧集（同一部剧的多集算一部）：剧集 id、季数、集数、最新一集、评分、收藏与观看状态。需要逐集清单时把 include_episodes 设为 true。",
            parameters: objectSchema([
                "scope": stringSchema("影院 id（local 或网盘 id）；省略则当前影院"),
                "matched": enumSchema(["matched", "unmatched", "all"],
                                      "只看已识别 / 未识别 / 全部，默认 matched"),
                "watch_state": enumSchema(["unwatched", "inProgress", "finished"],
                                          "按观看状态过滤，可省略"),
                "favorite_only": booleanSchema("只看收藏的剧集，默认 false"),
                "include_episodes": booleanSchema("是否附带每一集的 id、季集与观看状态，默认 false"),
                "limit": integerSchema("最多返回多少部剧集，默认 300，最大 1000", minimum: 1, maximum: 1000)
            ])
        )
    }

    private static var listCinemaActivity: AIRequestTool {
        AIRequestTool(
            name: "list_cinema_activity",
            description: "查看影院的动态与状态：继续观看、观看记录、刮削任务或通知中心。回答「看到哪了」「最近刮了什么」「有没有失败任务」时使用。",
            parameters: objectSchema([
                "scope": stringSchema("影院 id（local 或网盘 id）；省略则当前影院；任务与通知是全局的"),
                "kind": enumSchema(["continue", "history", "tasks", "notifications", "all"],
                                   "continue 继续观看；history 观看记录；tasks 刮削任务；notifications 通知；all 全部，默认 continue"),
                "limit": integerSchema("每类最多返回多少条，默认 300，最大 1000",
                                       minimum: 1, maximum: 1000)
            ])
        )
    }

    private static var listCinemaLists: AIRequestTool {
        AIRequestTool(
            name: "list_cinema_lists",
            description: "列出影院的全部自定义清单：id、名称、条目数。需要清单里具体有哪些影片时把 include_items 设为 true。",
            parameters: objectSchema([
                "include_items": booleanSchema("是否展开清单里的影片，默认 false"),
                "limit": integerSchema("最多返回多少个清单，默认 300，最大 1000", minimum: 1, maximum: 1000)
            ])
        )
    }

    // MARK: - 浏览与播放

    private static var navigateCinema: AIRequestTool {
        AIRequestTool(
            name: "navigate_cinema",
            description: "打开并切换影院界面：切到某个影院、全部 / 电影 / 电视剧 / 文件夹分段、书架 / 海报墙 / 卡片 / 列表视图、排序与筛选，也可直接打开搜索、观看记录、通知或新建清单面板。只改变界面，不修改数据。",
            parameters: objectSchema([
                "scope": stringSchema("影院 id（local 或网盘 id）或网盘名称；省略则当前影院"),
                "tab": enumSchema(["all", "movies", "shows", "folder"], "顶部分段，默认 all"),
                "view_mode": enumSchema(["shelf", "wall", "card", "list"],
                                        "呈现方式：书架 / 海报墙 / 卡片 / 列表"),
                "sort": enumSchema(["recent", "rating", "year", "title", "duration"],
                                   "排序字段"),
                "years": arraySchema(["type": "integer"], description: "年份筛选，例如 [2024]"),
                "genres": arraySchema(["type": "string"], description: "类型筛选，例如 [\"科幻\"]"),
                "resolutions": arraySchema(["type": "string",
                                            "enum": ["uhd4k", "fullHD", "sd"]],
                                           description: "分辨率筛选"),
                "watch_states": arraySchema(["type": "string",
                                             "enum": ["unwatched", "inProgress", "finished"]],
                                            description: "观看状态筛选"),
                "specs": arraySchema(["type": "string",
                                      "enum": ["dolbyVision", "hdr", "atmos", "highFrameRate"]],
                                     description: "规格筛选"),
                "high_rated": booleanSchema("只看评分 8 分以上的影片"),
                "recent": booleanSchema("只看最近 30 天入库"),
                "favorites_only": booleanSchema("只看影院收藏"),
                "list_id": stringSchema("按某个自定义清单筛选：清单 id；与 list_name 二选一"),
                "list_name": stringSchema("按某个自定义清单筛选：清单名称；与 list_id 二选一"),
                "reset_filters": booleanSchema("先清空全部影院筛选，再应用本次参数"),
                "panel": enumSchema(["none", "search", "history", "notifications", "new_list"],
                                    "顺带打开的影院面板，默认 none")
            ])
        )
    }

    private static var playCinema: AIRequestTool {
        AIRequestTool(
            name: "play_cinema",
            description: "播放影院里的影片或剧集：传剧集 id 时自动挑下一集（优先接着最近观看的进度，其次第一条未看）；也可指定季号与集号。省略 target 时继续播放当前影院最近一条未看完的记录。只打开播放器，不修改数据。",
            parameters: objectSchema([
                "target": stringSchema("视频 id、文件名、片名或剧集 id；省略则继续播放最近记录"),
                "scope": stringSchema("影院 id（local 或网盘 id）；省略则当前影院"),
                "season": integerSchema("剧集的季号，可省略；填了季号不填集号则播放该季第一集",
                                        minimum: 1, maximum: 100),
                "episode": integerSchema("集号，可省略", minimum: 1, maximum: 10000)
            ])
        )
    }

    // MARK: - 写

    private static var updateCinemaState: AIRequestTool {
        AIRequestTool(
            name: "update_cinema_state",
            description: "修改影院条目的收藏、想看与个人评分。targets 可传视频 id、文件名、片名或剧集 id；传剧集 id 会作用于整部剧。至少提供 favorite / watchlist / rating 之一，评分传 0 表示清除评分。",
            parameters: objectSchema([
                "targets": arraySchema(["type": "string"],
                                       description: "条目引用：视频 id、文件名、片名或剧集 id"),
                "scope": stringSchema("影院 id（local 或网盘 id）；省略则当前影院"),
                "favorite": booleanSchema("true 加入影院收藏，false 取消收藏"),
                "watchlist": booleanSchema("true 加入想看，false 移出想看"),
                "rating": integerSchema("个人评分 1–5；传 0 清除评分", minimum: 0, maximum: 5)
            ], required: ["targets"])
        )
    }

    private static var manageCinemaList: AIRequestTool {
        AIRequestTool(
            name: "manage_cinema_list",
            description: "管理影院自定义清单：新建、删除、加入影片、移出影片或清空清单。加入 / 移出时 targets 可传视频 id、文件名、片名或剧集 id。只改清单引用，不删除影片。",
            parameters: objectSchema([
                "action": enumSchema(["create", "delete", "add", "remove", "clear_items"],
                                     "要执行的动作"),
                "list_id": stringSchema("清单 id；delete / add / remove / clear_items 使用"),
                "list_name": stringSchema("清单名称；delete / add / remove / clear_items 可用名称代替 id"),
                "name": stringSchema("新建清单的名称；action = create 时使用"),
                "targets": arraySchema(["type": "string"],
                                       description: "要加入或移出的条目：视频 id、文件名、片名或剧集 id"),
                "scope": stringSchema("影院 id（local 或网盘 id）；省略则当前影院")
            ], required: ["action"])
        )
    }

    private static var ignoreCinema: AIRequestTool {
        AIRequestTool(
            name: "ignore_cinema",
            description: "忽略影院的视频或整部剧：从影院移除，以后刮削也不再处理（原文件不动，可随时恢复）。targets 传视频 id、文件名、片名或剧集 id。",
            parameters: objectSchema([
                "targets": arraySchema(["type": "string"],
                                       description: "要忽略的视频或剧集：id、文件名、片名或剧集 id"),
                "scope": stringSchema("影院 id（local 或网盘 id）；省略则当前影院")
            ], required: ["targets"])
        )
    }

    private static var restoreCinemaIgnored: AIRequestTool {
        AIRequestTool(
            name: "restore_cinema_ignored",
            description: "恢复某个影院里被忽略的全部视频，下次刮削会重新处理它们。",
            parameters: objectSchema([
                "scope": stringSchema("影院 id（local 或网盘 id）；省略则当前影院")
            ])
        )
    }

    private static var refreshCinemaMetadata: AIRequestTool {
        AIRequestTool(
            name: "refresh_cinema_metadata",
            description: "刷新影院条目的元数据：enrich 补全 TMDB 详情（演职员、分级、片长等）；rescrape 重新搜索并刮削标题、海报与简介。只写元数据与海报，不移动、不改名、不删除视频。省略 targets 时处理当前影院前若干条已识别影片。",
            parameters: objectSchema([
                "targets": arraySchema(["type": "string"],
                                       description: "要刷新的视频或剧集：id、文件名、片名或剧集 id；省略则自动挑选"),
                "scope": stringSchema("影院 id（local 或网盘 id）；省略则当前影院"),
                "mode": enumSchema(["enrich", "rescrape"],
                                   "enrich 补详情（默认）；rescrape 重新刮削"),
                "force": booleanSchema("enrich 时忽略已有详情强制刷新，默认 false"),
                "limit": integerSchema("最多处理多少条，默认 100，最大 1000", minimum: 1, maximum: 1000)
            ])
        )
    }

    private static var setCinemaIntroSkip: AIRequestTool {
        AIRequestTool(
            name: "set_cinema_intro_skip",
            description: "为剧集设置自动跳过片头 / 片尾的秒数，按整部剧生效；也可用 per_episode 只为某一集单独设置。两个秒数都传 0 表示关闭跳过。只影响播放器行为，不修改视频文件。",
            parameters: objectSchema([
                "targets": arraySchema(["type": "string"],
                                       description: "剧集 id、视频 id、文件名或片名"),
                "scope": stringSchema("影院 id（local 或网盘 id）；省略则当前影院"),
                "intro_seconds": integerSchema("跳过片头秒数，0 表示不跳", minimum: 0, maximum: 3600),
                "outro_seconds": integerSchema("跳过片尾秒数，0 表示不跳", minimum: 0, maximum: 3600),
                "per_episode": booleanSchema("true 时只为指定的单集设置，不改变整部剧默认值"),
                "clear": booleanSchema("true 时清除设置（等同于片头 / 片尾都传 0）")
            ], required: ["targets"])
        )
    }

    private static var manageCinemaProgress: AIRequestTool {
        AIRequestTool(
            name: "manage_cinema_progress",
            description: "管理影院观看记录：remove 移除指定影片 / 剧集的续播进度（下次从头播放）；clear 清空全部影院的观看记录。只删进度，不删除影片。",
            parameters: objectSchema([
                "action": enumSchema(["remove", "clear"], "要执行的动作"),
                "targets": arraySchema(["type": "string"],
                                       description: "要移除进度的视频或剧集：id、文件名、片名或剧集 id"),
                "scope": stringSchema("影院 id（local 或网盘 id）；省略则当前影院")
            ], required: ["action"])
        )
    }

    // MARK: - 确认弹窗文案

    static func describeCinema(_ call: AIToolCall) -> String? {
        let args = arguments(call.arguments)
        let count = stringArray(args["targets"]).count
        switch call.name {
        case "update_cinema_state":
            var parts: [String] = []
            if args["favorite"] != nil {
                parts.append(bool(args["favorite"], fallback: true) ? "加入收藏" : "取消收藏")
            }
            if args["watchlist"] != nil {
                parts.append(bool(args["watchlist"], fallback: true) ? "加入想看" : "移出想看")
            }
            if args["rating"] != nil {
                let rating = integer(args["rating"], fallback: 0)
                parts.append(rating > 0 ? "评分 \(rating) 星" : "清除评分")
            }
            return "影院条目 \(count) 项：\(parts.joined(separator: "、"))"
        case "manage_cinema_list":
            let action = string(args["action"]) ?? ""
            let name = string(args["name"]) ?? string(args["list_name"]) ?? "指定清单"
            switch action {
            case "create": return "新建影院清单「\(name)」"
            case "delete": return "删除影院清单「\(name)」（不会删除影片）"
            case "add": return "把 \(count) 项加入影院清单「\(name)」"
            case "remove": return "从影院清单「\(name)」移出 \(count) 项"
            case "clear_items": return "清空影院清单「\(name)」"
            default: return "管理影院清单「\(name)」"
            }
        case "ignore_cinema":
            return "忽略影院条目 \(count) 项（原文件不动，可恢复）"
        case "restore_cinema_ignored":
            return "恢复「\(string(args["scope"]) ?? "当前影院")」中被忽略的视频"
        case "refresh_cinema_metadata":
            let mode = string(args["mode"]) ?? "enrich"
            let targets = count > 0 ? "\(count) 项" : "自动挑选的影片"
            return mode == "rescrape"
                ? "重新刮削 \(targets)（只写元数据与海报）"
                : "补全 \(targets) 的 TMDB 详情（只写元数据）"
        case "set_cinema_intro_skip":
            if bool(args["clear"], fallback: false) {
                return "清除 \(count) 项影院的跳过片头 / 片尾设置"
            }
            let intro = integer(args["intro_seconds"], fallback: 0)
            let outro = integer(args["outro_seconds"], fallback: 0)
            var detail = "设置跳过片头 \(intro) 秒 / 片尾 \(outro) 秒"
            if bool(args["per_episode"], fallback: false) { detail += "（仅指定单集）" }
            return "\(detail)：\(count) 项"
        case "manage_cinema_progress":
            if string(args["action"]) == "clear" {
                return "清空全部影院的观看记录（不会删除影片）"
            }
            return "移除 \(count) 项的观看进度"
        default:
            return nil
        }
    }
}
