import SwiftUI
import FilmCore

/// App 主框架：首页 / 分类 / 搜索 / 直播（可选）/ 我的。
/// 触控适配：大 Tab 图标 + 安全区域；直播 Tab 按产品档案显隐（心屋无直播）。
public struct MainTabView: View {
    let profile: ProductProfile
    @EnvironmentObject private var store: CatalogStore
    @EnvironmentObject private var library: UserLibrary
    @Environment(\.filmTheme) private var theme
    @State private var selection = 0
    /// 外观档位（跟随系统 / 深色 / 浅色）—— 2026-09-22 起不再锁死深色
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    public init(profile: ProductProfile) {
        self.profile = profile
    }

    public var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                HomeView(profile: profile)
                    .navigationDestination(for: FeedItem.self) { DetailView(item: $0) }
            }
            .tabItem { Label("首页", systemImage: "house.fill") }
            .tag(0)

            NavigationStack {
                CategoryBrowseView()
                    .navigationDestination(for: FeedItem.self) { DetailView(item: $0) }
            }
            .tabItem { Label("分类", systemImage: "square.grid.2x2.fill") }
            .tag(1)

            NavigationStack {
                SearchView()
                    .navigationDestination(for: FeedItem.self) { DetailView(item: $0) }
            }
            .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            .tag(2)

            if let livePath = profile.liveM3UPath {
                NavigationStack {
                    LiveView(profile: profile, livePath: livePath)
                        .environment(\.colorScheme, .dark)   // 直播=视频层，恒定深色（不污染全局外观）
                }
                .tabItem { Label("直播", systemImage: "dot.radiowaves.left.and.right") }
                .tag(3)
            }

            NavigationStack {
                LibraryView()
                    .navigationDestination(for: FeedItem.self) { DetailView(item: $0) }
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
            .tag(4)
        }
        .tint(theme.accent)
        .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.colorScheme)
        // 直播页点「返回」= 真退出：停播 + 跳回首页（防后台出声）
        .onReceive(NotificationCenter.default.publisher(for: .liveExitToHome)) { _ in
            selection = 0
        }
        // 直播页「去添加直播源」= 切到「我的」tab（LibraryView 收到后推设置页）
        .onReceive(NotificationCenter.default.publisher(for: .openAppSettings)) { _ in
            selection = 4
        }
        // 设置页「加完直播源」= 直接切到直播 tab 看效果（心屋无直播 tab，忽略）
        // 用户报「直播添加以后也不知道怎么看」→ 加完必须直接带过去看，不让用户自己找
        .onReceive(NotificationCenter.default.publisher(for: .openLiveTab)) { _ in
            if profile.liveM3UPath != nil { selection = 3 }
        }
        // 57包（用户：「继续播放这个小横条有点烦人」）：底部迷你播放悬浮条整块移除。
        // 续播入口保留在首页「继续观看」货架（海报+进度条），不丢功能只去浮条。
    }

    // 57包：底部迷你播放悬浮条整块移除（用户：「继续播放这个小横条有点烦人」）。
    // 续播入口保留在首页「继续观看」货架（海报+进度条）。
}

/// 直播退出通知（LiveView → MainTabView 切回首页）。
extension Notification.Name {
    public static let liveExitToHome = Notification.Name("live.exitToHome")
    /// 打开设置（直播页空态/换源引导 → 我的 tab 内推设置页）。
    public static let openAppSettings = Notification.Name("app.openSettings")
    /// 跳到直播 tab（设置页添加直播源成功后 → 直接带用户去看）。
    public static let openLiveTab = Notification.Name("app.openLiveTab")
}

/// 首页：hero 大图 → 继续观看 → 热门推荐 → 新片速递 → 分类快捷入口 → 片库统计。
public struct HomeView: View {
    let profile: ProductProfile
    @EnvironmentObject private var store: CatalogStore
    @EnvironmentObject private var library: UserLibrary
    @Environment(\.filmTheme) private var theme

    public init(profile: ProductProfile) { self.profile = profile }

    /// 主视觉取色（整页背景跟着当前海报变色）。算法见 `HeroTint.swift`（自原型一比一移植）。
    @State private var heroPalette: HeroPalette = .fallback
    /// 屏宽（用于主视觉高度按比例算，避免 iPad/小屏比例走形）。
    @State private var screenWidth: CGFloat = 390

    /// 主视觉高度：原型 470pt @ 394pt 宽 → 屏宽 ×1.19，钳 400–560。
    private var heroHeight: CGFloat { max(400, min(560, screenWidth * 1.19)) }

    /// 整页背景（2026-09-23 四改·用户「下面完全没变化」根治）：
    /// ① **全页底色 = 落地色 deep×0.66** —— 不是只有上半截有颜色，整页（货架区也一样）都跟着海报取色；
    /// ② 顶部叠原型同款椭圆光晕 `radial-gradient(150% 72% at 50% -10%)`（SwiftUI RadialGradient 是正圆 →
    ///    圆 + Y 轴缩放得同款椭圆），62% 处就落到底色并保持不变 →
    ///    hero 落地雾带（同为 deep×0.66）无论滚到哪里都落在同色上，横线在结构上不可能出现。
    private var heroBackground: some View {
        let p = heroPalette
        let ground = p.deep.scaled(0.66).color
        return ZStack {
            ground
            GeometryReader { g in
                let rx = g.size.width * 1.5
                let ry = g.size.height * 0.72
                Circle()
                    .fill(RadialGradient(stops: [
                        .init(color: p.glow.alpha(0.70), location: 0.00),
                        .init(color: p.mid.alpha(0.86), location: 0.30),
                        .init(color: ground, location: 0.58),
                        .init(color: ground, location: 1.00)
                    ], center: .center, startRadius: 0, endRadius: rx))
                    .frame(width: rx * 2, height: rx * 2)
                    .scaleEffect(x: 1, y: ry / rx, anchor: .center)
                    .position(x: g.size.width / 2, y: -g.size.height * 0.10)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.9), value: heroPalette)
    }

    /// 大牌式搜索栏（2026-09-23 用户指令）：
    /// 一进首页就是一条通栏搜索胶囊（放大镜 + 提示词 + 「热搜」角标），点它进搜索页
    /// （搜索页本就有 热搜榜 / 历史 / 即时结果，见 `SearchView`），而不是只在右上角放个小放大镜。
    private var searchEntry: some View {
        NavigationLink { SearchView() } label: {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text("搜索片名 · 演员 · 导演")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                Text("热搜")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(theme.textPrimary.opacity(0.14), in: Capsule())
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            // 2026-09-23 用户两次点名：「货架背景颜色能不能透明化」「搜索框也跟可视化不一样是黑色条」
            // → 实色 theme.card 改**亮玻璃**：原型 `.searchBar` = rgba(255,255,255,.10) + 1px 亮边。
            //   注意不能用 .ultraThinMaterial（深色模式下它自己就是一层黑膜，看着还是黑条）。
            .background(Capsule().fill(.white.opacity(0.10)))
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .bootingFromHome:
                HomeSkeletonView()      // 大牌做法：骨架屏替代转圈（2026-09-22）
            case .failed(let msg):
                ErrorStateView(message: msg) { Task { await store.boot() } }
            case .ready, .syncing:
                content
            }
        }
        .background(heroBackground)
        .background(
            // 量一次屏宽（主视觉高度按比例；全铺时宽度=屏宽）
            GeometryReader { g in
                Color.clear
                    .onAppear { screenWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in if w > 0 { screenWidth = w } }
            }
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 顶部 LOGO 字标（奈飞式：加粗圆体 + 字距 + 主题色）
            ToolbarItem(placement: .principal) {
                Text(profile.logoName)
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .kerning(2.5)
                    .foregroundStyle(theme.accent)
                    .textCase(.uppercase)
            }
            // 右上角：观看历史 + 今天日期（X月X日·周X）+ 设置齿轮（大牌式右上功能区）
            // 60包（用户：「没有继续播放是不是少个历史按钮？」）：57包删掉迷你播放条后首页没有
            // 直达历史的入口 → 右上角补一个「历史」时钟按钮，一键进完整历史页（续播/删除/清空）。
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    NavigationLink { HistoryView() } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.body).foregroundStyle(theme.textPrimary)
                    }
                    Text(todayLabel).font(.caption).foregroundStyle(theme.textSecondary)
                    NavigationLink { SettingsView() } label: {
                        Image(systemName: "gearshape").font(.body).foregroundStyle(theme.textPrimary)
                    }
                }
            }
        }
    }

    private var todayLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f.string(from: Date())
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // 2026-09-23 用户：「片库同步那个加载能不能隐藏 因为那个地方现在放搜索栏了」
                // → 顶部「片库同步中」进度条撤掉（首屏仍有骨架屏兜底，不丢反馈）。
                searchEntry                      // 大牌式搜索栏（2026-09-23 用户指令）
                channelNav                       // 顶部频道导航（大牌式：推荐 + 聚合分类横滑）
                if !shelvesCache.hero.isEmpty {
                    // 主视觉：全铺 + 整页背景跟着海报取色 + 左右键 + 衬线标题
                    // （2026-09-23 用户钦定搬真机：原型 `home_proto.html` 用户看过并点头）
                    HeroCarousel(items: shelvesCache.hero,
                                 logoName: profile.logoName,
                                 height: heroHeight,
                                 palette: $heroPalette)
                }
                // 「继续观看」必须等主视觉就位再出现（2026-09-23 用户：「打开APP继续观看直接三个
                // 明晃晃的出现在搜索栏下方 主页加载出来才消失」）：货架计算是后台异步的，主视觉
                // 未就位时若先画本行，会顶在搜索栏下方闪一下又跳走 → 以 hero 就位为本行的出现条件。
                if !shelvesCache.hero.isEmpty && !library.history.isEmpty { continueWatchingRail }
                // 货架计划由 HomePolicy 统一给出（名称 = 内容口径），逐排渲染。
                // 2026-09-23 用户：「我不管几个货架都行但是你要按照货架名称给出对应的片啊！」
                ForEach(Array(shelvesCache.rails.enumerated()), id: \.offset) { _, rail in
                    PosterRail(title: rail.title, items: rail.items)
                }
            }
            .padding(.vertical, 8)
        }
        .refreshable { await store.syncAll() }
        // 货架缓存重建：catalog 赋值（boot/sync/快照兜底，低频）才触发；主线程零全量计算（34包）
        .onReceive(store.$catalog) { _ in rebuildShelves() }
        .onAppear { if shelvesCache.hero.isEmpty, !store.catalog.items.isEmpty { rebuildShelves() } }
    }

    // MARK: - 区块

    /// 顶部频道导航：**榜单 → 推荐 →（星幕专属「电视剧」）→ 聚合分类横滑 → 全部分类**。
    ///
    /// 2026-09-23 用户指令：「我还有分类这个顺序我觉得也不对啊 第一个不应该是榜单吗？第二个是推荐啊」
    /// → 榜单从第四格提到首格（大牌惯例也是榜单打头），推荐紧随其后。
    /// 2026-09-24 用户指令：分类后面的数字难看，去掉。
    private var channelNav: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                // ① 榜单（大牌标配：热播/高分/新片三榜）—— 用户钦定排第一。
                NavigationLink { TopListView() } label: {
                    chipLabel("榜单", isActive: false)
                }
                .buttonStyle(.plain)
                // ② 推荐（首页本页 = 当前选中态，故 isActive: true）。
                channelChip("推荐", isActive: true, destination: nil)
                // ③ 电视剧（星幕专属独立通道，自家片库优先）。
                if profile.mode == "normal" {
                    NavigationLink { TVSeriesView() } label: {
                        chipLabel("电视剧", isActive: false)
                    }
                    .buttonStyle(.plain)
                }
                // ④ 聚合分类（归并后大类，按条目数降序全量展示，不截断）。
                ForEach(navGroups) { g in
                    channelChip(g.title, isActive: false,
                                destination: CategoryBrowseView(initialGroup: g.id))
                }
                if store.catalog.categories.count > 0 {
                    NavigationLink { CategoryIndexView() } label: {
                        chipLabel("全部分类", isActive: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// 导航用大类：归并后按条目数降序（热门在前），全量不截断。
    private var navGroups: [NavCatalog.Group] {
        let g = NavCatalog.groups(categories: store.catalog.categories,
                                  mode: TVBoxConfigStore.currentProductMode())
            .filter { $0.count > 0 }
        // 2026-09-23 用户：「分类里居然弄出两个电视剧！」——星幕顶部已有「电视剧」独立通道
        // （TVSeriesView，自家片库优先），归并大类里若再列一次就是同屏两个同名入口 → normal 端剔除。
        // 其他端（心屋/夜航）没有独立通道，保持原样。
        let deduped = profile.mode == "normal" ? g.filter { $0.title != "电视剧" } : g
        return deduped.sorted { $0.count > $1.count }
    }

    @ViewBuilder
    private func channelChip(_ name: String, isActive: Bool,
                             destination: CategoryBrowseView?) -> some View {
        Group {
            if let destination {
                NavigationLink { destination } label: { chipLabel(name, isActive: isActive) }
                    .buttonStyle(.plain)
            } else {
                chipLabel(name, isActive: isActive)
            }
        }
    }

    private func chipLabel(_ name: String, isActive: Bool) -> some View {
        Text(name).font(.subheadline.weight(isActive ? .bold : .medium)).lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 8)
            // 2026-09-23 用户钦定：分类胶囊玻璃化，**选中态也是玻璃**（white .22 + 亮边，不要白底）
            .background {
                if isActive {
                    Capsule().fill(.white.opacity(0.22))
                        .overlay(Capsule().stroke(.white.opacity(0.36), lineWidth: 1))
                } else {
                    Capsule().fill(.white.opacity(0.09))
                }
            }
            .foregroundStyle(isActive ? Color.white : theme.textPrimary)
    }

    // MARK: - 货架统一计算（口径全部下沉到 HomePolicy，本处只做「取片 + 去重 + 截断」）

    /// 首页全部货架一次性计算（2026-09-23 重写）：
    /// 1) 选片口径（热门=真热度、高分=真评分、电影/电视剧=内容类型）统一在 `HomePolicy`，
    ///    与 `scripts/check_home_shelves.py` 机检脚本逐字对齐；
    /// 2) 跨货架去重按**系列键**（同剧不同季、同片不同语言/画质版本只出一部）；
    /// 3) 主视觉 15 部，仅电影/电视剧，排除动漫与黑名单。
    private struct HomeShelves {
        var hero: [FeedItem] = []
        var rails: [(title: String, items: [FeedItem])] = []
    }

    /// 货架缓存（34包）：原 shelves 是计算属性——每次 body 求值都对 13 万条全量 filter+sort，
    /// 且 syncing 进度每次刷新都重算 → 启动后持续卡。改为 catalog 变化时后台算一次缓存。
    @State private var shelvesCache = HomeShelves()

    private func rebuildShelves() {
        let items = store.catalog.items
        let cats = store.catalog.categories
        let mode = TVBoxConfigStore.currentProductMode()
        Task.detached(priority: .userInitiated) {
            let s = Self.computeShelves(items: items, categories: cats, mode: mode)
            await MainActor.run {
                shelvesCache = s
                // 首屏海报预热：主视觉 15 张先进缓存，滑到即显（34包）
                PosterLoader.shared.prefetch(s.hero.compactMap { $0.bestPosterURL?.absoluteString })
            }
        }
    }

    private static func computeShelves(items allItems: [FeedItem],
                                       categories allCats: [FeedCategoryStat],
                                       mode: String) -> HomeShelves {
        var out = HomeShelves()
        var used = Set<String>()
        // 消费式取片：同一系列键在首页只出现一次（同剧不同季/不同版本不重复占位）
        func take(_ items: [FeedItem], _ n: Int) -> [FeedItem] {
            var arr: [FeedItem] = []
            for it in items where arr.count < n {
                if used.insert(HomePolicy.seriesKey(it)).inserted { arr.append(it) }
            }
            return arr
        }

        // 主视觉轮播：仅电影/电视剧，排除动漫/黑名单；**优先近 3 年真热门**（否则纯按年份会
        // 让一堆没人认识的冷门新剧霸屏），不足 15 部再按年份新→旧补齐。
        let cur = Calendar.current.component(.year, from: Date())
        let heroBase = allItems.filter {
            HomePolicy.allowsOnHome($0, mode: mode) && ($0.contentType == "movie" || $0.contentType == "tv")
        }
        let heroRecent = heroBase.filter {
            HomePolicy.effectiveYear($0) >= cur - 2 && HomePolicy.votes($0) >= 500
        }
        var heroPool = heroRecent.sorted { HomePolicy.votes($0) > HomePolicy.votes($1) }
        if heroPool.count < 15 {
            heroPool += heroBase.sorted { HomePolicy.effectiveYear($0) > HomePolicy.effectiveYear($1) }
        }
        out.hero = take(heroPool, 15)

        // 主题货架：名字与口径由 HomePolicy 定义；不足最小条数不成排（避免空排）
        for spec in HomePolicy.shelves(forMode: mode) {
            let picked = take(HomePolicy.rank(spec.rule, pool: allItems, mode: mode), HomePolicy.shelfSize)
            if picked.count >= HomePolicy.minShelfItems {
                out.rails.append((title: spec.title, items: picked))
            }
        }
        return out
    }

    /// 继续观看：海报 + 底部观看进度条（大牌式续播识别）。
    private var continueWatchingRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("继续观看").font(.headline).foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(library.history.prefix(20).enumerated()), id: \.element.id) { _, entry in
                        NavigationLink(value: entry.item) {
                            VStack(alignment: .leading, spacing: 5) {
                                PosterImage(urlString: entry.item.bestPosterURL?.absoluteString)
                                    .frame(width: 108, height: 160)
                                    .cornerRadius(10)
                                    .overlay(alignment: .bottom) {
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                Rectangle().fill(.white.opacity(0.25))
                                                Rectangle().fill(theme.accent)
                                                    .frame(width: geo.size.width * min(1, entry.progressSeconds / max(entry.durationSeconds, 1)))
                                            }
                                        }
                                        .frame(height: 3)
                                        .clipShape(Capsule())
                                        .padding(.horizontal, 6).padding(.bottom, 6)
                                    }
                                Text(entry.item.title).font(.caption2)
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
        // ★ 模糊嵌入咬合（2026-09-23 用户点头原型）：整块上浮 54pt，
        //   让「继续观看」从主视觉底部那片化雾里长出来（外层 VStack spacing 22 → 22 - 76 = -54）。
        .padding(.top, -76)
    }

}

/// 主视觉单帧（2026-09-23 按用户点名通过的**可点原型** `home_v2.html` 一比一搬真机）：
/// ① 海报**全铺**（cover 大图，不再缩成小卡）；② 底部**化成雾** —— 同一张海报高斯模糊 + 渐隐蒙版，
/// 末端精确落到**与页面背景同色**（原型里那条"横线"就是这么消掉的，根因是底部落色≠页面底色）；
/// ③ **衬线标题**（用户钦定：eyebrow + 片名 + 细金线 + 年份/地区/评分 + 圆点）。
struct HeroSlide: View {
    let item: FeedItem
    let logoName: String
    let height: CGFloat
    let palette: HeroPalette
    let pageIndex: Int
    let pageCount: Int
    @Environment(\.filmTheme) private var theme

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear         // ① 不铺实底（2026-09-23 二改）：
                                //   原 `theme.background` 会让 hero 矩形内是主题底色，与页面取色背景不同色
                                //   → hero 底边/顶边各出现一条边界线。改透明 = 透明处直接透出页面取色背景。
            fadeLayer          // ② 底图（底部渐隐到全透明，无硬边）
            hazeLayer          // ③ 化雾层（真高斯模糊，只在下段显形）
            groundLayer        // ④ 落地雾带（两端都是透明的取色雾，不再有实色落点）
            topScrim           // ⑤ 顶部压暗（取色系，与页面背景同源）
            titleBlock         // ⑥ 衬线标题
        }
        .frame(height: height)
        .clipped()
    }

    // MARK: 图层

    /// 海报层：`blur = 0` 是底图，`blur = 9` 是化雾层（同一张图，走 PosterLoader 缓存，不重复下载）。
    /// 2026-09-24 23:22 用户指令：「主视觉海报怎么总是把顶部裁切成半个人或头，不能以顶部显示吗？下面地方那么多」
    /// → **顶部对齐**：海报顶部与容器顶对齐（人物头部完整），裁切全部落在底部（雾化带盖住）。
    /// frame 仍高 1.30h：多出的 0.30h 是给 blur 雾带的采样余量（blur 需要图像延伸出容器边界）。
    private func poster(blur: CGFloat) -> some View {
        GeometryReader { geo in
            PosterImage(urlString: item.bestPosterURL?.absoluteString, cornerRadius: 0, contentMode: .fill)
                .frame(width: geo.size.width, height: geo.size.height * 1.30, alignment: .top)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                .blur(radius: blur)
        }
    }

    private var fadeLayer: some View {
        poster(blur: 0)
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0.00),
                .init(color: .black, location: 0.40),
                .init(color: .black.opacity(0.72), location: 0.62),
                .init(color: .black.opacity(0.24), location: 0.82),
                .init(color: .clear, location: 1.00)
            ], startPoint: .top, endPoint: .bottom))
    }

    private var hazeLayer: some View {
        poster(blur: 9)
            .mask(LinearGradient(stops: [
                // 2026-09-24 23:23 用户指令：「雾化最边缘尽量不要雾化海报本身」
                // → 雾带收窄到只贴底边 ~14%（原 0.70 起雾盖了 30%，把海报下段糊掉了）。
                // 海报现在顶对齐且图像延伸出容器底部，本无硬边；雾带只做最后的柔和过渡。
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: 0.86),
                .init(color: .black, location: 0.94),
                .init(color: .black, location: 0.985),
                .init(color: .clear, location: 1.00)
            ], startPoint: .top, endPoint: .bottom))
    }

    /// 底部落地雾带（2026-09-23 二改）：**两端都是透明**，不再落实色。
    ///
    /// 上一版落"实色 deep×0.74"去凑页面底色 —— 但真机页面底色来自 `heroBackground` 的径向渐变，
    /// 半径随屏宽变化，落色永远对不齐 → 用户实测真机仍看得见一条横线。
    /// 现改为：hero 内部**不出现任何实色边界**，一律渐隐到 clear 直接透出页面取色背景，
    /// 结构上保证接缝零色差（判据脚本 `scripts/check_hero_seam.py`）。
    /// 底部落地雾带（2026-09-23 三改·**回到原型 fadeBot**）：底边 deep×0.74 不透明 → 38% 高度处 mid α.52 → 顶端透明。
    /// 二改把它改成"全透明"是矫枉过正——这条取色雾带就是用户点名的「背景颜色跟随」的主体，删掉=删功能
    /// （原型 `linear-gradient(to top, deep×.74 0%, mid .52 38%, transparent 100%)` 一比一）。
    /// 横线的真正杜绝方式：页面径向渐变外圈停色同步改成 deep×0.74（见 `heroBackground`），两侧同色无接缝。
    /// 底部落地雾带（2026-09-23 四改·**落地色与整页底色同值**）：底边 deep×0.66 → 38% 高度处 mid α.52 → 顶端透明。
    /// 横线根因 = 落地色 ≠ 页面同位置颜色：现在整页底色就是 deep×0.66（见 `heroBackground`），
    /// 落地带末端与页面同色，任何滚动位置都无色差（机检 `scripts/check_hero_seam.py` INV-3 同色判据）。
    /// 底部雾带（2026-09-24 六改·**两端透明，去实色落地**）。
    ///
    /// 横线真根因（2026-09-24 22:50 真机像素取证）：落地实色 deep×0.66 压在 hero 底部，
    /// 而整页背景是径向渐变——**轮播换页时**新海报取色雾带与页面背景渐变存在一段不同步
    /// 色差（实测 y≈860 处 RGB(22,13,8) 暖棕 vs RGB(22,27,18) 绿灰，50px 内硬过渡），
    /// 相邻页把实色雾带带出页面中央区，色差暴露成用户点名的「海报底边横线」。
    /// 原型没这问题是因为原型没有轮播；真机 TabView 相邻页必须有结构性无缝。
    ///
    /// 改法：雾带两端 clear（中段 mid 取色雾保留「化雾」视觉），hero 底部完全透明 →
    /// 透出的只有整页背景（唯一色源），静态/滑动/换页任何时刻都零色差。
    /// 「背景跟随海报变色」由整页 heroBackground 承担（全页 ground + 顶部光晕，不删功能）。
    private var groundLayer: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0.00),
            .init(color: .clear, location: 0.50),
            .init(color: palette.mid.alpha(0.42), location: 0.74),
            .init(color: palette.mid.alpha(0.16), location: 0.92),
            .init(color: .clear, location: 1.00)
        ], startPoint: .top, endPoint: .bottom)
    }

    /// 顶部压暗（2026-09-24 六改）：mid 取色实色顶与页面光晕在换页时有同样的色相差 →
    /// 改**黑色低α**只做压暗（放状态栏/LOGO），不引入第三种色相，任何背景上都无边界感。
    private var topScrim: some View {
        LinearGradient(colors: [.black.opacity(0.30), .clear],
                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.15))  // 原型 fadeTop 高 15%
    }

    // MARK: 衬线标题

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(logoName) · \(item.displayYear ?? "")")
                .font(.system(size: 9, weight: .semibold))
                .kerning(4.4)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.55))
            Text(item.title)
                .font(.custom("Songti SC", size: 27))       // 宋式衬线（用户钦定「标题就要衬线」）
                .kerning(3)
                .lineLimit(2)
                .foregroundStyle(.white)
                .padding(.top, 7)
            LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 44, height: 1)
                .padding(.top, 10)
                .padding(.bottom, 9)
            Text(metaText)
                .font(.system(size: 10.5))
                .kerning(1.8)
                .foregroundStyle(.white.opacity(0.62))
            dots
                .padding(.top, 13)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 116)         // 抬高标题，给下方「继续观看」留咬合位（原型 bottom:116pt；96 时标题与货架贴太近）
        .shadow(color: .black.opacity(0.5), radius: 12)
        .allowsHitTesting(false)       // 标题不吃点击，整帧照旧可点进详情
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(0..<pageCount, id: \.self) { i in
                Capsule()
                    .fill(i == pageIndex ? Color.white : Color.white.opacity(0.28))
                    .frame(width: i == pageIndex ? 22 : 5, height: 5)
                    .animation(.easeInOut(duration: 0.25), value: pageIndex)
            }
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if let y = item.displayYear, !y.isEmpty { parts.append(y) }
        if let a = item.area, !a.isEmpty { parts.append(a) }
        if let c = item.aggregateCategoryName, !c.isEmpty { parts.append(c) }
        let score = HomePolicy.rating(item)      // 有真评分才显示（源站假分一律不显示）
        if score > 0 { parts.append(String(format: "豆瓣 %.1f", score)) }
        return parts.joined(separator: "　·　")
    }
}

/// 主视觉轮播（2026-09-23 改版，用户看过原型点头）：
/// 整屏全铺 + 整页背景跟着海报取色 + 左右键 + 5 秒自动翻页 + 顶部可点进详情。
struct HeroCarousel: View {
    let items: [FeedItem]
    let logoName: String
    let height: CGFloat
    @Binding var palette: HeroPalette
    @State private var index = 0
    @Environment(\.filmTheme) private var theme

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                NavigationLink(value: item) {
                    HeroSlide(item: item, logoName: logoName, height: height,
                              palette: palette, pageIndex: i, pageCount: items.count)
                }
                .buttonStyle(.plain)
                .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: height)
        .overlay(alignment: .leading) { arrow("chevron.left") { step(-1) } }
        .overlay(alignment: .trailing) { arrow("chevron.right") { step(1) } }
        .task { await loadPalette() }
        .onChange(of: index) { _, _ in Task { await loadPalette() } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            guard items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                index = (index + 1) % items.count
            }
        }
        // 货架换内容后 index 可能越界 → TabView 选中不存在的 tag 会黑屏，钳回合法范围（35包）
        .onChange(of: items.count) { _, n in
            if n == 0 { index = 0 } else if index >= n { index = n - 1 }
        }
    }

    private func arrow(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .offset(y: -height * 0.05)
        .opacity(items.count > 1 ? 1 : 0)
    }

    private func step(_ d: Int) {
        guard items.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            index = (index + d + items.count) % items.count
        }
    }

    /// 当前帧取色 → 交给首页整页背景（同一张海报只算一次，走 `HeroTintStore` 缓存）。
    @MainActor
    private func loadPalette() async {
        guard items.indices.contains(index) else { return }
        let p = await HeroTintStore.shared.palette(for: items[index].bestPosterURL?.absoluteString)
        HeroTintStore.shared.current = p          // 2026-09-23：广播给分类页/详情页做整页取色底
        withAnimation(.easeInOut(duration: 0.9)) { palette = p }
    }
}
