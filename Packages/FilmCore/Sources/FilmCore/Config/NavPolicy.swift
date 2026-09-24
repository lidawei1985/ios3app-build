import Foundation

/// 端侧导航与源浏览策略（2026-09-22 用户钦定口径）。
///
/// 与中台 `E:\FilmCollector\audit\USER_NAV_MAP_20260922.json` 同源，但**独立实现**：
/// 中台侧负责采集期归并，本文件负责【客户端侧】——① 点播源浏览的分类分派；
/// ② 端隔离红线（成人内容只给夜航）；③ 特色分类（4K 专区 / 邵氏经典 / Netflix 专区）。
///
/// 用户原话（2026-09-22）：
///  - 「很多我想要的成人分类都在索倪源里，比如热舞写真、里番；有关奈飞的、邵氏电影这两种是星幕的；
///     还有伦理三级都有，但是是夜航的」
///  - 「源里分类叫伦理就叫伦理……直接叫伦理的都放进我们的伦理里」
///  - 「港台三级伦理这些必须是夜航，其他 APP 不能给」
///  - 「多源集合一个分类到我们的一个分类」（同名大类合并，禁止 A源伦理/B源伦理 各出一个）
public enum NavPolicy {

    // MARK: - 导航组

    /// 一个导航项：标题 + 命中词表（源分类名包含任一词即归入本组）。
    public struct NavGroup: Identifiable, Hashable {
        public let id: String
        public let title: String
        public let match: [String]

        public init(id: String, title: String, match: [String]) {
            self.id = id
            self.title = title
            self.match = match
        }
    }

    // MARK: - 三端导航表

    /// 星幕（normal）：内容只做【电影 + 电视剧 + 动漫 + 短剧】。
    /// 综艺/体育(足球篮球斯诺克)/纪录片/预告解说 一律不要（用户：「综艺足球什么的完全没必要有」）。
    /// 短剧 2026-09-23 放开为独立入口（用户要短剧源）；成人向「擦边短剧」仍只给夜航。
    /// 特色三类（用户点名）：4K专区 / 邵氏经典 / Netflix专区。
    ///
    /// **顺序 = 优先级（具体在前、笼统在后）**：`邵氏电影`/`Netflix电影`/`4K电影` 都含「电影」二字，
    /// 若「电影」组排前面会被它先抢走 → 所以特色组必须在最前；「动画电影」同理会先归「动漫」组。
    private static let normalGroups: [NavGroup] = [
        NavGroup(id: "normal_4k", title: "4K专区", match: ["4K电影", "4K", "4k"]),
        NavGroup(id: "normal_shaoshi", title: "邵氏经典", match: ["邵氏电影", "邵氏"]),
        NavGroup(id: "normal_netflix", title: "Netflix专区", match: ["Netflix电影", "Netflix自制剧", "Netflix"]),
        // 短剧（2026-09-23 新增）。用户原话：「再全网找找能内置的源……和短剧的 我记着有很多专门短剧的源」。
        // 取证结论：**不用外找** —— 我们自己的 7 个内置点播源全带短剧分类
        //   （暴风「短剧大全/AI漫剧」/ 无尽·最大·金鹰·天涯·360「短剧/爽文短剧/反转爽剧」/ 非凡「短剧」），
        //   之前被 `normalExcludedWords` 里的「短剧/爽剧/女频/穿越/仙侠/脑洞」整条挡掉 → 用户「找不到短剧」。
        // 现独立成组（不并入「电视剧」）——沿用用户 2026-09-20 拍板口径「短剧允许，但要独立分类不混流」。
        // **必排在 normal_anime 之前**：「AI漫剧」「漫剧」同时含动漫组词，先命中即归短剧。
        // **「擦边短剧」刻意不在此列**：含「擦边」→ isAdultCategory 先命中 → 只有夜航（红线不动）。
        NavGroup(id: "normal_short", title: "短剧",
                 match: ["短剧", "微短剧", "爽剧", "爽文", "反转爽剧", "AI漫剧", "漫剧",
                         "女频", "重生民国", "穿越年代", "古装仙侠", "仙侠",
                         "现代言情", "反转爽文", "女恋总裁", "闪婚离婚",
                         "都市脑洞", "言情总裁", "脑洞悬疑"]),
        NavGroup(id: "normal_anime", title: "动漫",
                 match: ["动漫", "国产动漫", "日韩动漫", "欧美动漫", "港台动漫", "海外动漫",
                         "动画片", "有声动漫", "动画", "漫剧"]),
        NavGroup(id: "normal_tv", title: "电视剧",
                 match: ["电视剧", "连续剧", "国产剧", "香港剧", "台湾剧", "港剧", "台剧", "韩国剧", "韩剧",
                         "日本剧", "日剧", "欧美剧", "海外剧", "泰国剧", "泰剧", "港澳剧"]),
        NavGroup(id: "normal_movie", title: "电影",
                 match: ["电影", "电影片", "动作片", "喜剧片", "爱情片", "科幻片", "恐怖片", "剧情片",
                         "战争片", "惊悚片", "悬疑片", "犯罪片", "灾难片", "西部片", "古装片", "历史片",
                         "动作", "喜剧", "爱情", "科幻", "恐怖", "惊悚", "悬疑", "犯罪", "战争", "灾难",
                         "奇幻", "武侠", "冒险", "历史", "传记", "古装", "西部", "戏曲", "歌舞", "同性",
                         "青春", "玄幻", "剧情", "家庭"]),
    ]

    /// 夜航（adult）：大类**由普查数据定**，不是我拍脑袋。
    ///
    /// 用户口径（2026-09-22 原话，两条）：
    ///  - 「你先把成人的分类和原始源找到，看看到底成人有多少大类，再给我们的 APP 给分类。
    ///     我不说了吗？100 个原始源里都有的分类就是大类对不对！！」
    ///  - 「100 个里面都有里番或者情色三级之类的那就也是大类对不对！」
    ///
    /// 普查（14 个可用成人源 / 481 条分类，`adult_cats_census.json`）后的分类族覆盖率：
    ///   成人动漫·里番 13源(93%) ｜ 三级·情色 12源(86%) ｜ 伦理 11源(79%)
    ///   无码有码 10源(71%) ｜ 主播素人·写真热舞 10源(71%) ｜ 中文字幕·精品推荐 10源(71%)
    ///   自拍偷拍·探花 9源(64%) ｜ 制服丝袜 9源(64%) ｜ 人妻熟女 8源(57%) ｜ 传媒 8源(57%)
    ///   …≥60% 的定为一级大类，其余全部进「其他」并由二级筛选（subBar）细分。
    /// **顺序 = 优先级**（越专有越靠前）。
    private static let adultGroups: [NavGroup] = [
        // 93% —— 里番/动漫（用户点名要做）
        NavGroup(id: "adult_anime", title: "成人动漫",
                 match: ["里番", "裏番", "肉番", "H动漫", "H动画", "エロアニメ", "成人动漫", "成人动画",
                         "动漫无码", "动漫有码", "卡通动漫", "动漫", "卡通", "动画", "漫剧", "两性课堂", "两性"]),
        // 86% —— 三级/情色（用户：「情色就是三级片，应该和港台三级、三级合并一个分类」）
        NavGroup(id: "adult_cat3", title: "三级",
                 match: ["三级", "三級", "三级片", "情色", "色情", "限制级", "Category III", "CAT III",
                         "港台三级", "香港三级", "台湾三级", "日本三级", "韩国三级",
                         "西方三级", "欧美三级"]),
        // 79% —— 伦理（用户：「打开我的分类看到三个，应该都是属于伦理下面的」）
        NavGroup(id: "adult_ethics", title: "伦理",
                 match: ["伦理", "理论"]),
        // 71% —— 主播/素人/自拍/偷拍/写真/热舞/唯美（擦边真人向）
        NavGroup(id: "adult_star", title: "写真热舞",
                 match: ["写真热舞", "写真", "热舞", "唯美", "模特", "主播", "素人", "网红",
                         "自拍", "偷拍", "盗摄", "裸聊", "擦边"]),
        // 64% —— 探花 / 门事件 / 黑料
        NavGroup(id: "adult_tanhua", title: "自拍探花",
                 match: ["探花", "门事件", "黑料", "网曝", "抖阴"]),
        // 71% —— 中文字幕 / 精品推荐（精选位）
        NavGroup(id: "adult_sub", title: "精选推荐",
                 match: ["中文字幕", "精品推荐", "推荐", "热门", "最新", "视频一区", "视频二区"]),
        // 71% —— 无码 / 有码 / AV（成人真人；放在精选之后，「精品推荐」不被它抢走）
        NavGroup(id: "adult_real", title: "成人真人",
                 match: ["无码", "無碼", "有码", "有碼", "AV解说", "AV", "精品", "成人"]),
        // 其余题材类目（人妻熟女 / 制服丝袜 / 性爱 / 乱伦强奸 / 另类重口 / SM调教 / 群交 /
        // 传媒工作室 / 换脸AI / VR / 小说图文…57%±）→ 全部进「其他」，靠二级筛选精确找。
    ]

    /// 心屋（child）：只做儿童适宜内容（用户：「儿童里不是不可以有电影，但是一定是适合儿童的」）。
    /// 顺序即优先级：「动画片」在「动漫剧场」「儿童电影」之前命中。
    private static let childGroups: [NavGroup] = [
        NavGroup(id: "child_anime", title: "动画片",
                 match: ["动画片", "动画电影", "动漫电影", "动画", "漫剧", "有声动漫"]),
        NavGroup(id: "child_anime_series", title: "动漫剧场",
                 match: ["动漫", "国产动漫", "日韩动漫", "欧美动漫", "港台动漫", "海外动漫"]),
        NavGroup(id: "child_kids", title: "儿童",
                 match: ["儿童", "儿童儿歌", "少儿", "亲子", "儿歌", "早教", "幼教", "科普学习"]),
        NavGroup(id: "child_movie", title: "儿童电影",
                 match: ["电影", "剧情", "喜剧", "动作", "科幻", "家庭", "冒险", "奇幻"]),
    ]

    /// 端 → 导航组。
    public static func navGroups(forMode mode: String) -> [NavGroup] {
        switch mode {
        case "adult": return adultGroups
        case "child": return childGroups
        default:      return normalGroups
        }
    }

    // MARK: - 分类分派

    /// 源分类名 → 本端导航标题。返回 nil = 本端不要这个分类（隔离或非目标内容）。
    public static func navTitle(forSourceCategory name: String, mode: String) -> String? {
        guard allowsCategory(name, mode: mode) else { return nil }
        for g in navGroups(forMode: mode) where g.match.contains(where: { name.contains($0) }) {
            return g.title
        }
        // 夜航兜底（2026-09-22 用户：「索倪只是样板，还有很多源都有这些分类，剩下的就是把源并进我们的分类」）：
        // 实测 9 个在线成人源共 **172 个题材类目**（强奸乱伦/制服诱惑/SM调教/丝袜美腿/探花系列/
        // 麻豆传媒/人妻熟女/校园春色…）。这些不是「伦理/三级/成人动漫/写真热舞」任一类，
        // 但**都是成人内容、必须能看到** —— 逐类建导航只会碎成一堆，统一进「其他」；
        // 进组后再由二级筛选（subBar）按原始类目名精确找。
        if mode == "adult" { return "其他" }
        return nil
    }

    /// 本端是否允许这个源分类（分类级闸门）。
    ///
    /// 顺序很关键：**先判红线，再判目标范围**。
    ///  - 成人分类（伦理/三级/成人动漫/写真热舞/题材类目…）：只有夜航可放行；
    ///  - 夜航**默认全收**（源本身就是成人源），只挡明确的儿童向分类；
    ///  - 心屋反向：成人分类已拦，再拦儿童不宜（恐怖/惊悚/犯罪/战争/悬疑…）；
    ///  - 星幕：成人分类已拦，另外综艺/体育/纪录片/预告解说 不要（短剧 2026-09-23 起独立放行）。
    public static func allowsCategory(_ name: String, mode: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return false }
        if isAdultCategory(n) { return mode == "adult" }
        switch mode {
        case "adult":
            // ① 明确儿童向分类（用户：「普通动漫片、儿童片绝对进不了夜航」）
            if contains(n, kidCategoryMarks) { return false }
            // ② 非成人正常影视分类（综艺/体育/剧集/院线片/短剧/真动画/小说…）
            //    普查：14 个成人源里 12 个都夹带这些。含成人向标记的（里番/无码/三级/情色/AV…）除外。
            if contains(n, adultExcludedCategoryWords) && !contains(n, adultKeepMarks) { return false }
            return true
        case "child":
            if contains(n, kidUnsafeCategoryWords) { return false }
            return navGroups(forMode: "child").contains { g in g.match.contains { n.contains($0) } }
        default:
            if contains(n, normalExcludedWords) { return false }
            return navGroups(forMode: "normal").contains { g in g.match.contains { n.contains($0) } }
        }
    }

    /// 是否成人向分类（跨端红线：只允许夜航）。
    /// 用户原话：「港台三级伦理这些必须是夜航，其他的 APP 不能给」「里番之类的成人内容一定是夜航的」。
    public static func isAdultCategory(_ name: String) -> Bool {
        contains(name, adultCategoryWords)
    }

    /// 是否成人类分类/片名（用于条目级兜底）。
    public static func isAdultText(_ text: String) -> Bool {
        contains(text, adultCategoryWords) || contains(text, adultTitleMarks)
    }

    // MARK: - 条目级闸门（源浏览用；与 FeedAdapter.isolationReject 同口径）

    /// 源内条目是否可在本端展示（标题 + 源分类双判）。
    public static func allowsItem(title: String, sourceCategory: String?, mode: String) -> Bool {
        if let c = sourceCategory, !allowsCategory(c, mode: mode) { return false }
        switch mode {
        case "adult":
            // 夜航：标题命中小学/儿童强特征 → 剔除（防纯动画片混入）
            if contains(title, kidStrongTitleMarks) { return false }
            return true
        case "child":
            if isAdultText(title) { return false }
            if contains(title, kidUnsafeTitleWords) { return false }
            return true
        default:
            if isAdultText(title) { return false }
            return true
        }
    }

    // MARK: - 词表

    /// 成人向分类词（红线：只给夜航）。
    ///
    /// 2026-09-22 第二版：实测 9 个在线成人源共 **172 个题材类目**（`adult_sources_cats.json`），
    /// 除「伦理/三级/成人动漫/写真热舞/成人真人」五个大类外，其余全是性题材标签
    /// （强奸乱伦 / 制服诱惑 / SM调教 / 丝袜美腿 / 探花系列 / 麻豆传媒 / 人妻熟女 / 校园春色…）。
    /// 这些也必须挡在星幕/心屋之外，故词表按实测扩充。
    /// **注意**：刻意用「同性恋」而非「同性」（星幕有正常的同性题材电影）、
    /// 用「学生妹」而非「学生」（避免误伤校园题材）。
    private static let adultCategoryWords: [String] = [
        // 大类
        "伦理", "情色", "色情", "三级", "三級", "限制级", "成人", "无码", "無碼", "有码", "有碼",
        "里番", "裏番", "肉番", "H动漫", "H动画", "エロアニメ", "擦边", "18禁", "R18",
        "写真热舞", "写真", "热舞", "两性", "风俗", "風俗", "福利", "激情",
        // 题材类目（实测成人源高频）
        "强奸", "乱伦", "制服", "诱惑", "同性恋", "人妻", "熟女", "丝袜", "美腿", "调教", "群交",
        "萝莉", "巨乳", "美乳", "爆乳", "换脸", "探花", "SWAG", "门事件", "抖阴", "野战", "春色",
        "性爱", "人兽", "重口", "网曝", "黑料", "麻豆", "传媒", "情事", "自慰", "口交", "车震",
        "偷情", "出轨", "偷窥", "按摩", "痴女", "痴汉", "少妇", "御姐", "学生妹", "淫", "骚",
        // 参演主体 / 渠道
        "素人", "自拍", "偷拍", "盗摄", "裸聊", "主播", "AV片",
    ]

    /// 夜航要挡掉的**儿童向分类**（用户：「普通动漫片、儿童片绝对进不了夜航」）。
    /// 刻意不含「动画/动漫」—— 成人源里的「卡通动漫」可能是成人卡通；普通动画分类改由
    /// `plainAnimeWords` + `adultAnimeMarks` 这一对判据处理（既挡真动画片、又留成人动漫）。
    private static let kidCategoryMarks: [String] = [
        "儿童", "儿歌", "亲子", "早教", "幼教", "少儿", "宝宝", "幼儿园", "益智", "科普",
    ]

    /// 夜航要挡的**普通动画分类词**（2026-09-22 用户：「真动画片还在，还占个分类」）。
    /// 已并入 `adultExcludedCategoryWords`，保留此别名仅为可读性。
    private static let plainAnimeWords: [String] = [
        "动画", "动漫", "卡通", "漫剧", "有声动漫",
    ]

    /// 夜航要挡的**非成人正常影视分类**（2026-09-22 普查驱动）。
    ///
    /// 普查发现：14 个可用成人源里有 **12 个（86%）** 夹带正常影视分类 ——
    /// 「大陆综艺 / 日韩综艺 / 欧美综艺 / 港台综艺 / 电视剧 / 日剧 / 韩剧 / 欧美剧 / 台湾剧 /
    ///   电影 / 动作片 / 喜剧片 / 恐怖片 / 战争片 / 爱情片 / 科幻片 / 剧情片 / 古装仙侠 /
    ///   反转爽剧 / 体育赛事 / 篮球 / 足球 / 动漫 / 卡通动漫 / 欧美动漫 / 国产动漫 / 动画片 /
    ///   另类小说 / 预告片 / 剧情介绍」。
    /// 这些不是成人内容，用户在夜航看到只会觉得「怎么还有动画片/综艺」（原话：
    /// 「最可笑的是动画那两个真动画片还在，而且还占个分类！！！」）→ 分类级一律挡掉。
    private static let adultExcludedCategoryWords: [String] = [
        // 综艺 / 体育
        "综艺", "真人秀", "体育", "赛事", "篮球", "足球", "斯诺克", "台球", "运动",
        // 剧集
        "电视剧", "连续剧", "国产剧", "港剧", "台剧", "日剧", "韩剧", "欧美剧", "海外剧",
        "泰剧", "台湾剧", "香港剧", "韩国剧", "日本剧", "港澳剧",
        // 正常电影类型（成人源夹带的院线片/网大）
        "电影", "动作片", "喜剧片", "爱情片", "科幻片", "恐怖片", "剧情片", "战争片",
        "惊悚片", "悬疑片", "犯罪片", "灾难片", "西部片", "古装片", "历史片", "4K",
        // 短剧 / 爽剧
        "短剧", "爽剧", "爽文", "女频", "脑洞", "古装仙侠", "仙侠", "穿越",
        // 真动画（用户点名）
        "动画", "动漫", "卡通", "漫剧", "有声动漫",
        // 其他非成人
        "纪录片", "记录片", "预告片", "预告", "解说", "演唱", "MV", "小说", "图文",
    ]

    /// 成人向标记 —— 含这些词说明是**成人内容**，不受上面排除表影响（白名单）。
    ///
    /// 「激情」「擦边」必须在内：普查实测有「激情动漫」「擦边短剧」这类源分类，
    /// 它们同时命中排除表的「动漫」「短剧」，但本质是成人内容（不能误挡）。
    private static let adultKeepMarks: [String] = [
        "里番", "裏番", "肉番", "成人", "H动漫", "H动画", "エロ", "无码", "無碼", "有码", "有碼",
        "情色", "色情", "三级", "三級", "限制级", "18禁", "R18", "AV", "激情", "擦边",
    ]

    /// 成人向片名强特征（几乎不可能是正常影视）。
    private static let adultTitleMarks: [String] = [
        "一本道", "東京熱", "东京热", "FANZA", "无修正", "無修正", "麻豆", "探花", "SWAG",
    ]

    /// 星幕（normal）明确不要的源分类（用户：「综艺足球什么的完全没必要有」）。
    ///
    /// 2026-09-23 变更：**移除短剧相关词**（短剧/爽剧/爽文/女频/反转/穿越/仙侠/脑洞）——
    /// 它们改由 `normal_short` 组收编（用户要短剧源）。综艺/体育/纪录片/预告解说 仍然不要。
    private static let normalExcludedWords: [String] = [
        "综艺", "真人秀", "体育", "赛事", "篮球", "足球", "斯诺克", "台球", "运动",
        "纪录片", "记录片", "预告片", "预告", "解说", "演唱", "MV",
    ]

    /// 心屋（child）儿童不宜分类词。
    private static let kidUnsafeCategoryWords: [String] = [
        "恐怖", "惊悚", "惊栗", "悬疑", "犯罪", "战争", "灾难", "暴力", "黑帮", "凶杀",
        "谋杀", "变态", "吸毒", "丧尸", "吸血", "血腥", "自杀", "灵异", "邪教", "鬼片",
    ]

    /// 夜航反向：儿童/小学向强特征片名（刻意不含「动画」——成人动漫也是动画）。
    private static let kidStrongTitleMarks: [String] = [
        "儿童", "亲子", "儿歌", "早教", "少儿", "宝宝", "幼儿园", "益智",
        "汪汪队", "小猪佩奇", "奥特曼", "熊出没", "喜羊羊", "大头儿子", "超级飞侠",
        "巴啦啦小魔仙", "迪士尼动画",
    ]

    /// 心屋条目级：儿童不宜片名特征。
    private static let kidUnsafeTitleWords: [String] = [
        "凶杀", "谋杀", "变态", "自杀", "吸毒", "血腥", "丧尸", "邪教",
    ]

    /// 二级筛选项短名（2026-09-22 用户：「合并了是不是得分区域？比如韩国/日本/港台，
    /// 我说不明白，但是我想看那种得能找到，也就是筛选吧」）。
    ///
    /// 合并大类之后，组内每个源分类名里天然带着维度信息（韩国伦理 / 日本伦理 / 港剧 / 动作片…），
    /// 把它剥成短标签当筛选项即可 —— 用户点「韩国」就只剩韩国的。
    /// 返回 nil = 该项是该大类的「通用项」（如「伦理」本身），已被「全部」覆盖，不出 chip。
    public static func subLabel(_ name: String, groupTitle: String) -> String? {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(groupTitle) { s.removeFirst(groupTitle.count) }
        else if s.hasSuffix(groupTitle) { s.removeLast(groupTitle.count) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 组名之外的常见大类尾缀（动作片→动作、国产剧→国产、Netflix电影→Netflix）
        for suffix in ["电影", "电视剧", "动漫", "片", "剧"] where s.count > suffix.count && s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
            break
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// 源分类名 / 源站地区字段 → 地区标签（**口径与中台 area 字段完全一致**，见 `regionOrder`）。
    /// 用户要的「想看韩国的能找到」就是靠这一层把 韩国伦理/韩剧/韩国三级 归成一个「韩国」。
    public static func regionLabel(_ name: String) -> String? {
        let s = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let first = s.components(separatedBy: CharacterSet(charactersIn: "/／、,，|")).first ?? s
        for cand in [first, s] {
            let c = cand.trimmingCharacters(in: .whitespacesAndNewlines)
            if c.isEmpty { continue }
            for (label, words) in regionWords where words.contains(where: { c == $0 || c.contains($0) }) {
                return label
            }
        }
        return nil
    }

    /// 分类页「地区」筛选 chip 的**固定展示顺序**（数据里没有的地区自动不出现）。
    /// 与中台 `tools/backfill_area.py` 的 `AREA_RULES` 逐字对齐，改一处必须同步另一处。
    public static let regionOrder: [String] = [
        "国产", "中国香港", "中国台湾", "日本", "韩国", "美国", "欧洲", "泰国", "印度", "其他",
    ]

    /// 地区词表（**顺序 = 匹配优先级**，必须与中台 `tools/backfill_area.py` 的 `AREA_RULES` 逐条对齐，
    /// 机检：`python scripts/check_region_filter.py`）：
    ///  - 「中国香港/中国台湾」必须排在「国产」前 —— 国产词表含「中国」，
    ///    否则"中国香港"会被整片判成国产（2026-09-23 机检实测抓到）；
    ///  - 「印度尼西亚」必须排在「印度」前，同理；
    ///  - 不用裸单字（英/法/西/印…），避免"西班牙→西""印尼→印度"这类误判。
    private static let regionWords: [(String, [String])] = [
        ("中国香港", ["中国香港", "香港", "港产", "港剧", "港台", "港"]),
        ("中国台湾", ["中国台湾", "台湾", "台剧", "台湾剧"]),
        ("其他", ["印度尼西亚", "印尼"]),
        ("印度", ["印度"]),
        ("国产", ["中国大陆", "中国内地", "大陆", "内地", "中国", "华语", "国产"]),
        ("日本", ["日本", "日剧"]),
        ("韩国", ["韩国", "韩剧"]),
        ("美国", ["美国"]),
        ("欧洲", ["英国", "法国", "德国", "意大利", "西班牙", "俄罗斯", "荷兰", "瑞典",
                 "挪威", "丹麦", "波兰", "比利时", "瑞士", "奥地利", "爱尔兰", "希腊",
                 "葡萄牙", "芬兰", "捷克", "匈牙利", "乌克兰", "欧洲", "欧美", "西方"]),
        ("泰国", ["泰国", "泰剧", "马泰"]),
        ("其他", ["加拿大", "澳大利亚", "新西兰", "巴西", "阿根廷", "墨西哥",
                 "南非", "新加坡", "马来西亚", "越南", "菲律宾", "土耳其",
                 "其它", "其他", "多国", "合拍"]),
    ]

    // MARK: - 工具

    /// 片名归一化（用于「同片 4K 替换」的匹配）。
    ///
    /// 实测（2026-09-22 索倪源只读扫描）：4K 分类 838 条里 105 条与普通电影同片，
    /// 但片名带版本后缀（`源代码4K` / `哈尔的移动城堡国语4K` / `无间道2粤语4K`）——
    /// 故剥离 4K/高清/国语/粤语/中字 等版本标记 + 标点空白后再比对。
    public static func canonicalTitle(_ raw: String) -> String {
        let drop: [String] = ["4K", "4k", "4Ｋ", "高清", "超清", "蓝光", "BluRay", "HDR", "REMUX",
                              "国语", "粤语", "国粤双语", "双语", "中字", "中文字幕", "无删减",
                              "未删减", "完整版", "剧场版", "加长版", "修复版", "重制版", "TC", "HD"]
        var s = raw
        for t in drop { s = s.replacingOccurrences(of: t, with: "") }
        let junk = CharacterSet(charactersIn: " \t\n-—_·:：!！?？,，.。/、'\"“”‘’()（）[]【】+&")
        s = s.components(separatedBy: junk).joined()
        return s.lowercased()
    }

    private static func contains(_ text: String, _ words: [String]) -> Bool {
        let low = text.lowercased()
        return words.contains { low.contains($0.lowercased()) }
    }
}
