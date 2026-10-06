import SwiftUI
import FilmCore

/// ★ v78.4：起播请求 —— 把「续播意图 + 起始集」打包成**一个值**，随 `fullScreenCover(item:)` 一起呈现。
///
/// 为什么必须这么改（主人 2026-10-05：「怎么续播也出问题了 刚才我看到的位置 装完从第一集开始了」）：
/// 旧写法是 `@State showPlayer=false` + `@State startAtResume=false` + `.fullScreenCover(isPresented:)`，
/// 内容闭包直接读那两个 @State。**真机铁证**（拉 `resume.traceLog`，10-03 至 10-05 共 40 条）
/// 里**没有一条 `gate=true`**，而同一时刻 `start()` 读到的历史明明有值：
/// ```
/// 2026-10-05T09:40:26Z start gate=false entry=1589.743995583 use=0.0 line=0   ← 历史有 26 分钟，却从头播
/// 2026-10-05T09:42:28Z start gate=false entry=1323.186103818 use=0.0 line=0
/// ```
/// 即：点击时算得再对（`resumeText` 屏幕上就写着「续播 26:29」），
/// **闭包拿到的仍是初始快照 false / 上一次残留的 line** —— 同一事务里连续改多个 @State
/// 再立刻呈现时，`isPresented` 版闭包读到的是上一帧的值。
/// 正解：改用 `fullScreenCover(item:)` —— 呈现由**这个值本身**驱动，取值与呈现同一份数据，
/// 不依赖任何时序；`request.id` 每次新建，连点同一部片也能可靠重开。
struct PlayRequest: Identifiable {
    let id = UUID()
    /// 本次是否「接着上次看」（true 时由播放器按**已就绪**的历史决定集与秒数）。
    let resume: Bool
    /// 起始线路下标（`allLines` / `playCandidates` 口径）。
    let line: Int
}

/// 影片详情：横版头图 → 信息区（年份/分类/评分/地区来源）→ 简介（可展开）→ 演员/导演 →
/// 播放入口（续播/从头播）+ 线路选择 + 收藏。
public struct DetailView: View {
    /// 可变条目：TVBox list 通道（分类浏览）进来的条目无播放地址，
    /// 进详情页自动按 dedupId 回源补拉 ac=detail&ids=，拉到后原地更新（「分类只有40部」配套改造）。
    @State private var liveItem: FeedItem
    var item: FeedItem { liveItem }
    /// 原始入参（独立保存，不复用 liveItem）：
    /// 从相关推荐连点两部片时 SwiftUI 可能复用同一个 DetailView 实例，
    /// @State 不会重新初始化 → 详情页仍显示上一部（用户报「相关推荐点进去不是推荐的这个」）。
    /// 保留入参 + onChange 兜底重同步，根除实例复用导致的错片。
    /// 2026-10-02 改 var：let 在视图复用时 SwiftUI 不会把新入参刷进旧实例，onChange 失效。
    private var incoming: FeedItem
    @EnvironmentObject private var library: UserLibrary
    @EnvironmentObject private var store: CatalogStore
    @EnvironmentObject private var router: DetailRouter
    @Environment(\.filmTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    /// 横屏角标形态（原型 v3 钦定）：横屏=纯图标＋深投影（无边无底不挡头图）；竖屏=原玻璃圆底（零改动）。
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var isLandscape: Bool { vSizeClass == .compact }

    /// ★ v78.4：起播请求（见文件头 `PlayRequest`）—— 取代旧的 `showPlayer` + `startAtResume` 两段式。
    /// 非 nil = 播放器全屏呈现；`req.resume/req.line` 就是**这次起播真正用的值与起始集**。
    @State private var playRequest: PlayRequest?
    /// 2026-10-02（主人：「点继续播放 —— ①海报直接打开 ②详情页」）：本实例是否已自动起播过，
    /// 防重绘把「落地即播」跑第二遍。
    @State private var autoplayFired = false
    // ★ v78.4：原 `pendingLine`（起播起始集）已并入 `playRequest`，不再单独保留 —— 两处状态
    //   分开写时，「起播意图」和「起始集」可能来自不同帧（一方生效一方没生效），这正是
    //   主人看到的「续播从第一集开始」的成因。现在只有 `playRequest` 一个来源。
    @State private var sourceIdx = 0        // 当前选集网格展示的线路（换源循环）
    @State private var lastEpName: String?  // 换源时保持同一集
    @State private var summaryExpanded = false
    @State private var refreshingPlay = false
    /// 详情页取色（2026-09-23 用户钦定原型 `home_v2.html` 详情浮层一比一搬真机）：
    /// 头图放大铺满 + 整页取色底色 + 浮动海报；取色与首页同源（`HeroTintStore` 缓存，不重复下载）。
    @State private var palette: HeroPalette = .fallback
    /// 相关推荐缓存（10-01 卡顿根修）：`related` 原是**计算属性**——每次 body 求值都对 13 万条
    /// 做 2~3 轮全量 `filter`（其中 `byTags` 那轮每条目还要 `Set(...)` + `pool.contains`），
    /// 而 body 里它被读了两次（`!related.isEmpty` + `ForEach(related)`）→ 详情页**每帧重绘**
    /// 都跑好几遍 13 万条扫描＝秒级主线程阻塞。
    /// 这就是用户报「详情页关闭按钮点了半天没反应」的直接根因：点关闭时 SwiftUI 还要
    /// 先把当前帧的 body 算完（含这堆扫描）才处理点击。
    /// 改为：进页面后台算一次存这里，body 只读缓存。
    @State private var relatedCache: [FeedItem] = []
    @State private var relatedKey: String = ""

    public init(item: FeedItem) {
        self.incoming = item
        _liveItem = State(initialValue: item)
    }

    /// 整页取色底：与首页同源（HeroPalette），随当前详情海报变色。
    /// 原型对应 `radial-gradient(150% 72% at 50% -10%, …)`。
    /// 2026-09-23：此前这里是死黑 `theme.background` —— 用户实测「详情页没改」的一半原因
    /// 就是「只有头图取色、往下全黑」。
    private var heroTintBackground: some View {
        ZStack {
            theme.background
            RadialGradient(
                stops: [
                    .init(color: palette.mid.alpha(0.55), location: 0.00),
                    .init(color: palette.deep.alpha(0.86), location: 0.55),
                    .init(color: palette.deep.scaled(0.66).color, location: 1.00)
                ],
                center: UnitPoint(x: 0.5, y: -0.10),
                startRadius: 0,
                endRadius: 620
            )
        }
        .animation(.easeInOut(duration: 0.9), value: palette)
    }

    /// 顶栏角标按钮的图标体（2026-10-04 原型 v3 钦定）：
    /// **横竖屏统一 = 纯图标＋深投影**（无边无底，材质不再把头图洗成灰药丸）。
    /// 2026-10-04 主人验机：「竖屏还是原来的」→ 撤掉横竖分叉，两端同款纯图标；
    /// 命中区尺寸仍按横竖各自保留（横 56 / 竖 44），点按手感不变。
    private func heroIcon(_ symbol: String, fontSize: CGFloat, frameSize: CGFloat, tint: Color = .white) -> some View {
        Image(systemName: symbol)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: frameSize, height: frameSize)    // 实心命中区（HIG 44 起步）
            .contentShape(Rectangle())
            .shadow(color: .black.opacity(0.9), radius: 4, y: 1)
    }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header
                infoSection
                actionButtons
                if let s = item.summary, !s.isEmpty { summarySection(s) }
                creditsSection
                // 电视剧 → 选集网格；电影 → 播放线路 chips（电影没有"选集"）
                if isTVItem {
                    // 与 refreshEpisodesFallback 共用同一判据（hasRealEpisodeList），防两处口径漂移。
                    if hasRealEpisodeList {
                        episodesSection
                        // ★ v67（主人 2026-10-04「有了选集就没有了选源了是吗？放弃换源了？」）：
                        //   选集 ≠ 放弃换源。episodesSection 顶部的「换源」按钮按 quality 分组，
                        //   中台数据 quality 恒空 → 恒 1 组 → 按钮永不出现，真剧详情页就只剩选集了。
                        //   补一行跨源线路 chips（与选集同一套 pendingLine 下标，点了直接播），
                        //   聚合出的跨源线路在详情页就能切，不必先进播放器。
                        if allSourceLines.count > 1 { sourceChipsSection }
                    } else if !allSourceLines.isEmpty {
                        // ★ v66：中台 feed 的剧只有「换源线路」（无集名）→ 先给线路入口
                        //   （真选集由 refreshEpisodesFallback 按片名去剧集源补拉；
                        //   补不到也不能让详情页一个播放入口都没有）。
                        sourceChipsSection
                    }
                } else if !allSourceLines.isEmpty {
                    // 电影：单源也显示线路入口（此前 count>1 才显示，单源电影无任何播放线路 UI）
                    sourceChipsSection
                }
                if !related.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("相关推荐").font(.headline).foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 10) {
                                ForEach(related) { rel in
                                    // 相关推荐也走详情卡弹层：router.item 换片 → sheet 内容 .id 重建
                                    //（@State 必重新初始化，根除「点相关推荐进的不是这个」的实例复用 BUG）。
                                    Button { router.open(rel, from: "相关推荐") } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            PosterImage(urlString: rel.bestPosterURL?.absoluteString)
                                                .frame(width: 108, height: 160)
                                                .cornerRadius(10)
                                            Text(rel.title).font(.caption2)
                                                .foregroundStyle(theme.textSecondary).lineLimit(1)
                                        }
                                        .frame(width: 108)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .padding(.bottom, 40)
        }
        .background(heroTintBackground.ignoresSafeArea())
        // ★★ 2026-10-03 主人：「详情页要能返回能关闭」「关闭点好几次关不掉」——**根因与修法**：
        //   旧写法把「收藏 + 关闭」浮在**贴 sheet 顶边 10pt** 的位置，而这张卡是
        //   `.presentationDetents([.fraction(0.88)])` 的 sheet —— 顶边那一条正是系统的
        //   **下拉关闭手势区**，命中点落在手势区边界上 → 系统把 tap 当拖拽吞掉，
        //   于是「有时能关、多数要点好几次」（实测：页中间的「续播」一击即中，
        //   同页顶部浮层连点三次毫无反应，证明不是坐标问题而是这一层被手势区吃了）。
        //   修法三条：
        //     ① 命中区**实心放大到 44×44**（HIG 最小可点尺寸）+ `contentShape`，
        //        不再只有 17pt 的字形吃触摸；
        //     ② 往下挪出抓取区（top 10 → 22）+ 左上角补一个 44×44 的**返回**，
        //        与直播页同口径（左返回 / 右关闭），「能返回能关闭」两条路都通；
        //     ③ 保留系统下拉关闭与拖拽把手作第三条退路。
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                // v60：横竖屏**同一形态**（纯图标＋投影），笔形尺寸也统一 22pt
                //（旧版竖屏 17pt / 横屏 26pt —— 尺寸两副面孔同样是「横竖不一致」）；
                // 只保留**命中区**按横竖各自 56 / 44（手感差异，肉眼不可见）。
                heroIcon("chevron.left", fontSize: 22, frameSize: isLandscape ? 56 : 44)
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .padding(.top, 22)                             // 挪出 sheet 抓取区
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                Button {
                    library.toggleFavorite(item)
                } label: {
                    heroIcon(library.isFavorite(item) ? "heart.fill" : "heart",
                             fontSize: 21,
                             frameSize: isLandscape ? 56 : 44,
                             tint: library.isFavorite(item) ? theme.accent : .white)
                }
                .buttonStyle(.plain)
                Button {
                    dismiss()
                } label: {
                    heroIcon("xmark", fontSize: 22, frameSize: isLandscape ? 56 : 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 12)
            .padding(.top, 22)                             // 挪出 sheet 抓取区
        }
        .fullScreenCover(item: $playRequest) { req in
            PlayerScreen(item: item, startAtResume: req.resume,
                         startLine: req.line,
                         extraLines: extraSources.map(\.url),
                         extraSourceNames: extraSources.map(\.source),
                         onClose: { playRequest = nil },
                         // ★ v66：只有**真分集**才把选集传给播放器。中台 feed 的剧只有 4 条换源线路
                         //   （无集名），传下去会让播放器把「换源」当「下一集」、选集面板里显示假 4 集
                         //   —— 主人看到的就是「电视剧都是四集」。无真分集时传空 = 播放器按换源口径走。
                         episodeGroups: (isTVItem && hasRealEpisodeList) ? episodeGroups : [],
                         onEpisodeChange: { lastEpName = $0 })
                .environment(\.colorScheme, .dark)   // 播放=视频层，恒深色
        }
        // 自动续播通道（★ 2026-10-04 起休眠：继续观看/历史已撤销 autoplay，点海报=只弹详情卡）。
        // 通道保留：只要有入口重新传 `router.open(..., autoplay: true)`，这里照常落地即续播——
        // 等 sheet 呈现完成 → 没源先回源补拉 → 按历史进度/质量最优源起播。
        .task {
            guard router.autoplay, !autoplayFired else { return }
            autoplayFired = true
            // 等 sheet 呈现实例化完成再起播，否则 fullScreenCover 会被 sheet 转场吞掉。
            try? await Task.sleep(nanoseconds: 350_000_000)
            // 分类浏览进来的 TVBox 条目进详情页才回源补拉播放地址 —— 自动起播同样要等它。
            if !item.isPlayable, canRefreshPlay { await refreshTVBoxPlay() }
            guard item.isPlayable else { return }        // 没源就留在详情页，不硬起、不空转
            // ★ v78.4：历史是**异步解码**的（启动提速改造），决策前先等它就绪，
            //   否则会读到空数组 → 续播退化成从头播（装包后首启尤其明显）。
            await library.ensureLoaded()
            let hist = library.historyEntry(for: item)
            let li = (hist?.lineIndex).flatMap { $0 >= 0 && $0 < allSourceLines.count ? $0 : nil }
            TapTrace.autoplay(dedupId: item.dedupId, title: item.title)
            playRequest = PlayRequest(resume: true, line: li ?? bestStartLineIndex)
            ResumeTrace.note("pick·autoplay hist=\(hist == nil ? "nil" : "有") prog=\(hist?.progressSeconds ?? -1) " +
                             "loaded=\(library.isLoaded) n=\(library.history.count) line=\(li ?? bestStartLineIndex)")
        }
        .task { await store.loadPersonAvatarsIfNeeded() }   // 演员小头像（2026-09-25）
        .task { await loadRelated() }
        .task { await aggregateSources() }
        .task {
            // 详情页取色：与首页同一张海报只算一次（HeroTintStore 缓存）
            palette = await HeroTintStore.shared.palette(for: item.poster?.url ?? item.backdrop?.url)
        }
        .task {
            await refreshTVBoxPlay()
            // 55包（用户钦定「不管内置源自定义源都得能显示选集 换剧集不能退出再进」）：
            // tvbox 补拉只覆盖电视剧页进来的条目；首页货架/搜索进来的剧（中台 feed 条目）
            // 没有分集数据 → 永远没选集。这里串行兜底：剧但没分集 → 按片名去剧集源搜同名补齐。
            await refreshEpisodesFallback()
        }
        // 实例复用兜底：入参换了（相关推荐下钻）就强制换片，不让 @State 停在旧条目
        .onChange(of: incoming.dedupId) { _, newID in
            if liveItem.dedupId != newID { liveItem = incoming }
        }
    }

    // MARK: - TVBox list 条目播放信息补拉

    /// 分类浏览走 ac=list（不含播放地址），进详情页按 dedupId="tvbox:<siteId>:<vodId>" 回源补拉详情。
    private func refreshTVBoxPlay() async {
        guard item.play?.defaultURL == nil, (item.play?.lines?.isEmpty ?? true),
              !refreshingPlay else { return }
        // siteId 本身可能含冒号（内置源 key="builtin:xxx"）——按 ":" 切分会错位
        // （siteId 解成 "builtin" → 找不到源 → 补拉永不执行 → 内置源点播放没反应，34包根修）。
        // 正解：拿源清单做最长前缀匹配。
        guard item.dedupId.hasPrefix("tvbox:") else { return }
        let rest = String(item.dedupId.dropFirst("tvbox:".count))
        // 52包（电视剧「播放时不能选集 / 没有下一集 / 点播失败」根因之一）：
        // 原来只在**用户配置的 TVBox 源**里找，而电视剧页用的是代码内置的 tvDramaSources
        // （key="liangzi" 等），用户配置里没有这些 key → 找不到源 → 补拉永不执行 →
        // 条目永远拿不到播放地址（episodeGroups 空 → 无选集、无下一集、点播放即失败）。
        // 现合并：配置源 + 内置剧集源 + 内置点播/混合源；仍按 id 前缀最长匹配，
        // 防 "liangzi" 与 "builtin:liangzi" 错配。
        let sites = TVBoxConfigStore.shared.displayResult.sites
            + DefaultSites.tvDramaSources
            + DefaultSites.builtinVodSources
            + DefaultSites.builtinMixedVodSources
        guard let site = sites.filter({ rest.hasPrefix($0.id + ":") })
                              .max(by: { $0.id.count < $1.id.count }) else { return }
        let vodId = String(rest.dropFirst(site.id.count + 1))
        guard !vodId.isEmpty else { return }
        refreshingPlay = true
        defer { refreshingPlay = false }
        guard let fresh = await TVBoxSiteClient.shared(for: site).detail(vodId: vodId),
              fresh.isPlayable else { return }
        liveItem = fresh
    }

    /// 55包：剧集分集兜底 —— 「不管内置源自定义源都得能显示选集」（用户钦定 2026-09-23）。
    /// 覆盖非 tvbox 条目（首页货架/搜索/收藏进来的剧）：没有分集数据时按片名
    /// 去内置剧集源搜同名，命中即整条替换（lines 带 2~3 线路 × N 集）。
    /// 只认「正统剧源」（tvDramaSources），三端共用该源，内容隔离红线不碰。
    private func refreshEpisodesFallback() async {
        // 2026-09-30 修「TV/电视剧看不到选集列表」——旧判据 `lines.count <= 1` 太窄：
        // 中台 feed 条目常带**多条线路**（一线路一条 url，是换源不是分集）→ lines.count ≥ 2 →
        // 旧判据直接 return，**兜底永不执行** → 电视剧永远拿不到分集 → 详情页没有选集区块。
        // 改为按「有没有真分集」判：任一分组 >1 集才算有，否则一律尝试补拉。
        guard !hasRealEpisodeList, !refreshingPlay else { return }
        // 电影明确跳过（电影多线路≠多集，2026-09-20 教训）。
        if item.contentType == "movie" { return }
        // 剧集判据放宽（55包）：类型标 tv／片名像剧／源分类名含「剧」——三者任一即补拉。
        // 只看 contentType=="tv" 会漏掉中台 feed 未标类型的剧（用户：「不管哪种都得能显示选集」）。
        let catBag = item.aggregateCategoryName ?? ""
        guard item.contentType == "tv" || looksLikeSeries(item.title)
                || catBag.contains("剧") || catBag.contains("连") else { return }
        let target = normalizedTitle(item.title)
        guard !target.isEmpty else { return }
        refreshingPlay = true
        defer { refreshingPlay = false }
        for site in DefaultSites.tvDramaSources {
            let c = TVBoxSiteClient.shared(for: site)
            let hits = await c.search(item.title)
            guard !hits.isEmpty else { continue }
            // 先精确；不中再退一步「归一化后互相包含 且 长度接近」——
            // 源站片名常带「国语/粤语/HD/年份/全集」等后缀，**全等匹配会把整片漏掉**，
            // 这正是电视剧明明搜得到却"看不到选集"的直接原因。
            let match = hits.first { normalizedTitle($0.title) == target }
                ?? hits.first {
                    let n = normalizedTitle($0.title)
                    return (n.contains(target) || target.contains(n))
                        && abs(n.count - target.count) <= 6
                }
            guard let match, let ml = match.play?.lines, ml.count > 1 else { continue }
            liveItem = match
            FilmLog.i("EPISODE fallback HIT: 「\(item.title)」→「\(match.title)」lines=\(ml.count)")
            return
        }
        FilmLog.i("EPISODE fallback MISS: 「\(item.title)」未在 \(DefaultSites.tvDramaSources.count) 个剧集源找到同名分集")
    }

    /// 是否已有「真正的分集」：**线路带非空集名**，且该组不止一集。
    ///
    /// ★ v66（主人 2026-10-04「电视剧都是四集！！！」「乡村爱情四集」）——旧判据只有
    /// `episodeGroups.contains { $0.eps.count > 1 }`（只看条数 > 1），而**中台 feed 的
    /// `play.lines` 是「换源线路」、不是「集」**。真机快照实测：tv 池 13604 条里 **13193 条
    /// 恰好 4 条线路、`name`/`quality` 全为空串**（例：《乡村爱情》4 条线路 = 4 个 CDN 域名，
    /// 不是 4 集）→ 被当成「第1~4集」→ 任何一部剧都显示 4 集。
    /// 更糟的是它让下面的 `refreshEpisodesFallback()` 认定「已有分集」→ **永不补拉真选集**。
    ///
    /// 真分集的唯一可靠信号 = 解析自 CMS `vod_play_url` 的 **line.name 非空**
    /// （见 `TVBoxPlayParser.parse`：集名进 `name`、线路名进 `quality`；中台通道的 lines 没有集名）。
    private var hasRealEpisodeList: Bool {
        (item.play?.lines ?? []).contains { ($0.name?.isEmpty == false) }
            && episodeGroups.contains { $0.eps.count > 1 }
    }

    /// 片名是否像剧集（含「第N季/部/集」或「季」结尾等常见剧名特征）。
    private func looksLikeSeries(_ title: String) -> Bool {
        title.range(of: "第[0-9一二三四五六七八九十]+[季部集]", options: .regularExpression) != nil
            || title.hasSuffix("季") || title.contains("电视剧")
    }

    // MARK: - 多源聚合（换源池扩容）

    /// 打开详情页即后台聚合：按片名去其余 CMS 源搜同名片，
    /// 命中的播放线路并入换源池（TVBox 式聚合）。电影/电视剧通用。
    /// ★ v67：保留**大源身份**（`SourceLine.source` = CMS 源站名）——
    ///   主人钦定「切换源应该是先换大源，大源里有小源就自动切小源」，
    ///   旧实现只收 URL，大源身份丢了 → 换源只能在平铺列表里盲轮。
    @State private var extraSources: [SourceLine] = []
    @State private var aggregating = false

    private func aggregateSources() async {
        // 46包（用户：「还有切源呢怎么没了呢！」）：原来只在星幕（normal）聚合跨源线路，
        // 成人端/心屋的详情页从不聚合 → 单线路片子连「换源/切换线路」按钮都不出现。
        // 现在三端都聚合：normal=剧集源；adult=索倪+前6个成人源；child=索倪。
        guard extraSources.isEmpty, !aggregating,
              store.profile.mode == "normal" || store.profile.mode == "adult"
              || store.profile.mode == "child" else { return }
        // 35包：详情页会被「相关推荐」连续下钻，每进一页都重发 4~6 个公网源搜索（弱网下页页转圈/耗流量）。
        // 进程内按 dedupId 缓存聚合结果（空结果也缓存，避免反复空搜）。
        if let cached = AggregateCache.shared.get(item.dedupId) {
            extraSources = cached
            return
        }
        aggregating = true
        defer { aggregating = false }
        // ★ v69：目标片名走与子任务同一套清洗（去空格/·/【】装饰段），否则
        //   「揭秘日【影视解说】」这类 CMS 变体会被精确匹配漏掉 → 白白少源。
        let target = detailTitleKey(item.title)
        guard !target.isEmpty else { return }
        let deadline = Date().addingTimeInterval(12)   // 聚合死线：到点收工，绝不无限转圈
        // 46包：按端选聚合源池（成人源绝不进 normal/child 的池子——内容隔离红线不碰）
        // ★ v69 聚合扩容（主人 2026-10-04「源的数量你再给我扩扩 以前我用tvbox的时候有几十个随便换」）：
        //   池子从 4 条扩到 ~48 条 = 剧集源 + 全部内置影视源（内置池 2026-09-20 实测存活才内置的，
        //   成人源依旧绝不入 normal/child 的池）。44 条里大量是同站镜像（红牛×3/360×7/天涯×3…），
        //   靠 `DefaultSites.brandKey` 在收集时按**品牌**去重 —— 大源数 = 真实源站数，不拿镜像凑数。
        let mode = store.profile.mode
        let pool: [TVBoxSite]
        switch mode {
        case "child":
            // 2026-10-01 用户钦定「心屋不内置任何带成人内容的源」：聚合池只用纯影视源。
            pool = DefaultSites.builtinVodSources + DefaultSites.tvDramaSources
        default:
            pool = DefaultSites.tvDramaSources + DefaultSites.builtinVodSources
        }
        // 片源自带线路的大源先占品牌位：聚合同品牌镜像时直接跳过（同名大源不出第二个 chip）。
        let ownRaw = (item.origin?.sourceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ownBrand = DefaultSites.brandKey(ownRaw.isEmpty ? "片源" : ownRaw)
        var collected: [SourceLine] = []
        var seenBrands: Set<String> = [ownBrand]
        // ★ v69 聚合重做（主人 2026-10-04 报「我记得以前十几个源一部片 现在就3个了？」）：
        //   实测根因 = **聚合太慢**：旧写法 10 条一批串行 6 批，Mac 上复刻同算法全程要 53s，
        //   手机更慢 → 等不到跑完就只看到先回来的两三家，看起来"源变少了"。
        //   重做三点：
        //   ① **全量并发**（52 条一起发，不再分批）—— 最慢的一站 8s 超时，整体 8~10s 出全；
        //   ② **边搜边出**：每回收回一条可用源就立刻刷 `extraSources`，chip 一颗颗亮起来，
        //      用户不用盯着"正在搜索更多源…"干等；
        //   ③ **12s 死线 + 满 9 品牌提前收工**：到点 `cancelAll()`，绝不无限转圈。
        // `target` 已在上方声明（guard !target.isEmpty）。
        let searchTitle = item.title          // 只把 String 捕获进 @Sendable 子任务（FeedItem 未标 Sendable）
        var failedSites: [String] = []        // 取证：本次聚合哪些源连网层就挂了（syslog 可核）
        let t0 = Date()
        await withTaskGroup(of: (String, [URL]).self) { group in
            for site in pool {
                // 子任务只捕获 Sendable 值：站点名（String）+ 客户端（actor 隐式 Sendable）
                let name = site.name
                let client = TVBoxSiteClient.shared(for: site)
                group.addTask {
                    let hits = await client.search(searchTitle)
                    let urls = hits.first(where: { detailTitleKey($0.title) == target })?.playCandidates ?? []
                    return (name, urls)
                }
            }
            for await (name, urls) in group {
                guard !urls.isEmpty else {
                    failedSites.append(name)
                    continue
                }
                let brand = DefaultSites.brandKey(name)
                guard !seenBrands.contains(brand) else { continue }   // 同品牌镜像只留首个命中的
                seenBrands.insert(brand)
                for u in urls where !collected.contains(where: { $0.url == u }) {
                    // 大源身份 = 归一后的品牌名（chip 显示「源N」；播放器按大源分层换）
                    collected.append(SourceLine(url: u, source: brand))
                }
                extraSources = collected                  // ② 边搜边出：立刻刷 chips
                if seenBrands.count >= 9 || Date() > deadline {   // ③ 死线 / 满员收工
                    group.cancelAll()
                }
            }
        }
        extraSources = collected
        AggregateCache.shared.set(item.dedupId, collected)
        filmLog.info("aggregate: '\(item.title)' 池\(pool.count) 命中品牌\(seenBrands.count - 1) 线路\(collected.count) 耗时\(Int(Date().timeIntervalSince(t0) * 1000))ms 失败\(failedSites.count)家")
    }

    private func normalizedTitle(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "·", with: "")
    }

    // MARK: - 区块

    /// 整页取色底色（原型 `.sheet`：`linear-gradient(180deg, mid 0, edge 300px, #0b0b0e 680px)` 一比一，
    /// 按屏高 844 折算成比例位 0 / 0.36 / 0.80）。随海报换色平滑过渡。
    private var detailBackground: some View {
        let base = Color(red: 11 / 255, green: 11 / 255, blue: 14 / 255)   // 原型 #0b0b0e
        return ZStack {
            base
            LinearGradient(stops: [
                .init(color: palette.mid.color, location: 0.00),
                .init(color: palette.edge.color, location: 0.36),
                .init(color: base, location: 0.80)
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: palette)
    }

    /// 影院式头图（原型 `.shStage`：海报放大 1.26 铺满 + 两侧暗角 + 顶部压暗 + 底部化进底色
    /// + 底部高斯雾带，与主页统一）。
    /// 2026-09-24 六改（与主页 HeroSlide 同一轮横线根治）：**去实色落地**。
    /// 旧 bottomFade 落 `edge` 实色——详情页背景是径向渐变，头图底边处渐变值 ≠ edge
    /// → 「海报底边横线」在详情页同样存在。改为主页同款结构：
    /// 海报自身渐隐 + 高斯雾带 + 两端透明取色雾，头图底部全透明 → 页面背景唯一色源。
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.clear         // 不铺实底，透出整页取色背景（与主页 HeroSlide 同构）
                fadeLayer           // 底图：底部渐隐到全透明，无硬边
                groundLayer         // 落地雾带（两端透明，无实色落点）
                sideVignette
                topScrim
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            headBlock                    // 浮动海报 + 衬线标题 + 大评分（上浮 104pt 咬进头图）
        }
    }

    /// 底图渐隐（主页 fadeLayer 七改同款，2026-09-25）：删高斯雾化带，长程平滑融合。
    /// 横线机制与主页一致：stageHaze 在 0.86~0.985 显形、最后 0.015 内突然归零，
    /// 该归零边就是横线本体。改为长程渐隐、0.96 处完全归零，底边前后全纯背景。
    private var fadeLayer: some View {
        stagePoster
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0.00),
                .init(color: .black, location: 0.48),
                .init(color: .black.opacity(0.80), location: 0.64),
                .init(color: .black.opacity(0.48), location: 0.78),
                .init(color: .black.opacity(0.18), location: 0.89),
                .init(color: .clear, location: 0.96),
                .init(color: .clear, location: 1.00)
            ], startPoint: .top, endPoint: .bottom))
    }

    /// 落地雾带（主页 groundLayer 同款）：两端透明，中段 mid 取色雾，零实色落点。
    private var groundLayer: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0.00),
            .init(color: .clear, location: 0.45),
            .init(color: palette.mid.alpha(0.35), location: 0.74),
            .init(color: palette.mid.alpha(0.12), location: 0.92),
            .init(color: .clear, location: 1.00)
        ], startPoint: .top, endPoint: .bottom)
    }

    private func stageImage() -> some View {
        GeometryReader { geo in
            // 10-01 P0：详情页头图同样是门面大图，原图档（不降采样）
            PosterImage(urlString: (item.bestBackdropURL ?? item.bestPosterURL)?.absoluteString,
                        cornerRadius: 0, contentMode: .fill, maxSide: PosterLoader.heroMaxSide)
                .scaleEffect(1.26)                       // 原型 transform:scale(1.26)
                .saturation(1.06).brightness(-0.08)      // 原型 filter:saturate(1.06) brightness(.92)
                // 2026-09-24 23:22 用户指令（与主页同）：顶部对齐不裁头，裁切全落底部融合区
                .frame(width: geo.size.width, height: geo.size.height * 1.25, alignment: .top)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
        }
    }

    private var stagePoster: some View { stageImage() }
    // stageHaze 高斯雾带已于 2026-09-25 删除（七改）：它就是横线本体，机制见 fadeLayer 注释。

    /// 两侧暗角（原型 `.vg`）
    private var sideVignette: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.52), location: 0.00),
            .init(color: .clear, location: 0.26),
            .init(color: .clear, location: 0.74),
            .init(color: .black.opacity(0.52), location: 1.00)
        ], startPoint: .leading, endPoint: .trailing)
    }

    /// 顶部压暗（原型 `.vt`：black .58 → 44% 处透明）
    private var topScrim: some View {
        LinearGradient(colors: [.black.opacity(0.58), .clear],
                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.44))
    }

    /// 底部化进底色（原型 `.shVB`：to top, edge 3% → 透明 78%；从下往上即 0.97 实 → 0.22 全透）
    private var bottomFade: some View {
        LinearGradient(stops: [
            .init(color: palette.edge.color, location: 0.97),
            .init(color: palette.edge.color.opacity(0), location: 0.22)
        ], startPoint: .bottom, endPoint: .top)
    }

    /// 浮动海报 + 标题块（原型 `.shHead`：竖版海报 112×164 圆角16 浮在头图下沿 -104pt，右侧衬线标题 + 大评分）
    private var headBlock: some View {
        HStack(alignment: .top, spacing: 16) {
            PosterImage(urlString: item.poster?.url ?? item.backdrop?.url)
                .frame(width: 112, height: 164)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.66), radius: 22, y: 10)
                .padding(.leading, 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.custom("Songti SC", size: 22).weight(.bold))   // 衬线（用户钦定「标题就要衬线」）
                    .kerning(1.2)
                    .lineLimit(2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.62), radius: 9, y: 1)
                if !metaLine.isEmpty {
                    Text(metaLine)
                        .font(.system(size: 10.5))
                        .kerning(1.5)
                        .foregroundStyle(.white.opacity(0.56))
                        .padding(.top, 8)
                }
                scoreRow.padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, -104)     // 原型 margin-top:-104：整块上浮咬进头图底部
    }

    private var metaLine: String {
        var parts: [String] = []
        if let y = item.displayYear, !y.isEmpty { parts.append(y) }
        if let a = item.area, !a.isEmpty { parts.append(a) }
        if let c = item.aggregateCategoryName, !c.isEmpty { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    /// 大评分行（原型 `.shScore`：27pt 粗分 + 金星 + 评分人数；有真评分才显示）
    private var scoreRow: some View {
        let score = HomePolicy.rating(item)
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            if score > 0 {
                Text(String(format: "%.1f", score))
                    .font(.system(size: 27, weight: .heavy))
                    .foregroundStyle(.white)
                HStack(spacing: 1) {
                    ForEach(0..<5, id: \.self) { i in
                        Image(systemName: Double(i) < (score / 2.0).rounded() ? "star.fill" : "star")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(red: 1.0, green: 0.81, blue: 0.35))
                    }
                }
                if let hv = item.votes, hv >= 100 {
                    Text("\(HomePolicy.votesText(hv))人评分")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else {
                Text("暂无评分").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let y = item.displayYear { tag(y) }
                if let cat = item.aggregateCategoryName, !cat.isEmpty { tag(cat) }
                // 2026-09-23 口径修正：feed 已带**真评分**（中台 IMDb/TMDB → 源站豆瓣分）→
                // 显示「评分 x.x」；热度改用**真实评分人数**，不再用 qualityScore×10 的伪热度。
                let realScore = HomePolicy.rating(item)
                if realScore > 0 { tag(String(format: "评分 %.1f", realScore)) }
                if let hv = item.votes, hv >= 1000 { tag("热度 \(HomePolicy.votesText(hv))") }
                if let ct = item.contentType, !ct.isEmpty {
                    tag(contentTypeName(ct))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func contentTypeName(_ code: String) -> String {
        switch code {
        case "movie": return "电影"
        case "tv": return "电视剧"
        case "short": return "短剧"
        default: return code
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                if item.isPlayable {
                    // ★ v78.4 全链加固（主人 2026-10-05「续播从第一集开始」）：
                    //   ① 先等历史就绪（异步解码，冷启动/刚装完时可能还没落定）；
                    //   ② `resume` **恒传 true** —— 主按钮的语义就是「接着看，没看过就从头」，
                    //      门槛（>30 秒才算看过）交给播放器在**起播那一刻**用真实历史判定。
                    //      旧写法在这里本地判 `>30`，一旦这一瞬读到空数组就把续播意图永久丢掉
                    //      （真机 40 条 trace 无一条 gate=true 就是这么来的）。
                    Task { @MainActor in
                        await library.ensureLoaded()
                        let hist = library.historyEntry(for: item)
                        let li = (hist?.lineIndex).flatMap { $0 >= 0 && $0 < allSourceLines.count ? $0 : nil }
                        let start = li ?? bestStartLineIndex     // v69：无历史 → 质量最优大源
                        ResumeTrace.note("pick·按钮 hist=\(hist == nil ? "nil" : "有") prog=\(hist?.progressSeconds ?? -1) " +
                                         "loaded=\(library.isLoaded) n=\(library.history.count) line=\(start)")
                        playRequest = PlayRequest(resume: true, line: start)
                    }
                } else if canRefreshPlay {
                    // 兜底：补拉成功就地开播，失败 toast 提示（不再永久灰死）
                    Task {
                        await refreshTVBoxPlay()
                        if item.isPlayable {
                            playRequest = PlayRequest(resume: false, line: bestStartLineIndex)
                        }
                    }
                }
            } label: {
                Label(refreshingPlay ? "正在获取播放源…" : resumeText,
                      systemImage: refreshingPlay ? "arrow.triangle.2.circlepath" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            // feed 通道 isPlayable 修复后即有地址即亮；TVBox list 条目（可回源补拉）永不灰死
            .disabled(!item.isPlayable && !canRefreshPlay)
            if !item.isPlayable {
                Text(refreshingPlay ? "正在获取播放信息…" : (canRefreshPlay ? "点按重试获取播放源" : "该影片暂无可用播放源"))
                    .font(.caption2).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
    }

    /// 该条目能否回源补拉播放地址（TVBox 通道：分类浏览 ac=list 条目天然无地址）。
    private var canRefreshPlay: Bool {
        item.dedupId.hasPrefix("tvbox:")
    }

    private var resumeText: String {
        if let h = library.historyEntry(for: item), h.progressSeconds > 30 {
            return "续播 \(Self.format(h.progressSeconds))"
        }
        return "立即播放"
    }

    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let d = item.directors, !d.isEmpty {
                row("导演", d.joined(separator: " / "))
            }
            if let a = item.actors, !a.isEmpty {
                castRow("主演", a)
            }
        }
        .padding(.horizontal, 16)
    }

    /// 主演行（可点：点演员名 → 该演员作品墙 —— 大牌标配，2026-09-22）。
    /// 2026-09-25 演员小头像（台账 247/258/288 行）：胶囊内 20pt 圆头像，
    /// persons.json 有图用 AsyncImage，无图回退姓名首字圆标——头像缺席不改变胶囊形态。
    private func castRow(_ label: String, _ names: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.footnote).foregroundStyle(theme.textSecondary)
                .frame(width: 34, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(names, id: \.self) { n in
                        NavigationLink { PersonWorksView(person: n, role: "主演") } label: {
                            // 2026-09-28 钦点：头像放大（56pt）+ 名字挪到头像下面（原 20pt 圆点+右侧小字看不清）
                            VStack(spacing: 5) {
                                CastAvatar(name: n, urlString: store.personAvatars[n])
                                Text(n)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .frame(maxWidth: 72)
                            }
                            .foregroundStyle(theme.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 演员头像（2026-09-28 放大到 56pt，名字移到下方）：有 persons.json 映射 → TMDB 头像；无 → 姓名首字。
    private struct CastAvatar: View {
        let name: String
        let urlString: String?
        @Environment(\.filmTheme) private var theme
        var body: some View {
            Group {
                if let s = urlString, !s.isEmpty, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            initialDot
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                } else {
                    initialDot
                }
            }
        }
        private var initialDot: some View {
            Text(String(name.prefix(1)))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 56, height: 56)
                .background(theme.card, in: Circle())
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.footnote).foregroundStyle(theme.textSecondary)
                .frame(width: 34, alignment: .leading)
            Text(value).font(.footnote).foregroundStyle(theme.textPrimary)
                .lineSpacing(3)
            Spacer(minLength: 0)
        }
    }

    private func summarySection(_ s: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("简介").font(.headline).foregroundStyle(theme.textPrimary)
            Text(s)
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(4)
                .lineLimit(summaryExpanded ? nil : 4)
            if s.count > 90 {
                Button(summaryExpanded ? "收起" : "展开") { summaryExpanded.toggle() }
                    .font(.caption).foregroundStyle(theme.accent)
            }
        }
        .padding(.horizontal, 16)
    }

    /// 选集分组：播放候选按线路（quality）分组，集名取 line.name。
    /// 电视剧多集 → 大牌式选集网格；电影单集多线路 → 线路切换。
    private var episodeGroups: [(line: String, eps: [(index: Int, name: String)])] {
        let lines = item.play?.lines ?? []
        // 2026-09-30 关键修复：面板里的 index 必须是这一集的 URL 在 **playCandidates** 里的下标
        // （PlayerViewModel.allLines == playCandidates + extraLines；而 playEpisode(_:) 就是拿这个下标
        // 去 allLines 取播放地址）。旧实现直接用 lines 的下标 —— 而 playCandidates 会**先塞 defaultURL
        // 再塞 lines**，只要条目带 defaultURL，两边下标就**整体错位一格**：点「第 1 集」实际播的是
        // defaultURL，点最后一集则越界被 `allLines.indices.contains` 拦掉 → 表现为「点不上 / 点错集」。
        // 正解＝按 URL 在 playCandidates 中定位；定位不到才回落 i。
        let cands = item.playCandidates
        var order: [String] = []
        var groups: [String: [(Int, String)]] = [:]
        for (i, l) in lines.enumerated() {
            let g = l.quality ?? "默认"
            if groups[g] == nil { order.append(g) }
            // 集名空串也兜底：CMS 线路 name 常为 ""（nil 已兜，空串此前漏兜 → 选集按钮没字）
            // ★ v66：中台 feed 的 lines 是**换源线路**（name/quality 恒空），此时兜底成
            //   「第N集」就是主人看到的「电视剧都是四集」的字面来源 → 改叫「线路N」。
            let n = (l.name?.isEmpty == false) ? l.name! : "线路\(i + 1)"
            let idx = URL(string: l.url).flatMap { u in cands.firstIndex(of: u) } ?? i
            groups[g, default: []].append((idx, n))
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// 是否电视剧：类型标记 tv，或**真分集**。
    /// 电影（contentType == "movie"）永不走选集：CMS 线路 quality 常为 nil，
    /// 多条线路全挤进"默认"组会被误判成多集（2026-09-20 真机反馈「电影是选集按钮」根因）。
    private var isTVItem: Bool {
        if item.contentType == "tv" { return true }
        if item.contentType == "movie" { return false }
        // v66：与 hasRealEpisodeList 同口径 —— 「条数 > 1」在中台数据里 = 多条换源线路（不是多集），
        // 只有带真集名才认作剧；否则按电影口径给「播放线路」入口。
        return hasRealEpisodeList
    }

    /// 换源池 = 片源自带线路（大源=中台源站名）+ 聚合外部源（各 CMS，去重）。带大源身份（v67）。
    private var allSourceLines: [SourceLine] {
        let s = (item.origin?.sourceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ownName = s.isEmpty ? "片源" : s
        var out = item.playCandidates.map { SourceLine(url: $0, source: ownName) }
        for e in extraSources where !out.contains(where: { $0.url == e.url }) { out.append(e) }
        return out
    }

    /// 按**大源**折叠（v67 换源分层，主人钦定「先换大源」）：
    /// [(大源名, 该大源第一条线路在换源池里的下标, 该大源的小源数)]，顺序 = 首次出现序。
    private var sourceChipGroups: [(name: String, firstIdx: Int, count: Int)] {
        var order: [String] = []
        var first: [String: Int] = [:]
        var cnt: [String: Int] = [:]
        for (i, l) in allSourceLines.enumerated() {
            let n = l.source.isEmpty ? "片源" : l.source
            if first[n] == nil { order.append(n); first[n] = i }
            cnt[n, default: 0] += 1
        }
        // ★ v69 源质量优先级（主人 2026-10-04「一定要把优先级搞好」）：
        //   按质量账本把「起播最快且最稳」的大源排到第一个 chip = 默认起播源 ——
        //   用户点开就是最快的那个源、秒播，后面的源根本不用换。
        //   无样本时 `orderedBrands` 原序返回 → chip 顺序与旧版 100% 一致（新装零回归）。
        let ordered = SourceQualityRank.shared.orderedBrands(order)
        return ordered.map { ($0, first[$0] ?? 0, cnt[$0] ?? 1) }
    }

    /// 默认起播线路下标 = 质量最优大源的第一条小源（无样本时 = 0，与旧版一致）。
    private var bestStartLineIndex: Int {
        sourceChipGroups.first?.firstIdx ?? 0
    }

    /// 详情页「播放源」：一行 chips，**一个大源一个 chip**（片名下挂它聚合到的各 CMS 源站），
    /// 点 chip = 用该大源的第一条小源起播（播放中可再一键轮大源 / 失败自动在同源内切小源）。
    private var sourceChipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("播放源（\(sourceChipGroups.count)）")
                    .font(.headline).foregroundStyle(theme.textPrimary)
                if aggregating {
                    Text("正在搜索更多源…").font(.caption2).foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(sourceChipGroups.enumerated()), id: \.offset) { idx, g in
                        Button {
                            lastEpName = nil
                            // 用户主动选源 = 明确「从头播这一条源」（不续播、不按历史跳集）。
                            ResumeTrace.note("pick·源chip 源\(idx + 1) line=\(g.firstIdx)")
                            playRequest = PlayRequest(resume: false, line: g.firstIdx)
                        } label: {
                            HStack(spacing: 5) {
                                // ★ v69 显示口径（主人 2026-10-04「不要出现名字网址之类的 只显示源1源2源3」）：
                                //   chip 只写「源N」，**不露源站名/网址**；N = 质量优先级顺位（源1 = 最快最稳，
                                //   也是点开默认起播的那个）。真实品牌仍留在 SourceLine.source 里给账本记账。
                                Text("源\(idx + 1)")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                if g.count > 1 {
                                    Text("\(g.count)线").font(.caption2)
                                        .foregroundStyle(theme.textSecondary)
                                }
                            }
                            .padding(.horizontal, 18).padding(.vertical, 11)
                            // ★ v60（主人 2026-10-04「源1 源2 也有框，但感觉不是纯玻璃、是深灰」）：
                            //   旧写法 `filmGlass()` 走**默认档 `.regular` = thinMaterial**，
                            //   而材质会把海报彩色底**去色** → 渲染出来就是一块深灰（v27 已定论：
                            //   只要还挂着材质，白度怎么调都还是灰的）。默认线路 accent 描边标出。
                            //   正解＝`.clear` 档（不挂任何材质、只叠极淡均匀白）→ 底色连同色相原样透出。
                            .filmGlass(cornerRadius: 999, tint: 0.08, strokeOpacity: 0.13, weight: .clear)
                            .overlay(Capsule().stroke(idx == 0 ? theme.accent.opacity(0.55) : .white.opacity(0.13), lineWidth: idx == 0 ? 1 : 0.5))
                            .foregroundStyle(idx == 0 ? theme.accent : theme.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 52)   // 横滚定高，防贪婪分屏
        }
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let groups = episodeGroups
            let group = groups[min(sourceIdx, groups.count - 1)]
            HStack(spacing: 10) {
                Text("选集（\(group.eps.count)）")
                    .font(.headline).foregroundStyle(theme.textPrimary)
                // ★ v78（主人 2026-10-05「我选了第几集 但是选集按钮上却不显示」）：
                //   表头直接写「当前：第N集」—— `lastEpName` 由「点选集格」写入、并由播放器
                //   切集时经 `onEpisodeChange` 回传更新，所以这里显示的恒是**当前这一集**。
                if let name = lastEpName {
                    Text("当前：\(name)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accent)
                }
                if groups.count > 1 {
                    // 大牌式一键换源：循环切换线路，选集网格随之刷新
                    // ★ v78.4：这里**只切网格展示的线路**（`sourceIdx`）。旧实现顺带写
                    //   `pendingLine = hit.index`，而本按钮并不起播 —— 那个写入会残留在 @State 里，
                    //   等下一次别的入口起播时被误当成「用户选的集」。起播一律由 `playRequest` 决定，
                    //   这里不再写任何起播状态。
                    Button {
                        sourceIdx = (sourceIdx + 1) % groups.count
                    } label: {
                        Label("换源 \(sourceIdx + 1)/\(groups.count)", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                ForEach(group.eps, id: \.index) { ep in
                    Button {
                        lastEpName = ep.name
                        // 用户主动选集 = 明确这一集，从头播（不续播、不被历史覆盖）。
                        ResumeTrace.note("pick·选集 \(ep.name) line=\(ep.index)")
                        playRequest = PlayRequest(resume: false, line: ep.index)
                    } label: {
                        Text(ep.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            // v60：选集格同线路 chips 口径 —— `.clear` 档（不挂材质、不去色），
                            // 旧默认档 thinMaterial 会把海报底洗成深灰（主人点名的同一类问题）。
                            .filmGlass(cornerRadius: 8, tint: 0.08, strokeOpacity: 0.13, weight: .clear)
                            // ★ v78：当前这一集描边用强调色加粗 —— 旧实现所有格子一模一样，
                            //   选完第几集在格子上完全看不出来（主人本次反馈的第一条）。
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(ep.name == lastEpName ? theme.accent : .white.opacity(0.13),
                                                lineWidth: ep.name == lastEpName ? 1.6 : 0.5))
                            .foregroundStyle(ep.name == lastEpName ? theme.accent : theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// 相关推荐：同聚合分类优先，其次分类标签交集；排除自身，最多 12 部。
    /// 只被 body 读取的**缓存**（不再现场全量扫描，见 `relatedCache` 声明处注释）。
    private var related: [FeedItem] { relatedCache }

    private func loadRelated() async {
        let key = "\(item.dedupId)|\(store.catalog.items.count)"
        guard relatedKey != key else { return }        // 同一部片 + 同一份目录 → 不重算
        relatedKey = key
        let snapshot = store.catalog.items
        let myDedup = item.dedupId
        let myAgg = item.aggregateCategoryId
        let myTags = Set(item.categories?.tags ?? [])
        let found = await Task.detached(priority: .utility) { () -> [FeedItem] in
            let others = snapshot.filter { $0.dedupId != myDedup && $0.bestPosterURL != nil }
            let sameAggregate = others.filter { $0.aggregateCategoryId != nil && $0.aggregateCategoryId == myAgg }
            var pool = Array(sameAggregate.prefix(12))
            if pool.count < 12 {
                let byTags = others.filter { other in
                    !pool.contains(where: { $0.dedupId == other.dedupId }) &&
                    !Set(other.categories?.tags ?? []).isDisjoint(with: myTags)
                }
                pool += byTags.prefix(12 - pool.count).map { $0 }
            }
            return pool
        }.value
        relatedCache = found
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            // 玻璃徽章（原型 `.shBadge`：white .10 + 1px 亮边），透出整页取色底
            .background(.white.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
            .foregroundStyle(.white.opacity(0.85))
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// 详情页「多源聚合」结果进程内缓存（35包）：
/// 相关推荐可连续下钻详情页，每进一页都对 4~6 个公网 CMS 源重发搜索 → 页页转圈 + 白耗流量。
/// 按 dedupId 缓存（空结果也缓存，避免反复空搜），轻量 FIFO 上限 80 条，进程内生命周期。
/// 标题归一（文件级纯函数，v69 并发聚合用）：并发子任务里不捕获 View 的 self。
/// ★ v69：小写 + 去空格/· + **去【】/（）/() 装饰段** —— CMS 源常给片名挂尾巴
///   （「揭秘日【影视解说】」「沙丘2(2024)」），不去掉会被精确匹配漏掉、白白少源。
///   只剥**第一个**装饰符号起的尾巴、不做模糊包含（「揭秘日历」绝不能撞上「揭秘日」）——宁缺勿错配。
private func detailTitleKey(_ s: String) -> String {
    var t = s.lowercased()
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "·", with: "")
    for mark in ["【", "（", "("] {
        if let r = t.range(of: mark) { t = String(t[..<r.lowerBound]) }
    }
    return t
}

@MainActor
final class AggregateCache {
    static let shared = AggregateCache()
    private var map: [String: [SourceLine]] = [:]
    private var order: [String] = []
    private let cap = 80
    private init() {}

    func get(_ key: String) -> [SourceLine]? { map[key] }

    func set(_ key: String, _ value: [SourceLine]) {
        if map[key] == nil { order.append(key) }
        map[key] = value
        while order.count > cap { map[order.removeFirst()] = nil }
    }
}
