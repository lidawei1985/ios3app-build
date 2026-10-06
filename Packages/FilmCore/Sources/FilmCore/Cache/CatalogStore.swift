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
    ///
    /// 36包 启动提速（用户 2026-09-26：「ISO 启动的时候首页显示的有点慢」）：
    /// 旧流程根因＝**串行等待 + 主线程解码**：
    ///  ① 先等磁盘缓存解码完（星幕全量 13 万条 JSON，数秒）才考虑上屏；
    ///  ② `loadEmbeddedSnapshot()` 的读文件+JSON 解码跑在主线程（@MainActor 上）。
    /// 新流程（三条，均不动数据格式）：
    ///  ① 内嵌快照读盘+解码放后台线程；
    ///  ② 内嵌快照（3~6MB，必然存在）与磁盘缓存**并发**解码，内嵌先上屏，
    ///     磁盘缓存（上次全量同步产物，更全）后到**静默升级**，绝不互相等待；
    ///  ③ 升级仅当新目录数 ≥ 当前（防降级闪变）。
    /// 2026-09-30 启动提速（用户：「直接把启动太慢的问题解决了吧 点开半天打不开」）——
    /// 上一版（36包）只把「读盘+解码」挪到后台，仍有三处结构性浪费：
    ///  ① 内嵌三片（主件 9945 + p1 3621 + p2 6433 ≈ **54MB JSON**）**解完才上屏**，首屏白等 3 倍；
    ///  ② 磁盘快照（全量同步产物，星幕 8.98 万条 ≈ **150MB**）与首屏解码**同优先级并发**，抢 CPU；
    ///  ③ 每片读盘用 `Data(contentsOf:)` 顺序读，且 `syncAll()` 每次启动重拉 180 片 ≈150MB。
    /// 本版三改（均不动数据格式，不动判据）：
    ///  ① **主件先上屏**：主件与 p1/p2 的 dedup_id 零重复 → 9945 条本身自洽，足够铺满首屏；
    ///  ② 续件与磁盘快照**后置 + 降 .utility**：首屏已在屏上，两路只做静默升级，绝不抢首屏的核；
    ///  ③ 全量同步加版本闸门（见 `syncAll`）：内容版本未变不再重拉。
    public func boot() async {
        let mode = profile.mode
        let t0 = Date()
        MainThreadWatchdog.start()   // v76：启动即开主线程看门狗（卡 ≥300ms 记黑匣子）
        // v76.2：本地持久化往返自检（几十微秒）。这条就是本次「快照 100% 解不开」的守门人 ——
        // 以后再有人给 DataLedger 加「URL/ID/OK 连写」字段，第一轮启动黑匣子就会写 FAIL。
        LiveDiag.write("自检·DataLedger 往返 \(DataLedger.selfCheckRoundTrip())")
        var lastStage = t0
        func stage(_ label: String, _ n: Int) {
            let now = Date()
            let gap = Int(now.timeIntervalSince(lastStage) * 1000)
            let total = Int(now.timeIntervalSince(t0) * 1000)
            lastStage = now
            FilmLog.i("BOOT \(label): items=\(n) at \(total)ms")
            // v76：os_log 在 LC guest 里抓不到（历史教训），启动各阶段耗时一并进黑匣子
            LiveDiag.write("启动·\(label) n=\(n) 本段=\(gap)ms 累计=\(total)ms")
        }

        // ① 首屏：只解内嵌**主件**就先上屏（不等续件、不等磁盘快照）。
        let mainItems = await Task.detached(priority: .userInitiated) { () -> [FeedItem]? in
            Self.loadEmbeddedShard(mode: mode, name: Self.embeddedSnapshotFile(mode: mode))
        }.value
        if let items = mainItems, !items.isEmpty {
            await applyEmbedded(items: items)
            stage("main shard on screen", items.count)
        }

        // ② 续件（p1…p8）先补，再解磁盘快照——**串行且 .utility**，首屏不再被抢核。
        let restItems = await Task.detached(priority: .utility) { () -> [FeedItem] in
            Self.loadEmbeddedRest(mode: mode)
        }.value
        if !restItems.isEmpty {
            var merged = mainItems ?? []
            merged += restItems
            await applyEmbedded(items: merged)
            stage("shards merged", merged.count)
        }

        // ③ 磁盘快照（上次全量同步产物）：版本合法且更全 → 静默升级（不降级）
        MainThreadMark.set("磁盘快照 load")
        let snap = await Task.detached(priority: .utility) { [cache] in cache.load() }.value
        MainThreadMark.set("磁盘快照 判定")
        if let snap, snap.catalog.items.count > 0 {
            let versionKey = "\(snap.ledger.version ?? "nil")@\(profile.mode)@\(CatalogCache.adapterVersion)"
            if snap.versionKey == versionKey, snap.catalog.items.count >= catalog.items.count {
                MainThreadMark.set("目录落位(快照) n=\(snap.catalog.items.count)")
                catalog = snap.catalog
                ledger = snap.ledger
                phase = .ready
                stage("disk snapshot upgraded", catalog.items.count)
            } else {
                // v76.1 取证：为什么没用上快照 —— 两种拒绝原因分开写清楚
                LiveDiag.write("快照·拒绝 键不符=\(snap.versionKey != versionKey) " +
                               "条数不足=\(snap.catalog.items.count < catalog.items.count) " +
                               "snapKey=\(snap.versionKey) 期望=\(versionKey) snap=\(snap.catalog.items.count) 当前=\(catalog.items.count)")
            }
        } else {
            LiveDiag.write("快照·未命中（load 返回空）")
        }
        // ④ 两路都没出目录（无内嵌资源且缓存空/旧格式）→ 走网络轻量首屏
        if phase != .ready, catalog.items.isEmpty {
            await bootFromHome()
        }
        await syncAll()          // 后台全量（版本闸门内建，内容未变不再重拉）
        stage("boot done (syncAll returned)", catalog.items.count)
    }

    /// 双端内嵌快照（35包起全端覆盖）：
    /// feed 分片全走 GitHub 系域名，手机网络间歇不通 → 全量同步失败 → 目录永远停在首屏40/分类。
    /// 快照随包（构建时从 feed 仓合并：child=心屋3664部 / normal=星幕约3500部精选切片），
    /// 断网/同步失败也有可用目录；星幕全量 13 万条仍由后台同步补齐。
    nonisolated private static func embeddedSnapshotFile(mode: String) -> String? {
        switch mode {
        case "child": return "xinwu_feed_snapshot"
        default: return "xingmu_feed_snapshot"   // 35包：星幕也内嵌，打开就要显示
        }
    }

    /// 内嵌快照读盘+解码（nonisolated：36包提速，允许在后台线程执行，不再占主线程）。
    /// 分片快照（2026-09-23）：大快照过不了 Git API 单 blob 通道（>30MB payload 被
    /// 网关掐断/401/422）→ 主文件 + `_p1/_p2…` 续件，各自为合法 FeedPart，端上按序拼接。
    nonisolated private static func loadEmbeddedSnapshot(mode: String) -> [FeedItem]? {
        var all: [FeedItem] = []
        if let m = loadEmbeddedShard(mode: mode, name: embeddedSnapshotFile(mode: mode)) { all += m }
        all += loadEmbeddedRest(mode: mode)
        return all.isEmpty ? nil : all
    }

    /// 读**单个**内嵌分片并解码（主件 / pN 续件通用）。读盘+解码均可在后台线程执行。
    /// 2026-09-30 首屏提速：主件可单独解出先上屏，不再被续件拖住。
    nonisolated private static func loadEmbeddedShard(mode: String, name: String?) -> [FeedItem]? {
        guard let name else { return nil }
        let u = Bundle.module.url(forResource: name, withExtension: "json",
                                  subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        guard let u, let d = try? Data(contentsOf: u),
              let m = try? FilmJSON.decoder().decode(FeedPart.self, from: d) else { return nil }
        return m.items.isEmpty ? nil : m.items
    }

    /// 读 p1…p8 续件（主件之外的部分）。
    nonisolated private static func loadEmbeddedRest(mode: String) -> [FeedItem] {
        guard let file = embeddedSnapshotFile(mode: mode) else { return [] }
        var all: [FeedItem] = []
        for p in 1...8 {
            guard let m = loadEmbeddedShard(mode: mode, name: file + "_p\(p)") else { break }
            all += m
        }
        return all
    }

    /// 应用内嵌快照（读取已在外层后台化）。36包提速：只做目录构建与状态落位。
    private func applyEmbedded(items: [FeedItem]) async {
        guard !items.isEmpty else { return }
        let mode = profile.mode
        // 35包：聚合也下后台——快照 3~6MB 解码可容忍一次性开销，buildCatalog 循环不放主线程
        let (cat, led) = await Task.detached(priority: .userInitiated) {
            FeedAdapter.buildCatalog(items: items, mode: mode,
                                     manifestCount: items.count, homeCount: items.count,
                                     version: "embedded")
        }.value
        guard cat.items.count >= catalog.items.count else {
            // 已有更全目录（磁盘缓存/首屏包先到）→ 不降级，但目录非空必须离开骨架屏
            if !catalog.items.isEmpty { phase = .ready }
            return
        }
        MainThreadMark.set("目录落位(内嵌) n=\(cat.items.count)")
        catalog = cat
        ledger = led
        phase = .ready
    }

    /// 兼容入口（bootFromHome / syncAll 兜底路径沿用）：读盘 + 应用，一条龙。
    private func applyEmbeddedSnapshot() async -> Bool {
        let mode = profile.mode
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.loadEmbeddedSnapshot(mode: mode)
        }.value
        guard let items = loaded, !items.isEmpty else { return false }
        await applyEmbedded(items: items)
        return phase == .ready
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

    /// 上次成功全量同步的 feed 版本 / 时刻（版本闸门用；UserDefaults 比磁盘快照更耐久，清缓存不丢）。
    private static let lastSyncVersionKey = "catalog.lastFullSyncVersion"
    private static let lastSyncAtKey = "catalog.lastFullSyncAt"

    public func syncAll(force: Bool = false) async {
        guard !syncing else { return }           // 单飞
        syncing = true
        defer { syncing = false }
        do {
            let manifest = try await client.fetchManifest(mode: profile.mode)

            // 版本闸门（2026-09-30 启动提速）：内容版本未变且本地已是「全量级」目录 → 不再重拉。
            // 星幕全量 = 180 片 ≈ 150MB（8.98 万条）；旧流程**每次冷启动都重拉一遍**：
            // 下载 150MB + 解码 180 片 + buildCatalog 9 万条 + 编码写盘 150MB，首屏被这堆活饿死。
            // 三条同时成立才跳：① 版本号与上次成功全量一致；② 本地目录 ≥ manifest 一半
            // （说明磁盘快照已把目录恢复成「全量级」，不是内嵌 2 万条的首屏档）；③ 距上次全量 < 7 天。
            // 任一不成立照常全量；用户下拉刷新 / 点「手动刷新片库」传 force=true 可强制全量。
            let lastVer = UserDefaults.standard.string(forKey: Self.lastSyncVersionKey)
            let lastAt = UserDefaults.standard.object(forKey: Self.lastSyncAtKey) as? Date
            let fresh = lastAt.map { Date().timeIntervalSince($0) < 7 * 86_400 } ?? false
            let fullEnough = manifest.count > 0 && catalog.items.count >= manifest.count / 2
            if !force, fresh, fullEnough, let lastVer, manifest.version == lastVer {
                FilmLog.i("SKIP full sync: version=\(lastVer) unchanged, catalog=\(catalog.items.count)/\(manifest.count)")
                networkOffline = false
                return
            }

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
                MainThreadMark.set("目录落位(全量) n=\(cat.items.count)")
                catalog = cat
                ledger = led
                phase = .ready
                let versionKey = "\(manifest.version ?? "nil")@\(profile.mode)@\(CatalogCache.adapterVersion)"
                // 快照编码+写盘（13万条）后台化——同步落盘同样会卡主线程（34包）
                let snap = CatalogCache.Snapshot(versionKey: versionKey, catalog: cat, ledger: led, savedAt: Date())
                Task.detached(priority: .utility) { [cache] in cache.save(snap) }
                // 版本闸门记账：本次全量成功 → 记版本 + 时刻，供下次启动判断能否跳过。
                if let v = manifest.version { UserDefaults.standard.set(v, forKey: Self.lastSyncVersionKey) }
                UserDefaults.standard.set(Date(), forKey: Self.lastSyncAtKey)
            }
            networkOffline = false
        } catch {
            networkOffline = true
            FilmLog.w("SYNC failed: \(error.localizedDescription)")
            // 心屋等端：全量同步失败且目录还是首屏小目录 → 快照兜底补全量（28/30号包）
            if Self.embeddedSnapshotFile(mode: profile.mode) != nil, catalog.items.count < 500 {
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
