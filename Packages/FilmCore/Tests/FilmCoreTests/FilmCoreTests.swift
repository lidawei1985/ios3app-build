import XCTest
@testable import FilmCore

/// 生产 feed 契约解码 + 适配器隔离/去重/台账 + 检索 + M3U + 产品身份。
/// 夹具 = 真实生产数据样本（build 时从 xinwu p0.json 抽样生成），非假数据。
final class FilmCoreTests: XCTestCase {

    private func loadFixture() throws -> FeedPart {
        let bundle = Bundle(for: FilmCoreTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "part_sample", withExtension: "json",
                                           subdirectory: "Fixtures"))
        return try FilmJSON.decoder().decode(FeedPart.self, from: try Data(contentsOf: url))
    }

    // MARK: 契约解码

    func testFeedItemDecodingRealContract() throws {
        let part = try loadFixture()
        XCTAssertTrue(part.ok)
        XCTAssertEqual(part.mode, "child")
        XCTAssertEqual(part.items.count, 9)
        let first = try XCTUnwrap(part.items.first)
        XCTAssertFalse(first.title.isEmpty)
        XCTAssertNotNil(first.play)
        XCTAssertEqual(first.play?.lines?.first?.url.contains("http"), true)
    }

    func testManifestDecoding() throws {
        let json = """
        {"ok":true,"mode":"normal","version":"2026-09-18T01:19:06+08:00","count":69603,
         "part_size":500,"parts":["p0.json","p1.json"]}
        """.data(using: .utf8)!
        let m = try FilmJSON.decoder().decode(FeedManifest.self, from: json)
        XCTAssertEqual(m.count, 69603)
        XCTAssertEqual(m.partSize, 500)
        XCTAssertEqual(m.parts.count, 2)
    }

    // MARK: 隔离安全网（产品内容边界）

    func testIsolationAdultRejectedInNormalAndChild() throws {
        let part = try loadFixture()
        let (catalog, ledger) = FeedAdapter.buildCatalog(
            items: part.items, mode: "child", manifestCount: 100, homeCount: 0, version: nil)
        // ISOLATION_TEST_ADULT 必须被 child 端拦截
        XCTAssertFalse(catalog.items.contains { $0.title == "ISOLATION_TEST_ADULT" })
        XCTAssertGreaterThan(ledger.isolationDroppedCount, 0)
        XCTAssertNotNil(ledger.isolationReasons["adult_in_child"])
        // normal 端同样拦截
        let (cat2, _) = FeedAdapter.buildCatalog(
            items: part.items, mode: "normal", manifestCount: 100, homeCount: 0, version: nil)
        XCTAssertFalse(cat2.items.contains { $0.title == "ISOLATION_TEST_ADULT" })
        // adult 端不复判（feed 已是成人池），不扩大也不缩小
        let (_, led3) = FeedAdapter.buildCatalog(
            items: part.items, mode: "adult", manifestCount: 100, homeCount: 0, version: nil)
        XCTAssertEqual(led3.isolationDroppedCount, 0)
    }

    // MARK: 去重 + 数据保留策略

    func testDedupeAndDataRetention() throws {
        let part = try loadFixture()
        let (catalog, ledger) = FeedAdapter.buildCatalog(
            items: part.items, mode: "child", manifestCount: 100, homeCount: 0, version: nil)
        let ids = catalog.items.map(\.dedupId)
        XCTAssertEqual(ids.count, Set(ids).count, "入库目录不允许重复 ID")
        XCTAssertGreaterThanOrEqual(ledger.duplicateIDCount, 1, "夹具含 1 条重复")
        // 无播放源条目：保留 + 记账（禁止因播放源缺失删数据）
        XCTAssertTrue(catalog.items.contains { $0.dedupId == "noplay_001" })
        XCTAssertGreaterThanOrEqual(ledger.noPlayURLCount, 1)
    }

    // MARK: 台账（防缩水）

    func testLedgerShrinkDetection() {
        var led = DataLedger()
        led.sourceCount = 69603
        led.catalogCount = 60000
        XCTAssertFalse(led.shrinkDetected, ">=80% 不算缩水")
        led.catalogCount = 50000
        XCTAssertTrue(led.shrinkDetected, "<80% 必须触发缩水预警")
    }

    // MARK: 检索

    func testSearchPrefixAndPeople() {
        let a = makeItem(title: "流浪地球2", actors: ["吴京"])
        let b = makeItem(title: "满江红", actors: ["沈腾"])
        let r = FeedAdapter.search([a, b], query: "流浪")
        XCTAssertEqual(r.first?.title, "流浪地球2")
        let r2 = FeedAdapter.search([a, b], query: "吴京")
        XCTAssertEqual(r2.first?.title, "流浪地球2")
        XCTAssertTrue(FeedAdapter.search([a, b], query: "不存在关键词xyz").isEmpty)
    }

    /// 拼音检索（2026-09-22 检索升级）：首字母 / 全拼 / 演员拼音首字母 + 命中来源标注。
    func testPinyinSearchInitialsAndPeople() {
        let a = makeItem(title: "流浪地球2", actors: ["吴京"])
        let b = makeItem(title: "满江红", actors: ["沈腾", "李丽珍"])

        XCTAssertEqual(FeedAdapter.search([a, b], query: "lldq").first?.title, "流浪地球2", "首字母 ll dq")
        XCTAssertEqual(FeedAdapter.search([a, b], query: "liulang").first?.title, "流浪地球2", "全拼前缀")
        XCTAssertEqual(FeedAdapter.search([a, b], query: "wujing").first?.title, "流浪地球2", "演员全拼")
        XCTAssertEqual(FeedAdapter.search([a, b], query: "llz").first?.title, "满江红", "演员拼音首字母（大牌做法）")

        let hits = FeedAdapter.searchHits([a, b], query: "llz")
        XCTAssertEqual(hits.first?.matchedPerson, "李丽珍")
        XCTAssertEqual(hits.first?.matchedRole, "演员")
    }

    /// ü 双通道：吕 → lu（常规）与 lv（大牌允许用户这样敲）。
    func testPinyinUmlautVChannel() {
        let k = PinyinIndex.key(for: "吕梁英雄传")
        XCTAssertTrue(k.full.hasPrefix("lu"), "保留 u 通道，实际=\(k.full)")
        XCTAssertTrue(k.fullV.hasPrefix("lv"), "必须支持 v 通道，实际=\(k.fullV)")
        XCTAssertEqual(String(k.initials.prefix(1)), "l")
    }

    // MARK: 播放地址候选

    func testPlayCandidatesOrder() throws {
        let json = """
        {"dedup_id":"p1","title":"t","play":{"lines":[
          {"name":"a","url":"https://x/1.m3u8","quality":""},
          {"name":"b","url":"https://x/2.mp4","quality":""}],
          "default_line":"","default_url":"https://x/1.m3u8"}}
        """.data(using: .utf8)!
        let item = try FilmJSON.decoder().decode(FeedItem.self, from: json)
        let urls = item.playCandidates.map(\.absoluteString)
        XCTAssertEqual(urls, ["https://x/1.m3u8", "https://x/2.mp4"], "默认线路优先，去重")
    }

    // MARK: M3U

    func testM3UParsing() {
        let m3u = """
        #EXTM3U
        #EXTINF:-1,CCTV-1 综合
        http://a.example/1.m3u8
        #EXTINF:-1,CCTV-6 电影
        http://a.example/6.m3u8
        http://a.example/1.m3u8
        """
        let chs = M3UParser.parse(m3u)
        XCTAssertEqual(chs.count, 2, "重复 URL 去重")
        XCTAssertEqual(chs[0].name, "CCTV-1 综合")
        XCTAssertEqual(chs[1].name, "CCTV-6 电影")
    }

    // MARK: 产品身份（三 App 独立性）

    func testProductProfilesIndependent() {
        let profiles = ProductProfile.all
        XCTAssertEqual(profiles.count, 3)
        XCTAssertEqual(Set(profiles.map(\.mode)).count, 3, "mode 必须互不相同")
        XCTAssertEqual(Set(profiles.map(\.feedRepo)).count, 3, "feed 仓库必须互不相同")
        XCTAssertEqual(profiles.map(\.appName), ["星幕", "心屋", "夜航"], "品牌名不得擅改")
        // 心屋无直播（生产现状）
        XCTAssertNil(ProductProfile.xinwu.liveM3UPath)
        XCTAssertNotNil(ProductProfile.xingmu.liveM3UPath)
        XCTAssertNotNil(ProductProfile.yehang.liveM3UPath)
    }

    // MARK: FeedBases 契约

    func testFeedBasesChain() {
        let bases = FeedBases(profile: .xingmu)
        XCTAssertEqual(bases.bases.count, 2)
        XCTAssertTrue(bases.bases[0].contains("filmcollector-pages-xingmu"))
        XCTAssertTrue(bases.bases[1].contains("raw.githubusercontent.com"))
        let urls = bases.url(for: "/v1/feed/normal/manifest.json")
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[0].absoluteString.hasSuffix("/v1/feed/normal/manifest.json"))
    }

    // MARK: 隔离拒绝函数直测

    func testIsolationRejectFunction() {
        let adult = makeItem(title: "x", isAdult: true)
        XCTAssertNotNil(FeedAdapter.isolationReject(adult, mode: "normal"))
        XCTAssertNotNil(FeedAdapter.isolationReject(adult, mode: "child"))
        XCTAssertNil(FeedAdapter.isolationReject(adult, mode: "adult"))
        let normal = makeItem(title: "y", isAdult: false)
        XCTAssertNil(FeedAdapter.isolationReject(normal, mode: "child"))
    }

    /// 隔离词表护栏（2026-09-22 用户红线：三级/伦理/里番只能给夜航；心屋必须适合儿童）。
    func testIsolationKeywordGuard() {
        // 星幕池实测漏入的「情色」类条目（且未打 is_adult）→ 必须挡
        let qingse = makeItem(title: "引郎入室", sourceCategory: "情色")
        XCTAssertNotNil(FeedAdapter.isolationReject(qingse, mode: "normal"))
        XCTAssertNotNil(FeedAdapter.isolationReject(qingse, mode: "child"))
        // 夜航本来就是成人池 → 放行
        XCTAssertNil(FeedAdapter.isolationReject(qingse, mode: "adult"))

        // 心屋：儿童不宜分类（成人词不命中，靠 kid 词表拦）
        let kidBad = makeItem(title: "迷雾镇", sourceCategory: "悬疑")
        XCTAssertNotNil(FeedAdapter.isolationReject(kidBad, mode: "child"))
        // 星幕：普通悬疑片不该被误杀
        XCTAssertNil(FeedAdapter.isolationReject(kidBad, mode: "normal"))

        // 正常动画片：星幕/心屋都放行
        let ok = makeItem(title: "狮子王", sourceCategory: "动画")
        XCTAssertNil(FeedAdapter.isolationReject(ok, mode: "normal"))
        XCTAssertNil(FeedAdapter.isolationReject(ok, mode: "child"))

        // 片名强特征（成人来源）→ 挡
        let mark = makeItem(title: "一本道 精选合集", sourceCategory: "剧情")
        XCTAssertNotNil(FeedAdapter.isolationReject(mark, mode: "normal"))
    }

    /// 夜航反向闸门（2026-09-22 用户指令）：普通动画片 / 儿童片不得混入夜航。
    func testAdultPoolRejectsKidsAndKeepsAdultAnime() {
        // 夜航里混进普通儿童动画 → 必须剔除
        let peppa = makeItem(title: "小猪佩奇 第一季", sourceCategory: "动画")
        XCTAssertNotNil(FeedAdapter.isolationReject(peppa, mode: "adult"))
        let kidsShow = makeItem(title: "汪汪队立大功", sourceCategory: "儿童")
        XCTAssertNotNil(FeedAdapter.isolationReject(kidsShow, mode: "adult"))

        // 真成人动画（源分类=两性课堂，＝夜航动漫实测来源）→ 必须放行
        let hAnime = makeItem(title: "ばにぃうぉ～か～ OVA 作品集", sourceCategory: "两性课堂")
        XCTAssertNil(FeedAdapter.isolationReject(hAnime, mode: "adult"))

        // 无成人证据的普通动画：判据刻意收窄，宁可不挡不可误杀 → 放行
        let generic = makeItem(title: "海贼王", sourceCategory: "动画")
        XCTAssertNil(FeedAdapter.isolationReject(generic, mode: "adult"))

        // 儿童片在星幕/心屋本属正常内容 → 不受夜航闸门影响
        XCTAssertNil(FeedAdapter.isolationReject(peppa, mode: "child"))
        XCTAssertNil(FeedAdapter.isolationReject(peppa, mode: "normal"))

        // 严格模式（夜航池成人证据覆盖率 ≥50% 时启用）：无成人证据一律剔除
        // 实测混入样本：咱们裸熊：电影版（心屋儿童源） / 裸体哈维闯人生（普通动画）
        let bears = makeItem(title: "咱们裸熊：电影版", sourceCategory: "喜剧")
        XCTAssertNotNil(FeedAdapter.isolationReject(bears, mode: "adult", adultStrict: true))
        let harvey = makeItem(title: "裸体哈维闯人生", sourceCategory: "动画")
        XCTAssertNotNil(FeedAdapter.isolationReject(harvey, mode: "adult", adultStrict: true))
        // 真成人动画在严格模式下必须留存（否则夜航被误杀成空库）
        XCTAssertNil(FeedAdapter.isolationReject(hAnime, mode: "adult", adultStrict: true))
    }

    /// 成人证据覆盖率（决定夜航闸门严格/宽松）。
    func testAdultEvidenceRatio() {
        let pool = [
            makeItem(title: "ばにぃうぉ～か～ OVA", sourceCategory: "两性课堂"),
            makeItem(title: "有码精选", sourceCategory: "伦理片有码"),
            makeItem(title: "咱们裸熊：电影版", sourceCategory: "喜剧"),
            makeItem(title: "海贼王", sourceCategory: "动画"),
        ]
        XCTAssertEqual(FeedAdapter.adultEvidenceRatio(pool), 0.5, accuracy: 0.001)
        XCTAssertEqual(FeedAdapter.adultEvidenceRatio([]), 0.0, accuracy: 0.001)
    }

    /// 端隔离与导航分派（2026-09-22 用户钦定口径）：
    /// 「很多我想要的成人分类都在索倪源里，比如热舞写真、里番；有关奈飞的、邵氏电影这两种是星幕的；
    ///   还有伦理三级都有，但是是夜航的」。
    func testNavPolicyDispatching() {
        // 成人分类：只有夜航放行，星幕/心屋一律不给（跨端红线）
        for c in ["伦理", "港台三级", "日本伦理", "西方伦理", "韩国伦理",
                  "两性课堂", "写真热舞", "擦边短剧"] {
            XCTAssertTrue(NavPolicy.allowsCategory(c, mode: "adult"), "夜航应放行「\(c)」")
            XCTAssertFalse(NavPolicy.allowsCategory(c, mode: "normal"), "星幕不得出现「\(c)」")
            XCTAssertFalse(NavPolicy.allowsCategory(c, mode: "child"), "心屋不得出现「\(c)」")
        }
        // 星幕专属（用户点名的三类）：奈飞 / 邵氏 / 4K
        XCTAssertEqual(NavPolicy.navTitle(forSourceCategory: "邵氏电影", mode: "normal"), "邵氏经典")
        XCTAssertEqual(NavPolicy.navTitle(forSourceCategory: "Netflix电影", mode: "normal"), "Netflix专区")
        XCTAssertEqual(NavPolicy.navTitle(forSourceCategory: "Netflix自制剧", mode: "normal"), "Netflix专区")
        XCTAssertEqual(NavPolicy.navTitle(forSourceCategory: "4K电影", mode: "normal"), "4K专区")
        XCTAssertEqual(NavPolicy.navTitle(forSourceCategory: "剧情片", mode: "normal"), "电影")
        XCTAssertEqual(NavPolicy.navTitle(forSourceCategory: "动画片", mode: "normal"), "动漫")
        // 星幕不要的：综艺 / 体育
        XCTAssertNil(NavPolicy.navTitle(forSourceCategory: "大陆综艺", mode: "normal"))
        XCTAssertNil(NavPolicy.navTitle(forSourceCategory: "足球", mode: "normal"))
        // 短剧（2026-09-23 用户要短剧源）：星幕独立成组，词表按内置源实测分类名
        for c in ["短剧", "短剧大全", "爽文短剧", "反转爽剧", "女频恋爱", "AI漫剧", "漫剧",
                  "重生民国", "穿越年代", "现代言情", "都市脑洞"] {
            XCTAssertEqual(NavPolicy.navTitle(forSourceCategory: c, mode: "normal"), "短剧",
                           "星幕「\(c)」应归短剧组")
        }
        // 红线不动：擦边短剧是成人内容 → 只有夜航
        XCTAssertNil(NavPolicy.navTitle(forSourceCategory: "擦边短剧", mode: "normal"))
        // 短剧不进心屋；夜航只做成人，不显示短剧
        XCTAssertNil(NavPolicy.navTitle(forSourceCategory: "短剧", mode: "child"))
        XCTAssertNil(NavPolicy.navTitle(forSourceCategory: "短剧", mode: "adult"))
        // 夜航：源本身是成人源 → 分类级默认全收（172 个题材类目如 制服诱惑/丝袜美腿 都要能看到），
        // 只挡明确儿童向分类；混进来的普通动画/儿童片由条目级 kidStrongMarks 兜住
        XCTAssertTrue(NavPolicy.allowsCategory("动作片", mode: "adult"))
        XCTAssertTrue(NavPolicy.allowsCategory("制服诱惑", mode: "adult"))
        XCTAssertTrue(NavPolicy.allowsCategory("丝袜美腿", mode: "adult"))
        XCTAssertFalse(NavPolicy.allowsCategory("儿童儿歌", mode: "adult"))
        XCTAssertFalse(NavPolicy.allowsCategory("科普学习", mode: "adult"))
        // 夜航兜底：题材类目归「其他」（进组后靠二级筛选精确找）
        XCTAssertEqual(NavPolicy.navTitle(forSourceCategory: "制服诱惑", mode: "adult"), "其他")
        XCTAssertEqual(NavPolicy.navTitle(forSourceCategory: "写真热舞", mode: "adult"), "写真热舞")
        XCTAssertEqual(NavPolicy.navTitle(forSourceCategory: "港台三级", mode: "adult"), "三级")
        // 同一批题材类目在星幕/心屋必须被挡掉（红线）
        XCTAssertNil(NavPolicy.navTitle(forSourceCategory: "制服诱惑", mode: "normal"))
        XCTAssertNil(NavPolicy.navTitle(forSourceCategory: "丝袜美腿", mode: "normal"))
        XCTAssertNil(NavPolicy.navTitle(forSourceCategory: "探花系列", mode: "normal"))
        XCTAssertFalse(NavPolicy.allowsItem(title: "制服诱惑精选", sourceCategory: "剧情", mode: "normal"))
        // 心屋：只留儿童向；成人已拦；恐怖惊悚等儿童不宜也拦
        XCTAssertEqual(NavPolicy.navTitle(forSourceCategory: "儿童儿歌", mode: "child"), "儿童")
        XCTAssertEqual(NavPolicy.navTitle(forSourceCategory: "动画片", mode: "child"), "动画片")
        XCTAssertNil(NavPolicy.navTitle(forSourceCategory: "恐怖片", mode: "child"))
        XCTAssertNil(NavPolicy.navTitle(forSourceCategory: "港台三级", mode: "child"))
        // 条目级兜底（源分类缺失时靠片名/关键词）
        XCTAssertFalse(NavPolicy.allowsItem(title: "写真热舞精选", sourceCategory: "剧情", mode: "normal"))
        XCTAssertFalse(NavPolicy.allowsItem(title: "小猪佩奇", sourceCategory: "儿童儿歌", mode: "adult"))
        XCTAssertTrue(NavPolicy.allowsItem(title: "小猪佩奇", sourceCategory: "儿童儿歌", mode: "child"))
    }

    /// 4K 同片匹配：片名归一化（实测索倪源 4K 分类 838 条中 105 条与普通电影同片）。
    func testNavPolicy4KCanonicalTitle() {
        XCTAssertEqual(NavPolicy.canonicalTitle("源代码4K"), NavPolicy.canonicalTitle("源代码"))
        XCTAssertEqual(NavPolicy.canonicalTitle("哈尔的移动城堡国语4K"),
                       NavPolicy.canonicalTitle("哈尔的移动城堡"))
        XCTAssertEqual(NavPolicy.canonicalTitle("无间道2粤语4K"), "无间道2")
    }

    /// 二级筛选（用户 2026-09-22：「合并了是不是得分区域？比如韩国/日本/港台……
    /// 我说不明白，但是我想看那种得能找到，也就是筛选吧」）。
    func testNavPolicySubLabelAndRegion() {
        XCTAssertEqual(NavPolicy.subLabel("日本伦理", groupTitle: "伦理"), "日本")
        XCTAssertEqual(NavPolicy.subLabel("韩国伦理", groupTitle: "伦理"), "韩国")
        XCTAssertEqual(NavPolicy.subLabel("西方伦理", groupTitle: "伦理"), "西方")
        XCTAssertNil(NavPolicy.subLabel("伦理", groupTitle: "伦理"))          // 通用项 → 归「全部」
        XCTAssertEqual(NavPolicy.subLabel("港台三级", groupTitle: "三级"), "港台")
        XCTAssertEqual(NavPolicy.subLabel("动作片", groupTitle: "电影"), "动作")
        XCTAssertEqual(NavPolicy.subLabel("国产剧", groupTitle: "电视剧"), "国产")
        XCTAssertEqual(NavPolicy.subLabel("韩剧", groupTitle: "电视剧"), "韩")
        XCTAssertEqual(NavPolicy.subLabel("Netflix电影", groupTitle: "Netflix专区"), "Netflix")
        // 地区标签
        XCTAssertEqual(NavPolicy.regionLabel("韩国伦理"), "韩国")
        XCTAssertEqual(NavPolicy.regionLabel("港台三级"), "港台")
        XCTAssertEqual(NavPolicy.regionLabel("日韩动漫"), "日本")
        XCTAssertNil(NavPolicy.regionLabel("剧情片"))
    }

    /// 内置源可见性不变量（2026-09-22 用户报「我发现内置源消失」后加的防回归）：
    /// 三端内置点播源**永远非空**且索倪三端共有；成人专用源**绝不**出现在星幕/心屋。
    /// 为什么必须有这条：内置源一旦整体为空，设置页那一栏就"消失"了；
    /// 而历史上「内置线路」与「内置点播源」共用一个删除墓碑集合，会把可见性搞串。
    func testBuiltinSourcesVisibilityInvariants() {
        let normal = DefaultSites.builtinVodSources(forMode: "normal")
        let child  = DefaultSites.builtinVodSources(forMode: "child")
        let adult  = DefaultSites.builtinVodSources(forMode: "adult")

        // ① 三端都非空 —— 空了就是用户眼里的"内置源消失"
        XCTAssertFalse(normal.isEmpty, "星幕内置点播源不得为空")
        XCTAssertFalse(child.isEmpty,  "心屋内置点播源不得为空")
        XCTAssertFalse(adult.isEmpty,  "夜航内置点播源不得为空")

        // ② 索倪（全类目混合源）三端共有 —— 用户的分类诉求全靠它
        for (mode, list) in [("normal", normal), ("child", child), ("adult", adult)] {
            XCTAssertTrue(list.contains { $0.key == "builtin:suoni" }, "\(mode) 必须能看到索倪源")
        }

        // ③ 成人专用源只给夜航（内容隔离红线）
        let adultOnly = Set(DefaultSites.builtinAdultVodSources.map(\.key))
        XCTAssertFalse(adultOnly.isEmpty)
        for s in normal + child {
            XCTAssertFalse(adultOnly.contains(s.key), "\(s.key) 是成人专用源，不得出现在非夜航端")
        }
        // ④ 夜航 = 共有源 + 成人专用源（不丢不重）
        XCTAssertEqual(adult.count, normal.count + adultOnly.count)
    }

    /// 内置线路可见性（心屋=空集是**设计**，故设置页必须常显说明而不是整段隐藏）。
    func testBuiltinReposPerMode() {
        XCTAssertFalse(DefaultSites.builtinRepos(forMode: "normal").isEmpty)
        XCTAssertFalse(DefaultSites.builtinRepos(forMode: "adult").isEmpty)
        XCTAssertTrue(DefaultSites.builtinRepos(forMode: "child").isEmpty, "心屋零线路是设计，不是缺陷")
        // 首条必须是随包直连（bundle:），零网络依赖兜底
        XCTAssertTrue(DefaultSites.builtinRepos(forMode: "normal").first?.url.hasPrefix("bundle:") == true)
    }

    private func makeItem(title: String, actors: [String]? = nil, isAdult: Bool? = false,
                          sourceCategory: String? = nil) -> FeedItem {
        var body = """
        "dedup_id":"\(UUID().uuidString)","title":"\(title)",
         "actors":\(actors.map { "\($0)" } ?? "[]"),"is_adult":\(isAdult == true)
        """
        if let sc = sourceCategory { body += ",\"origin\":{\"category\":\"\(sc)\"}" }
        let json = ("{" + body + "}").data(using: .utf8)!
        return try! FilmJSON.decoder().decode(FeedItem.self, from: json)
    }
}
