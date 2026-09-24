import SwiftUI
import FilmCore

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
    private let incoming: FeedItem
    @EnvironmentObject private var library: UserLibrary
    @EnvironmentObject private var store: CatalogStore
    @Environment(\.filmTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showPlayer = false
    @State private var startAtResume = false
    @State private var pendingLine = 0      // 选集进入：目标集（playCandidates 下标）
    @State private var sourceIdx = 0        // 当前选集网格展示的线路（换源循环）
    @State private var lastEpName: String?  // 换源时保持同一集
    @State private var summaryExpanded = false
    @State private var refreshingPlay = false
    /// 详情页取色（2026-09-23 用户钦定原型 `home_v2.html` 详情浮层一比一搬真机）：
    /// 头图放大铺满 + 整页取色底色 + 浮动海报；取色与首页同源（`HeroTintStore` 缓存，不重复下载）。
    @State private var palette: HeroPalette = .fallback

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

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                infoSection
                actionButtons
                if let s = item.summary, !s.isEmpty { summarySection(s) }
                creditsSection
                // 电视剧 → 选集网格；电影 → 播放线路 chips（电影没有"选集"）
                if isTVItem {
                    if episodeGroups.contains(where: { $0.eps.count > 1 }) { episodesSection }
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
                                    // 显式 destination（同 PosterRail/PosterGrid）：详情页已是「深层推入页」，
                                    // value 路由在此解析失效 → 点相关推荐进的是别的片（用户实测 BUG，35包修）。
                                    // .id(dedupId) 再保一层：强制每个条目独立视图身份，@State 必重新初始化。
                                    NavigationLink {
                                        DetailView(item: rel).id(rel.dedupId)
                                    } label: {
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    library.toggleFavorite(item)
                } label: {
                    Image(systemName: library.isFavorite(item) ? "heart.fill" : "heart")
                        .foregroundStyle(library.isFavorite(item) ? theme.accent : .white)
                }
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreen(item: item, startAtResume: startAtResume,
                         startLine: pendingLine,
                         extraLines: extraSources,
                         onClose: { showPlayer = false },
                         episodeGroups: isTVItem ? episodeGroups : [],
                         onEpisodeChange: { lastEpName = $0 })
                .environment(\.colorScheme, .dark)   // 播放=视频层，恒深色
        }
        .task { await store.loadPersonAvatarsIfNeeded() }   // 演员小头像（2026-09-25）
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
        guard let fresh = await TVBoxSiteClient(site: site).detail(vodId: vodId),
              fresh.isPlayable else { return }
        liveItem = fresh
    }

    /// 55包：剧集分集兜底 —— 「不管内置源自定义源都得能显示选集」（用户钦定 2026-09-23）。
    /// 覆盖非 tvbox 条目（首页货架/搜索/收藏进来的剧）：没有分集数据时按片名
    /// 去内置剧集源搜同名，命中即整条替换（lines 带 2~3 线路 × N 集）。
    /// 只认「正统剧源」（tvDramaSources），三端共用该源，内容隔离红线不碰。
    private func refreshEpisodesFallback() async {
        let lines = item.play?.lines ?? []
        guard lines.count <= 1, !refreshingPlay else { return }   // 已有分集就不动
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
            let c = TVBoxSiteClient(site: site)
            let hits = await c.search(item.title)
            guard let match = hits.first(where: { normalizedTitle($0.title) == target }),
                  let ml = match.play?.lines, ml.count > 1 else { continue }
            liveItem = match
            return
        }
    }

    /// 片名是否像剧集（含「第N季/部/集」或「季」结尾等常见剧名特征）。
    private func looksLikeSeries(_ title: String) -> Bool {
        title.range(of: "第[0-9一二三四五六七八九十]+[季部集]", options: .regularExpression) != nil
            || title.hasSuffix("季") || title.contains("电视剧")
    }

    // MARK: - 多源聚合（换源池扩容）

    /// 打开详情页即后台聚合：按片名去其余 CMS 源搜同名片，
    /// 命中的播放线路并入换源池（TVBox 式聚合）。电影/电视剧通用。
    @State private var extraSources: [URL] = []
    @State private var aggregating = false

    private func aggregateSources() async {
        // 46包（用户：「还有切源呢怎么没了呢！」）：原来只在星幕（normal）聚合跨源线路，
        // 夜航/心屋的详情页从不聚合 → 单线路片子连「换源/切换线路」按钮都不出现。
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
        let target = normalizedTitle(item.title)
        guard !target.isEmpty else { return }
        // 46包：按端选聚合源池（成人源绝不进 normal/child 的池子——内容隔离红线不碰）
        let mode = store.profile.mode
        let pool: [TVBoxSite]
        switch mode {
        case "adult":
            pool = DefaultSites.builtinMixedVodSources + Array(DefaultSites.builtinAdultVodSources.prefix(6))
        case "child":
            pool = DefaultSites.builtinMixedVodSources
        default:
            pool = DefaultSites.tvDramaSources
        }
        var collected: [URL] = []
        for site in pool {
            let c = TVBoxSiteClient(site: site)
            let hits = await c.search(item.title)
            if let match = hits.first(where: { normalizedTitle($0.title) == target }) {
                for u in match.playCandidates where !collected.contains(u) {
                    collected.append(u)
                }
            }
        }
        extraSources = collected
        AggregateCache.shared.set(item.dedupId, collected)
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
                stageHaze           // 化雾层（真高斯模糊，只贴下沿）
                groundLayer         // 落地雾带（两端透明，无实色落点）
                sideVignette
                topScrim
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            headBlock                    // 浮动海报 + 衬线标题 + 大评分（上浮 104pt 咬进头图）
        }
    }

    /// 底图渐隐（主页 fadeLayer 同款）：海报下部逐步透明，化进整页取色背景。
    private var fadeLayer: some View {
        stagePoster
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0.00),
                .init(color: .black, location: 0.45),
                .init(color: .black.opacity(0.55), location: 0.72),
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

    private func stageImage(blur: CGFloat) -> some View {
        GeometryReader { geo in
            PosterImage(urlString: (item.bestBackdropURL ?? item.bestPosterURL)?.absoluteString,
                        cornerRadius: 0, contentMode: .fill)
                .scaleEffect(1.26)                       // 原型 transform:scale(1.26)
                .saturation(1.06).brightness(-0.08)      // 原型 filter:saturate(1.06) brightness(.92)
                // 2026-09-24 23:22 用户指令（与主页同）：顶部对齐不裁头，裁切全落底部雾化区
                .frame(width: geo.size.width, height: geo.size.height * 1.25, alignment: .top)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                .blur(radius: blur)
        }
    }

    private var stagePoster: some View { stageImage(blur: 0) }

    /// 底部高斯雾带：与主页 hazeLayer 同参数（2026-09-24 23:23 用户指令：只贴最底边，不糊海报本体）。
    private var stageHaze: some View {
        stageImage(blur: 9)
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: 0.86),
                .init(color: .black, location: 0.94),
                .init(color: .black, location: 0.985),
                .init(color: .clear, location: 1.00)
            ], startPoint: .top, endPoint: .bottom))
    }

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
                    startAtResume = library.historyEntry(for: item)?.progressSeconds ?? 0 > 30
                    showPlayer = true
                } else if canRefreshPlay {
                    // 兜底：补拉成功就地开播，失败 toast 提示（不再永久灰死）
                    Task {
                        await refreshTVBoxPlay()
                        if item.isPlayable {
                            startAtResume = false
                            showPlayer = true
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
                HStack(spacing: 6) {
                    ForEach(names, id: \.self) { n in
                        NavigationLink { PersonWorksView(person: n, role: "主演") } label: {
                            HStack(spacing: 5) {
                                CastAvatar(name: n, urlString: store.personAvatars[n])
                                Text(n).font(.footnote).lineLimit(1)
                            }
                            .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 3)
                            .background(theme.card, in: Capsule())
                            .foregroundStyle(theme.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 演员小头像圆标：有 persons.json 映射 → TMDB 头像；无 → 姓名首字。
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
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
                } else {
                    initialDot
                }
            }
        }
        private var initialDot: some View {
            Text(String(name.prefix(1)))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 20, height: 20)
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
        var order: [String] = []
        var groups: [String: [(Int, String)]] = [:]
        for (i, l) in lines.enumerated() {
            let g = l.quality ?? "默认"
            if groups[g] == nil { order.append(g) }
            // 集名空串也兜底：CMS 线路 name 常为 ""（nil 已兜，空串此前漏兜 → 选集按钮没字）
            let n = (l.name?.isEmpty == false) ? l.name! : "第\(i + 1)集"
            groups[g, default: []].append((i, n))
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// 是否电视剧：类型标记 tv，或多线路多集。
    /// 电影（contentType == "movie"）永不走选集：CMS 线路 quality 常为 nil，
    /// 多条线路全挤进"默认"组会被误判成多集（2026-09-20 真机反馈「电影是选集按钮」根因）。
    private var isTVItem: Bool {
        if item.contentType == "tv" { return true }
        if item.contentType == "movie" { return false }
        return episodeGroups.contains(where: { $0.eps.count > 1 })
    }

    /// 电影换源池 = 自带线路 + 聚合外部源（去重）。
    private var allSourceLines: [URL] {
        item.playCandidates + extraSources.filter { !item.playCandidates.contains($0) }
    }

    /// 电影的「播放线路」：一行 chips（只显示「源N」，用户钦定 2026-09-23：地址去掉，字号加大）。
    private var sourceChipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("播放线路（\(allSourceLines.count)）")
                    .font(.headline).foregroundStyle(theme.textPrimary)
                if aggregating {
                    Text("正在搜索更多源…").font(.caption2).foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(allSourceLines.enumerated()), id: \.offset) { idx, _ in
                        Button {
                            pendingLine = idx
                            lastEpName = nil
                            startAtResume = false
                            showPlayer = true
                        } label: {
                            Text("源\(idx + 1)")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18).padding(.vertical, 11)
                            .background(theme.card, in: Capsule())
                            .foregroundStyle(theme.textPrimary)
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
                if groups.count > 1 {
                    // 大牌式一键换源：循环切换线路，选集网格随之刷新
                    Button {
                        sourceIdx = (sourceIdx + 1) % groups.count
                        // 换源后保持在"同一集"：按集名在新线路里对位
                        if let name = lastEpName,
                           let hit = groups[sourceIdx].eps.first(where: { $0.name == name }) {
                            pendingLine = hit.index
                        }
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
                        pendingLine = ep.index
                        lastEpName = ep.name
                        startAtResume = false
                        showPlayer = true
                    } label: {
                        Text(ep.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// 相关推荐：同聚合分类优先，其次分类标签交集；排除自身，最多 12 部。
    private var related: [FeedItem] {
        let others = store.catalog.items.filter { $0.dedupId != item.dedupId && $0.bestPosterURL != nil }
        let sameAggregate = others.filter { $0.aggregateCategoryId != nil && $0.aggregateCategoryId == item.aggregateCategoryId }
        var pool = Array(sameAggregate.prefix(12))
        if pool.count < 12 {
            let myTags = Set(item.categories?.tags ?? [])
            let byTags = others.filter { other in
                !pool.contains(where: { $0.dedupId == other.dedupId }) &&
                !Set(other.categories?.tags ?? []).isDisjoint(with: myTags)
            }
            pool += byTags.prefix(12 - pool.count).map { $0 }
        }
        return pool
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
@MainActor
final class AggregateCache {
    static let shared = AggregateCache()
    private var map: [String: [URL]] = [:]
    private var order: [String] = []
    private let cap = 80
    private init() {}

    func get(_ key: String) -> [URL]? { map[key] }

    func set(_ key: String, _ value: [URL]) {
        if map[key] == nil { order.append(key) }
        map[key] = value
        while order.count > cap { map[order.removeFirst()] = nil }
    }
}
