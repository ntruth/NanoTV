import Foundation

/// 黄果主站（huangguoai.io / .com）经常被 DNS 拦成连不上。
/// 官方「最新地址」发布页会定期换一批随机子域（`thu.aqkmowihz.cc` 这类），
/// 这里只在**真正连不上**时才去发布页取候选域名并逐个探测：
/// - 找到的可用地址直接落盘缓存，下次启动先用它，不再探测；
/// - 缓存的地址失效时由调用方通知 `invalidate` / `refresh` 重新找。
actor HuangguoAddressResolver {
    static let shared = HuangguoAddressResolver()

    /// 官方地址发布页：pages.dev 优先，GitHub Pages 作为备份。
    private static let discoveryPages: [URL] = [
        URL(string: "https://huangguoai.pages.dev/")!,
        URL(string: "https://huangguo88.pages.dev/")!,
        URL(string: "https://huang-guo.pages.dev/")!,
        URL(string: "https://huangguotv.github.io/")!
    ]

    private static let storageKey = "catalog.huangguo.resolvedBases"

    /// 主站 host → 可用地址。落在 UserDefaults，重启后先按缓存直连。
    private var entries: [String: URL] = [:]
    /// 一次都没找到可用地址时，短时间内不再反复探测发布页。
    private var lastFailure: [String: Date] = [:]
    private var loaded = false

    /// 缓存的可用地址（不联网）。
    func cachedBase(for original: URL) -> URL? {
        loadIfNeeded()
        return entries[key(for: original)].map(Self.trimmed)
    }

    /// 取一个可用地址：有缓存直接用；没缓存或缓存刚失败过才联网找。
    func base(for original: URL, source: CatalogSource) async -> URL {
        if let cached = cachedBase(for: original) { return cached }
        let key = key(for: original)
        if let failedAt = lastFailure[key], Date().timeIntervalSince(failedAt) < 60 {
            return original
        }
        return await refresh(original, source: source)
    }

    /// 重新找地址：主站能连就回主站，否则去发布页取候选并探测。
    @discardableResult
    func refresh(_ original: URL, source: CatalogSource) async -> URL {
        loadIfNeeded()
        // 被取消（切页面 / 新一轮健康检测）不算「找不到地址」，
        // 绝不能把结果写进失败缓存，否则接下来 60 秒都会直接打不可用的主站。
        guard !Task.isCancelled else { return original }
        let key = key(for: original)

        if await Self.isSite(original, source: source) {
            let usable = Self.trimmed(original)
            entries[key] = usable
            lastFailure[key] = nil
            persist()
            Diagnostics.record("黄果地址：主站可用 \(usable.absoluteString)")
            return usable
        }
        guard !Task.isCancelled else { return original }
        Diagnostics.record("黄果地址：主站不可用 \(original.absoluteString)，查发布页")

        if let found = await Self.discover(source: source, excluding: original.host) {
            let fresh = Self.trimmed(found)
            entries[key] = fresh
            lastFailure[key] = nil
            persist()
            Diagnostics.record("黄果地址：切换到 \(fresh.absoluteString)")
            return fresh
        }
        guard !Task.isCancelled else { return original }
        lastFailure[key] = Date()
        Diagnostics.record("黄果地址：发布页也没有可用地址")
        return original
    }

    func invalidate(_ original: URL) {
        loadIfNeeded()
        let key = key(for: original)
        entries[key] = nil
        lastFailure[key] = nil
        persist()
    }

    // MARK: - 持久化

    private func key(for original: URL) -> String {
        original.host ?? original.absoluteString
    }

    /// 统一去掉结尾斜杠：调用方用 `\(base)/api/…` 拼路径，
    /// 带斜杠会出现 `//api/…`，镜像服务器直接返回 404。
    private static func trimmed(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text) ?? url
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey)
                as? [String: String] else { return }
        for (host, value) in stored {
            if let url = URL(string: value) { entries[host] = Self.trimmed(url) }
        }
    }

    private func persist() {
        UserDefaults.standard.set(entries.mapValues(\.absoluteString),
                                  forKey: Self.storageKey)
    }

    // MARK: - 探测

    /// 站点可用 = 返回 HTML 且带黄果的卡片 / 导航标记。
    /// 发布页本身只有几百字节，用标记就能排除。
    static func isSite(_ base: URL, source: CatalogSource) async -> Bool {
        guard let html = await text(base, source: source, timeout: 6) else { return false }
        return html.count > 5_000
            && (html.contains("hg-drama-card") || html.contains("data-nav-key=\"home\""))
    }

    private static func text(_ url: URL, source: CatalogSource,
                             timeout: TimeInterval) async -> String? {
        guard let data = try? await CatalogHTTP.fetchData(url: url, headers: [
            "User-Agent": source.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ], timeout: timeout) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 发现

    /// 拉发布页 → 顺带拉它引用的脚本 → 汇总候选域名 → 并发探测。
    private static func discover(source: CatalogSource, excluding host: String?) async -> URL? {
        var pages: [(page: URL, html: String)] = []
        await withTaskGroup(of: (URL, String?).self) { group in
            for page in discoveryPages {
                group.addTask {
                    (page, await text(page, source: source, timeout: 4))
                }
            }
            for await (page, html) in group {
                if let html { pages.append((page, html)) }
            }
        }
        guard !Task.isCancelled, !pages.isEmpty else { return nil }

        // 发布页把域名写在 publish.js 里，脚本也要读。
        var texts = pages.map(\.html)
        var scripts: [URL] = []
        for (page, html) in pages {
            for raw in matches(#"<script[^>]+src="([^"]+)""#, in: html) {
                if let url = URL(string: raw, relativeTo: page)?.absoluteURL {
                    scripts.append(url)
                }
            }
        }
        let firstScripts = Array(scripts.prefix(4))
        if !firstScripts.isEmpty {
            await withTaskGroup(of: String?.self) { group in
                for url in firstScripts {
                    group.addTask { await text(url, source: source, timeout: 4) }
                }
                for await value in group {
                    if let value { texts.append(value) }
                }
            }
        }
        guard !Task.isCancelled else { return nil }

        // 轮换子域优先（发布页提示这是「最新可用」），其次永久域名。
        var candidates: [URL] = []
        var seen = Set<String>()
        for text in texts {
            for url in rotatingAddresses(in: text) + absoluteAddresses(in: text) {
                guard let candidateHost = url.host,
                      candidateHost != host,
                      !candidateHost.hasSuffix("pages.dev"),
                      !candidateHost.hasSuffix("github.io"),
                      seen.insert(candidateHost).inserted else { continue }
                candidates.append(url)
            }
        }
        guard !candidates.isEmpty else { return nil }

        // 并发探测，命中一个就立刻返回，不再等慢的超时。
        let probes = Array(candidates.prefix(8))
        return await withTaskGroup(of: URL?.self) { group in
            for url in probes {
                group.addTask {
                    let ok = await isSite(url, source: source)
                    return ok ? url : nil
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    /// `var subdomains = ['thu', …]` + `var urls = ['aqkmowihz.cc/', …]`
    /// → `https://thu.aqkmowihz.cc/` 这类轮换地址。
    static func rotatingAddresses(in text: String) -> [URL] {
        guard let subBlock = CatalogHTML.first(#"var\s+subdomains\s*=\s*\[([\s\S]*?)\]"#, in: text),
              let hostBlock = CatalogHTML.first(#"var\s+urls\s*=\s*\[([\s\S]*?)\]"#, in: text)
        else { return [] }

        let subs = quotedStrings(in: subBlock)
        let hosts = quotedStrings(in: hostBlock)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }
            .filter { !$0.isEmpty }
        guard !subs.isEmpty, !hosts.isEmpty else { return [] }

        var result: [URL] = []
        for host in hosts.prefix(2) {
            for sub in subs.prefix(6) {
                if let url = URL(string: "https://\(sub).\(host)/") {
                    result.append(url)
                }
            }
        }
        return result
    }

    /// 文本里出现的黄果相关绝对地址（永久域名、其它发布页）。
    static func absoluteAddresses(in text: String) -> [URL] {
        matches(#"https?://([a-zA-Z0-9.-]+)"#, in: text)
            .filter { $0.contains("huangguo") || $0.contains("huang-guo") }
            .compactMap { URL(string: "https://\($0)/") }
    }

    private static func quotedStrings(in text: String) -> [String] {
        let pattern = #"['"]([^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil }
    }
}
