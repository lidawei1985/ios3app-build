import Foundation

// MARK: - Feed 契约模型（字段与 FilmCollector 生产 feed v1 逐一对齐，禁止自行增删语义）

/// 分片/全量条目。对应 p*.json items[] 元素。
public struct FeedItem: Codable, Identifiable, Hashable {
    public let dedupId: String
    public let title: String
    public let year: String?
    public let directors: [String]?
    public let actors: [String]?
    public let summary: String?
    public let contentType: String?          // "movie" / "tv" / "short"
    /// 国家/地区（中台按源站 vod_area 归一化：国产/中国香港/中国台湾/日本/韩国/美国/欧洲/泰国/印度/其他）。
    /// 2026-09-23 用户指令「分类里没有国家地区筛选找片太难找了」→ 分类页按此维度筛选。
    public let area: String?
    public let isAdult: Bool?
    public let playable: Bool?
    public let categories: FeedCategories?
    public let aggregateCategoryId: String?
    public let aggregateCategoryName: String?
    /// 源分类原名（生产 feed 的 `original_category_name`）。
    /// 2026-09-22 审计实锤：此前模型缺此字段 → App 端**读不到源分类**，
    /// 导致关键词隔离闸门（星幕挡成人 / 成人端只收成人）有一半形同虚设。
    public let originalCategoryName: String?
    public let poster: PosterRef?
    public let backdrop: PosterRef?
    public let qualityScore: Double?
    /// 真实评分（0–10；0 = 无）。中台口径：IMDb/TMDB 判定为 REAL 的评分优先，无则回退源站豆瓣分。
    /// **不是** `qualityScore`（那是完整度+可播性的综合分，不是评分）。
    /// 2026-09-23 用户：「高分经典就更惨不忍睹了都是啥玩意啊」→ 高分榜必须用真评分。
    public let rating: Double?
    /// 真实热度：评分人数（IMDb/TMDB 票数 → 否则源站评分人数）。
    /// 2026-09-23 用户：「热门的片2018的！」→ 热度榜必须用真热度，不能用 qualityScore。
    public let votes: Int?
    /// 源站站内点击数（噪声大，仅作并列时的次序参考）。
    public let hits: Int?
    public let origin: FeedOrigin?
    public let play: FeedPlay?

    public var id: String { dedupId }

    /// 海报优先级：backdrop(横版) 缺失时回退 poster。绝不因图片失败丢弃数据。
    public var bestPosterURL: URL? {
        if let s = poster?.url, !s.isEmpty { return URL(string: s) }
        if let s = backdrop?.url, !s.isEmpty { return URL(string: s) }
        return nil
    }
    public var bestBackdropURL: URL? {
        if let s = backdrop?.url, !s.isEmpty { return URL(string: s) }
        return bestPosterURL
    }
    public var isPlayable: Bool {
        // playable 字段在生产 feed 里恒为 null（2026-09-22 实测 home.json 540/540 为 null），
        // 必须回退推断：有默认线路或任一线路即视为可播。否则详情页播放按钮全灰（用户实测反馈）。
        if let playable { return playable }
        if let d = play?.defaultURL, !d.isEmpty { return true }
        return !(play?.lines?.isEmpty ?? true)
    }

    /// 值类型不可变 → 补图时重建（仅换 poster，其余原样）。34包内置源补图用。
    public func withPoster(_ url: String) -> FeedItem {
        FeedItem(dedupId: dedupId, title: title, year: year, directors: directors, actors: actors,
                 summary: summary, contentType: contentType, area: area, isAdult: isAdult,
                 playable: playable,
                 categories: categories, aggregateCategoryId: aggregateCategoryId,
                 aggregateCategoryName: aggregateCategoryName,
                 originalCategoryName: originalCategoryName,
                 poster: PosterRef(url: url, thumb: nil), backdrop: backdrop,
                 qualityScore: qualityScore, rating: rating, votes: votes, hits: hits,
                 origin: origin, play: play)
    }
    /// 值类型不可变 → 热度回填时重建（仅换 votes/rating，其余原样）。HeatIndex 用。
    public func withHeat(votes: Int?, rating: Double?) -> FeedItem {
        FeedItem(dedupId: dedupId, title: title, year: year, directors: directors, actors: actors,
                 summary: summary, contentType: contentType, area: area, isAdult: isAdult,
                 playable: playable,
                 categories: categories, aggregateCategoryId: aggregateCategoryId,
                 aggregateCategoryName: aggregateCategoryName,
                 originalCategoryName: originalCategoryName,
                 poster: poster, backdrop: backdrop,
                 qualityScore: qualityScore, rating: rating, votes: votes, hits: hits,
                 origin: origin, play: play)
    }
    /// 播放地址候选：默认线路优先，其后全部线路。iOS 端只消费，不改写。
    public var playCandidates: [URL] {
        var urls: [URL] = []
        if let d = play?.defaultURL, let u = URL(string: d) { urls.append(u) }
        for line in play?.lines ?? [] {
            if let u = URL(string: line.url), !urls.contains(u) { urls.append(u) }
        }
        return urls
    }
}

public struct FeedCategories: Codable, Hashable {
    public let normal: [String]?
    public let canonical: [String]?
    public let tags: [String]?
}

public struct PosterRef: Codable, Hashable {
    public let url: String
    public let thumb: String?
}

public struct FeedOrigin: Codable, Hashable {
    public let sourceId: String?
    public let sourceName: String?
    public let category: String?
}

/// 带**大源身份**的播放线路（v67 换源分层，主人 2026-10-04 钦定
/// 「切换源应该是先换大源，大源里有小源就自动切小源」）。
///
/// 大源 = CMS 源站（量子/天涯/非凡/卧龙…，`TVBoxSite.name`；片源自带线路的大源名
/// 用 `FeedOrigin.sourceName`）；小源 = 同一大源内的多条线路/CDN。
/// 旧实现只传 `[URL]`，大源身份在聚合时被丢掉 → 换源只能在整个平铺列表里逐条轮。
public struct SourceLine: Hashable, Sendable {
    public let url: URL
    public let source: String
    public init(url: URL, source: String) {
        self.url = url
        self.source = source
    }
}

public struct FeedPlay: Codable, Hashable {
    public struct Line: Codable, Hashable {
        public let name: String?
        public let url: String
        public let quality: String?
    }
    public let lines: [Line]?
    public let defaultLine: String?
    public let defaultURL: String?

    /// convertFromSnakeCase 把 `default_url` 转成 `defaultUrl`，与属性名 `defaultURL`（全大写缩写）
    /// 不匹配 → 主播放线路永远解码失败（2026-09-22 键名审计实锤，唯一不匹配的键）。
    /// 显式 CodingKeys 的 stringValue 必须写**策略转换后**的形态。
    private enum CodingKeys: String, CodingKey {
        case lines, defaultLine
        case defaultURL = "defaultUrl"
    }
}

// MARK: - manifest / 分片 / home 契约

public struct FeedManifest: Codable {
    public let ok: Bool
    public let mode: String
    public let version: String?
    public let count: Int
    public let partSize: Int
    public let parts: [String]
}

public struct FeedPart: Codable {
    public let ok: Bool
    public let mode: String
    public let offset: Int?
    public let total: Int?
    public let version: String?
    public let items: [FeedItem]
}

/// home.json 轻量首屏包：分类统计 + hero 候选 ≤40 + 头部精品 ≤500。
public struct FeedHome: Codable {
    public let ok: Bool
    public let mode: String
    public let version: String?
    public let total: Int
    public let categories: [FeedCategoryStat]?
    public let posters: [FeedItem]?
    public let pool: [FeedItem]?
}

public struct FeedCategoryStat: Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let count: Int
}

// MARK: - 数量台账（§七 防缩水）

/// 每级记录输入/输出/丢弃/原因。任何无理由下降都会在台账里显形。
public struct DataLedger: Codable, Hashable {
    public var sourceCount: Int = 0          // feed manifest count（SOURCE）
    public var feedFetchedCount: Int = 0     // 实际拉到并解码的条数（PRODUCTION FEED）
    public var decodeErrorCount: Int = 0
    public var dedupDroppedCount: Int = 0
    public var isolationDroppedCount: Int = 0
    public var isolationReasons: [String: Int] = [:]
    public var catalogCount: Int = 0         // 入目录条数（APP CATALOG）
    public var emptyPosterCount: Int = 0
    public var noPlayURLCount: Int = 0
    public var duplicateIDCount: Int = 0
    public var unknownCategoryCount: Int = 0 // 未知分类只记账，不丢弃（数据保留 > UI 可展示 > 扩展）
    public var homeCount: Int = 0
    public var version: String?
    public var updatedAt: Date?

    /// ★ 2026-10-05 冷启动卡顿**真根因**（v76.2）——
    ///
    /// `FilmJSON` 是「`convertToSnakeCase` 编码 / `convertFromSnakeCase` 解码」这对策略，
    /// **而这对策略不是互逆的**：缩写词在编码时被切碎、解码时回不来。
    ///
    ///   `noPlayURLCount` --编码--> `no_play_url_count` --解码--> `noPlayUrlCount`（URL→Url）✗
    ///   `duplicateIDCount` --编码--> `duplicate_id_count` --解码--> `duplicateIdCount`（ID→Id）✗
    ///
    /// 两个键与属性名不匹配 ⇒ **磁盘快照 100% 解码失败**。端上黑匣子铁证（v76.1 实测）：
    ///   `快照·load 解析失败 152977723B read=87ms decode=3167ms
    ///    err=DecodingError.keyNotFound: Key 'noPlayURLCount' not found ... Path: ledger`
    ///
    /// 后果（主人报的「启动卡住一下 / 响应速度太差 / 直播加载慢」的结构性主因）：
    /// ① 146MB 磁盘快照永远用不上 → 启动目录停在 2 万条内嵌档；
    /// ② `syncAll` 的「本地已是全量级」闸门因此不成立 → **每次冷启动重拉 180 片 ≈150MB**
    ///    （实测 `本段=32122ms`，v76 那轮 `本段=91416ms`）；
    /// ③ 重算 9 万条 + 重新编码写回 146MB（实测 `enc=6578ms`）；
    /// ④ 这堆活和首屏货架计算抢核抢内存 → 主线程被卡 9 秒（实测 `主线程·卡 9044ms`）；
    /// ⑤ 启动期 6 条并发连接把带宽吃满 → 这时进直播就「加载很慢」。
    ///
    /// 修法与 `FeedPlay.defaultURL`（2026-09-22 键名审计）**完全同一套**：
    /// 给不对称键显式声明 `CodingKeys`，stringValue 写**策略转换后**的形态。
    /// 因为 `convertToSnakeCase("noPlayUrlCount") == "no_play_url_count"`，
    /// **磁盘上的键名一个字节都不变** —— 旧快照直接可读，向后兼容。
    ///
    /// 教训：凡「首字母缩写连写」（URL / ID / OK / TV）的持久化字段，都必须走这一步；
    /// `scripts/` 外再加一道 `FilmJSON.selfCheck()` 启动自检，防以后再有人踩。
    private enum CodingKeys: String, CodingKey {
        case sourceCount, feedFetchedCount, decodeErrorCount, dedupDroppedCount,
             isolationDroppedCount, isolationReasons, catalogCount, emptyPosterCount,
             unknownCategoryCount, homeCount, version, updatedAt
        case noPlayURLCount = "noPlayUrlCount"
        case duplicateIDCount = "duplicateIdCount"
    }

    public var shrinkDetected: Bool {
        guard sourceCount > 0 else { return false }
        return catalogCount < sourceCount * 8 / 10   // <80% 即触警（与 Android 端口径一致）
    }

    public mutating func recordIsolationDrop(_ reason: String) {
        isolationDroppedCount += 1
        isolationReasons[reason, default: 0] += 1
    }
}

extension DataLedger {

    /// 启动自检（v76.2）：本地持久化的**往返是否真的对称**。
    ///
    /// 为什么值得付出这几十微秒：`noPlayURLCount` / `duplicateIDCount` 这对缩写键
    /// 让「146MB 磁盘快照 100% 解不开」憋了不知道多少版 —— 因为解码失败被 `try?` 吞掉，
    /// 端上表现只是「启动慢一点、每次都在同步」，没有任何人能看到原因。
    /// 现在每次启动写一行到黑匣子：`自检·DataLedger 往返 ok 312B`。
    /// 值取「每个字段都不同」的样本（含 Date 取整秒，避开 iso8601 亚秒截断），
    /// 任何一个字段对不上都会在这里现形。
    public static func selfCheckRoundTrip() -> String {
        var a = DataLedger()
        a.sourceCount = 89_842
        a.feedFetchedCount = 89_842
        a.decodeErrorCount = 1
        a.dedupDroppedCount = 25
        a.isolationDroppedCount = 25
        a.isolationReasons = ["adult_word[x]_in_normal": 19]
        a.catalogCount = 89_817
        a.emptyPosterCount = 2
        a.noPlayURLCount = 7
        a.duplicateIDCount = 9
        a.unknownCategoryCount = 3
        a.homeCount = 19_999
        a.version = "2026-09-24T23:20:00+08:00"
        a.updatedAt = Date(timeIntervalSince1970: 0)     // 整秒：iso8601 无小数位
        guard let d = try? FilmJSON.encoder().encode(a) else { return "FAIL 编码抛错" }
        guard let b = try? FilmJSON.decoder().decode(DataLedger.self, from: d) else {
            return "FAIL 解码抛错 \(d.count)B"
        }
        guard b == a else {
            var diffs: [String] = []
            if b.sourceCount != a.sourceCount { diffs.append("sourceCount") }
            if b.isolationReasons != a.isolationReasons { diffs.append("isolationReasons") }
            if b.noPlayURLCount != a.noPlayURLCount { diffs.append("noPlayURLCount(得\(b.noPlayURLCount))") }
            if b.duplicateIDCount != a.duplicateIDCount { diffs.append("duplicateIDCount(得\(b.duplicateIDCount))") }
            if b.version != a.version { diffs.append("version") }
            if b.updatedAt != a.updatedAt { diffs.append("updatedAt") }
            return "FAIL 往返不等：\(diffs.isEmpty ? "其它字段" : diffs.joined(separator: ","))"
        }
        return "ok \(d.count)B"
    }
}
