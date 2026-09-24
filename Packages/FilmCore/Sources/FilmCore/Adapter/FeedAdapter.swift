import Foundation

/// 数据适配层：feed 原始条目 → App 目录（Catalog）。
/// 职责边界（红线 §六）：
///  - 只做协议翻译 + 去重 + 隔离安全网 + 台账记账；
///  - 不重新分类、不猜分类、不改 FilmCollector 数据；
///  - 未知分类/无海报/无播放地址：数据保留（记账不丢弃）。
public struct FeedAdapter {

    /// 隔离安全网语义（仅兜底，不重新分类；与 Android 端 NormalFilter/ChildFilter 对齐）：
    /// - adult（夜航）：不过滤，feed 本身即成人池；
    /// - normal（星幕）：拒绝成人向条目 —— (a) `is_adult == true`；(b) 源分类/标签/聚合分类命中成人词表；
    /// - child（心屋）：在 normal 基础上，再拒绝「儿童不宜」条目（恐怖/惊悚/犯罪/战争/灾难…）。
    ///
    /// 2026-09-22 用户红线：「港台三级、伦理、里番这类必须是夜航，其他 App 不能给」；
    /// 「心屋不是不能有电影，但一定得是适合儿童的」。
    /// 实测（FilmCollector 导出池）：星幕池混入 17 条「情色/伦理」条目**且未打 is_adult 标记**，
    /// 单看 isAdult 挡不住 → 故加宽为「词表」多源判据；心屋池实测 0 条成人、1 条悬疑（迷雾镇）。
    public static func isolationReject(_ item: FeedItem, mode: String, adultStrict: Bool = false) -> String? {
        // 夜航（adult）：反向闸门 —— 只收成人内容，普通动画片/儿童片不得混入
        // （2026-09-22 用户指令：夜航那两个动画分类里混进了普通动画片，必须修掉）
        if mode == "adult" { return adultPoolReject(item, strict: adultStrict) }
        if item.isAdult == true { return "adult_flag_in_\(mode)" }
        if let hit = keywordHit(item, in: Self.adultWords) { return "adult_word[\(hit)]_in_\(mode)" }
        if mode == "child", let hit = keywordHit(item, in: Self.kidUnsafeWords) {
            return "kid_unsafe[\(hit)]_in_child"
        }
        return nil
    }

    /// 夜航反向闸门（2026-09-22 用户指令）：夜航只放成人内容，**普通动画片 / 儿童片一律不得进夜航**。
    ///
    /// 实测（dist/pages-browse/adult，2003 条）：夜航池里混入普通内容，
    /// 例：**咱们裸熊：电影版**（来源=电影天堂(心屋儿童源)）、**裸体哈维闯人生**（普通动画）、
    /// **热血雷锋侠之激情营救**（国产动画）—— 均因旧模型读不到源分类而漏过。
    ///
    /// 两档策略（由整池成人证据覆盖率决定，见 `adultEvidenceRatio`）：
    /// - `strict = true`（覆盖率 ≥50%，实测 99%）：**必须有成人证据才放行**，其余剔除；
    /// - `strict = false`（覆盖率 <50%，说明上游字段缺失）：退化为"只剔明显儿童片"，
    ///   宁可不挡也不误杀（若夜间池字段一旦缺失还强行严格，会把整池成人内容误杀成空库）。
    public static func adultPoolReject(_ item: FeedItem, strict: Bool) -> String? {
        let evidence = hasAdultEvidence(item)
        if strict {
            return evidence ? nil : "no_adult_evidence_in_adult"
        }
        guard !evidence else { return nil }
        if let hit = keywordHit(item, in: Self.kidStrongMarks) { return "kid_in_adult[\(hit)]" }
        if let hit = Self.kidStrongMarks.first(where: { item.title.contains($0) }) {
            return "kid_in_adult_title[\(hit)]"
        }
        return nil
    }

    /// 成人证据覆盖率：用于决定夜航闸门走严格还是宽松（防上游字段变化导致整池误杀）。
    public static func adultEvidenceRatio(_ items: [FeedItem]) -> Double {
        guard !items.isEmpty else { return 0 }
        let hit = items.reduce(0) { $0 + (hasAdultEvidence($1) ? 1 : 0) }
        return Double(hit) / Double(items.count)
    }

    /// 成人证据（宽松，任一命中即算成人）：isAdult 标记 / 分类字段命中成人词 /
    /// 片名命中成人词或强特征 / 来源源名含"成人"。
    private static func hasAdultEvidence(_ item: FeedItem) -> Bool {
        if item.isAdult == true { return true }
        if keywordHit(item, in: Self.adultWords) != nil { return true }
        if keywordHit(item, in: Self.adultTitleMarks) != nil { return true }
        if Self.adultWords.contains(where: { item.title.contains($0) }) { return true }
        if (item.origin?.sourceName ?? "").contains("成人") { return true }
        return false
    }

    /// 儿童强特征（仅用于夜航反向剔除；**刻意不含"动画"二字** —— 成人动漫也是动画）。
    private static let kidStrongMarks: [String] = [
        "儿童", "亲子", "儿歌", "早教", "少儿", "宝宝", "幼儿园", "益智",
        "汪汪队", "小猪佩奇", "奥特曼", "熊出没", "喜羊羊", "大头儿子", "超级飞侠",
        "巴啦啦小魔仙", "迪士尼动画", "动画片",
    ]

    /// 成人向关键词（用于星幕/心屋兜底拦截；夜航不受影响）。
    /// 2026-09-22 用户口径补词：「很多我想要的成人分类都在索倪源里，比如热舞写真」——
    /// 索倪实测成人分类：伦理/港台三级/韩国伦理/西方伦理/日本伦理/两性课堂/写真热舞/擦边短剧，
    /// 故补 `写真/热舞/擦边` 等，防这些条目的源分类名漏过闸门混进星幕。
    private static let adultWords: [String] = [
        "情色", "色情", "伦理", "三级", "三級", "成人", "无码", "無碼", "有码", "有碼",
        "里番", "裏番", "肉番", "素人", "自拍", "偷拍", "盗摄", "主播", "裸聊",
        "限制级", "18禁", "R18", "写真", "热舞", "擦边", "两性课堂", "两性", "风俗", "風俗",
        "福利", "激情",
    ]

    /// 儿童不宜关键词（仅心屋生效；成人词已在前面拦掉）。
    private static let kidUnsafeWords: [String] = [
        "恐怖", "惊悚", "惊栗", "悬疑", "犯罪", "战争", "灾难", "暴力", "黑帮",
        "凶杀", "谋杀", "变态", "吸毒", "赌", "丧尸", "吸血", "血腥", "自杀",
        "灵异", "邪教", "鬼片",
    ]

    /// 强特征片名（几乎不可能是正常影视；仅用于星幕/心屋兜底）。
    private static let adultTitleMarks: [String] = [
        "一本道", "東京熱", "东京热", "FANZA", "无修正", "無修正", "麻豆", "探花", "SWAG",
    ]

    /// 在条目的分类字段（源分类 / 标签 / 聚合分类）查词表，并检查片名强特征。
    private static func keywordHit(_ item: FeedItem, in words: [String]) -> String? {
        var fields: [String] = []
        if let c = item.originalCategoryName { fields.append(c) }   // 2026-09-22 补：源分类原名（此前缺失→闸门失效）
        if let c = item.origin?.category { fields.append(c) }
        if let v = item.categories?.normal { fields.append(contentsOf: v) }
        if let v = item.categories?.canonical { fields.append(contentsOf: v) }
        if let v = item.categories?.tags { fields.append(contentsOf: v) }
        if let v = item.aggregateCategoryName { fields.append(v) }
        for f in fields {
            let low = f.lowercased()
            for w in words where low.contains(w.lowercased()) { return w }
        }
        for m in adultTitleMarks where item.title.contains(m) { return "片名:\(m)" }
        return nil
    }

    /// 全量构建目录 + 台账。
    public static func buildCatalog(items: [FeedItem], mode: String,
                                    manifestCount: Int, homeCount: Int, version: String?) -> (Catalog, DataLedger) {
        var ledger = DataLedger()
        ledger.sourceCount = manifestCount
        ledger.homeCount = homeCount
        ledger.feedFetchedCount = items.count
        ledger.version = version
        ledger.updatedAt = Date()

        // 夜航闸门策略：先算整池成人证据覆盖率（≥50% 走严格：只放有证据的），
        // 防上游字段一旦变化把整池成人内容误杀成空库（2026-09-22 实测定策）。
        let adultStrict = (mode == "adult") && adultEvidenceRatio(items) >= 0.5

        var seen = Set<String>()
        var out: [FeedItem] = []
        out.reserveCapacity(items.count)
        for item in items {
            if item.dedupId.isEmpty {
                ledger.decodeErrorCount += 1
                continue
            }
            if seen.contains(item.dedupId) {
                ledger.duplicateIDCount += 1
                ledger.dedupDroppedCount += 1
                continue
            }
            seen.insert(item.dedupId)
            if let reason = isolationReject(item, mode: mode, adultStrict: adultStrict) {
                ledger.recordIsolationDrop(reason)
                continue
            }
            if (item.poster?.url ?? "").isEmpty { ledger.emptyPosterCount += 1 }   // 保留，占位图兜底
            if item.playCandidates.isEmpty { ledger.noPlayURLCount += 1 }          // 保留，播放失败态兜底
            if (item.aggregateCategoryName ?? "").isEmpty { ledger.unknownCategoryCount += 1 }
            out.append(item)
        }
        ledger.catalogCount = out.count

        var categories = categoryStats(from: out)
        categories.sort { $0.count > $1.count }
        let catalog = Catalog(items: out, categories: categories)
        FilmLog.i("ADAPTER source=\(ledger.sourceCount) fetched=\(ledger.feedFetchedCount) "
                + "catalog=\(ledger.catalogCount) isoDrop=\(ledger.isolationDroppedCount) "
                + "dup=\(ledger.duplicateIDCount) emptyPoster=\(ledger.emptyPosterCount)")
        return (catalog, ledger)
    }

    /// 分类统计（与 Android aggregateToStats 同口径：按 aggregate_category_id 聚合）。
    ///
    /// 2026-09-23 用户钦定两条：
    /// ①「分类一部也叫个分类」→ 源分类少于 8 条不上榜（与货架 `minShelfItems=8` 同口径；
    ///   实测全量 85659 条里 36 个源分类有 12 个不足 8 条，全是源站拆分残渣：战争1/恐怖1/爱情1…）。
    /// ② 同名分类按 id 拆裂（电视剧 10509+759+6）在展示层由 `NavCatalog.groups` 归并，
    ///   **此处不合并 id** —— 分类浏览路由按源 id 过滤（`Group.catIDs`），合并会断路由。
    public static func categoryStats(from items: [FeedItem]) -> [FeedCategoryStat] {
        var counts: [String: (name: String, count: Int)] = [:]
        for it in items {
            let id = it.aggregateCategoryId ?? "_unknown"
            let name = it.aggregateCategoryName ?? "未知分类"
            counts[id, default: (name, 0)].count += 1
        }
        return counts.compactMap { id, v in
            v.count < 8 ? nil : FeedCategoryStat(id: id, name: v.name, count: v.count)
        }
    }

    /// 一条检索命中：影片 + 命中来源（用于结果上标注「演员 xxx」，让用户知道这条为什么出现）。
    /// 一条检索命中：影片 + 命中来源（用于结果上标注「演员 xxx」，让用户知道这条为什么出现）。
    public struct SearchHit: Identifiable, Hashable {
        public let item: FeedItem
        /// 命中的人物名（非人物命中时为 nil）
        public let matchedPerson: String?
        /// 人物身份（"演员" / "导演"）
        public let matchedRole: String?
        public var id: String { item.dedupId }

        public init(item: FeedItem, matchedPerson: String? = nil, matchedRole: String? = nil) {
            self.item = item
            self.matchedPerson = matchedPerson
            self.matchedRole = matchedRole
        }
    }

    /// 本地检索（标题前缀 > 标题包含 > 演员/导演 > 拼音首字母 > 拼音全拼 > 演员/导演拼音），无网络依赖。
    ///
    /// 拼音通道（2026-09-22 用户反馈「搜索首字母用不了」）：
    /// 仅当查询串是纯 ASCII（`lldq` / `liulangdiqiu` / `llz`）时才启用——中文查询不付任何额外成本；
    /// 命中排序放在中文通道之后（用户敲中文时中文结果优先）。
    ///
    /// **口径（用户钦定）**：对齐大牌做法——① 演员/导演同样可拼音首字母搜（`llz` 出李丽珍参演的片）；
    /// ② 每个档位内按「可播 > 热度分 > 片名短」排序，避免单字母输入时返回一堆随机顺序的片子；
    /// ③ 支持「吕」类 ü 的 `lv` / `lu` 双通道。**不采用** TV 版依赖中台 `pinyin_abbr` 字段的做法。
    public static func search(_ items: [FeedItem], query raw: String, limit: Int = 120) -> [FeedItem] {
        searchHits(items, query: raw, limit: limit).map(\.item)
    }

    /// 同上，但返回带「命中来源」的富结果（搜索页用它标注演员命中）。
    public static func searchHits(_ items: [FeedItem], query raw: String, limit: Int = 120) -> [SearchHit] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var prefix: [FeedItem] = [], contains: [FeedItem] = [], people: [FeedItem] = []
        var loose: [FeedItem] = []                          // 跳字容错档（漏「的」等连接字仍可命中）
        var personOf: [String: (String, String)] = [:]      // dedupId → (人名, 身份)
        let qLoose = q.replacingOccurrences(of: " ", with: "")
        let looseON = qLoose.count >= 3                     // 太短的 query 做跳字匹配会误命中泛滥
        for it in items {
            if it.title.hasPrefix(q) { prefix.append(it) }
            else if it.title.contains(q) { contains.append(it) }
            else if looseON, PinyinIndex.isSubsequence(qLoose, in: it.title.replacingOccurrences(of: " ", with: "")) {
                loose.append(it)
            }
            else if let p = firstPersonMatch(it, needle: q) {
                people.append(it)
                personOf[it.dedupId] = p
            }
            if prefix.count >= limit { break }
        }

        var out: [SearchHit] = ranked(prefix).map { SearchHit(item: $0) }
            + ranked(contains).map { SearchHit(item: $0) }
            + ranked(loose).map { SearchHit(item: $0) }
        // 注：不直接写 `dict[k]?.0`（可选链取元组元素），CI 35733441270 报
        // 「cannot convert '(String, String)?' to 'String?'」→ 先解包再用。
        for it in ranked(people) {
            if let p = personOf[it.dedupId] {
                out.append(SearchHit(item: it, matchedPerson: p.0, matchedRole: p.1))
            } else {
                out.append(SearchHit(item: it))
            }
        }
        var seen = Set(out.map(\.id))

        // 中文通道已够用时不再计算拼音（片库上万条时避免无谓的转换开销）
        guard out.count < limit, PinyinIndex.isPinyinQuery(q) else {
            return Array(out.prefix(limit))
        }

        let needle = PinyinIndex.normalize(q)
        var buckets: [PinyinIndex.Tier: [SearchHit]] = [:]
        for it in items where !seen.contains(it.dedupId) {
            var tier = PinyinIndex.titleTier(PinyinIndex.key(for: it.title), needle: needle)
            var personName: String? = nil
            var personRole: String? = nil
            // 片名命中优先；片名只是「包含」级时才看人名（人名的「前缀命中」比片名的「包含命中」更相关）
            if tier.rawValue > PinyinIndex.Tier.person.rawValue {
                if let p = firstPersonPinyinMatch(it, needle: needle) {
                    tier = .person
                    personName = p.0
                    personRole = p.1
                }
            }
            guard tier != .none else { continue }
            seen.insert(it.dedupId)
            buckets[tier, default: []].append(SearchHit(item: it,
                                                        matchedPerson: personName,
                                                        matchedRole: personRole))
        }

        for tier in [PinyinIndex.Tier.iniPrefix, .fullPrefix, .person, .iniContains, .fullContains] {
            guard let arr = buckets[tier], !arr.isEmpty else { continue }
            out += rankedHits(arr)
        }
        return Array(out.prefix(limit))
    }

    /// 档位内排序（大牌式相关度）：可播优先 → 热度分降序 → 片名短优先。
    private static func ranked<T>(_ arr: [T], item: (T) -> FeedItem) -> [T] {
        arr.sorted { lhs, rhs in
            let a = item(lhs), b = item(rhs)
            if a.isPlayable != b.isPlayable { return a.isPlayable }
            let qa = a.qualityScore ?? 0, qb = b.qualityScore ?? 0
            if qa != qb { return qa > qb }
            return a.title.count < b.title.count
        }
    }

    private static func ranked(_ arr: [FeedItem]) -> [FeedItem] { ranked(arr) { $0 } }

    private static func rankedHits(_ arr: [SearchHit]) -> [SearchHit] { ranked(arr) { $0.item } }

    /// 中文人名命中（演员优先于导演，与详情页展示顺序一致）。返回 (人名, 身份)。
    private static func firstPersonMatch(_ it: FeedItem, needle: String) -> (String, String)? {
        if let a = (it.actors ?? []).first(where: { $0.contains(needle) }) { return (a, "演员") }
        if let d = (it.directors ?? []).first(where: { $0.contains(needle) }) { return (d, "导演") }
        return nil
    }

    /// 拼音人名命中（`llz` → 李丽珍；`wujing` → 吴京）。返回 (人名, 身份)。
    private static func firstPersonPinyinMatch(_ it: FeedItem, needle: String) -> (String, String)? {
        for n in (it.actors ?? []) where PinyinIndex.personTier(n, needle: needle) != .none { return (n, "演员") }
        for n in (it.directors ?? []) where PinyinIndex.personTier(n, needle: needle) != .none { return (n, "导演") }
        return nil
    }
}

// MARK: - 目录

public struct Catalog: Codable {
    public var items: [FeedItem]
    public var categories: [FeedCategoryStat]

    public func items(inCategory id: String) -> [FeedItem] {
        items.filter { $0.aggregateCategoryId == id }
    }

    /// 多分类并集（导航大类归并后用）。
    /// 2026-09-22 用户：「打开我的分类看到三个分类，应该都是属于伦理下面的，像日本伦理、西方伦理」
    /// → 合并大类后一个组对应多个原始分类，取并集才是该大类的真实内容。
    public func items(inCategories ids: [String]) -> [FeedItem] {
        guard !ids.isEmpty else { return [] }
        let set = Set(ids)
        return items.filter { if let c = $0.aggregateCategoryId { return set.contains(c) } else { return false } }
    }
}
