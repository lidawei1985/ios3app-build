import Foundation

/// 包内热度索引（2026-10-04 ·「主视觉都是小电影」根修）。
///
/// 根因（2026-10-04 实测，主人点名「主视觉的影片推荐都是小电影的感觉」）：
///   中台 feed 当前**全量无 rating/votes**——home.json 540/540 缺失、全量分片抽查 p0/p89/p179
///   共 1500 条全缺失（85842 条目录同口径）。于是首页 Hero/货架的「真热门（votes≥500）」档
///   永远为空，全部落到「按年份新→旧」兜底 → 2026 年的冷门采集剧（如《乌鸦俱乐部》）
///   霸占主视觉。而包内快照（xingmu/xinwu_feed_snapshot.json）里的豆瓣票数/评分是真数据。
///
/// 修法：**构建期**把快照票数/评分提取成「归一化标题+年份 → [votes, rating]」查询表打进包
///   （`heat_index_normal.json` / `heat_index_xinwu.json`，由 `scripts/build_heat_index.py` 生成）；
///   **运行期**在 `FeedAdapter.buildCatalog` 逐条回填。
///
/// 原则（防误伤，主人 2026-10-04 口径「宁可不治也不能错治」的同类纪律）：
///   ① 只兜底不覆盖 —— 条目自带真值（votes>0 / rating>0）一律不动；
///   ② 查不到原样返回 —— 宁可不上榜也不编数据；
///   ③ 成人端（adult）无索引，行为与旧版完全一致。
///
/// 实测收益（Python 复刻验证，2026-10-04）：快照 2024+ 且票≥500 的 714 部热门片，
///   702 部（98.3%）能按「归一化标题+年份」命中真机目录；回填后 Hero 前 15 =
///   沙丘2 / 死侍与金刚狼 / 某种物质 / 凶器 / 阿诺拉 / 编号17 / 长安的荔枝 …（全是真院线片）。
enum HeatIndex {

    /// 键 → [votes, rating]。rating 0 = 无评分。
    private typealias Table = [String: [Double]]

    private static let lock = NSLock()
    private static var cache: [String: Table] = [:]

    /// 归一化：删空白与常见标点（**与 scripts/build_heat_index.py 逐字一致**，改一处必须同步另一处）。
    static func normalizeTitle(_ t: String) -> String {
        let drop = Set(" \t\r\n·:：-—–~!！?？,，.。;；、'\"“”‘’()（）[]【】<>《》".unicodeScalars)
        return String(t.unicodeScalars.filter { !drop.contains($0) }).lowercased()
    }

    static func key(title: String, year: String?) -> String {
        let y = (year ?? "").prefix(4)
        return normalizeTitle(title) + "|" + y
    }

    /// 按 mode 取表（normal=星幕 / child=心屋；adult=成人端无表返回空）。
    /// 首次访问读包内 JSON 并缓存；文件缺失/损坏 = 空表（回填静默不生效，绝不抛错）。
    private static func table(for mode: String) -> Table {
        let resource: String?
        switch mode {
        case "normal": resource = "heat_index_normal"
        case "child":  resource = "heat_index_xinwu"
        default:       resource = nil      // adult：无快照无索引
        }
        guard let resource else { return [:] }
        lock.lock()
        if let hit = cache[resource] { lock.unlock(); return hit }
        lock.unlock()
        var t: Table = [:]
        // v64 关键修复：资源实际落在 bundle 的 **Resources 子目录**（IPA 实测
        // FilmCore_FilmCore.bundle/Resources/heat_index_normal.json）。原写法不带 subdirectory
        // → url 返回 nil → 静默空表 → 回填全不生效（中台全量无票数 → 首屏好、同步后掉回冷门片，
        // 主人 2026-10-04 实测「上一秒超人沙丘2，转眼又回以前的」）。与包内快照加载同款两步查法。
        let url = Bundle.module.url(forResource: resource, withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: resource, withExtension: "json")
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Table.self, from: data) {
            t = decoded
        }
        FilmLog.i("HEATIDX table=\(resource) entries=\(t.count)")   // 空表=资源没读到，日志可查
        lock.lock()
        cache[resource] = t
        lock.unlock()
        return t
    }

    /// 回填：自带真值优先；查不到原样返回。在 buildCatalog 后台循环里逐条调（8.5 万条 ≈ 几十毫秒）。
    static func enrich(_ item: FeedItem, mode: String) -> FeedItem {
        let hasVotes = (item.votes ?? 0) > 0
        let hasRating = (item.rating ?? 0) > 0
        if hasVotes && hasRating { return item }        // 真值优先，绝不覆盖
        let t = table(for: mode)
        if t.isEmpty { return item }
        guard let v = t[key(title: item.title, year: item.year)] else { return item }
        let votes = hasVotes ? item.votes : (v.count > 0 ? Int(v[0]) : nil)
        let rating = hasRating ? item.rating : (v.count > 1 && v[1] > 0 ? v[1] : nil)
        if votes == item.votes && rating == item.rating { return item }
        return item.withHeat(votes: votes, rating: rating)
    }
}
