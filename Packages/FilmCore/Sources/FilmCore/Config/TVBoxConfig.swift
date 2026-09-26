import Foundation

// MARK: - TVBox 配置基底（用户钦定：点播/直播都必须支持自定义 JSON 配置，入口在「设置」）
// 支持三种主流格式：
//   1. 多仓：{"urls":[{"url":"...","name":"..."}]} / {"storeHouse":[{"sourceName":"...","sourceUrl":"..."}]}
//   2. 单仓：{"sites":[{"key":"..","name":"..","type":3,"api":".."}],"lives":[{"name":"..","type":0,"url":"m3u地址或直链"}]}
//   3. 纯 M3U 直播文本（#EXTINF）

/// 订阅条目（持久化到本地 JSON）。
public struct TVBoxSubscription: Codable, Identifiable, Hashable {
    public var id: String { url }
    public let name: String
    public let url: String
    public var enabled: Bool
    public var addedAt: Date

    public init(name: String, url: String, enabled: Bool = true) {
        self.name = name
        self.url = url
        self.enabled = enabled
        self.addedAt = Date()
    }
}

/// 解析出的点播源（仅展示与管理；播放路由仍以本产品 feed 为主，自定义源作为 TVBox 基底能力保留）。
public struct TVBoxSite: Codable, Identifiable, Hashable {
    public var id: String { key.isEmpty ? name : key }
    public let key: String
    public let name: String
    public let api: String
    public let type: Int?

    public init(key: String, name: String, api: String, type: Int?) {
        self.key = key
        self.name = name
        self.api = api
        self.type = type
    }
}

/// 解析出的直播源分组（一个订阅可含多组，每组一个 M3U 地址或频道直链）。
public struct TVBoxLiveGroup: Codable, Identifiable, Hashable {
    public var id: String { name + "#" + m3uURLs.joined(separator: "|") }
    public let name: String
    public let m3uURLs: [String]

    public init(name: String, m3uURLs: [String]) {
        self.name = name
        self.m3uURLs = m3uURLs
    }
}

/// 一次订阅解析的完整结果。
public struct TVBoxParseResult: Codable, Hashable {
    public var repos: [TVBoxSubscription] = []     // 多仓展开出的下级订阅
    public var sites: [TVBoxSite] = []
    public var lives: [TVBoxLiveGroup] = []
    public var message: String = ""

    public var isEmpty: Bool { repos.isEmpty && sites.isEmpty && lives.isEmpty }
}

// MARK: - 解析器（纯函数，只做协议翻译，不做内容判断）

public enum TVBoxParser {

    private static func resolve(_ ref: String, baseURL: String?) -> String {
        if ref.hasPrefix("http://") || ref.hasPrefix("https://") || ref.hasPrefix("bundle:") {
            return ref
        }
        guard let base = baseURL,
              let baseU = URL(string: base),
              let resolved = URL(string: ref, relativeTo: baseU)?.absoluteString else {
            return ref
        }
        return resolved
    }

    public static func parse(data: Data, baseURL: String? = nil) -> TVBoxParseResult {
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.hasPrefix("#EXTM3U") {
            let channels = M3UParser.parse(text)
            let urls = channels.map { $0.url.absoluteString }
            return TVBoxParseResult(lives: [TVBoxLiveGroup(name: "M3U 直播源", m3uURLs: urls)],
                                    message: "M3U 文本，共 \(channels.count) 个频道")
        }
        guard let obj = try? FilmJSON.decoder().decode(TVBoxRawConfig.self, from: data) else {
            return TVBoxParseResult(message: "无法解析：既不是 TVBox JSON 也不是 M3U 文本")
        }
        var result = TVBoxParseResult()
        // 多仓（2026-09-26 fix：子仓相对路径拼回父配置地址，否则 ./0821.json 直接请求必挂）
        if let urls = obj.urls, !urls.isEmpty {
            result.repos = urls.compactMap { entry in
                guard let u = entry.url, !u.isEmpty else { return nil }
                return TVBoxSubscription(name: entry.name ?? "未命名仓库", url: resolve(u, baseURL: baseURL))
            }
        }
        if let house = obj.storeHouse, !house.isEmpty {
            result.repos += house.compactMap { entry in
                guard let u = entry.sourceUrl, !u.isEmpty else { return nil }
                return TVBoxSubscription(name: entry.sourceName ?? "未命名仓库", url: resolve(u, baseURL: baseURL))
            }
        }
        // 单仓点播：只保留 type 0/1 直连 CMS 站（spider type 3 需要 jar 引擎，手机端跑不了；
        // 带 ext 的站需要额外扩展参数，当前也不支持）。用户实测 298 站里 291 个 type 3 全打不开。
        if let sites = obj.sites {
            result.sites = sites.compactMap { s in
                guard let name = s.name, !name.isEmpty,
                      let type = s.type, (type == 0 || type == 1),
                      s.ext?.isEmpty ?? true
                else { return nil }
                let api = resolve(s.api ?? "", baseURL: baseURL)
                guard !api.isEmpty else { return nil }
                return TVBoxSite(key: s.key ?? name, name: name, api: api, type: s.type)
            }
        }
        // 单仓直播
        if let lives = obj.lives {
            result.lives = lives.compactMap { l in
                guard let name = l.name, !name.isEmpty else { return nil }
                var urls: [String] = []
                if let u = l.url {
                    if u.hasPrefix("["), let arr = try? FilmJSON.decoder().decode([String].self,
                            from: Data(u.utf8)) { urls = arr } else { urls = [u] }
                }
                if let urlsArr = l.urls { urls += urlsArr }
                return urls.isEmpty ? nil : TVBoxLiveGroup(name: name, m3uURLs: urls)
            }
        }
        var parts: [String] = []
        if !result.repos.isEmpty { parts.append("多仓 \(result.repos.count)") }
        if !result.sites.isEmpty { parts.append("点播源 \(result.sites.count)") }
        if !result.lives.isEmpty { parts.append("直播组 \(result.lives.count)") }
        result.message = parts.isEmpty ? "解析成功但未发现可用配置" : parts.joined(separator: " · ")
        return result
    }
}

/// TVBox 配置 JSON 原始骨架（宽松可选字段）。
private struct TVBoxRawConfig: Codable {
    struct RepoEntry: Codable { let url: String?; let name: String? }
    struct HouseEntry: Codable { let sourceUrl: String?; let sourceName: String? }
    struct SiteEntry: Codable { let key: String?; let name: String?; let type: Int?; let api: String?; let ext: String? }
    struct LiveEntry: Codable {
        let name: String?
        let type: Int?
        let url: String?      // 单地址或 JSON 数组字符串
        let urls: [String]?
    }
    let urls: [RepoEntry]?
    let storeHouse: [HouseEntry]?
    let sites: [SiteEntry]?
    let lives: [LiveEntry]?
}

// MARK: - 抓取（github raw 自动走 jsDelivr 镜像兜底，与 feed 拉取链路同策略）

public enum TVBoxFetcher {

    /// 候选地址：原链 → github raw 转 jsDelivr → ghproxy 加速。
    public static func candidateURLs(_ urlString: String) -> [URL] {
        var out: [URL] = []
        func push(_ s: String) { if let u = URL(string: s), !out.contains(u) { out.append(u) } }
        push(urlString)
        if urlString.contains("raw.githubusercontent.com") {
            // raw.githubusercontent.com/<user>/<repo>/<branch>/<path> → fastly.jsdelivr.net/gh/<user>/<repo>@<branch>/<path>
            let comps = urlString.split(separator: "/").map(String.init)
            if comps.count >= 6,
               comps[2] == "raw.githubusercontent.com",
               let idx = comps.firstIndex(of: "main") ?? comps.firstIndex(of: "master") {
                let user = comps[3], repo = comps[4], branch = comps[idx]
                let path = comps[(idx + 1)...].joined(separator: "/")
                push("https://fastly.jsdelivr.net/gh/\(user)/\(repo)@\(branch)/\(path)")
            }
        }
        return out
    }

    /// authToken：GitHub 私有仓直播/配置文件鉴权（2026-09-21 夜航成人直播接入）。
    /// 仅对 github 域注入，避免把 token 泄给第三方 CDN。
    /// v16：默认超时 15→25s（PC 实测「高天流云」就要 21.8s，手机更慢——15s 必超时触发静默兜底，
    /// 用户看到的就是「选了这条内置线路没反应」）。
    public static func fetch(_ urlString: String, timeout: TimeInterval = 25,
                             authToken: String? = nil) async -> Data? {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg)
        for url in candidateURLs(urlString) {
            var req = URLRequest(url: url)
            // TVBox 原版以 okhttp UA 出请求；部分 CMS/订阅服务对空/默认 UA 返回空体或 403
            req.setValue("okhttp/4.10.0", forHTTPHeaderField: "User-Agent")
            if let tok = authToken, !tok.isEmpty,
               url.host?.contains("github") == true {
                req.setValue("token \(tok)", forHTTPHeaderField: "Authorization")
            }
            if let (data, resp) = try? await session.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                return data
            }
        }
        return nil
    }

    /// 文本解码自动兜底：UTF-8 优先，失败转 GB18030（TVBox 原版同款；老 CMS/直播源常为 GBK）。
    public static func decodeAuto(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
        let gbkEnc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: gbkEnc)
    }
}

// MARK: - 配置仓（TVBox 原版语义移植：配置历史点选生效 / 多仓选仓加载 / 单独添加点播直播源）

@MainActor
public final class TVBoxConfigStore: ObservableObject {

    public static let shared = TVBoxConfigStore()

    /// 产品模式（normal=星幕 / child=心屋 / adult=夜航）——App 入口 configure 注入，
    /// 决定内置线路仓的可见集合（影视组=normal+adult，成人组=仅 adult，心屋=空）。
    private var productMode: String = "normal"

    /// 当前产品模式（只读；源浏览/搜索的端隔离用它做分类与条目闸门，见 `NavPolicy`）。
    public var currentMode: String { productMode }

    /// 产品模式的持久化键（`configure` 写入）。
    /// 为何多此一举：`TVBoxConfigStore` 是 `@MainActor`，而 SwiftUI 视图里的
    /// 辅助函数（分类分组、条目过滤）是同步非隔离上下文，直接读会触发并发隔离编译错误；
    /// UserDefaults 读取无隔离，任何上下文都能安全调用。
    public static let productModeKey = "tvbox.productMode"

    /// 任意上下文可读的产品模式（供 `SiteBrowseView` 的端隔离闸门使用）。
    public static func currentProductMode() -> String {
        UserDefaults.standard.string(forKey: productModeKey) ?? "normal"
    }

    /// App 启动时注入产品身份（幂等，每次启动调用一次）。
    public func configure(productMode mode: String) {
        productMode = mode
        UserDefaults.standard.set(mode, forKey: Self.productModeKey)
        autoActivateBuiltinRepoIfNeeded()
    }

    /// 首次使用（无任何生效配置且从未自动激活过）自动激活最优内置线路。
    /// 用户反馈「内置还是8个源」：手动点选不构成"内置"，必须开箱即用。
    /// 只做一次（UserDefaults 旗标），之后用户手动选什么就是什么。
    private func autoActivateBuiltinRepoIfNeeded() {
        let flag = "tvbox.builtinRepoAutoDone"
        guard activeURL == nil, activeRepoURL == nil, activeBuiltinRepoURL == nil,
              lastResult == nil,
              !UserDefaults.standard.bool(forKey: flag) else { return }
        guard let best = DefaultSites.builtinRepos(forMode: productMode).first else { return }
        UserDefaults.standard.set(true, forKey: flag)
        activeBuiltinRepoURL = best.url
        persistState()
        Task { await refreshAll() }
    }

    /// 配置历史：添加过的地址全部留档（TVBox「配置历史」），点选哪条哪条生效。
    @Published public private(set) var subscriptions: [TVBoxSubscription] = []
    /// 当前生效的配置地址（TVBox 单选语义，不再多订阅合并）。
    @Published public private(set) var activeURL: String?
    /// 多仓配置下当前选中的仓库地址（TVBox 选仓加载）。
    @Published public private(set) var activeRepoURL: String?
    /// 手动添加的自定义点播源（不走订阅，TVBox「单独配置线路地址」同款能力）。
    @Published public private(set) var customSites: [TVBoxSite] = []
    /// 手动添加的自定义直播源（不走订阅，M3U / TVBox JSON / 频道直链均可）。
    @Published public private(set) var customLives: [TVBoxLiveGroup] = []
    /// 当前生效配置（含选中仓）的解析结果。
    @Published public private(set) var lastResult: TVBoxParseResult?
    @Published public private(set) var refreshing = false
    @Published public private(set) var refreshMessage: String = ""

    private let fileURL: URL
    private let stateURL: URL
    private let customURL: URL

    private struct ActiveState: Codable {
        var activeURL: String?
        var activeRepoURL: String?
        var activeBuiltinRepoURL: String?
    }
    private struct CustomSources: Codable {
        var sites: [TVBoxSite] = []
        var lives: [TVBoxLiveGroup] = []
    }

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("tvbox_subscriptions.json")
        stateURL = dir.appendingPathComponent("tvbox_active_state.json")
        customURL = dir.appendingPathComponent("tvbox_custom_sources.json")
        load()
    }

    // MARK: 配置历史管理

    /// 添加配置地址进历史；TVBox 语义：添加即启用。
    @discardableResult
    public func add(name: String, url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http") else { return false }
        if !subscriptions.contains(where: { $0.url == trimmed }) {
            let entry = TVBoxSubscription(
                name: name.isEmpty ? URL(string: trimmed)?.host ?? "自定义配置" : name,
                url: trimmed)
            subscriptions.insert(entry, at: 0)
            persist()
        }
        if activeURL != trimmed {
            activeURL = trimmed
            activeRepoURL = nil      // 换配置必须重新选仓
            activeBuiltinRepoURL = nil   // 配置历史与内置线路互斥
            persistState()
        }
        return true
    }

    /// 从配置历史删除；删的是当前生效条目时清空生效态。
    public func remove(_ sub: TVBoxSubscription) {
        subscriptions.removeAll { $0.url == sub.url }
        if activeURL == sub.url {
            activeURL = nil
            activeRepoURL = nil
            lastResult = nil
            persistState()
        }
        persist()
    }

    /// 点选配置历史条目 = 切换生效配置（TVBox 原版行为）。
    public func activate(_ sub: TVBoxSubscription) {
        guard activeURL != sub.url else { return }
        activeURL = sub.url
        activeRepoURL = nil
        activeBuiltinRepoURL = nil   // 配置历史与内置线路互斥
        persistState()
        Task { await refreshAll() }
    }

    // MARK: 刷新（TVBox 语义：只解析当前生效配置；多仓须先选仓）

    public func refreshAll() async {
        refreshing = true
        refreshMessage = ""
        defer { refreshing = false }
        // 内置线路生效中：按内置地址刷新（与自定义配置历史互斥）
        if let builtin = activeBuiltinRepoURL {
            await refreshBuiltin(builtin)
            return
        }
        guard let url = activeURL else {
            lastResult = nil
            refreshMessage = "尚未选择配置地址，请在上方点选或添加"
            return
        }
        guard let data = await TVBoxFetcher.fetch(url) else {
            refreshMessage = "「\(activeName)」拉取失败，请检查地址或稍后重试"
            return
        }
        let parsed = TVBoxParser.parse(data: data, baseURL: url)
        if !parsed.repos.isEmpty {
            // 多仓：自动按顺序尝试加载仓库，第一个能打开的仓库直接出内容，用户无需再选
            if let repo = activeRepoURL, parsed.repos.contains(where: { $0.url == repo }) {
                await loadRepo(repo, parent: parsed)
            } else {
                var loaded = false
                for repo in parsed.repos {
                    activeRepoURL = repo.url
                    await loadRepo(repo.url, parent: parsed)
                    if refreshMessage.hasPrefix("仓「") {
                        loaded = true
                        break
                    }
                }
                if !loaded {
                    activeRepoURL = nil
                    lastResult = parsed
                    refreshMessage = "多仓配置（\(parsed.repos.count) 个仓库）：均无法加载，请换线路"
                    persistResult()
                }
            }
            return
        }
        lastResult = parsed
        refreshMessage = parsed.message
        persistResult()
    }

    /// 点选仓库 = 加载该仓内容（单仓生效，TVBox 原版行为）。
    public func activateRepo(_ repo: TVBoxSubscription) {
        guard activeRepoURL != repo.url else { return }
        activeRepoURL = repo.url
        persistState()
        Task { await refreshAll() }
    }

    // MARK: 内置线路仓（2026-09-20 盒子审计实测；TVBox 配置历史同款交互：点选生效 / 删除墓碑可恢复）

    /// 当前生效的内置线路地址（与 activeURL 互斥：激活内置线路时清空自定义配置生效态，反之亦然）。
    @Published public private(set) var activeBuiltinRepoURL: String?

    /// 可见内置线路 = 产品模式过滤（影视组 normal+adult / 成人组仅 adult / 心屋空集）- 线路墓碑。
    public var builtinRepoOptions: [TVBoxSubscription] {
        DefaultSites.builtinRepos(forMode: productMode)
            .filter { !deletedBuiltinRepoURLs.contains($0.url) }
    }

    /// 点选内置线路 = 拉取解析生效（单仓出点播源；多仓亮仓列表供再选）。
    public func activateBuiltinRepo(_ repo: TVBoxSubscription) {
        guard activeBuiltinRepoURL != repo.url else { return }
        activeBuiltinRepoURL = repo.url
        activeURL = nil            // TVBox 单生效语义：内置线路与配置历史互斥
        activeRepoURL = nil
        persistState()
        Task { await refreshAll() }
    }

    /// 刷新当前生效的内置线路（refreshAll 的内置分支）。
    /// bundle: 前缀 = 随包配置（零网络依赖，手机端 ghproxy/jsdelivr 常不可达的兜底，2026-09-21）。
    /// 网络线路拉取失败 → 自动切换到首条 bundle 精选线路（用户无感，消息栏说明）。
    private func refreshBuiltin(_ builtinURL: String) async {
        let all = DefaultSites.builtinRepos(forMode: productMode)
        let name = all.first(where: { $0.url == builtinURL })?.name ?? "内置线路"
        var data: Data?
        if builtinURL.hasPrefix("bundle:") {
            let res = String(builtinURL.dropFirst("bundle:".count))
            if let u = Bundle.module.url(forResource: res, withExtension: "json", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: res, withExtension: "json") {
                data = try? Data(contentsOf: u)
            }
        } else {
            data = await TVBoxFetcher.fetch(builtinURL)
        }
        if data == nil {
            if !builtinURL.hasPrefix("bundle:") {
                // 自动兜底：切到随包直连精选（不依赖被墙域名）
                if let fallback = all.first(where: { $0.url.hasPrefix("bundle:") }) {
                    refreshMessage = "「\(name)」拉取失败，已自动切换到「直连精选」"
                    activeBuiltinRepoURL = fallback.url
                    persistState()
                    await refreshBuiltin(fallback.url)
                    return
                }
            }
            refreshMessage = "内置线路「\(name)」拉取失败，请稍后重试或换一条线路"
            return
        }
        guard let payload = data else { return }
        let parsed = TVBoxParser.parse(data: payload, baseURL: builtinURL)
        if !parsed.repos.isEmpty {
            // 内置线路要开箱即用：多仓自动按顺序试仓，第一个能打开的直接出内容
            var loaded = false
            let preferred = activeRepoURL.flatMap { sel in parsed.repos.first(where: { $0.url == sel }) }
            let ordered = preferred.map { [$0] + parsed.repos.filter { $0.url != sel } } ?? parsed.repos
            for repo in ordered {
                activeRepoURL = repo.url
                await loadRepo(repo.url, parent: parsed)
                if refreshMessage.hasPrefix("仓「") {
                    loaded = true
                    break
                }
            }
            if !loaded {
                activeRepoURL = nil
                lastResult = parsed
                refreshMessage = "内置线路「\(name)」多仓均无法加载，请换一条线路"
                persistResult()
            }
        } else {
            lastResult = parsed
            refreshMessage = "内置线路「\(name)」：\(parsed.message)"
            persistResult()
        }
    }

    /// 删除内置线路 = 持久墓碑（可恢复）。墓碑与内置点播源**分属两套集合**（2026-09-22 拆分），
    /// 只影响 `builtinRepoOptions`，不会误伤点播源列表。
    public func removeBuiltinRepo(_ repo: TVBoxSubscription) {
        deletedBuiltinRepoURLs.insert(repo.url)
        persistDeletedBuiltinRepos()
        if activeBuiltinRepoURL == repo.url {
            activeBuiltinRepoURL = nil
            lastResult = nil
            persistState()
        }
        objectWillChange.send()
    }

    private func loadRepo(_ repoURL: String, parent: TVBoxParseResult) async {
        if let data = await TVBoxFetcher.fetch(repoURL) {
            let parsed = TVBoxParser.parse(data: data, baseURL: repoURL)
            var merged = parsed
            // 保留父多仓的仓库列表，这样「解析源」行能显示当前进的是哪个仓，也便于切仓
            merged.repos = parent.repos
            let repoName = parent.repos.first(where: { $0.url == repoURL })?.name ?? "仓库"
            merged.message = "仓「\(repoName)」：\(parsed.message)"
            lastResult = merged
            refreshMessage = merged.message
        } else {
            lastResult = parent                    // 至少保住仓列表供换仓
            refreshMessage = "仓库拉取失败，请点选其他仓库重试"
        }
        persistResult()
    }

    private var activeName: String {
        subscriptions.first(where: { $0.url == activeURL })?.name ?? activeURL ?? "配置"
    }

    // MARK: 多仓展开（保留为高级操作：把仓全部收进配置历史）

    public func adoptRepos() {
        guard let repos = lastResult?.repos else { return }
        var added = 0
        for r in repos where !subscriptions.contains(where: { $0.url == r.url }) {
            subscriptions.append(r)
            added += 1
        }
        if added > 0 { persist() }
    }

    // MARK: 自定义点播源（单独添加，不依赖订阅）

    /// 添加结果（35包新增：用户报「添加后不知道去哪看/放不了」→ 必须给成败与原因）
    public enum AddOutcome: Equatable {
        case ok(site: TVBoxSite)
        case emptyURL
        case badURL                 // 不以 http 开头
        case duplicate              // 已存在
        case unreachable(String)    // 探测失败（给原因，仍允许保留）

        public var isOK: Bool { if case .ok = self { return true }; return false }

        public var message: String {
            switch self {
            case .ok(let s):       return "已添加「\(s.name)」，点下方条目即可浏览"
            case .emptyURL:        return "添加失败：请填写源地址"
            case .badURL:          return "添加失败：地址需以 http:// 或 https:// 开头"
            case .duplicate:       return "该地址已存在，无需重复添加"
            case .unreachable(let r): return "已添加，但探测未通过：\(r)"
            }
        }
    }

    @discardableResult
    public func addSite(name: String, api: String) -> AddOutcome {
        let a = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return .emptyURL }
        guard a.hasPrefix("http") else { return .badURL }
        guard !customSites.contains(where: { $0.api == a }) else { return .duplicate }
        let entry = TVBoxSite(key: a, name: name.isEmpty ? URL(string: a)?.host ?? "自定义点播" : name,
                              api: a, type: 1)
        customSites.insert(entry, at: 0)
        persistCustom()
        objectWillChange.send()
        return .ok(site: entry)
    }

    /// 探测自定义点播源是否可用（ac=list 拉一页），供添加时给结果、也供列表「测试」按钮复用。
    public func probeSite(api: String, timeout: TimeInterval = 8) async -> String? {
        let a = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard a.hasPrefix("http"), var comp = URLComponents(string: a) else { return "地址格式不合法" }
        var items = comp.queryItems ?? []
        items.removeAll { $0.name == "ac" || $0.name == "pg" }
        items.append(URLQueryItem(name: "ac", value: "list"))
        comp.queryItems = items
        guard let u = comp.url else { return "地址格式不合法" }
        do {
            let (data, resp) = try await URLSession.shared.data(from: u)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return "HTTP \(((resp as? HTTPURLResponse)?.statusCode).map(String.init) ?? "无响应")"
            }
            guard let text = TVBoxFetcher.decodeAuto(data) ?? String(data: data, encoding: .utf8),
                  text.contains("class") || text.contains("list") else { return "返回内容不是有效 CMS 接口" }
            return nil   // 通过
        } catch {
            return "网络不可达（\(error.localizedDescription)）"
        }
    }

    public func removeSite(_ site: TVBoxSite) {
        if site.key.hasPrefix("builtin:") {
            // 内置源删除 = 持久标记（可随时恢复），非物理删除
            deletedBuiltinKeys.insert(site.key)
            persistDeletedBuiltinSites()
            objectWillChange.send()
        } else {
            customSites.removeAll { $0.id == site.id }
            persistCustom()
        }
    }

    // MARK: 自定义直播源（单独添加，不依赖订阅）

    @discardableResult
    public func addLive(name: String, url: String) -> AddOutcome {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return .emptyURL }
        guard u.hasPrefix("http") else { return .badURL }
        guard !customLives.contains(where: { $0.m3uURLs == [u] }) else { return .duplicate }
        let gname = name.isEmpty ? "自定义直播" : name
        let group = TVBoxLiveGroup(name: gname, m3uURLs: [u])
        customLives.insert(group, at: 0)
        persistCustom()
        objectWillChange.send()
        return .ok(site: TVBoxSite(key: u, name: gname, api: u, type: 1))
    }

    /// 探测自定义直播源（m3u/txt/json 或直链），返回 nil = 通过，否则给原因。
    public func probeLive(url: String, timeout: TimeInterval = 10) async -> String? {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u.hasPrefix("http"), let url0 = URL(string: u) else { return "地址格式不合法" }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url0)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return "HTTP \(((resp as? HTTPURLResponse)?.statusCode).map(String.init) ?? "无响应")"
            }
            guard !data.isEmpty else { return "返回内容为空" }
            let text = TVBoxFetcher.decodeAuto(data) ?? String(data: data, encoding: .utf8) ?? ""
            // 认三种：m3u(#EXTM3U)、TVBox txt(频道名,#genre#)、json(含 lives/channels)
            let ok = text.contains("#EXTM3U") || text.contains("#genre#")
                || text.contains("\"lives\"") || text.contains("\"channels\"") || text.contains(",#")
            return ok ? nil : "内容不是可识别的直播源（需 m3u / TVBox txt / json）"
        } catch {
            return "网络不可达（\(error.localizedDescription)）"
        }
    }

    public func removeLive(_ group: TVBoxLiveGroup) {
        customLives.removeAll { $0.id == group.id }
        persistCustom()
    }

    // MARK: 内置源管理（用户钦定：实测能用的内置，但要能删除）

    /// 【旧】统一墓碑键。历史上「内置线路」与「内置点播源」共用一个集合，导致两个可见缺陷
    /// （2026-09-22 用户报「我发现内置源消失」后拆分）：
    ///   ① 删了一条**线路**，却在**点播源**区冒出「恢复内置（N 个已删）」；
    ///   ② 点一次「恢复」把两类一起复活，用户无法只恢复其中一类。
    /// 仅保留用于一次性迁移读取，新写入一律走下面两个分键。
    private static let legacyDeletedBuiltinKey = "tvbox.deletedBuiltinKeys"
    /// 内置**点播源**墓碑（key 形如 `builtin:suoni`）。
    private static let deletedBuiltinSiteKey = "tvbox.deletedBuiltinSiteKeys"
    /// 内置**线路**墓碑（url 形如 `bundle:builtin_curated` / `https://…`）。
    private static let deletedBuiltinRepoKey = "tvbox.deletedBuiltinRepoURLs"

    /// 被用户删除的内置**点播源** key（持久化，删除持久生效）。
    @Published public private(set) var deletedBuiltinKeys: Set<String> = []

    /// 被用户删除的内置**线路** url（持久化）。与点播源墓碑严格分离，互不串台。
    @Published public private(set) var deletedBuiltinRepoURLs: Set<String> = []

    public var hasDeletedBuiltins: Bool { !deletedBuiltinKeys.isEmpty }
    public var hasDeletedBuiltinRepos: Bool { !deletedBuiltinRepoURLs.isEmpty }

    /// 恢复全部被删的内置**点播源**（只恢复点播源，不动线路）。
    public func restoreBuiltins() {
        deletedBuiltinKeys.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.deletedBuiltinSiteKey)
        objectWillChange.send()
    }

    /// 恢复全部被删的内置**线路**（只恢复线路，不动点播源）。
    public func restoreBuiltinRepos() {
        deletedBuiltinRepoURLs.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.deletedBuiltinRepoKey)
        objectWillChange.send()
    }

    private func persistDeletedBuiltinSites() {
        UserDefaults.standard.set(Array(deletedBuiltinKeys), forKey: Self.deletedBuiltinSiteKey)
    }

    private func persistDeletedBuiltinRepos() {
        UserDefaults.standard.set(Array(deletedBuiltinRepoURLs), forKey: Self.deletedBuiltinRepoKey)
    }

    // MARK: 展示与播放合并（配置来源 + 手动自定义来源统一出口）

    /// 合并展示：内置源（未删除，排最前）+ 手动自定义源 + 当前生效配置解析结果。
    public var displayResult: TVBoxParseResult {
        var r = lastResult ?? TVBoxParseResult()
        var seen = Set<String>()
        var builtins: [TVBoxSite] = []
        for s in DefaultSites.builtinVodSources(forMode: productMode) where !deletedBuiltinKeys.contains(s.key) {
            if seen.insert(s.id).inserted { builtins.append(s) }
        }
        var customs: [TVBoxSite] = []
        for s in customSites where seen.insert(s.id).inserted { customs.append(s) }
        var parsed = r.sites
        r.sites = builtins + customs + parsed.filter { seen.insert($0.id).inserted }
        var seenLives = Set(r.lives.map(\.id))
        for l in customLives where seenLives.insert(l.id).inserted { r.lives.append(l) }
        return r
    }

    /// 全部自定义直播频道（直播页合并展示；手动源不依赖配置激活，始终生效）。
    public var customLiveChannels: [LiveChannel] {
        var out: [LiveChannel] = []
        var seen = Set<String>()
        for group in (lastResult?.lives ?? []) + customLives {
            for u in group.m3uURLs {
                if Self.isExpandableListAddress(u) { continue }   // 列表地址（m3u/txt/json）需异步展开，不是直链
                if seen.insert(u).inserted, let url = URL(string: u) {
                    out.append(LiveChannel(id: u, name: group.name, url: url))
                }
            }
        }
        return out
    }

    /// 列表型直播地址（需异步拉取展开为频道列表）：m3u/m3u8/txt/json。
    /// 此前只认 .m3u —— txt 直播地址被误当「直链频道」塞进播放列表，是「添加了直播源还是不能用」根因之一。
    public static func isExpandableListAddress(_ u: String) -> Bool {
        let lower = u.lowercased()
        return lower.contains(".m3u") || lower.contains(".txt") || lower.contains(".json")
    }

    /// 需要异步拉取展开的直播列表地址（M3U 与 TVBox txt 均在此列；配置来源 + 手动来源）。
    public var customM3UAddresses: [String] {
        var out: [String] = []
        for group in (lastResult?.lives ?? []) + customLives {
            for u in group.m3uURLs where Self.isExpandableListAddress(u) {
                if !out.contains(u) { out.append(u) }
            }
        }
        return out
    }

    /// 展开一个直播列表地址为频道列表（GBK 源自动兜底解码；M3UParser 已统一支持 M3U/TVBox txt 双格式）。
    public func expandM3U(_ address: String) async -> [LiveChannel] {
        // 夜航模式透传私有仓 token（成人直播文件在私有 feed 仓，jsDelivr 拉不到）
        let tok = productMode == "adult" ? FeedSecret.yehangFeedToken : ""
        // ③直播慢修复 2026-09-22：直播列表 8s 快速失败（原 15s × 多候选兜底拖慢整个聚合）
        guard let data = await TVBoxFetcher.fetch(address, timeout: 8, authToken: tok.isEmpty ? nil : tok),
              let text = TVBoxFetcher.decodeAuto(data) else { return [] }
        return M3UParser.parse(text)
    }

    // MARK: 数据备份（TVBox「数据备份」：配置历史 + 当前生效态 + 自定义源 整包导出/导入）

    private struct BackupPayload: Codable {
        var subscriptions: [TVBoxSubscription] = []
        var activeURL: String?
        var activeRepoURL: String?
        var sites: [TVBoxSite] = []
        var lives: [TVBoxLiveGroup] = []
    }

    /// 导出全部配置为 JSON 文本（配合剪贴板 = TVBox「复制配置」分享语义）。
    public func exportState() -> String? {
        let payload = BackupPayload(subscriptions: subscriptions, activeURL: activeURL,
                                    activeRepoURL: activeRepoURL,
                                    sites: customSites, lives: customLives)
        guard let d = try? FilmJSON.encoder().encode(payload) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// 从 JSON 文本导入配置（配合剪贴板 = TVBox「粘贴配置」导入语义）；成功后建议 refreshAll。
    @discardableResult
    public func importState(_ text: String) -> Bool {
        guard let d = text.data(using: .utf8),
              let p = try? FilmJSON.decoder().decode(BackupPayload.self, from: d) else { return false }
        subscriptions = p.subscriptions
        activeURL = p.activeURL
        activeRepoURL = p.activeRepoURL
        customSites = p.sites
        customLives = p.lives
        lastResult = nil
        persist()
        persistState()
        persistCustom()
        return true
    }

    // MARK: 持久化

    private func load() {
        if let d = try? Data(contentsOf: fileURL),
           let subs = try? FilmJSON.decoder().decode([TVBoxSubscription].self, from: d) {
            subscriptions = subs
        }
        if let d = try? Data(contentsOf: stateURL),
           let s = try? FilmJSON.decoder().decode(ActiveState.self, from: d) {
            activeURL = s.activeURL
            activeRepoURL = s.activeRepoURL
            activeBuiltinRepoURL = s.activeBuiltinRepoURL
        } else if activeURL == nil {
            // 旧版本迁移：历史里启用中的第一条 → 当前生效
            activeURL = subscriptions.first(where: \.enabled)?.url ?? subscriptions.first?.url
            persistState()
        }
        if let d = try? Data(contentsOf: customURL),
           let c = try? FilmJSON.decoder().decode(CustomSources.self, from: d) {
            customSites = c.sites
            customLives = c.lives
        }
        // 墓碑载入 + 旧统一键一次性迁移（2026-09-22 拆分为「点播源」「线路」两个集合）。
        // 迁移判据：`builtin:` 前缀 = 点播源 key；其余（bundle:/http…）= 线路 url。
        // 迁移是幂等的：旧键读完即删，重复启动不会二次分拣。
        if let legacy = UserDefaults.standard.stringArray(forKey: Self.legacyDeletedBuiltinKey) {
            for k in legacy {
                if k.hasPrefix("builtin:") { deletedBuiltinKeys.insert(k) }
                else { deletedBuiltinRepoURLs.insert(k) }
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyDeletedBuiltinKey)
            persistDeletedBuiltinSites()
            persistDeletedBuiltinRepos()
        }
        if let arr = UserDefaults.standard.stringArray(forKey: Self.deletedBuiltinSiteKey) {
            deletedBuiltinKeys.formUnion(arr)
        }
        if let arr = UserDefaults.standard.stringArray(forKey: Self.deletedBuiltinRepoKey) {
            deletedBuiltinRepoURLs.formUnion(arr)
        }
        let resultURL = fileURL.deletingLastPathComponent().appendingPathComponent("tvbox_last_result.json")
        if let d = try? Data(contentsOf: resultURL),
           let r = try? FilmJSON.decoder().decode(TVBoxParseResult.self, from: d) {
            lastResult = r
        }
    }

    private func persist() {
        if let data = try? FilmJSON.encoder().encode(subscriptions) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func persistState() {
        let s = ActiveState(activeURL: activeURL, activeRepoURL: activeRepoURL,
                            activeBuiltinRepoURL: activeBuiltinRepoURL)
        if let data = try? FilmJSON.encoder().encode(s) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func persistCustom() {
        let c = CustomSources(sites: customSites, lives: customLives)
        if let data = try? FilmJSON.encoder().encode(c) {
            try? data.write(to: customURL, options: .atomic)
        }
    }

    private func persistResult() {
        guard let result = lastResult else { return }
        let resultURL = fileURL.deletingLastPathComponent().appendingPathComponent("tvbox_last_result.json")
        if let data = try? FilmJSON.encoder().encode(result) {
            try? data.write(to: resultURL, options: .atomic)
        }
    }
}
