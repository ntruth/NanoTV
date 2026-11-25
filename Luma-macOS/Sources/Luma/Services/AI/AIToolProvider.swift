import Foundation

/// 一组按源能力注册的 AI 工具：定义与执行都收在 provider 里。
/// 新增电视 / 在线影院时只注册 provider，不再往中央 switch 里加 case。
@MainActor
struct AIToolProvider {
    let name: String
    let definitions: [AIRequestTool]
    let handles: (String) -> Bool
    let execute: (AIToolCall, [String: Any]) async -> AIToolExecution
}

/// 工具注册表：按注册顺序询问 provider，未命中返回 nil 交给兜底 switch。
@MainActor
final class AIToolRegistry {
    private var providers: [AIToolProvider]

    init(providers: [AIToolProvider] = []) {
        self.providers = providers
    }

    var definitions: [AIRequestTool] {
        providers.flatMap(\.definitions)
    }

    func register(_ provider: AIToolProvider) {
        providers.append(provider)
    }

    func execute(_ call: AIToolCall, args: [String: Any]) async -> AIToolExecution? {
        for provider in providers where provider.handles(call.name) {
            return await provider.execute(call, args)
        }
        return nil
    }
}

enum AIToolProviders {
    /// 网络资源工具：来源列表、检索、稍后看与档案跟随都在这里。
    @MainActor
    static func catalog(store: LibraryStore) -> AIToolProvider {
        let names: Set<String> = [
            "list_catalog_sources", "search_catalog", "list_catalog_following",
            "list_catalog_watchlist", "catalog_new_today", "browse_catalog",
            "play_catalog_item", "set_catalog_watchlist", "follow_catalog_person"
        ]
        return AIToolProvider(
            name: "catalog",
            definitions: AILibraryTools.catalogToolDefinitions,
            handles: { names.contains($0) },
            execute: { call, args in
                switch call.name {
                case "list_catalog_sources": return store.listCatalogSourcesTool()
                case "search_catalog": return await store.searchCatalogTool(args)
                case "list_catalog_following": return store.listCatalogFollowingTool()
                case "list_catalog_watchlist": return store.listCatalogWatchlistTool(args)
                case "catalog_new_today": return store.catalogNewTodayTool(args)
                case "browse_catalog": return store.browseCatalogTool(args)
                case "play_catalog_item": return store.playCatalogItemTool(args)
                case "set_catalog_watchlist": return store.setCatalogWatchlistTool(args)
                case "follow_catalog_person": return store.followCatalogPersonTool(args)
                default:
                    return store.failure("资源工具未注册：\(call.name)")
                }
            }
        )
    }

    /// 网络影院工具：聚合列表、跨源搜索、续看与播放。影视源仍由资源页管理。
    @MainActor
    static func networkCinema(store: LibraryStore) -> AIToolProvider {
        let names: Set<String> = [
            "list_network_cinema_sources", "list_network_cinema",
            "search_network_cinema", "network_cinema_history", "play_network_cinema"
        ]
        return AIToolProvider(
            name: "networkCinema",
            definitions: AILibraryTools.networkCinemaToolDefinitions,
            handles: { names.contains($0) },
            execute: { call, args in
                switch call.name {
                case "list_network_cinema_sources": return store.listNetworkCinemaSourcesTool()
                case "list_network_cinema": return store.listNetworkCinemaTool(args)
                case "search_network_cinema": return await store.searchNetworkCinemaTool(args)
                case "network_cinema_history": return store.networkCinemaHistoryTool(args)
                case "play_network_cinema": return store.playNetworkCinemaTool(args)
                default:
                    return store.failure("网络影院工具未注册：\(call.name)")
                }
            }
        )
    }

    /// 网络电视工具：源库、频道、节目单、直播 / 回看与导航。
    @MainActor
    static func television(store: LibraryStore) -> AIToolProvider {
        let names: Set<String> = [
            "list_tv_sources", "list_tv_channels", "get_tv_guide",
            "play_tv_channel", "favorite_tv_channel", "navigate_tv"
        ]
        return AIToolProvider(
            name: "television",
            definitions: AILibraryTools.tvToolDefinitions,
            handles: { names.contains($0) },
            execute: { call, args in
                switch call.name {
                case "list_tv_sources": return store.listTVSourcesTool()
                case "list_tv_channels": return await store.listTVChannelsTool(args)
                case "get_tv_guide": return await store.getTVGuideTool(args)
                case "play_tv_channel": return await store.playTVChannelTool(args)
                case "favorite_tv_channel": return store.favoriteTVChannelTool(args)
                case "navigate_tv": return store.navigateTVTool(args)
                default:
                    return store.failure("电视工具未注册：\(call.name)")
                }
            }
        )
    }

    /// 影院工具：定义与执行都留在这个 provider 里，中央 switch 不再感知影院细节。
    @MainActor
    static func cinema(store: LibraryStore) -> AIToolProvider {
        let names: Set<String> = [
            "list_cinema_items", "list_cinema_scopes", "cinema_tree",
            "search_cinema_candidates", "apply_cinema_match", "scrape_cinema", "match_cinema",
            "search_cinema_library", "list_cinema_series", "list_cinema_activity",
            "list_cinema_lists", "navigate_cinema", "play_cinema",
            "update_cinema_state", "manage_cinema_list", "ignore_cinema",
            "restore_cinema_ignored", "refresh_cinema_metadata",
            "set_cinema_intro_skip", "manage_cinema_progress"
        ]
        return AIToolProvider(
            name: "cinema",
            definitions: AILibraryTools.cinemaToolDefinitions,
            handles: { names.contains($0) },
            execute: { call, args in
                switch call.name {
                case "list_cinema_items": return store.listCinemaItemsTool(args)
                case "list_cinema_scopes": return store.listCinemaScopesTool()
                case "cinema_tree": return store.cinemaTreeTool(args)
                case "search_cinema_candidates": return await store.searchCinemaCandidatesTool(args)
                case "apply_cinema_match": return store.applyCinemaMatchTool(args)
                case "scrape_cinema": return store.scrapeCinemaTool(args)
                case "match_cinema": return await store.matchCinemaTool(args)
                case "search_cinema_library": return store.searchCinemaLibraryTool(args)
                case "list_cinema_series": return store.listCinemaSeriesTool(args)
                case "list_cinema_activity": return store.listCinemaActivityTool(args)
                case "list_cinema_lists": return store.listCinemaListsTool(args)
                case "navigate_cinema": return store.navigateCinemaTool(args)
                case "play_cinema": return store.playCinemaTool(args)
                case "update_cinema_state": return store.updateCinemaStateTool(args)
                case "manage_cinema_list": return store.manageCinemaListTool(args)
                case "ignore_cinema": return store.ignoreCinemaTool(args)
                case "restore_cinema_ignored": return store.restoreCinemaIgnoredTool(args)
                case "refresh_cinema_metadata": return await store.refreshCinemaMetadataTool(args)
                case "set_cinema_intro_skip": return store.setCinemaIntroSkipTool(args)
                case "manage_cinema_progress": return store.manageCinemaProgressTool(args)
                default:
                    return store.failure("影院工具未注册：\(call.name)")
                }
            }
        )
    }
}
