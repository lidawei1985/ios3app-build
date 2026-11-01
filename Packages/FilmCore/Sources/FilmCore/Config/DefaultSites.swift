import Foundation

/// 星幕电视剧独立通道（2026-09-20 新增，公网承载，零本地依赖）：
/// - 采集端 feed 是纯电影库（70096 条全 movie_*），电视剧由本模块独立供给；
/// - 协议 = MacCMS10 标准 JSON（TVBox 点播源同款 ac= 端点），纯公网 HTTPS；
/// - 多源自动容灾：源挂自动切下一个（量子→天涯→非凡→卧龙），无人值守；
/// - 违禁内容双层硬过滤：分类级只放行「剧」类，条目级再过黑名单关键词。
public enum DefaultSites {

    /// 公网 CMS 源（2026-09-20 实测存活顺序）
    public static let tvDramaSources: [TVBoxSite] = [
        // 2026-11-01 全量彻查：原 量子/天涯/非凡/卧龙 已全灭
        //   （cj.lziapi 404、tyyszy 连接被重置、cj.ffzyapi 403、collect.wolongzyw 200 但零条目）。
        //   判据不是「HTTP 200 就算活」，而是 ①ac=videolist 拉到片 ②取首部片详情
        //   解析播放地址 ③播放地址带 okhttp UA / Referer / 浏览器 UA 三种头实测 HTTP 200。
        //   以下 4 条为当轮实测全通过者（多源自动容灾：挂了自动切下一个）。
        TVBoxSite(key: "drama:hongniu4", name: "红牛资源", api: "https://www.hongniuzy4.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "drama:jinying",  name: "金鹰资源", api: "https://jinyingzy.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "drama:hhzy",     name: "豪华资源", api: "https://hhzyapi.com/api.php/provide/vod/?ac=list", type: 1),
        TVBoxSite(key: "drama:subocj",   name: "速播资源", api: "https://subocj.com/api.php/provide/vod/?ac=videolist", type: 1),
    ]

    /// ★ v69 品牌归一（详情页聚合扩容配套，主人 2026-10-04「源的数量再给我扩扩」）：
    /// 同一 CMS 源站的多个镜像（「红牛资源 2」「红牛资源3」「❤红牛资源」…）必须归并成
    /// **同一个大源** —— 不然「一级源」chip 会拿镜像凑数，换源看着多其实换汤不换药。
    /// 规则：去括号说明（光速资源(切)）→ 去 emoji/空格/符号 → 去尾部序号（红牛资源 2 / 老司机10）。
    /// 「360资源」「155资源」里的数字在**中部**不受影响（尾部才剥）。
    public static func brandKey(_ raw: String) -> String {
        var s = raw
        if let r = s.range(of: "（") ?? s.range(of: "(") { s = String(s[..<r.lowerBound]) }
        s = s.filter { $0.isLetter || $0.isNumber }
        while let last = s.last, last.isNumber { s.removeLast() }
        return s
    }

    /// 内置点播源（TVBox sites 域，用户钦定：实测能用的内置进去、但可删除）。
    /// 2026-09-20 实测 20 候选存活 8：并发 ac=list 校验分类+条目，ac=detail 校验播放地址真实。
    /// key 统一 "builtin:" 前缀 —— 删除走 deletedBuiltinKeys 持久化，可一键恢复。
    /// 内置点播源（影视区；心屋 child 只吃这一区，见 builtinVodSources(forMode:)）。
    ///
    /// 2026-11-01 全量彻查结果（主人钦定：「替换无效源是真的无效打不开的」）：
    /// - 原 50 条里 **34 条真死**：8 条连列表都打不开（502/404/SSL 断/连接重置）、
    ///   4 条 200 但零条目（空壳）、22 条有片但播放地址 403/404/被重置（能看不能播＝无效）。
    ///   判据三级：拉到片 → 详情有播放地址 → 播放地址三种 UA/Referer 组合实测 200。
    /// - 存活的 24 条**全部**分类表里都带「伦理片」等成人分类（实测 44-60 类/源，
    ///   无一例外）→ 按 2026-10-01 口径「心屋源池不许有带成人内容的源、不靠闸门兜」，
    ///   **一条都不能留在影视区**，全部下沉到 builtinMixedVodSources（星幕/成人端可见）。
    /// - 心屋不再共用本区：改走 `builtinChildVodSources`（v102 建池，3 条实测源 + 分类正名单）。
    /// 心屋（child）专用点播源池 —— 2026-11-01 建立（v102）。
    ///
    /// 背景：全量彻查发现**全网点播源无一例外带「伦理片」等成人分类**
    ///   （实测 24 条活源，分类表 44-60 类，全部含成人词）。本轮另做两轮扩源实测：
    ///   ① 40 条动漫/儿童站域名 → DNS 全不存在（猜域名不可行）；
    ///   ② 从 5 条真实活跃公开线路实挖 11 条源 → 零成人词的 **0 条**。
    ///   「源池里不含成人分类」的源在现实中不存在 → 一味源池级清空 = 心屋零源（内容归零），
    ///   与主人 2026-11-01「成人和影视保持现有量」直接冲突。
    /// 解法（四层，风险方向**只会少内容、不会漏脏内容**）：
    ///   ① 源池级：只收两轮实测都稳定、安全分类真正拉得到片的源（360/猫眼/茅台，首片播放地址实测 200）；
    ///   ② 分类级**正名单**（白名单枚举，非黑名单）：心屋只放行 动漫/动画/儿童/儿歌/科普/
    ///      纪录/教育/益智/家庭/亲子 类，其余分类在分类条里**根本不出现**；
    ///   ③ **禁全库流**：心屋不显示「全部」chip，首屏也不发不带 t= 的请求
    ///      （CMS 无分类参数返回全库混合流 —— 2026-10-01 心屋漏成人内容走的就是这条通道）；
    ///   ④ 条目级：NavPolicy.allowsItem 再兜一次（标题 + 源分类双判）。
    public static let builtinChildVodSources: [TVBoxSite] = [
        TVBoxSite(key: "builtin:kids:360zy", name: "360资源", api: "https://360zy.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:kids:maoyan", name: "猫眼资源", api: "https://api.maoyanapi.top/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:kids:mtzy", name: "茅台资源", api: "https://mtzy.me/api.php/provide/vod/", type: 1),
    ]

    /// 心屋分类**正名单**（白名单枚举）：命中任一关键词才放行。
    /// 2026-11-01 实测三源的安全分类：家庭篇 / 纪录片 / 动画片 / 国产动漫 / 动漫 / 动漫电影 …
    static let childCategoryAllowWords = ["动漫", "动画", "儿童", "儿歌", "科普", "纪录",
                                          "教育", "益智", "家庭", "亲子", "国学", "童话",
                                          "幼儿", "早教", "少儿"]

    /// 心屋分类**硬否决词**（双保险：正名单万一被上游新分类名绕过，这里再挡一次）。
    /// 含成人类目 + 儿童不宜类目（爱情/言情/都市/恐怖/惊悚/犯罪/悬疑 ——
    /// 2026-10-01 心屋真机漏出的正是「爱情片」「都市言情短剧」）。
    static let childCategoryDenyWords = ["伦理", "三级", "情色", "成人", "色情", "写真", "福利",
                                         "无码", "有码", "里番", "自拍", "强奸", "乱伦", "人妻",
                                         "熟女", "制服", "性爱", "AV", "av", "激情", "偷拍",
                                         "限制级", "一本道", "爱情", "言情", "都市", "恐怖",
                                         "惊悚", "犯罪", "悬疑"]

    /// 心屋是否放行这个源分类（**正名单**：不命中＝不显示）。
    public static func isChildSafeCategory(_ name: String) -> Bool {
        if childCategoryDenyWords.contains(where: { name.contains($0) }) { return false }
        return childCategoryAllowWords.contains(where: { name.contains($0) })
    }

    /// 心屋分类过滤（源浏览页用）：只留正名单分类。
    public static func childSafeCategories(_ cats: [SiteCategory]) -> [SiteCategory] {
        cats.filter { isChildSafeCategory($0.name) }
    }

    public static let builtinVodSources: [TVBoxSite] = []

    // ⛔ 2026-09-26 红线修复（用户实测心屋出现成人内容）：上面列表原有 11 条成人 CMS 源
    //   （ac=list 全量机检 _probe_common_adult.py：分类含 强奸乱伦/三级/无码/人妻 等），
    //   已全部移出——成人内容从此在心屋/星幕物理不可见。
    //   apilsbzy 家族 5 条已移入 builtinAdultVodSources（仅成人端可见）；
    //   森林/玉兔/小鸡窝×2/豆豆/黑料 6 条与成人列表同域名重复，直接删除。

    /// 混合源（**三端共有**；内容按端闸门分派，见 `NavPolicy`）。
    ///
    /// 2026-09-22 用户钦定：「很多我想要的成人分类都在索倪源里，比如热舞写真、里番；
    /// 有关奈飞的、邵氏电影这两种是星幕的；还有伦理三级都有，但是是成人端的」。
    /// → 索倪是**全类目源**（实测 61 分类 / 14.5 万条：电影/电视剧/动漫/4K电影/邵氏电影/
    ///   Netflix电影/Netflix自制剧/儿童儿歌 + 成人 55-61 类），必须三端都能看见：
    ///   星幕取 电影/电视剧/动漫/4K/邵氏/Netflix；心屋取 动画片/儿童儿歌/科普；
    ///   成人端取 伦理/港台三级/韩国伦理/西方伦理/日本伦理/两性课堂/写真热舞。
    /// 隔离由 `NavPolicy.allowsCategory/isAdultCategory`（分类级）+ `NavPolicy.allowsItem`
    /// （条目级）双闸门保证——**成人分类永远不会出现在星幕/心屋**。
    /// 混合源（星幕 normal + 成人端可见；**心屋 child 永不出现**）。
    ///
    /// 2026-11-01 全量彻查后重排：以下 24 条为三级实测全通过者
    /// （ac=videolist 有片 → 详情有播放地址 → 播放地址 okhttp/Referer/浏览器 UA 实测 200）。
    /// 被替换掉的 34 条已确认真死（详见 builtinVodSources 注释），不再占位误导用户。
    /// 全部 44-60 分类且均含「伦理片」等成人分类，故只进混合区，由源池级隔离挡在心屋之外。
    public static let builtinMixedVodSources: [TVBoxSite] = [
        TVBoxSite(key: "builtin:harv:360zy-com-api-php-provide-vod", name: "360资源", api: "https://360zy.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:harv:360zy4-com-api-php-provide-vod", name: "360资源", api: "https://360zy4.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:360zy8-com-api-php-provide-vod", name: "360资源", api: "https://360zy8.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:360zy9-com-api-php-provide-vod", name: "360资源", api: "https://360zy9.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:360zy10-com-api-php-provide-vod", name: "360资源", api: "http://360zy10.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:www-wsyzy-cc-api-php-provide-vod", name: "无水印资源", api: "http://www.wsyzy.cc/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:api-wsyzy-net-api-php-provide-vod-ac-vid", name: "无水印资源", api: "https://api.wsyzy.net/api.php/provide/vod/?ac=videolist", type: 1),
        TVBoxSite(key: "builtin:harv:api-guangsuapi-com-api-php-provide-vod", name: "光速资源", api: "https://api.guangsuapi.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:api-xinlangapi-com-xinlangapi-php-provid", name: "新浪云播", api: "http://api.xinlangapi.com/xinlangapi.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:jszyapi-com-api-php-provide-vod", name: "极速资源", api: "https://jszyapi.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:harv:www-jszyapi-com-api-php-provide-vod", name: "极速资源", api: "https://www.jszyapi.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:api-maoyanapi-top-api-php-provide-vod", name: "猫眼资源", api: "https://api.maoyanapi.top/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:www-hongniuzy2-com-api-php-provide-vod", name: "红牛资源", api: "https://www.hongniuzy2.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:www-hongniuzy3-com-api-php-provide-vod", name: "红牛资源", api: "https://www.hongniuzy3.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:www-hongniuzy4-com-api-php-provide-vod", name: "红牛资源", api: "https://www.hongniuzy4.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:www-huyaapi-com-api-php-provide-vod-from", name: "虎牙采集", api: "https://www.huyaapi.com/api.php/provide/vod/from/hym3u8", type: 1),
        TVBoxSite(key: "builtin:harv:hhzyapi-com-api-php-provide-vod-ac-list", name: "豪华资源", api: "https://hhzyapi.com/api.php/provide/vod/?ac=list", type: 1),
        TVBoxSite(key: "builtin:harv:subocj-com-api-php-provide-vod-ac-videol", name: "速播资源", api: "https://subocj.com/api.php/provide/vod/?ac=videolist", type: 1),
        TVBoxSite(key: "builtin:harv:subocaiji-com-api-php-provide-vod", name: "速播资源", api: "https://subocaiji.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:jinyingzy-com-api-php-provide-vod", name: "金鹰资源", api: "https://jinyingzy.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:harv:www-jinyingzy-com-api-php-provide-vod", name: "金鹰资源", api: "https://www.jinyingzy.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:jyzyapi-com-provide-vod", name: "金鹰资源", api: "https://jyzyapi.com/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:caiji-maotaizy-cc-api-php-provide-vod-at", name: "茅台资源", api: "https://caiji.maotaizy.cc/api.php/provide/vod/at/josn/", type: 1),
        TVBoxSite(key: "builtin:harv:mtzy-me-api-php-provide-vod", name: "茅台资源", api: "https://mtzy.me/api.php/provide/vod/", type: 1),
    ]

    /// 成人内置点播源（2026-09-30 起星幕 normal / 成人端 adult 可见；心屋 child 物理不可见——儿童端红线）。
    /// 用户钦定 2026-09-22：「索倪源内置到点播源列表里」——原来是藏在「索倪精选·直连17站」
    /// 订阅仓里要点两层才看到，现直接铺进点播源列表顶层，点开即浏览/播放（不用再乱找）。
    /// 全部 2026-09-22 ac=list 实测可用（17/17），key 带 builtin: 前缀走删除墓碑可恢复机制。
    /// 注：索倪已上移到 `builtinMixedVodSources`（三端共有），此处不再重复。
    public static let builtinAdultVodSources: [TVBoxSite] = []

    /// 点播源分区（2026-09-26 用户钦定：「列表里没有分成人区和普通区，看不明白哪些是电影的哪些是成人的」）。
    /// 每个站点按所属内置数组归区；自定义源单独一区。2026-09-30 起成人区星幕/成人端出现，心屋永不出现。
    public enum VodZone: String, CaseIterable {
        case film = "影视"
        case mixed = "混合（影视+成人分类）"
        case custom = "自定义"
        case adult = "成人"
    }

    /// 站点 → 分区。按 key 精确判定（同域名可能既在影视也在成人列表，key 才是唯一身份）：
    /// 混合 → 成人 → 内置影视 → 自定义。
    public static func vodZone(of site: TVBoxSite) -> VodZone {
        if builtinMixedVodSources.contains(where: { $0.key == site.key }) { return .mixed }
        if builtinAdultVodSources.contains(where: { $0.key == site.key }) { return .adult }
        if site.key.hasPrefix("builtin:") { return .film }
        return .custom
    }

    /// 按产品模式返回内置点播源：
    /// - 三端共有 = 通用影视源 + **混合源（索倪）**；
    /// - adult（成人端）额外挂成人专用源；
    /// - 内容隔离硬门禁：**成人专用源**绝不出现在星幕/心屋；
    ///   混合源里的成人分类靠 `NavPolicy` 在浏览层拦掉（星幕/心屋看不到伦理/三级/写真热舞）。
    public static func builtinVodSources(forMode mode: String) -> [TVBoxSite] {
        // 2026-10-01 用户钦定改口径（比运行时闸门更彻底的**源池级隔离**）：
        // 「心屋不内置任何带成人内容的源，把它们从心屋源池删掉」。
        // 索倪（builtinMixedVodSources）实测 61 分类里 55+ 类是成人，靠 NavPolicy 在浏览层拦
        // 永远拦不干净（2026-10-01 真机：心屋索倪页仍出现爱情片/都市言情短剧）；
        // 故心屋**源池里就没有它** —— 不靠闸门、不留擦边。
        if mode == "child" {
            // 心屋 = 儿童专用源池（2026-11-01 建立，见 builtinChildVodSources 注释）。
            // 源本身是活源（含成人分类是全行业通病），心屋靠**分类正名单 + 禁全库流**
            // 保证成人分类在儿童端物理不可见（比黑名单可靠：漏词只会少内容，不会漏脏内容）。
            return builtinChildVodSources
        }
        let common = builtinVodSources + builtinMixedVodSources
        // 2026-09-30 用户钦定：星幕（normal）也挂成人源（「星幕可以有，不止成人端；心屋不行」）。
        return common
    }

    /// 分类级黑名单（违禁/成人类目 + 非剧类垃圾类目不放行）。
    /// 注：短剧/剧场**允许**（用户拍板：可以有，但要独立分类不混流）——
    /// 隔离靠「默认锁定连续剧、永不无分类请求」实现（见 preferredCategory）。
    static let bannedCategoryWords = ["伦理", "三级", "情色", "成人", "色情", "写真", "福利",
                                      "体育", "球赛", "足球", "篮球",
                                      "赛事", "综艺", "动漫", "动画", "真人秀"]

    /// 条目级黑名单（标题/分类命中即剔除；包含分类级全部词）
    static let bannedItemWords = bannedCategoryWords + ["erotic", "18+", "R级"]

    /// 电视剧模块分类过滤（按量子源真实分类表校准 2026-09-20）：
    /// ✅ 连续剧/国产剧/香港剧/韩国剧/欧美剧/台湾剧/日本剧/海外剧/泰国剧/短剧
    /// ❌ 喜剧片/剧情片（含剧字的电影类！）、AI漫剧、体育/球赛/综艺/伦理片等
    /// 规则：必须含「剧」且不以「片」结尾且不含「漫剧」且不在黑名单。
    public static func isAllowedCategory(_ name: String) -> Bool {
        guard name.contains("剧"),
              !name.hasSuffix("片"),
              !name.contains("漫剧"),
              !bannedCategoryWords.contains(where: { name.contains($0) })
        else { return false }
        return true
    }

    /// 默认选中分类：优先「连续剧」（正统电视剧大库），否则第一个合法剧类。
    /// 绝不默认「全部」——CMS 不带分类参数时返回全库混合流（球赛/短剧都混在里面）。
    public static func preferredCategory(in categories: [SiteCategory]) -> SiteCategory? {
        categories.first(where: { $0.name.contains("连续") })
            ?? categories.first(where: { $0.name.contains("国产") })
            ?? categories.first
    }

    /// 短剧类（短剧/AI漫剧/反转爽剧）：允许存在但不混入「全部剧集」聚合池（用户钦定 2026-09-20）。
    public static func isShortDramaCategory(_ name: String) -> Bool {
        name.contains("短剧") || name.contains("漫剧") || name.contains("爽剧")
    }

    /// 内置直播源（2026-09-20 并发实测存活，jsDelivr CDN 直链不依赖单点；按存活频道数排序）。
    /// 用途：默认订阅源失败时多源容灾 + 直播页「直播源」切换入口（TVBox 原版语义）。
    ///
    /// 2026-09-23 复审 + 扩容：用户「再全网找找能内置的源……直播的」。
    /// 线上 5 条复审 = 4 活 1 待换（`盒子聚合直播` 仍为我们自己仓的 TVBox txt，813 行央视/卫视，正常）。
    /// 全网 7 个新候选实测 = 新增 3 条真活且频道数大的（jsDelivr 直链优先，手机端可达性最好）：
    ///   zbds 530 频道 / BigBigGrandG 1956 频道 / YueChan 96 频道；
    ///   另 4 条 404 剔除（tvbox-live、yaoxieyoulei、fanmingming 路径已变更）。
    public static let builtinLiveSources: [TVBoxLiveGroup] = [
        TVBoxLiveGroup(name: "聚合精选源",
                       m3uURLs: ["https://cdn.jsdelivr.net/gh/vbskycn/iptv@master/tv/iptv4.m3u"]),
        TVBoxLiveGroup(name: "每日更新源",
                       m3uURLs: ["https://cdn.jsdelivr.net/gh/suxuang/myIPTV@main/ipv4.m3u"]),
        TVBoxLiveGroup(name: "YanG 聚合源",
                       m3uURLs: ["https://cdn.jsdelivr.net/gh/YanG-1989/m3u@main/Gather.m3u"]),
        TVBoxLiveGroup(name: "咪咕精选源",
                       m3uURLs: ["https://cdn.jsdelivr.net/gh/YanG-1989/m3u@main/Migu.m3u"]),
        // 2026-09-23 新增（实测通道数）
        TVBoxLiveGroup(name: "全量聚合源(1956频道)",
                       m3uURLs: ["https://cdn.jsdelivr.net/gh/BigBigGrandG/IPTV-URL@release/Gather.m3u"]),
        TVBoxLiveGroup(name: "zbds 精选源(530频道)",
                       m3uURLs: ["https://live.zbds.org/tv/iptv4.m3u"]),
        TVBoxLiveGroup(name: "YueChan 精品源(96频道)",
                       m3uURLs: ["https://cdn.jsdelivr.net/gh/YueChan/Live@main/IPTV.m3u"]),
        // 盒子直播（2026-09-20 中兴盒子 TVBox 拆机 live_v2.txt，43 组央视/卫视/体育/少儿等，
        // TVBox txt 格式由 M3UParser 双格式统一解析；txt 托管在公开 feed 仓走 jsDelivr CDN）
        TVBoxLiveGroup(name: "盒子聚合直播",
                       m3uURLs: ["https://fastly.jsdelivr.net/gh/lidawei1985/filmcollector-pages-xingmu@main/live/box_live_v2.txt"]),
    ]

    /// 直播源产品隔离（2026-09-21 用户钦定）：成人端(adult)=仅官方成人直播
    /// （订阅源已在 /v1/live/adult.m3u，采集器维护），通用央视/卫视源严禁混入成人端；
    /// 心屋(child)无直播；星幕(normal)=通用公开源。
    public static func builtinLiveSources(forMode mode: String) -> [TVBoxLiveGroup] {
        switch mode {
        case "adult", "child": return []
        default: return builtinLiveSources
        }
    }

    // MARK: - 盒子内置线路仓（2026-09-20 中兴盒子 ZXV10B860AV5.2-M TVBox 配置审计产物）
    // 61 条去重线路逐一并发测活：影视组 26 条 + 成人组 14 条存活；盒子迷（纯中文域名编码失败）/小马（BADJSON）剔除。
    // 交互 = TVBox 配置历史同款：设置页点选生效；删除走 deletedBuiltinKeys 墓碑（可一键恢复）。
    // 产品隔离：影视组 → 星幕+成人端；成人组 → 仅成人端；心屋（child）= 空集，物理不可见。

    /// 影视线路组（星幕 + 成人端共用；URL 均为实测存活地址，中文段已百分号编码保证 URL(string:) 可用）。
    /// 首条 = 随包直连精选（bundle 内置零网络依赖；ghproxy/jsdelivr 等域名手机端常不可达，2026-09-21 用户实测「内置源都打不开」根因）。
    public static let builtinRepos: [TVBoxSubscription] = [
        TVBoxSubscription(name: "直连精选", url: "bundle:builtin_curated"),
        TVBoxSubscription(name: "心魔线路", url: "https://ghproxy.net/https://raw.githubusercontent.com/yw88075/tvbox/main/yw.json"),
        TVBoxSubscription(name: "业余打发", url: "https://ghproxy.net/https://raw.githubusercontent.com/yydfys/yydf/main/yydf/yydfjk.json"),
        TVBoxSubscription(name: "高天流云0707", url: "https://cdn.jsdelivr.net/gh/gaotianliuyun/gao@master/0707.json"),
        TVBoxSubscription(name: "宝盒PG", url: "http://ygbhbox.3vfree.club/pg/jsm.json"),
        TVBoxSubscription(name: "高天流云0821", url: "https://cdn.jsdelivr.net/gh/gaotianliuyun/gao@master/0821.json"),
        TVBoxSubscription(name: "菜妮丝", url: "https://play.iptv365.org/%E8%8F%9C%E5%A6%AE%E4%B8%9D/api.json"),
        TVBoxSubscription(name: "高天流云0825", url: "https://cdn.jsdelivr.net/gh/gaotianliuyun/gao@master/0825.json"),
        TVBoxSubscription(name: "高天流云0827", url: "https://cdn.jsdelivr.net/gh/gaotianliuyun/gao@master/0827.json"),
        TVBoxSubscription(name: "神仙线路", url: "http://xhztv.top/dc/%E7%A5%9E%E4%BB%99/api.json"),
        TVBoxSubscription(name: "OK杰克", url: "https://play.iptv365.org/OK/api.json"),
        TVBoxSubscription(name: "dxawi老牌", url: "https://dxawi.github.io/0/0.json"),
        TVBoxSubscription(name: "菜妮线路", url: "http://liucn.cc/box/dc/lns/lns.json"),
        TVBoxSubscription(name: "WZ南风3", url: "https://play.iptv365.org/%E5%8D%97%E9%A3%8E/api.json"),
        TVBoxSubscription(name: "WZ短剧频道", url: "http://box.ufuzi.com/tv/qq/%E7%9F%AD%E5%89%A7%E9%A2%91%E9%81%93/api.json"),
        TVBoxSubscription(name: "newwex", url: "https://9280.kstore.vip/newwex.json"),
        TVBoxSubscription(name: "俊哥98", url: "http://home.jundie.top:81/top98.json"),
        TVBoxSubscription(name: "动漫城", url: "https://www.yingm.cc/dm/dm.json"),
        TVBoxSubscription(name: "南风线路", url: "https://gitlab.com/noimank/tvbox/-/raw/main/tvbox1.json"),
        TVBoxSubscription(name: "小米线路", url: "https://play.iptv365.org/%E5%B0%8F%E7%B1%B3/api.json"),
        TVBoxSubscription(name: "挺好接口", url: "http://ztha.top/TVBox/thdjk.json"),
        TVBoxSubscription(name: "摸鱼线路", url: "https://play.iptv365.org/%E6%91%B8%E9%B1%BC%E5%84%BF/api.json"),
        TVBoxSubscription(name: "网盘4K", url: "https://gitlab.com/dokiss1/tvbox/-/raw/master/doki-Dx.json"),
        TVBoxSubscription(name: "肥猫线路", url: "https://play.iptv365.org/%E8%82%A5%E7%8C%AB/api.json"),
        TVBoxSubscription(name: "软件哥哥", url: "http://47.96.82.41:8/api.json"),
        TVBoxSubscription(name: "高天流云", url: "https://cdn.jsdelivr.net/gh/gaotianliuyun/gao@master/js.json"),
        TVBoxSubscription(name: "高天流云0826", url: "https://cdn.jsdelivr.net/gh/gaotianliuyun/gao@master/0826.json"),
    ]


    /// 按产品模式返回内置线路：child = 空（心屋零线路）；其余 = 影视组。
    /// 2026-10-05：第三端（成人流 App）彻底下线 → 原「成人线路组」整组删除。
    public static func builtinRepos(forMode mode: String) -> [TVBoxSubscription] {
        switch mode {
        case "child": return []
        default: return builtinRepos
        }
    }

    /// 条目级过滤：标题或分类名命中黑名单即剔除。
    public static func isAllowedItem(title: String, typeName: String?) -> Bool {
        let bag = title + (typeName ?? "")
        return !bannedItemWords.contains(where: { bag.localizedLowercase.contains($0.localizedLowercase) })
    }
}
