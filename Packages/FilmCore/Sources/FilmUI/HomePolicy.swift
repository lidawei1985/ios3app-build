import Foundation
import FilmCore

/// 首页货架策略（2026-09-23 用户指令重写）。
///
/// 用户原话：
///  - 「主页货架以前我记着不是这些分类」
///  - 「怎么老是一些老片 我记着不是从新2026优先级的吗？2025 2024 这片都不是啊」
///  - 「热门的片2018的！大轰炸 好小子！电影精选就更惨不忍睹了都是啥玩意啊！！」
///  - 「我不管几个货架都行但是你要按照货架名称给出对应的片啊！」
///  - 「格斗之王那个可以不要放主页吗？」
///  - 「动画片啊？一个动漫的海报看着就难受」
///
/// 三条根因（2026-09-23 实测 dist/feed.normal.json 85,659 条）：
///  1) 「热门推荐」「高分经典」此前都用 `qualityScore`（完整度+可播性的综合分，**不是热度也不是评分**）
///     → 线路多、字段全的老片永远排在前面（2018《大轰炸》、1995《格斗之王》就是这么上来的）。
///  2) 真正可用的信号一直都在源站原始响应里，只是聚合阶段被丢掉了：
///     `vod_douban_score`（真豆瓣分）/ `vod_score_num`（评分人数=真热度）/
///     中台已判定的 IMDb·TMDB 评分。现已补进 feed（`rating` / `votes`）。
///  3) 分类货架此前按「大类条目数前 4」取，取到的是 4K专区/邵氏经典/Netflix专区/动漫
///     这类**专题集合**——邵氏经典本身就是老片合集，动漫则直接把动画海报推上主页。
///
/// 现口径（货架名 = 内容）：
///   热门推荐  → 近 5 年里**真热度（评分人数）最高**的片（不再用综合分）
///   最新上线  → 年份新的在前，同年前提下热度高的在前
///   电影精选  → contentType == movie
///   电视剧精选 → contentType == tv
///   动作/喜剧/悬疑犯罪精选 → 该题材里年份新的在前
///   高分经典  → **真评分 ≥ 9.0**，评分高的在前
/// 全站统一排除：动漫类内容、用户点名黑名单、无海报、同剧不同季/不同版本重复。
public enum HomePolicy {

    // MARK: - 排除项

    /// 首页黑名单标题（用户点名：「格斗之王那个可以不要放主页吗？」）。
    /// 只影响首页货架，不影响分类页/搜索——片还在库里，找得到。
    public static let blacklistTitles: Set<String> = ["格斗之王", "格斗之王2", "格斗之王 2"]

    /// 动漫判定词表：分类名或源分类名含任一词即算动漫（不上主页）。
    /// 用户：「动画片啊？一个动漫的海报看着就难受」。
    public static let animeWords: [String] = [
        "动漫", "动画", "卡通", "漫剧", "国漫", "日漫", "里番", "番剧",
    ]

    /// 是否动漫类内容。
    ///
    /// 某个分类名里是否含任一关键词（无分配早退）。
    @inline(__always)
    private static func hitAnimeWord(_ n: String) -> Bool {
        for w in animeWords where n.contains(w) { return true }
        return false
    }

    /// v76.3（2026-10-05）性能改写：**语义逐字不变，只去掉中间数组**。
    /// 原实现把 5 组分类名 `append` 进一个 `[String]` 再做 8×N 次 `contains`，
    /// 每个条目都要分配一次数组。
    ///
    /// ★ v76.5（2026-10-05）**回退 v76.4 的「拼接成串再查」改法** —— 真机 A/B 实测它是
    /// **负收益**：v76.4 黑匣子「全量货架计算 2468ms / 主线程卡 2023ms」，反而比 v76.3 的
    /// 2149ms / 1729ms 更慢。原因（原理可判）：首页自 v76.3 起 `allowsOnHome` 已改成
    /// **全量只过滤一次**，8.98 万条每条只调一次 `isAnime`；而绝大多数条目**不是动漫**
    /// （必须查满全表才能返回 false），拼接法对它**无条件**把 5 组名字拷进新串
    /// （多次 realloc + 堆分配）再去搜一个更长的串，比「直接搜短串、命中即早退」更贵。
    /// 教训：优化前必须先确认真实调用次数（v76.4 沿用了 v76.3 之前的旧前提）。
    public static func isAnime(_ item: FeedItem) -> Bool {
        if (item.contentType ?? "").lowercased() == "anime" { return true }
        if let n = item.aggregateCategoryName, hitAnimeWord(n) { return true }
        if let n = item.originalCategoryName, hitAnimeWord(n) { return true }
        for n in item.categories?.normal ?? [] where hitAnimeWord(n) { return true }
        for n in item.categories?.canonical ?? [] where hitAnimeWord(n) { return true }
        for n in item.categories?.tags ?? [] where hitAnimeWord(n) { return true }
        return false
    }

    /// 某个分类名里是否含任一给定词（无分配早退；供 `.genre` 排使用）。
    @inline(__always)
    private static func hitAnyWord(_ n: String, _ words: [String]) -> Bool {
        for w in words where n.contains(w) { return true }
        return false
    }

    /// 该条目是否可上首页（海报 + 黑名单 + 动漫规则）。
    ///
    /// **动漫排除只对星幕生效**：星幕定位=电影+电视剧（用户：「动画片啊？一个动漫的海报
    /// 看着就难受」）；心屋的动画片就是主体内容，成人端的成人动漫也是正经大类，都不能排除。
    public static func allowsOnHome(_ item: FeedItem, mode: String) -> Bool {
        guard item.bestPosterURL != nil else { return false }
        if mode == "normal" && isAnime(item) { return false }
        // v76.4：黑名单 3 条（格斗之王/格斗之王2/格斗之王 2）**全都含「格斗」二字** ——
        //   标题里连「格斗」都没有就绝不可能在名单里，直接跳过 trim + Set（9 万条 × 每次
        //   一次 String 分配）。含「格斗」的才走原来的精确路径，结果逐条等价。
        if item.title.contains("格斗") {
            let t = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if blacklistTitles.contains(t) { return false }
        }
        return true
    }

    // MARK: - 可排序指标

    /// 当前年份（进程内缓存，30 秒有效期）。
    ///
    /// v76.3（2026-10-05）：`effectiveYear` 原来**每次调用**都走一遍
    /// `Calendar.current.component(.year, from: Date())`（一次 NSCalendar 运算 ≈ 微秒级），
    /// 而它在 `.sorted` 的比较器里被调用 O(n log n) 次 —— 9 万条排序一轮就是 ~150 万次比较、
    /// 上百万次日历运算。这正是 v76.2 真机复测里「全量货架计算 9494ms / 主线程卡 9029ms」
    /// 的头号成本项（占 9.5s 里的 5~6s）。
    /// 缓存 30 秒：跨年那一瞬最多 30 秒误差，远小于「主线程冻 9 秒」，且不影响任何排序结果。
    private static let yearLock = NSLock()
    private static var cachedYear = 0
    private static var cachedYearAt = Date.distantPast

    public static func currentYear() -> Int {
        let now = Date()
        yearLock.lock()
        if cachedYear > 0, now.timeIntervalSince(cachedYearAt) < 30 {
            let y = cachedYear; yearLock.unlock(); return y
        }
        yearLock.unlock()
        let y = Calendar.current.component(.year, from: now)
        yearLock.lock(); cachedYear = y; cachedYearAt = now; yearLock.unlock()
        return y
    }

    /// 有效年份：越界（未来）年份视为 0（= 排最后），杜绝 2027/2030 脏数据抢占前排。
    public static func effectiveYear(_ item: FeedItem) -> Int {
        effectiveYear(item, cur: currentYear())
    }

    /// 同上的「年份已知」版本（排序热路径专用：一次算好 cur，避免在比较器里反复取日历）。
    @inline(__always)
    public static func effectiveYear(_ item: FeedItem, cur: Int) -> Int {
        guard let y = item.year, let n = Int(y.prefix(4)) else { return 0 }
        return (1900...cur).contains(n) ? n : 0
    }

    /// 真评分（0–10）；0 = 无评分（不进高分榜）。
    public static func rating(_ item: FeedItem) -> Double {
        let r = item.rating ?? 0
        return (r > 0 && r <= 10) ? r : 0
    }

    /// 真热度（评分人数）；0 = 无（不进热门榜的候选优先级最低）。
    public static func votes(_ item: FeedItem) -> Int { max(0, item.votes ?? 0) }

    /// 热度文本（评分人数）：1 万以上折「万」，便于阅读。
    public static func votesText(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
        if n >= 10_000 { return String(format: "%.1f万", Double(n) / 10_000) }
        return "\(n)"
    }

    // MARK: - 同名去重（同剧不同季 / 不同语言版本）

    private static let seasonRegex = try? NSRegularExpression(
        pattern: "(第[一二三四五六七八九十0-9]+季|第[一二三四五六七八九十0-9]+部|Season\\s*\\d+|S\\d{1,2})",
        options: [.caseInsensitive])
    private static let versionRegex = try? NSRegularExpression(
        pattern: "(国语|粤语|普通话|英语|日语|韩语|泰语|中字|双语|台配|配音|国语版|粤语版|HD|蓝光|BD|4K|1080P|720P|高清|完整版|未删减|修复版|典藏版|真人版)",
        options: [.caseInsensitive])

    /// 系列键：剥掉季数/语言/画质后缀后的标题。同一键在首页只出一部。
    public static func seriesKey(_ item: FeedItem) -> String {
        var t = item.title
        for re in [seasonRegex, versionRegex] {
            guard let re else { continue }
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? item.title : t
    }

    // MARK: - 货架计划

    public enum Rule: Equatable {
        case hot                    // 热门推荐：近 N 年真热度最高
        case fresh                  // 最新上线：年份新→旧
        case content(String)        // 按内容类型（movie / tv）
        case genre([String])        // 按题材（分类名包含任一词）
        case classic                // 高分经典：真评分 ≥ 阈值
    }

    public struct ShelfSpec: Equatable {
        public let title: String
        public let rule: Rule
    }

    /// 首页货架计划（三端各自一套）。货架名必须等于该排的内容口径——
    /// 排名的分类词表按**该端 feed 里真实存在的聚合分类名**来定（不是拍脑袋）：
    ///   成人端实测分类名：伦理片有码 / 有码 / 日本伦理有码 / 无码 / 动漫有码 / 港台三级有码 …
    ///   心屋实测分类名：动画电影 / 剧情 / 喜剧 / 动作 / 科幻 / 家庭 …
    public static func shelves(forMode mode: String) -> [ShelfSpec] {
        switch mode {
        case "adult":
            return [
                ShelfSpec(title: "热门推荐", rule: .hot),
                ShelfSpec(title: "最新上线", rule: .fresh),
                ShelfSpec(title: "伦理精选", rule: .genre(["伦理"])),
                ShelfSpec(title: "三级精选", rule: .genre(["三级", "港台"])),
                ShelfSpec(title: "成人动漫", rule: .genre(["动漫", "里番"])),
                ShelfSpec(title: "无码精选", rule: .genre(["无码"])),
            ]
        case "child":
            return [
                ShelfSpec(title: "最新上线", rule: .fresh),
                ShelfSpec(title: "动画片精选", rule: .genre(["动画", "动漫"])),
                ShelfSpec(title: "儿童电影", rule: .content("movie")),
                ShelfSpec(title: "高分动画", rule: .classic),
            ]
        default:   // normal（星幕）
            return [
                ShelfSpec(title: "热门推荐", rule: .hot),
                ShelfSpec(title: "最新上线", rule: .fresh),
                ShelfSpec(title: "电影精选", rule: .content("movie")),
                ShelfSpec(title: "电视剧精选", rule: .content("tv")),
                // 短剧精选（2026-09-23 用户要短剧源）：按中台 contentType == "short_drama" 精确取，
                // **不混进电视剧池**（用户 2026-09-20 口径「独立分类不混流」）。
                // 内容不足 8 部时自动不出排（`minShelfItems`），采集侧一开短剧分类即自动亮起。
                ShelfSpec(title: "短剧精选", rule: .content("short_drama")),
                ShelfSpec(title: "动作精选", rule: .genre(["动作"])),
                ShelfSpec(title: "喜剧精选", rule: .genre(["喜剧"])),
                ShelfSpec(title: "悬疑犯罪", rule: .genre(["悬疑", "犯罪", "惊悚"])),
                ShelfSpec(title: "高分经典", rule: .classic),
            ]
        }
    }

    /// 参数（与 `scripts/check_home_shelves.py` 机检脚本逐字一致，改一处必须同步另一处）。
    public static let hotRecentYears = 5      // 「热门推荐」只看近 5 年
    public static let hotMinVotes = 200       // 「热门推荐」热度门槛（评分人数）
    public static let shelfSize = 20          // 每排最多 20 部
    public static let minShelfItems = 8       // 少于 8 部不成排（防止出现"几乎空"的货架）

    /// 「高分经典」评分门槛：星幕的 feed 评分来自 IMDb/TMDB+豆瓣，9.0 才叫经典；
    /// 心屋儿童片评分普遍偏低（8.0 已是头部）→ 用 8.0；成人端无评分数据，不出该排。
    public static func classicMinRating(forMode mode: String) -> Double {
        mode == "child" ? 8.0 : 9.0
    }

    /// 排序用装饰条目（v76.3 2026-10-05）：把比较器里本来要**反复现算**的三个指标
    /// （有效年份 / 热度 / 评分）**只算一次**存进结构体。
    ///
    /// 为什么值：9 万条排序一轮 ≈ 150 万次比较，每次比较原来要现调 `effectiveYear`
    /// （内含 Calendar 运算）2~6 次 ⇒ 单次全量货架计算上百万次函数调用 + 日历运算。
    /// 装饰后比较器只读字段。
    ///
    /// **为什么结果与原来逐条等价**：装饰只做「提前求值」，**比较判据、判据顺序、
    /// 短路方式全部照抄原实现**（`a != b ? a 序 : b 序` 一字未改）。比较结果序列与
    /// 原来完全相同 ⇒ 同一套 `sorted` 算法（控制流只依赖比较结果）产出的排列也完全相同。
    public struct Ranked {
        public let item: FeedItem
        public let year: Int
        public let votes: Int
        public let rating: Double
    }

    public static func decorate(_ pool: [FeedItem], cur: Int) -> [Ranked] {
        pool.map { Ranked(item: $0, year: effectiveYear($0, cur: cur),
                          votes: votes($0), rating: rating($0)) }
    }

    /// 一次算完某货架的候选序列（已排序；调用方负责全局去重与截断）。
    ///
    /// - 排序一律是「主序 + 次序」两级确定性排序，便于机检与复现。
    public static func rank(_ rule: Rule, pool: [FeedItem], mode: String) -> [FeedItem] {
        let usable = pool.filter { allowsOnHome($0, mode: mode) }
        return rank(rule, usable: usable, mode: mode, cur: currentYear())
    }

    /// 同上，但**可用池已经过滤好**（v76.3）。
    ///
    /// 首页一次要出 8~10 排，每排的候选池都是**同一份全量目录**、用的是**同一条
    /// `allowsOnHome` 判据**。旧写法每排都重扫一遍全量（含逐条 `isAnime` + `URL(string:)`），
    /// 9 万条 × 8 排 = 72 万次重复判定。现在由调用方（`computeShelves`）过滤一次共用。
    public static func rank(_ rule: Rule, usable: [FeedItem], mode: String, cur: Int) -> [FeedItem] {
        rank(rule, decorated: decorate(usable, cur: cur), mode: mode, cur: cur)
    }

    /// v76.5（2026-10-05）：**已装饰池**（首页「一次装饰、多排复用」）。
    ///
    /// v76.3 只把 `allowsOnHome` 从「每排一次」降为「全量一次」，但 `decorate`（把每条的
    /// 有效年份/热度/评分现算一遍存成 `Ranked`）**仍然每排算一遍** —— 8 排 × 8.7 万条
    /// = 约 70 万次 `effectiveYear`（内含 `year.prefix(4)` 字符串切片 + `Int()` 解析）
    /// + 70 万次结构体构造与数组分配。这正是 v76.4 真机分段里「各排合计 831ms」的主成本。
    ///
    /// **为什么结果与「逐排 decorate」逐条等价**：`decorate` 是纯函数（无副作用、同输入同输出），
    /// 本重载只是把「函数内算一次」挪到「函数外算一次再共用」，`switch` 内的判据、排序、
    /// 短路写法**一字未改** ⇒ 每个 `Ranked` 的值不变 ⇒ 排序结果序列不变。
    public static func rank(_ rule: Rule, decorated d: [Ranked], mode: String, cur: Int) -> [FeedItem] {
        switch rule {
        case .hot:
            let recent = d.filter { $0.year >= cur - hotRecentYears }
            let strong = recent.filter { $0.votes >= hotMinVotes }
            let ranked = strong.sorted {
                $0.votes != $1.votes ? $0.votes > $1.votes
                    : ($0.rating != $1.rating ? $0.rating > $1.rating
                       : $0.year > $1.year)
            }.map(\.item)
            // 门槛内不够一排放宽为「近 5 年全部（按热度）」，仍不够才放全库（避免空排）
            if ranked.count >= minShelfItems { return ranked }
            var wide = recent.sorted { $0.votes != $1.votes ? $0.votes > $1.votes
                : $0.year > $1.year }.map(\.item)
            if wide.count >= minShelfItems { return wide }
            wide.append(contentsOf: d.sorted {
                $0.votes != $1.votes ? $0.votes > $1.votes
                    : $0.year > $1.year
            }.map(\.item))
            return wide
        case .fresh:
            return d.sorted {
                $0.year != $1.year ? $0.year > $1.year
                    : ($0.votes != $1.votes ? $0.votes > $1.votes
                       : $0.rating > $1.rating)
            }.map(\.item)
        case .content(let ct):
            return d.filter { ($0.item.contentType ?? "movie") == ct }
                .sorted {
                    $0.year != $1.year ? $0.year > $1.year
                        : ($0.votes != $1.votes ? $0.votes > $1.votes
                           : $0.rating > $1.rating)
                }.map(\.item)
        case .genre(let words):
            // v76.5：去掉每条的中间 `names` 数组（原来 8.7 万条 × 每个题材排 分配一次），
            //   改为逐名早退。等价：原判据 = ∃词 ∃名: 名含词；新写法对每个名跑同一谓词，
            //   任一命中即返回，结果 Bool 相同 ⇒ filter 结果相同。
            //   ★ 只查 4 组名（aggregate / original / normal / canonical），**与旧实现一致**：
            //     旧实现就**没有**把 `categories.tags` 算进来，改造时不得顺手加上（会改变结果集）。
            return d.filter { rd in
                if let n = rd.item.aggregateCategoryName, hitAnyWord(n, words) { return true }
                if let n = rd.item.originalCategoryName, hitAnyWord(n, words) { return true }
                for n in rd.item.categories?.normal ?? [] where hitAnyWord(n, words) { return true }
                for n in rd.item.categories?.canonical ?? [] where hitAnyWord(n, words) { return true }
                return false
            }
            .sorted {
                $0.year != $1.year ? $0.year > $1.year
                    : ($0.votes != $1.votes ? $0.votes > $1.votes
                       : $0.rating > $1.rating)
            }.map(\.item)
        case .classic:
            let gate = classicMinRating(forMode: mode)
            return d.filter { $0.rating >= gate }
                .sorted {
                    $0.rating != $1.rating ? $0.rating > $1.rating
                        : ($0.votes != $1.votes ? $0.votes > $1.votes
                           : $0.year > $1.year)
                }.map(\.item)
        }
    }
}
