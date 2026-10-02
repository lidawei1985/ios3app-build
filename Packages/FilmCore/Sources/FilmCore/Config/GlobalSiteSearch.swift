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
    /// - Parameter onBatch: 每批完成后回调**累计去重快照**（调用方直接整体上屏即可）。
    /// - Returns: 最终全量去重结果（≤ totalLimit）。
    @discardableResult
    public static func search(
        _ raw: String, mode: String,
        batchSize: Int = 12, perSourceLimit: Int = 12, totalLimit: Int = 120,
        onBatch: (([FeedItem]) -> Void)? = nil
    ) async -> [FeedItem] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let sites = pool(forMode: mode)
        var acc: [FeedItem] = []
        var seen = Set<String>()
        func absorb(_ hits: [FeedItem]) {
            for it in hits where acc.count < totalLimit {
                let k = it.title + "|" + (it.year ?? "")
                if seen.insert(k).inserted { acc.append(it) }
            }
        }
        var start = 0
        while start < sites.count, !Task.isCancelled, acc.count < totalLimit {
            let batch = Array(sites[start..<min(start + batchSize, sites.count)])
            start += batchSize
            let hits: [FeedItem] = await withTaskGroup(of: [FeedItem]?.self) { group in
                for site in batch {
                    group.addTask {
                        let c = TVBoxSiteClient(site: site)
                        let r = await c.search(q).filter {
                            NavPolicy.allowsItem(title: $0.title,
                                                 sourceCategory: $0.aggregateCategoryName,
                                                 mode: mode)
                        }
                        return r.isEmpty ? nil : Array(r.prefix(perSourceLimit))
                    }
                }
                var out: [FeedItem] = []
                for await r in group {
                    guard let r else { continue }
                    out.append(contentsOf: r)
                }
                return out
            }
            absorb(hits)
            onBatch?(acc)
        }
        return acc
    }
}
