import Foundation

/// 星幕电视剧独立通道（2026-09-20 新增，公网承载，零本地依赖）：
/// - 采集端 feed 是纯电影库（70096 条全 movie_*），电视剧由本模块独立供给；
/// - 协议 = MacCMS10 标准 JSON（TVBox 点播源同款 ac= 端点），纯公网 HTTPS；
/// - 多源自动容灾：源挂自动切下一个（量子→天涯→非凡→卧龙），无人值守；
/// - 违禁内容双层硬过滤：分类级只放行「剧」类，条目级再过黑名单关键词。
public enum DefaultSites {

    /// 公网 CMS 源（2026-09-20 实测存活顺序）
    public static let tvDramaSources: [TVBoxSite] = [
        TVBoxSite(key: "liangzi", name: "量子资源", api: "https://cj.lziapi.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "tianya",  name: "天涯资源", api: "https://tyyszy.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "feifan",  name: "非凡资源", api: "https://cj.ffzyapi.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "wolong",  name: "卧龙资源", api: "https://collect.wolongzyw.com/api.php/provide/vod", type: 1),
    ]

    /// 内置点播源（TVBox sites 域，用户钦定：实测能用的内置进去、但可删除）。
    /// 2026-09-20 实测 20 候选存活 8：并发 ac=list 校验分类+条目，ac=detail 校验播放地址真实。
    /// key 统一 "builtin:" 前缀 —— 删除走 deletedBuiltinKeys 持久化，可一键恢复。
    public static let builtinVodSources: [TVBoxSite] = [
        TVBoxSite(key: "builtin:baofeng", name: "暴风资源", api: "https://bfzyapi.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:liangzi", name: "量子资源", api: "http://cj.lziapi.com/api.php/provide/vod/at/xml", type: 1),
        TVBoxSite(key: "builtin:wujin",   name: "无尽资源", api: "https://api.wujinapi.me/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:zuida",   name: "最大资源", api: "https://api.zuidapi.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:jinying", name: "金鹰资源", api: "https://jinyingzy.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:tianya",  name: "天涯资源", api: "https://tyyszy.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:360",     name: "360资源", api: "https://360zy.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:feifan",  name: "非凡资源", api: "https://cj.ffzyapi.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:harv:360zy-net-api-php-provide-vod", name: "360zy.net", api: "http://360zy.net/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:360zy10-com-api-php-provide-vod", name: "360zy10.com", api: "http://360zy10.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:360zy4-com-api-php-provide-vod", name: "360zy4.com", api: "http://360zy4.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:360zy6-com-api-php-provide-vod", name: "360zy6.com", api: "http://360zy6.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:360zy7-com-api-php-provide-vod", name: "360zy7.com", api: "http://360zy7.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:360zy8-com-api-php-provide-vod", name: "360zy8.com", api: "http://360zy8.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:360zy9-com-api-php-provide-vod", name: "360zy9.com", api: "https://360zy9.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:360zy-com-api-php-provide-vod-ac-videoli", name: "360资源", api: "https://360zy.com/api.php/provide/vod/?ac=videolist", type: 1),
        TVBoxSite(key: "builtin:harv:api-okzyw-net-api-php-provide-vod-ac-vid", name: "OK资源", api: "http://api.okzyw.net/api.php/provide/vod/?ac=videolist", type: 1),
        TVBoxSite(key: "builtin:harv:okzyw-net-api-php-provide-vod-from-okm3u", name: "OK资源 2", api: "http://okzyw.net/api.php/provide/vod/from/okm3u8/at/xml", type: 1),
        TVBoxSite(key: "builtin:harv:okzyw-cc-api-php-provide-vod-from-okm3u8", name: "OK资源 3", api: "http://okzyw.cc/api.php/provide/vod/from/okm3u8/at/xml", type: 1),
        TVBoxSite(key: "builtin:harv:api-ukuapi88-com-api-php-provide-vod-ac-", name: "U酷资源", api: "https://api.ukuapi88.com/api.php/provide/vod/?ac=list", type: 1),
        TVBoxSite(key: "builtin:harv:apilsbzy-com-api-php-provide-vod", name: "apilsbzy", api: "https://apilsbzy.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:tyyszy2-com-api-php-provide-vod", name: "tyyszy2", api: "http://tyyszy2.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:harv:tyyszy3-com-api-php-provide-vod", name: "tyyszy3", api: "http://tyyszy3.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:harv:www-wsyzy-cc-api-php-provide-vod", name: "www.wsyzy.cc", api: "http://www.wsyzy.cc/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:beiyong-slapibf-com-api-php-provide-vod-", name: "♥️森林采集", api: "https://beiyong.slapibf.com/api.php/provide/vod/?ac=list", type: 1),
        TVBoxSite(key: "builtin:harv:apiyutu-com-api-php-provide-vod", name: "♥️玉兔采集", api: "https://apiyutu.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:api-xinlangapi-com-xinlangapi-php-provid", name: "♻️新浪.云播", api: "http://api.xinlangapi.com/xinlangapi.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:suoniapi-com-api-php-provide-vod-ac-list", name: "♻️索尼资源", api: "https://suoniapi.com/api.php/provide/vod/?ac=list", type: 1),
        TVBoxSite(key: "builtin:harv:sdzyapi-com-api-php-provide-vod", name: "♻️闪电.云播", api: "http://sdzyapi.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:bfzyapi-com-api-php-provide-vod-ac-list", name: "❤暴风资源", api: "https://bfzyapi.com/api.php/provide/vod/?ac=list", type: 1),
        TVBoxSite(key: "builtin:harv:api-apibdzy-com-api-php-provide-vod-ac-l", name: "❤百度", api: "https://api.apibdzy.com/api.php/provide/vod/?ac=list", type: 1),
        TVBoxSite(key: "builtin:harv:www-hongniuzy2-com-api-php-provide-vod", name: "❤红牛资源", api: "https://www.hongniuzy2.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:www-hongniuzy4-com-api-php-provide-vod", name: "❤红牛资源 2", api: "https://www.hongniuzy4.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:cj-yayazy-net-api-php-provide-vod", name: "丫丫资源", api: "https://cj.yayazy.net/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:api-guangsuapi-com-api-php-provide-vod", name: "光速资源(切)", api: "https://api.guangsuapi.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:tyyszyapi-com-api-php-provide-vod-ac-vid", name: "天涯资源", api: "https://tyyszyapi.com/api.php/provide/vod/?ac=videolist", type: 1),
        TVBoxSite(key: "builtin:harv:api-xiaojizy-live-provide-vod", name: "小鸡窝", api: "https://api.xiaojizy.live/provide/vod", type: 1),
        TVBoxSite(key: "builtin:harv:xiaojizy-live-provide-vod", name: "小鸡窝 2", api: "https://xiaojizy.live/provide/vod", type: 1),
        TVBoxSite(key: "builtin:harv:hhzyapi-com-api-php-provide-vod-ac-list", name: "影视 | 豪华资源", api: "https://hhzyapi.com/api.php/provide/vod/?ac=list", type: 1),
        TVBoxSite(key: "builtin:harv:ffzy-tv-api-php-provide-vod", name: "影视 | 非凡[直连]", api: "http://ffzy.tv/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:api-wujinapi-net-api-php-provide-vod", name: "无尽 | 采集", api: "https://api.wujinapi.net/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:api-wsyzy-net-api-php-provide-vod-ac-vid", name: "无水印资源", api: "https://api.wsyzy.net/api.php/provide/vod/?ac=videolist", type: 1),
        TVBoxSite(key: "builtin:harv:jszyapi-com-api-php-provide-vod", name: "极速资源", api: "https://jszyapi.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:harv:api-maoyanapi-top-api-php-provide-vod", name: "猫眼资源", api: "https://api.maoyanapi.top/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:www-hongniuzy3-com-api-php-provide-vod", name: "红牛资源3", api: "https://www.hongniuzy3.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:apilsbzy1-com-api-php-provide-vod", name: "老牛资源", api: "https://apilsbzy1.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:apilsbzy3-com-api-php-provide-vod", name: "老牛资源 2", api: "https://apilsbzy3.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:apilsbzy2-com-api-php-provide-vod", name: "老牛资源 3", api: "https://apilsbzy2.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:apilsbzy4-com-api-php-provide-vod", name: "老牛资源 4", api: "https://apilsbzy4.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:mtzy-me-api-php-provide-vod", name: "茅台 | 采集", api: "https://mtzy.me/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:caiji-maotaizy-cc-api-php-provide-vod-at", name: "茅台资源", api: "https://caiji.maotaizy.cc/api.php/provide/vod/at/josn/", type: 1),
        TVBoxSite(key: "builtin:harv:caiji-dbzy5-com-api-php-provide-vod-at-j", name: "豆瓣资源", api: "https://caiji.dbzy5.com/api.php/provide/vod/at/josn/", type: 1),
        TVBoxSite(key: "builtin:harv:api-douapi-cc-api-php-provide-vod-ac-lis", name: "豆豆", api: "https://api.douapi.cc/api.php/provide/vod/?ac=list", type: 1),
        TVBoxSite(key: "builtin:harv:subocaiji-com-api-php-provide-vod", name: "速播 | 采集", api: "https://subocaiji.com/api.php/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:subocj-com-api-php-provide-vod-ac-videol", name: "速播资源", api: "https://subocj.com/api.php/provide/vod/?ac=videolist", type: 1),
        TVBoxSite(key: "builtin:harv:jyzyapi-com-provide-vod", name: "金鹰资源", api: "https://jyzyapi.com/provide/vod/", type: 1),
        TVBoxSite(key: "builtin:harv:api-ffzyapi-com-api-php-provide-vod", name: "非凡资源", api: "https://api.ffzyapi.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:harv:heiliaozyapi-com-api-php-provide-vod", name: "黑料", api: "https://heiliaozyapi.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:harv:caiji-dyttzyapi-com-api-php-provide-vod-", name: "🎞️天堂┃采集", api: "http://caiji.dyttzyapi.com/api.php/provide/vod/from/dyttm3u8/at/m3u8/", type: 1),
        TVBoxSite(key: "builtin:harv:www-huyaapi-com-api-php-provide-vod-from", name: "🐯虎牙采集", api: "https://www.huyaapi.com/api.php/provide/vod/from/hym3u8", type: 1),
    ]

    /// 混合源（**三端共有**；内容按端闸门分派，见 `NavPolicy`）。
    ///
    /// 2026-09-22 用户钦定：「很多我想要的成人分类都在索倪源里，比如热舞写真、里番；
    /// 有关奈飞的、邵氏电影这两种是星幕的；还有伦理三级都有，但是是夜航的」。
    /// → 索倪是**全类目源**（实测 61 分类 / 14.5 万条：电影/电视剧/动漫/4K电影/邵氏电影/
    ///   Netflix电影/Netflix自制剧/儿童儿歌 + 成人 55-61 类），必须三端都能看见：
    ///   星幕取 电影/电视剧/动漫/4K/邵氏/Netflix；心屋取 动画片/儿童儿歌/科普；
    ///   夜航取 伦理/港台三级/韩国伦理/西方伦理/日本伦理/两性课堂/写真热舞。
    /// 隔离由 `NavPolicy.allowsCategory/isAdultCategory`（分类级）+ `NavPolicy.allowsItem`
    /// （条目级）双闸门保证——**成人分类永远不会出现在星幕/心屋**。
    public static let builtinMixedVodSources: [TVBoxSite] = [
        TVBoxSite(key: "builtin:suoni", name: "索倪", api: "https://suoniapi.com/api.php/provide/vod", type: 1),
    ]

    /// 成人内置点播源（仅夜航 adult 可见；星幕 normal / 心屋 child 物理不可见——内容隔离红线）。
    /// 用户钦定 2026-09-22：「索倪源内置到点播源列表里」——原来是藏在「索倪精选·直连17站」
    /// 订阅仓里要点两层才看到，现直接铺进点播源列表顶层，点开即浏览/播放（不用再乱找）。
    /// 全部 2026-09-22 ac=list 实测可用（17/17），key 带 builtin: 前缀走删除墓碑可恢复机制。
    /// 注：索倪已上移到 `builtinMixedVodSources`（三端共有），此处不再重复。
    public static let builtinAdultVodSources: [TVBoxSite] = [
        TVBoxSite(key: "builtin:lb9",      name: "乐播资源",   api: "https://lbapi9.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:yutu",     name: "玉兔采集",   api: "https://apiyutu.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:doudou",   name: "豆豆资源",   api: "https://api.douapi.cc/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:heiliao",  name: "黑料资源",   api: "https://heiliaozyapi.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:danaizi",  name: "大奶子资源", api: "https://apidanaizi.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:xiaojizy", name: "小鸡窝资源", api: "https://api.xiaojizy.live/provide/vod", type: 1),
        TVBoxSite(key: "builtin:senlin",   name: "森林采集",   api: "https://beiyong.slapibf.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:yb155",    name: "155资源",    api: "https://155api.com/api.php/provide/vod", type: 1),
        TVBoxSite(key: "builtin:huyals",   name: "虎牙资源",   api: "https://www.huyaapi.com/api.php/provide/vod/at/json", type: 1),
        TVBoxSite(key: "builtin:ls2",      name: "老司机2",    api: "https://www.msnii.com/api/json.php", type: 0),
        TVBoxSite(key: "builtin:ls3",      name: "老司机3",    api: "https://www.xrbsp.com/api/json.php", type: 0),
        TVBoxSite(key: "builtin:ls5",      name: "老司机5",    api: "http://www.gdlsp.com/api/json.php", type: 0),
        TVBoxSite(key: "builtin:ls10",     name: "老司机10",   api: "http://www.kxgav.com/api/json.php", type: 0),
        TVBoxSite(key: "builtin:ls11",     name: "老司机11",   api: "http://fhapi9.com/api.php/provide/vod/", type: 0),
        TVBoxSite(key: "builtin:huangA",   name: "黄A资源",    api: "https://www.pgxdy.com/api/json.php", type: 0),
        // 以下 17 条 = 用户钦定「找到合并去重」产物（2026-09-22）：
        // 来源 lidawei1985/tvbox2 仓内 15 个成人配置（18+.txt / 二哈18+ / 巧计18+ / 成人路线 / 老马18+ 等）
        // → 正则容错提取 210 个 type0/1 源 → 域名去重 → ac=list 实测存活 39 → 再排除与上面重复的站点
        // → 净新增 17 条。合并脚本：F:\IOS3APP\ios_ctrl\merge_adult_sources.py
        TVBoxSite(key: "builtin:adult:api-apibdzy-com", name: "APIBDZY",       api: "https://api.apibdzy.com/api.php/provide/vod?ac=list", type: 1),
        TVBoxSite(key: "builtin:adult:api-ddapi-cc",    name: "滴滴资源",      api: "https://api.ddapi.cc/api.php/provide/vod/", type: 0),
        TVBoxSite(key: "builtin:adult:harv:apidanaizi-com-api-php-provide-vod-ac-li", name: "大奶子", api: "https://apidanaizi.com/api.php/provide/vod/?ac=list", type: 1),
        TVBoxSite(key: "builtin:adult:harv:www-mdzyapi-com-api-php-provide-vod-ac-v", name: "魔都资源", api: "https://www.mdzyapi.com/api.php/provide/vod/?ac=videolist", type: 1),
        TVBoxSite(key: "builtin:adult:harv:www-pgxdy-com-api-json-php", name: "黄AV", api: "https://www.pgxdy.com/api/json.php", type: 1),
        TVBoxSite(key: "builtin:adult:harv:fhapi9-com-api-php-provide-vod", name: "💞番号资源💞", api: "http://fhapi9.com/api.php/provide/vod/", type: 1),
    ]

    /// 按产品模式返回内置点播源：
    /// - 三端共有 = 通用影视源 + **混合源（索倪）**；
    /// - adult（夜航）额外挂成人专用源；
    /// - 内容隔离硬门禁：**成人专用源**绝不出现在星幕/心屋；
    ///   混合源里的成人分类靠 `NavPolicy` 在浏览层拦掉（星幕/心屋看不到伦理/三级/写真热舞）。
    public static func builtinVodSources(forMode mode: String) -> [TVBoxSite] {
        let common = builtinVodSources + builtinMixedVodSources
        return mode == "adult" ? common + builtinAdultVodSources : common
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

    /// 直播源产品隔离（2026-09-21 用户钦定）：夜航(adult)=仅官方成人直播
    /// （订阅源已在 /v1/live/adult.m3u，采集器维护），通用央视/卫视源严禁混入夜航；
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
    // 产品隔离：影视组 → 星幕+夜航；成人组 → 仅夜航；心屋（child）= 空集，物理不可见。

    /// 影视线路组（星幕 + 夜航共用；URL 均为实测存活地址，中文段已百分号编码保证 URL(string:) 可用）。
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

    /// 成人线路组（仅夜航 adult 模式可见；星幕 normal / 心屋 child 严禁出现）。
    /// 首条 = 索倪领衔随包直连精选（用户钦定 2026-09-21；全 type0/1 免引擎，bundle 零网络依赖）。
    public static let builtinAdultRepos: [TVBoxSubscription] = [
        TVBoxSubscription(name: "索倪精选", url: "bundle:builtin_adult_curated"),
        TVBoxSubscription(name: "fanfu0", url: "https://ghproxy.net/https://raw.githubusercontent.com/fanfu0/mov/main/json/mov.json"),
        TVBoxSubscription(name: "bluefriend", url: "https://ghproxy.net/https://raw.githubusercontent.com/bluefriendCN/set/main/ma.json"),
        TVBoxSubscription(name: "zyscdx9", url: "https://ghproxy.net/https://raw.githubusercontent.com/zyscdx/tvbox/main/9.txt"),
        TVBoxSubscription(name: "tjyu010", url: "https://ghproxy.net/https://raw.githubusercontent.com/tjyu010/tvbox/main/cr1.json"),
        TVBoxSubscription(name: "zeee-u", url: "https://ghproxy.net/https://raw.githubusercontent.com/zeee-u/lzh06/main/video.json"),
        TVBoxSubscription(name: "扛把子线路", url: "https://ghproxy.net/https://raw.githubusercontent.com/felixiao/TVBoxSource/main/18/%E6%89%9B%E6%8A%8A%E5%AD%90%E7%BA%BF%E8%B7%AF.json"),
        TVBoxSubscription(name: "wanjune3721", url: "https://ghproxy.net/https://raw.githubusercontent.com/wanjune/wanjune.github.io/main/static/tvbox/3721.json"),
        TVBoxSubscription(name: "zyscdx3", url: "https://ghproxy.net/https://raw.githubusercontent.com/zyscdx/tvbox/main/3.txt"),
        TVBoxSubscription(name: "fhqeeqzp", url: "https://ghproxy.net/https://raw.githubusercontent.com/fhqeeqzp/tvbox/main/1111.json"),
        TVBoxSubscription(name: "Supprise0901", url: "https://ghproxy.net/https://raw.githubusercontent.com/Supprise0901/Fetch/main/single_lines/adult18.json"),
        TVBoxSubscription(name: "浮力yyfxz1", url: "https://ghproxy.net/https://raw.githubusercontent.com/yotudo/tvbox/main/TVBoxSource-main/18/%E6%B5%AE%E5%8A%9Byyfxz1.json"),
        TVBoxSubscription(name: "小武哥", url: "https://ghproxy.net/https://raw.githubusercontent.com/wwb521/live/main/video.json"),
        TVBoxSubscription(name: "娱乐影院05", url: "https://ghproxy.net/https://raw.githubusercontent.com/guxiangbin/tvbox2/main/%E5%A8%B1%E4%B9%90%E5%BD%B1%E9%99%A205.txt"),
    ]

    /// 按产品模式返回可用内置线路：adult = 影视+成人；child = 空（心屋零线路）；其余 = 影视组。
    public static func builtinRepos(forMode mode: String) -> [TVBoxSubscription] {
        switch mode {
        case "adult": return builtinRepos + builtinAdultRepos
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
