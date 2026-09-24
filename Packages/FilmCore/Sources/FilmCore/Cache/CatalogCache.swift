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
            guard let data = try? FilmJSON.encoder().encode(snapshot) else { return }
            try? data.write(to: self.fileURL, options: .atomic)
        }
    }

    public func load() -> Snapshot? {
        // 同步读（启动一次性小成本），异常返回 nil 走网络路径
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? FilmJSON.decoder().decode(Snapshot.self, from: data)
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
        if let d = try? Data(contentsOf: favoritesURL),
           let favs = try? FilmJSON.decoder().decode([FeedItem].self, from: d) { favorites = favs }
        if let d = try? Data(contentsOf: historyURL),
           let hist = try? FilmJSON.decoder().decode([WatchEntry].self, from: d) { history = hist }
    }

    private func persist<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? FilmJSON.encoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
