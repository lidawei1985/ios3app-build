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
    public static func isAnime(_ item: FeedItem) -> Bool {
        if (item.contentType ?? "").lowercased() == "anime" { return true }
        var names: [String] = []
        if let n = item.aggregateCategoryName { names.append(n) }
        if let n = item.originalCategoryName { names.append(n) }
        names.append(contentsOf: item.categories?.normal ?? [])
        names.append(contentsOf: item.categories?.canonical ?? [])
        names.append(contentsOf: item.categories?.tags ?? [])
        for n in names where animeWords.contains(where: { n.contains($0) }) { return true }
        return false
    }

    /// 该条目是否可上首页（海报 + 黑名单 + 动漫规则）。
    ///
    /// **动漫排除只对星幕生效**：星幕定位=电影+电视剧（用户：「动画片啊？一个动漫的海报
    /// 看着就难受」）；心屋的动画片就是主体内容，夜航的成人动漫也是正经大类，都不能排除。
    public static func allowsOnHome(_ item: FeedItem, mode: String) -> Bool {
        guard item.bestPosterURL != nil else { return false }
        if mode == "normal" && isAnime(item) { return false }
        let t = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if blacklistTitles.contains(t) { return false }
        return true
    }

    // MARK: - 可排序指标

    /// 有效年份：越界（未来）年份视为 0（= 排最后），杜绝 2027/2030 脏数据抢占前排。
    public static func effectiveYear(_ item: FeedItem) -> Int {
        guard let y = item.year, let n = Int(y.prefix(4)) else { return 0 }
        let cur = Calendar.current.component(.year, from: Date())
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
    ///   夜航实测分类名：伦理片有码 / 有码 / 日本伦理有码 / 无码 / 动漫有码 / 港台三级有码 …
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
    /// 心屋儿童片评分普遍偏低（8.0 已是头部）→ 用 8.0；夜航无评分数据，不出该排。
    public static func classicMinRating(forMode mode: String) -> Double {
        mode == "child" ? 8.0 : 9.0
    }

    /// 一次算完某货架的候选序列（已排序；调用方负责全局去重与截断）。
    ///
    /// - 排序一律是「主序 + 次序」两级确定性排序，便于机检与复现。
    public static func rank(_ rule: Rule, pool: [FeedItem], mode: String) -> [FeedItem] {
        let usable = pool.filter { allowsOnHome($0, mode: mode) }
        let cur = Calendar.current.component(.year, from: Date())
        switch rule {
        case .hot:
            let recent = usable.filter { effectiveYear($0) >= cur - hotRecentYears }
            let strong = recent.filter { votes($0) >= hotMinVotes }
            let ranked = strong.sorted {
                votes($0) != votes($1) ? votes($0) > votes($1)
                    : (rating($0) != rating($1) ? rating($0) > rating($1)
                       : effectiveYear($0) > effectiveYear($1))
            }
            // 门槛内不够一排放宽为「近 5 年全部（按热度）」，仍不够才放全库（避免空排）
            if ranked.count >= minShelfItems { return ranked }
            var wide = recent.sorted { votes($0) != votes($1) ? votes($0) > votes($1)
                : effectiveYear($0) > effectiveYear($1) }
            if wide.count >= minShelfItems { return wide }
            wide.append(contentsOf: usable.sorted {
                votes($0) != votes($1) ? votes($0) > votes($1)
                    : effectiveYear($0) > effectiveYear($1) })
            return wide
        case .fresh:
            return usable.sorted {
                effectiveYear($0) != effectiveYear($1) ? effectiveYear($0) > effectiveYear($1)
                    : (votes($0) != votes($1) ? votes($0) > votes($1)
                       : rating($0) > rating($1))
            }
        case .content(let ct):
            return usable.filter { ($0.contentType ?? "movie") == ct }
                .sorted {
                    effectiveYear($0) != effectiveYear($1) ? effectiveYear($0) > effectiveYear($1)
                        : (votes($0) != votes($1) ? votes($0) > votes($1)
                           : rating($0) > rating($1))
                }
        case .genre(let words):
            return usable.filter { item in
                var names: [String] = []
                if let n = item.aggregateCategoryName { names.append(n) }
                if let n = item.originalCategoryName { names.append(n) }
                names.append(contentsOf: item.categories?.normal ?? [])
                names.append(contentsOf: item.categories?.canonical ?? [])
                return words.contains { w in names.contains { $0.contains(w) } }
            }
            .sorted {
                effectiveYear($0) != effectiveYear($1) ? effectiveYear($0) > effectiveYear($1)
                    : (votes($0) != votes($1) ? votes($0) > votes($1)
                       : rating($0) > rating($1))
            }
        case .classic:
            let gate = classicMinRating(forMode: mode)
            return usable.filter { rating($0) >= gate }
                .sorted {
                    rating($0) != rating($1) ? rating($0) > rating($1)
                        : (votes($0) != votes($1) ? votes($0) > votes($1)
                           : effectiveYear($0) > effectiveYear($1))
                }
        }
    }
}
