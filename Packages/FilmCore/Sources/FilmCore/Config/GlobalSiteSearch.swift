import Foundation

/// 全局跨源搜索（2026-10-01 用户钦定：「全部带搜索都搜全部源内容」）。
///
/// 此前各页搜索各搜各的池（主页 `prefix(8/12/14)` 截流、浏览页只搜本站、
/// 剧集页只搜本地快照/本片源）→ 统一收拢到一个引擎：**全量内置源**并发检索，
/// 结果统一过 `NavPolicy.allowsItem` 端隔离（心屋不出现成人 —— 儿童端红线原样保留）。
///
/// 性能设计（全量源 = 星幕约 40 / 夜航约 64，单源超时 30s）：
///  - **健康源优先**（`SourceHealth.sortKey` 熔断源沉底）→ 前两批基本就出结果；
///  - **分批并发**（每批 12 源）+ 渐进回调（`onBatch` 传累计去重快照）→ 先到先上屏；
///  - 每源限流（prefix 12）+ 全局限流（120），防单页爆量拖垮渲染。
public enum GlobalSiteSearch {

    /// 按端取全量点播源池（健康优先排序）。
    ///
    /// 池构成：剧集源 + `builtinVodSources(forMode:)`（心屋 = 仅共通源，成人源**物理排除**；
    /// 星幕/夜航 = 共通 + 成人 —— 2026-09-30 用户钦定口径）。
    /// Spider 引擎源未移植，跳过；熔断/半开源沉底但保留（冷却后半开探测自愈，与「切换源」面板同口径）。
    public static func pool(forMode mode: String) -> [TVBoxSite] {
        var p = DefaultSites.tvDramaSources + DefaultSites.builtinVodSources(forMode: mode)
        p.sort { SourceHealth.shared.sortKey($0.key) < SourceHealth.shared.sortKey($1.key) }
        return p.filter { $0.type != 3 }
    }

    /// 跨全源搜索。
    /// - Parameter onBatch: **每有任一源返回就回调**一次累计去重快照（先到先上屏）。
    /// - Parameter budget: 交互预算（秒）。到点即停——剩下的源不要了，用户已经能看到东西。
    /// - Returns: 最终全量去重结果（≤ totalLimit）。
    ///
    /// 2026-10-02「搜索好慢」根治（78 源实测：中位 2.1s、最慢 38.6s、6 个源 >22s）：
    ///  - **不再分批**。旧写法 `batchSize=12` 分 7 批，而批内要**等最慢那个源**才回调，
    ///    于是慢源被重复计了 7 次 → 总耗时 ≈ 各批最慢之和（实测 **58.9s**）。
    ///    搜索各源之间毫无依赖，全量一次并发即可，总耗时 = 最慢那个源（再被 8s 超时掐到 8s）。
    ///  - **边收边上屏**：`group.next()` 回来一个就 absorb 一个、回调一次，
    ///    首屏时间 = 最快那个源（实测 **0.38s**），不再是"第一批 12 个全回来"。
    ///  - **预算到点就走**：`budget` 秒后 `cancelAll()`，不再为长尾源干等。
    @discardableResult
    public static func search(
        _ raw: String, mode: String,
        perSourceLimit: Int = 12, totalLimit: Int = 120, budget: TimeInterval = 6.0,
        onBatch: (([FeedItem]) -> Void)? = nil
    ) async -> [FeedItem] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let sites = pool(forMode: mode)

        return await withTaskGroup(of: [FeedItem]?.self) { group in
            for site in sites {
                group.addTask {
                    // 只捕获不可变量（site/q/mode/perSourceLimit），可变状态一律留在 group 体内——
                    // 并发闭包里改共享状态既不安全，Swift 严格并发下也过不了编译
                    let c = TVBoxSiteClient.shared(for: site)
                    let r = await c.search(q).filter {
                        NavPolicy.allowsItem(title: $0.title,
                                             sourceCategory: $0.aggregateCategoryName,
                                             mode: mode)
                    }
                    return r.isEmpty ? nil : Array(r.prefix(perSourceLimit))
                }
            }

            var acc: [FeedItem] = []
            var seen = Set<String>()
            let deadline = Date().addingTimeInterval(budget)
            while let r = await group.next() {
                guard let r else { continue }
                var added = false
                for it in r where acc.count < totalLimit {
                    let k = it.title + "|" + (it.year ?? "")
                    if seen.insert(k).inserted { acc.append(it); added = true }
                }
                if added { onBatch?(acc) }
                if acc.count >= totalLimit || Date() > deadline { group.cancelAll() }
            }
            return acc
        }
    }
}
