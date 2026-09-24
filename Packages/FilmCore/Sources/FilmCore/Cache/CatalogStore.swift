import Foundation

/// 目录编排器（对应 Android DataManager 角色）：
/// 启动快照命中 → 秒开；未命中 → home.json 轻量包先渲染 → 后台全量分片同步 → 台账落盘。
/// 单飞闸门：同一时刻仅一个全量同步；刷新不阻塞 UI。
@MainActor
public final class CatalogStore: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case bootingFromHome       // home.json 轻量首屏
        case syncing(progress: Int, total: Int)
        case ready
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var catalog: Catalog = Catalog(items: [], categories: [])
    @Published public private(set) var ledger = DataLedger()
    @Published public private(set) var networkOffline = false
    /// 演员头像映射（演员名 → TMDB 头像 URL，persons.json）。
    /// 2026-09-25 演员小头像：详情页主演胶囊渲染用；空表时端上回退首字圆标。
    @Published public private(set) var personAvatars: [String: String] = [:]
    private var personAvatarsLoaded = false

    public let profile: ProductProfile
    private let client: FeedClient
    private let cache: CatalogCache
    private var syncing = false

    public init(profile: ProductProfile, lanBase: String? = nil) {
        self.profile = profile
        FilmLog.productTag = profile.appName
        self.client = FeedClient(bases: FeedBases(profile: profile, lanBase: lanBase))
        self.cache = CatalogCache()
    }

    // MARK: - 演员头像（2026-09-25 台账 247 行）

    /// 懒加载 persons.json（一次/会话）。文件未上线或失败静默为空表——
    /// 头像属增强功能，绝不因它让详情页报错或重试轰炸。
    public func loadPersonAvatarsIfNeeded() async {
        guard !personAvatarsLoaded else { return }
        personAvatarsLoaded = true
        guard let m = try? await client.fetchPersons(mode: profile.mode), !m.isEmpty else { return }
        personAvatars = m
        FilmLog.i("PERSONS avatars loaded: \(m.count)")
    }

    // MARK: - 启动

    /// App 启动入口：快照秒开 + 后台同步。
    public func boot() async {
        // 快照解码（13万条 JSON）放后台线程——主线程解码是「启动卡」根因之一（34包）
        let snap = await Task.detached(priority: .userInitiated) { [cache] in cache.load() }.value
        if let snap, snap.catalog.items.count > 0 {
            let versionKey = "\(snap.ledger.version ?? "nil")@\(profile.mode)@\(CatalogCache.adapterVersion)"
            if snap.versionKey == versionKey {
                catalog = snap.catalog
                ledger = snap.ledger
                phase = .ready
                FilmLog.i("BOOT snapshot hit: catalog=\(catalog.items.count)")
            }
        }
        if phase != .ready {
            // 35包根治：打开就要显示——内嵌快照先行即时上屏，不等任何网络；
            // 网络（home/全量）只做后台静默更新，永远不赌运气。
            if await applyEmbeddedSnapshot() {
                FilmLog.i("BOOT embedded snapshot first (35包)")
            } else {
                await bootFromHome()
            }
        }
        await syncAll()          // 后台全量（不阻塞已渲染的首屏）
    }

    /// 三端内嵌快照（35包起全端覆盖）：
    /// feed 分片全走 GitHub 系域名，手机网络间歇不通 → 全量同步失败 → 目录永远停在首屏40/分类。
    /// 快照随包（构建时从 feed 仓合并：adult=夜航2019部 / child=心屋3664部 / normal=星幕约3500部精选切片），
    /// 断网/同步失败也有可用目录；星幕全量 13 万条仍由后台同步补齐。
    private var snapshotResource: (file: String, enabled: Bool) {
        switch profile.mode {
        case "adult": return ("yehang_feed_snapshot", true)
        case "child": return ("xinwu_feed_snapshot", true)
        default: return ("xingmu_feed_snapshot", true)   // 35包：星幕也内嵌，打开就要显示
        }
    }

    private func loadEmbeddedSnapshot() -> [FeedItem]? {
        let (file, enabled) = snapshotResource
        guard enabled else { return nil }
        func read(_ name: String) -> Data? {
            let u = Bundle.module.url(forResource: name, withExtension: "json",
                                      subdirectory: "Resources")
                ?? Bundle.module.url(forResource: name, withExtension: "json")
            return u.flatMap { try? Data(contentsOf: $0) }
        }
        // 分片快照（2026-09-23）：大快照过不了 Git API 单 blob 通道（>30MB payload 被
        // 网关掐断/401/422）→ 主文件 + `_p1/_p2…` 续件，各自为合法 FeedPart，端上按序拼接。
        var all: [FeedItem] = []
        if let d = read(file), let m = try? FilmJSON.decoder().decode(FeedPart.self, from: d) {
            all += m.items
        }
        for p in 1...8 {
            guard let d = read(file + "_p\(p)"),
                  let m = try? FilmJSON.decoder().decode(FeedPart.self, from: d) else { break }
            all += m.items
        }
        return all.isEmpty ? nil : all
    }

    private func applyEmbeddedSnapshot() async -> Bool {
        guard snapshotResource.enabled, let items = loadEmbeddedSnapshot(), !items.isEmpty else { return false }
        let mode = profile.mode
        // 35包：聚合也下后台——快照 3~6MB 解码可容忍一次性开销，buildCatalog 循环不放主线程
        let (cat, led) = await Task.detached(priority: .userInitiated) {
            FeedAdapter.buildCatalog(items: items, mode: mode,
                                     manifestCount: items.count, homeCount: items.count,
                                     version: "embedded")
        }.value
        catalog = cat
        ledger = led
        phase = .ready
        FilmLog.i("EMBEDDED snapshot applied: \(items.count) items")
        return true
    }

    /// 轻量首屏：home.json（分类统计 + posters + pool≤500）。
    private func bootFromHome() async {
        phase = .bootingFromHome
        do {
            let home = try await client.fetchHome(mode: profile.mode)
            let manifestCount = max(home.total, (home.posters?.count ?? 0))
            let mode = profile.mode
            let homeCount = home.posters?.count ?? 0
            let (cat, led) = await Task.detached(priority: .userInitiated) {
                FeedAdapter.buildCatalog(items: (home.pool ?? []) + (home.posters ?? []),
                                         mode: mode,
                                         manifestCount: manifestCount,
                                         homeCount: homeCount,
                                         version: home.version)
            }.value
            // 首屏轻量包来源是 pool+posters，sourceCount 以 home.total 为准修正
            var led2 = led
            led2.sourceCount = home.total
            catalog = cat
            ledger = led2
            phase = .ready
        } catch {
            networkOffline = true
            if await applyEmbeddedSnapshot() { return }   // 三端内嵌快照兜底（35包起全覆盖）
            if catalog.items.isEmpty {
                phase = .failed(error.localizedDescription)
            } else {
                phase = .ready   // 已有旧缓存：降级可用，不白屏
            }
            FilmLog.w("BOOT home failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 全量同步（含防缩水闸门）

    public func syncAll() async {
        guard !syncing else { return }           // 单飞
        syncing = true
        defer { syncing = false }
        do {
            let manifest = try await client.fetchManifest(mode: profile.mode)
            let items = try await client.fetchAllParts(mode: profile.mode, manifest: manifest) { [weak self] done, total in
                // 节流（34包）：原每分片刷一次 @Published → 270+ 次全局重渲染 × 每次 13 万条货架重算 = 启动持续卡。
                // 每 8 片或最后一片才刷。
                guard done % 8 == 0 || done >= total else { return }
                Task { @MainActor in
                    self?.phase = .syncing(progress: done, total: total)
                }
            }
            // buildCatalog（13 万条去重/聚合/排序）放后台线程——主线程聚合是「启动卡」头号根因（34包）
            let mode = profile.mode
            let homeCount = ledger.homeCount
            let manifestCnt = manifest.count
            let mVersion = manifest.version
            let (cat, led) = await Task.detached(priority: .userInitiated) {
                FeedAdapter.buildCatalog(items: items,
                                         mode: mode,
                                         manifestCount: manifestCnt,
                                         homeCount: homeCount,
                                         version: mVersion)
            }.value
            // 数量守恒闸门：sync 后目录数不应低于 home 首屏口径，否则视为异常不覆盖现有目录
            if cat.items.count < ledger.catalogCount * 8 / 10, ledger.catalogCount > 50 {
                FilmLog.w("SHRINK GUARD: new=\(cat.items.count) < 80% of current=\(ledger.catalogCount); keep old")
            } else {
                catalog = cat
                ledger = led
                phase = .ready
                let versionKey = "\(manifest.version ?? "nil")@\(profile.mode)@\(CatalogCache.adapterVersion)"
                // 快照编码+写盘（13万条）后台化——同步落盘同样会卡主线程（34包）
                let snap = CatalogCache.Snapshot(versionKey: versionKey, catalog: cat, ledger: led, savedAt: Date())
                Task.detached(priority: .utility) { [cache] in cache.save(snap) }
            }
            networkOffline = false
        } catch {
            networkOffline = true
            FilmLog.w("SYNC failed: \(error.localizedDescription)")
            // 夜航/心屋：全量同步失败且目录还是首屏小目录 → 快照兜底补全量（28/30号包）
            if snapshotResource.enabled, catalog.items.count < 500 {
                if await applyEmbeddedSnapshot() { return }
            }
            if catalog.items.isEmpty { phase = .failed(error.localizedDescription) }
        }
    }

    // MARK: - 查询

    public func search(_ q: String) -> [FeedItem] { FeedAdapter.search(catalog.items, query: q) }

    /// 清除本地片库快照（设置页「清除缓存」入口；下次启动重新从 feed 同步）。
    public func clearSnapshot() {
        cache.clear()
    }

    public var homePosters: [FeedItem] {
        // 首页海报位：有图、可播，按质量分排序（对齐 Android homeFeatured 语义，不新增过滤规则）
        catalog.items.filter { $0.bestPosterURL != nil && $0.isPlayable }
            .sorted { ($0.qualityScore ?? 0) > ($1.qualityScore ?? 0) }
    }

    public var latestUpdated: [FeedItem] { catalog.items.prefix(60).map { $0 } }
}
