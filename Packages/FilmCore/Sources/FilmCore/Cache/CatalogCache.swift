import Foundation

/// 目录快照缓存：首屏秒开（快照优先），后台再增量同步。
/// 版本键 = feedVersion@mode@adapterVersion，feed 版本或适配器变更时强制重建（防旧源残留）。
public final class CatalogCache {

    /// 2026-09-23: v1-20260923-area —— FeedItem 新增 `area`（地区筛选），旧快照无此字段 → 强制重建。
    public static let adapterVersion = "ios-v1-20260923-home"
    private let fileURL: URL
    private let queue = DispatchQueue(label: "film.catalogcache")

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("catalog_snapshot.json")
    }

    public struct Snapshot: Codable {
        public var versionKey: String
        public var catalog: Catalog
        public var ledger: DataLedger
        public var savedAt: Date
    }

    public func save(_ snapshot: Snapshot) {
        queue.async {
            // v76.1 取证：146MB JSON 的编码+落盘到底多久、成没成 —— 这是「每次启动白拉 150MB」的关键一环
            let t0 = Date()
            guard let data = try? FilmJSON.encoder().encode(snapshot) else {
                LiveDiag.write("快照·save 编码失败 items=\(snapshot.catalog.items.count)")
                return
            }
            let encMs = Int(-t0.timeIntervalSinceNow * 1000)
            let t1 = Date()
            do {
                try data.write(to: self.fileURL, options: .atomic)
            } catch {
                LiveDiag.write("快照·save 写盘失败 \(data.count)B enc=\(encMs)ms err=\(error.localizedDescription)")
                return
            }
            LiveDiag.write("快照·save ok \(data.count)B enc=\(encMs)ms write=\(Int(-t1.timeIntervalSinceNow * 1000))ms items=\(snapshot.catalog.items.count)")
        }
    }

    public func load() -> Snapshot? {
        // 同步读（启动一次性小成本），异常返回 nil 走网络路径
        // v76.1 取证：读没读到 / 多大 / 解析成没成 / 多久 —— 失败时 `try?` 会吞掉一切原因
        let t0 = Date()
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
        guard let data = try? Data(contentsOf: fileURL) else {
            LiveDiag.write("快照·load 读不到文件 size=\(size) 用时=\(Int(-t0.timeIntervalSinceNow * 1000))ms")
            return nil
        }
        let readMs = Int(-t0.timeIntervalSinceNow * 1000)
        let t1 = Date()
        do {
            let snap = try FilmJSON.decoder().decode(Snapshot.self, from: data)
            LiveDiag.write("快照·load ok \(data.count)B read=\(readMs)ms decode=\(Int(-t1.timeIntervalSinceNow * 1000))ms " +
                           "items=\(snap.catalog.items.count) key=\(snap.versionKey)")
            return snap
        } catch {
            LiveDiag.write("快照·load 解析失败 \(data.count)B read=\(readMs)ms " +
                           "decode=\(Int(-t1.timeIntervalSinceNow * 1000))ms err=\(error)")
            return nil
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// 收藏 / 播放历史 / 最近观看（JSON 文件持久化，主线程模型）。
@MainActor
public final class UserLibrary: ObservableObject {

    public static let shared = UserLibrary()

    @Published public private(set) var favorites: [FeedItem] = []
    @Published public private(set) var history: [WatchEntry] = []   // 按最近观看倒序
    /// ★ v78.4：磁盘内容是否已解码落定。`load()` 是**异步**的（2026-09-30 启动提速），
    /// 在此之前 `history` 恒为空 —— 任何「续播决策」都必须先 `await ensureLoaded()`，
    /// 否则会读到空数组，把「接着上次看」退化成「从头播」（主人 2026-10-05 报的现象）。
    @Published public private(set) var isLoaded = false
    private var loadTask: Task<Void, Never>?

    /// 等到收藏/历史解码完成（已就绪时立即返回，零等待、无阻塞）。
    /// 调用点：详情页「播放/续播」与自动续播通道 —— 那是唯一依赖历史的用户可见决策。
    public func ensureLoaded() async { await loadTask?.value }

    private let favoritesURL: URL
    private let historyURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        favoritesURL = dir.appendingPathComponent("favorites.json")
        historyURL = dir.appendingPathComponent("history.json")
        load()
    }

    // MARK: - 收藏

    public func isFavorite(_ item: FeedItem) -> Bool {
        favorites.contains { $0.dedupId == item.dedupId }
    }

    public func toggleFavorite(_ item: FeedItem) {
        if let idx = favorites.firstIndex(where: { $0.dedupId == item.dedupId }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(item, at: 0)
        }
        persist(favorites, to: favoritesURL)
    }

    // MARK: - 播放历史 / 最近观看

    public struct WatchEntry: Codable, Identifiable {
        public var id: String { item.dedupId }
        public var item: FeedItem
        public var playedAt: Date
        public var progressSeconds: Double
        public var durationSeconds: Double
        public var lineIndex: Int
    }

    public func recordWatch(_ item: FeedItem, progress: Double, duration: Double, lineIndex: Int) {
        history.removeAll { $0.item.dedupId == item.dedupId }
        history.insert(WatchEntry(item: item, playedAt: Date(),
                                  progressSeconds: progress, durationSeconds: duration, lineIndex: lineIndex), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        persist(history, to: historyURL)
    }

    public func historyEntry(for item: FeedItem) -> WatchEntry? {
        history.first { $0.item.dedupId == item.dedupId }
    }

    /// 清空全部播放历史（我的页「清空」入口）。
    public func clearHistory() {
        history.removeAll()
        persist(history, to: historyURL)
    }

    /// 删除单条历史（左滑）。
    public func removeHistoryEntry(id: String) {
        history.removeAll { $0.id == id }
        persist(history, to: historyURL)
    }

    // MARK: - 持久化

    private func load() {
        // 2026-09-30 启动提速：收藏/历史首帧前不再同步占主线程。
        // 历史最多 200 条、每条是**完整 FeedItem**（含 play/summary），文件可达数 MB——
        // 原来在 `@StateObject` 初始化里同步解码，直接顶住 App 首帧。改后台解码、回主线程赋值。
        // ★ v78.4：任务句柄留档 → `ensureLoaded()` 可等它；落定后置 `isLoaded`。
        loadTask = Task.detached(priority: .userInitiated) { [favoritesURL, historyURL] in
            var favs: [FeedItem] = []
            var hist: [WatchEntry] = []
            if let d = try? Data(contentsOf: favoritesURL),
               let f = try? FilmJSON.decoder().decode([FeedItem].self, from: d) { favs = f }
            if let d = try? Data(contentsOf: historyURL),
               let h = try? FilmJSON.decoder().decode([WatchEntry].self, from: d) { hist = h }
            await MainActor.run {
                // ★ v78.4：解码期间用户若已经写过（recordWatch/toggleFavorite/removeHistoryEntry），
                //   内存里就是**更新的一份**，不能被这份「旧盘内容」倒灌覆盖（否则刚看的进度会丢）。
                if self.history.isEmpty { self.history = hist }
                if self.favorites.isEmpty { self.favorites = favs }
                self.isLoaded = true
            }
        }
    }

    private func persist<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? FilmJSON.encoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
