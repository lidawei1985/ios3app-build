import Foundation

/// FeedItem 是只读值类型（全是 let），跨线程传递安全；这里显式声明是为了让
/// `CatalogStore` 能在后台线程登记索引而不产生并发告警。
extension FeedItem: @unchecked Sendable {}

/// 片名 → 海报 的**本地兜底索引**（2026-10-17 「点播源海报一直转圈」根修配套）。
///
/// 为什么必须有这一层：
///  · 内置点播源的 `ac=list` 端点实测**海报字段 100% 为空**（10 源抽样：20~30 条/页，有图 0 条），
///    图只存在于 `ac=detail`。也就是说，源列表页的每一格都必须**额外发一次 detail** 才能拿到图；
///  · detail 是随源站状态波动的（实测同一个源 0.8s / 3.1s / 15s 超时都有），慢源一多，
///    整页海报就集体转圈。
///  · 而本地片库（catalog）里同一部片子**本来就有海报**（自家 CDN，快且稳）。
///
/// 所以：能靠片名在本地片库命中的，**立刻出图、零网络等待**；没命中的才去发 detail。
/// 这一层只是"兜底显示"，不影响点播源播放链路（播放仍走源自己的地址）。
///
/// 安全口径（宁可不出图，也不能张冠李戴）：
///  · 只在 `NavPolicy.canonicalTitle` **完全相等**时命中；
///  · 双方都有年份且相差 > 1 年 → 不命中（重名不同片用它挡住）；
///  · 标题归一化后长度 < 2 → 不索引也不查询（"1"、"a" 这类会大面积误配）。
public final class TitlePosterIndex: @unchecked Sendable {

    public static let shared = TitlePosterIndex()

    private struct Entry {
        let poster: String
        let year: Int?
    }

    private let lock = NSLock()
    private var map: [String: Entry] = [:]
    /// 上限：catalog 约 9 万条，但只有「有海报」的才入索引，实际几万；给到 200k 足够，
    /// 超了直接重建（重建比做 LRU 便宜，且数据源本身是全量快照）。
    private let capacity = 200_000

    private init() {}

    /// 年份字段在 FeedItem 里是字符串（各源混杂 "2024" / "2024-01-01" / 空），统一取前 4 位数字。
    private static func yearValue(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        var digits = ""
        for ch in raw {
            if ch.isNumber { digits.append(ch); if digits.count == 4 { break } }
            else if !digits.isEmpty { break }
        }
        return digits.count == 4 ? Int(digits) : nil
    }

    /// 批量登记（CatalogStore 每次 catalog 变化时调用；主线程调用，内部只做 map 写）。
    public func remember(_ items: [FeedItem]) {
        guard !items.isEmpty else { return }
        var fresh: [String: Entry] = [:]
        fresh.reserveCapacity(items.count)
        for it in items {
            guard let url = (it.poster?.url ?? it.backdrop?.url), !url.isEmpty, url.hasPrefix("http") else { continue }
            let key = NavPolicy.canonicalTitle(it.title)
            guard key.count >= 2 else { continue }
            if fresh[key] == nil { fresh[key] = Entry(poster: url, year: Self.yearValue(it.year)) }
        }
        guard !fresh.isEmpty else { return }
        lock.lock()
        if map.count + fresh.count > capacity { map = [:] }
        // 已有条目优先保留（先来的通常是主片库口径），增量只补空缺
        for (k, v) in fresh where map[k] == nil { map[k] = v }
        lock.unlock()
    }

    /// 按片名取本地海报（命中即秒回；未命中返回 nil，调用方再走网络）。
    public func poster(for title: String, year: String?) -> String? {
        let key = NavPolicy.canonicalTitle(title)
        guard key.count >= 2 else { return nil }
        lock.lock()
        let e = map[key]
        lock.unlock()
        guard let e else { return nil }
        let probe = Self.yearValue(year)
        if let a = e.year, let b = probe, abs(a - b) > 1 { return nil }
        return e.poster
    }

    /// 当前已索引条目数（诊断/日志用）。
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return map.count
    }
}
