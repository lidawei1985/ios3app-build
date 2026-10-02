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
    /// 导致关键词隔离闸门（星幕挡成人 / 夜航只收成人）有一半形同虚设。
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

    public var shrinkDetected: Bool {
        guard sourceCount > 0 else { return false }
        return catalogCount < sourceCount * 8 / 10   // <80% 即触警（与 Android 端口径一致）
    }

    public mutating func recordIsolationDrop(_ reason: String) {
        isolationDroppedCount += 1
        isolationReasons[reason, default: 0] += 1
    }
}
