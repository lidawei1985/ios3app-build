import SwiftUI
import FilmCore

/// 星幕电视剧（2026-09-23 用户钦定重构：**自家片库优先**，公网只当兜底）。
///
/// 用户最大痛点原话：「电视剧一部也播不了」。
/// 根因：本页此前**只**依赖公网 CMS 源（`DefaultSites.tvDramaSources`：量子/天涯/非凡/卧龙），
/// 公网源一挂，整页只剩「公网片源暂时全部不可达」；而自家中台 feed 里
/// **12,759 部剧集（100% 带 playUrl、99.9% 带海报）端侧压根没被用过**。
///
/// 现优先级（先自家、后公网）：
///   ① 自家片库 TV 池（`store.catalog` 里 `contentType == "tv"`，排除动漫/短剧）——
///      即时可用、不依赖任何公网 CMS；
///   ② 自家池为空（首次启动尚未同步完）→ 自动降级到原公网多源容灾通道，不再白屏。
public struct TVSeriesView: View {
    @Environment(\.filmTheme) private var theme
    @EnvironmentObject private var store: CatalogStore

    // MARK: - 自家池状态

    @State private var poolLoading = true
    @State private var pool: [FeedItem] = []
    @State private var poolReady = false

    // MARK: - 筛选 / 排序

    private enum SortMode: String, CaseIterable, Identifiable {
        case hot, latest, rated
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hot: return "最热"
            case .latest: return "最新"
            case .rated: return "高分"
            }
        }
    }

    @State private var chip: String? = nil        // nil = 全部剧集
    @State private var area: String? = nil        // nil = 全部地区
    @State private var sort: SortMode = .latest
    @State private var shown = 60
    @State private var result: [FeedItem] = []
    @State private var recomputing = true

    // MARK: - 搜索

    @State private var searchText = ""
    @State private var searchResults: [FeedItem]?

    private let pageSize = 60

    public init() {}

    public var body: some View {
        Group {
            if poolLoading {
                LoadingView(text: "加载电视剧库…")
            } else if poolReady {
                localBody
            } else {
                // 自家池为空（首次启动尚未同步完 feed）→ 公网通道兜底
                PublicTVSeriesView()
            }
        }
        .background(tintBackground.ignoresSafeArea())
        .navigationTitle("电视剧")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPool() }
        .task(id: filterKey) { await recompute() }
    }

    /// 整页取色底（2026-09-24 用户：「电视剧分类里面的颜色不跟着变啊，我看分其他的都跟随了就他自己不变」）：
    /// 旧版死底 `theme.background` 是全 App 唯一不跟色的页面。改用与分类页同一方案
    /// （`HeroTintStore.shared.current` 线性渐变，从首页进来颜色连续不跳色）。
    @ObservedObject private var tint = HeroTintStore.shared

    private var tintBackground: some View {
        let p = tint.current
        return LinearGradient(stops: [
            .init(color: p.mid.alpha(0.40), location: 0.00),
            .init(color: p.deep.scaled(0.94).color, location: 0.31),
            .init(color: Color(hex: "#0A0A0D") ?? .black, location: 0.76)
        ], startPoint: .top, endPoint: .bottom)
        .animation(.easeInOut(duration: 0.9), value: tint.current)
    }

    // MARK: - 自家池

    /// TV 池：contentType == tv，排除动漫（星幕不上动漫）与短剧（红线：短剧绝不混进电视剧池）。
    private func loadPool() async {
        poolLoading = true
        // 已有目录则直接用；尚未同步完则等一下（syncAll 由 App 启动时驱动）
        if store.catalog.items.isEmpty {
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !store.catalog.items.isEmpty { break }
            }
        }
        let items = store.catalog.items
        let built = await Task.detached(priority: .userInitiated) { () -> [FeedItem] in
            items.filter { it in
                guard (it.contentType ?? "").lowercased() == "tv" else { return false }
                guard !HomePolicy.isAnime(it) else { return false }
                guard !Self.isShortDrama(it) else { return false }
                return it.bestPosterURL != nil
            }
        }.value
        pool = built
        poolReady = !built.isEmpty
        poolLoading = false
        FilmLog.i("TVSERIES local pool=\(built.count)")
    }

    /// 短剧判定（与 NavPolicy 同口径；短剧留在自己的入口，不进电视剧池）。
    static func isShortDrama(_ it: FeedItem) -> Bool {
        if (it.contentType ?? "").lowercased().contains("short") { return true }
        let blob = [it.aggregateCategoryName ?? "", it.originalCategoryName ?? ""].joined(separator: " ")
        return ["短剧", "微短剧", "竖屏"].contains { blob.contains($0) }
    }

    private var filterKey: String { "\(chip ?? "_")|\(area ?? "_")|\(sort.rawValue)|\(pool.count)" }

    private func recompute() async {
        guard !pool.isEmpty else { recomputing = false; return }
        recomputing = true
        let base = pool
        let c = chip, a = area, s = sort
        let out = await Task.detached(priority: .userInitiated) { () -> [FeedItem] in
            var arr = base
            if let c { arr = arr.filter { ($0.aggregateCategoryName ?? "") == c } }
            if let a { arr = arr.filter { Self.areaKey($0) == a } }
            arr.sort { lhs, rhs in
                switch s {
                case .hot:
                    let la = max(0, lhs.votes ?? 0), ra = max(0, rhs.votes ?? 0)
                    if la != ra { return la > ra }
                case .rated:
                    let la = min(max(lhs.rating ?? 0, 0), 10), ra = min(max(rhs.rating ?? 0, 0), 10)
                    if la != ra { return la > ra }
                case .latest:
                    let ly = HomePolicy.effectiveYear(lhs), ry = HomePolicy.effectiveYear(rhs)
                    if ly != ry { return ly > ry }
                }
                // 并列时统一按「年份新 → 热度高」兜底，保证顺序稳定
                let ly = HomePolicy.effectiveYear(lhs), ry = HomePolicy.effectiveYear(rhs)
                if ly != ry { return ly > ry }
                return max(0, lhs.votes ?? 0) > max(0, rhs.votes ?? 0)
            }
            return arr
        }.value
        result = out
        shown = pageSize
        recomputing = false
    }

    /// 地区归一键（feed 的 `area` 原始值直接当分组名；空值归「其他」）。
    static func areaKey(_ it: FeedItem) -> String {
        let a = (it.area ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? "其他" : a
    }

    // MARK: - 分类 chips（中台聚合分类直读，端上不重新分类）

    private var chips: [(name: String, count: Int)] {
        var m: [String: Int] = [:]
        for it in pool {
            let n = (it.aggregateCategoryName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { continue }
            m[n, default: 0] += 1
        }
        return m.map { (name: $0.key, count: $0.value) }
            .filter { $0.count >= 20 }
            .sorted { $0.count > $1.count }
            .prefix(10)
            .map { $0 }
    }

    /// 当前分类范围内真实存在的地区（决定地区行出哪些）。
    private var areas: [(name: String, count: Int)] {
        let scope = chip == nil ? pool : pool.filter { ($0.aggregateCategoryName ?? "") == chip }
        var m: [String: Int] = [:]
        for it in scope { m[Self.areaKey(it), default: 0] += 1 }
        return m.map { (name: $0.key, count: $0.value) }
            .filter { $0.count >= 20 }
            .sorted { $0.count > $1.count }
            .prefix(9)
            .map { $0 }
    }

    // MARK: - 视图

    private var localBody: some View {
        VStack(spacing: 0) {
            searchBar            // 2026-09-24 用户指令：「电视剧里面的搜索能不能放顶部分类上边」
            header
            chipBar
            areaBar
            content
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tv.fill").foregroundStyle(theme.accent)
            Text("自家片库 · \(pool.count) 部剧集 · 持续更新")
                .font(.caption).foregroundStyle(theme.textSecondary).lineLimit(1)
            Spacer()
            ForEach(SortMode.allCases) { m in
                Button(m.title) { sort = m }
                    .font(.caption.weight(sort == m ? .bold : .regular))
                    .foregroundStyle(sort == m ? theme.accent : theme.textSecondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                chipButton(name: "全部剧集", selected: chip == nil) {
                    chip = nil; area = nil
                }
                ForEach(chips, id: \.name) { c in
                    chipButton(name: "\(c.name) \(c.count)", selected: chip == c.name) {
                        chip = c.name; area = nil
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(height: 50)
    }

    private var areaBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                areaButton(name: "全部地区", selected: area == nil) { area = nil }
                ForEach(areas, id: \.name) { a in
                    areaButton(name: "\(a.name) \(a.count)", selected: area == a.name) { area = a.name }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .frame(height: 42)
    }

    private func chipButton(name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.footnote.weight(selected ? .bold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? theme.accent : theme.card, in: Capsule())
                .foregroundStyle(selected ? .white : theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private func areaButton(name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.caption.weight(selected ? .bold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(Capsule().stroke(selected ? theme.accent : theme.card, lineWidth: 1))
                .foregroundStyle(selected ? theme.accent : theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            if let sr = searchResults {
                searchHeader(count: sr.count)
                if sr.isEmpty {
                    EmptyStateView(icon: "tv", title: "没有搜到", subtitle: "换个关键词试试")
                } else {
                    PosterGrid(items: sr, columns: 3).padding(.vertical, 12)
                }
            } else if recomputing && result.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("加载中…").font(.footnote).foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            } else if result.isEmpty {
                // 红线（2026-09-22 用户钦定）：任何情况不出现分类空态文案
                VStack(spacing: 12) {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "这个筛选下暂时没有内容",
                                   subtitle: "换个分类或地区试试")
                    Button("看全部剧集") { chip = nil; area = nil }
                        .font(.footnote).foregroundStyle(theme.accent)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                PosterGrid(items: Array(result.prefix(shown)), columns: 3)
                    .padding(.vertical, 12)
                if shown < result.count {
                    HStack(spacing: 8) {
                        ProgressView().tint(theme.accent)
                        Text("上滑加载更多（\(shown)/\(result.count)）")
                            .font(.footnote).foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 14)
                    .onAppear { shown = min(shown + pageSize, result.count) }
                } else {
                    Text("共 \(result.count) 部")
                        .font(.footnote).foregroundStyle(theme.textSecondary)
                        .padding(.vertical, 14)
                }
            }
        }
        .refreshable { await loadPool() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("在电视剧库里搜剧", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { commitSearch() }
            if !searchText.isEmpty {
                Button { searchText = ""; searchResults = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16).padding(.top, 4)
    }

    private func searchHeader(count: Int) -> some View {
        HStack {
            Text("搜到 \(count) 部").font(.footnote).foregroundStyle(theme.textSecondary)
            Spacer()
            Button("返回浏览") { searchResults = nil }
                .font(.footnote).foregroundStyle(theme.accent)
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    /// 本地检索（无网络依赖；中文 + 拼音首字母，含演员/导演，与搜索页同口径）。
    private func commitSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchResults = FeedAdapter.search(pool, query: q)
    }
}

// MARK: - 公网兜底通道（自家池为空时才走；原多源容灾逻辑原样保留）

/// 独立公网通道：多源自动容灾（当前源挂掉自动切下一个，全灭才亮错误）。
private struct PublicTVSeriesView: View {
    @Environment(\.filmTheme) private var theme

    @State private var sourceIndex = 0
    @State private var categories: [SiteCategory] = []
    @State private var selectedCategory: SiteCategory? = nil
    @State private var allMode = true
    @State private var items: [FeedItem] = []
    @State private var page = 1
    @State private var loading = false
    @State private var loadingMore = false
    @State private var reachedEnd = false
    @State private var allSourcesDead = false
    @State private var searchText = ""
    @State private var searchResults: [FeedItem]?
    @State private var searchTask: Task<Void, Never>?
    @State private var autoRetryKey = ""

    private var currentSite: TVBoxSite { DefaultSites.tvDramaSources[min(sourceIndex, DefaultSites.tvDramaSources.count - 1)] }
    private var client: TVBoxSiteClient { TVBoxSiteClient(site: currentSite) }
    private var retryKey: String { "\(sourceIndex)|\(selectedCategory?.id ?? "_")" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(theme.accent)
                Text("公网片源 · \(currentSite.name) · 字幕组更新")
                    .font(.caption).foregroundStyle(theme.textSecondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            categoryBar
            content
        }
        .task { await bootstrap() }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                chip(name: "全部剧集", selected: allMode) {
                    guard !allMode else { return }
                    allMode = true
                    selectedCategory = nil
                    Task { await reload() }
                }
                ForEach(categories.filter { $0.name != "连续剧" }) { cat in
                    chip(name: cat.name, selected: !allMode && selectedCategory?.id == cat.id) {
                        allMode = false
                        selectedCategory = cat
                        Task { await reload() }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(height: 50)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            LoadingView(text: "加载电视剧库…")
        } else if allSourcesDead {
            VStack(spacing: 12) {
                EmptyStateView(icon: "wifi.exclamationmark", title: "片源暂时不可达",
                               subtitle: "网络恢复后下拉即可重试")
                Button("重试") { Task { await bootstrap() } }
                    .font(.footnote).foregroundStyle(theme.accent)
            }
        } else {
            browseList
        }
    }

    private var browseList: some View {
        ScrollView {
            searchBar
            if searchResults != nil { searchHeader }
            let display = searchResults ?? items
            if display.isEmpty {
                if searchResults != nil {
                    EmptyStateView(icon: "tv", title: "没有搜到", subtitle: "换个关键词试试")
                } else if autoRetryKey != retryKey {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("加载中…").font(.footnote).foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .task {
                        guard autoRetryKey != retryKey else { return }
                        autoRetryKey = retryKey
                        await bootstrap()
                    }
                } else {
                    VStack(spacing: 12) {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "该源暂时没有内容",
                                       subtitle: "换一条线路，或稍后再试")
                        Button("换个源试试") {
                            sourceIndex = (sourceIndex + 1) % max(DefaultSites.tvDramaSources.count, 1)
                            Task { await bootstrap() }
                        }
                        .font(.footnote).foregroundStyle(theme.accent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
            } else {
                PosterGrid(items: display, columns: 3)
                    .padding(.vertical, 12)
                if searchResults == nil && !reachedEnd {
                    HStack(spacing: 8) {
                        if loadingMore { ProgressView().tint(theme.accent) }
                        Text(loadingMore ? "加载中…" : "上滑加载更多")
                            .font(.footnote).foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 14)
                    .onAppear { Task { await loadMore() } }
                }
            }
        }
        .refreshable { await bootstrap() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("在本片源内搜剧", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { commitSearch() }
            if !searchText.isEmpty {
                Button { searchText = ""; searchResults = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16).padding(.top, 4)
    }

    private var searchHeader: some View {
        HStack {
            Text("搜到 \(searchResults?.count ?? 0) 部").font(.footnote).foregroundStyle(theme.textSecondary)
            Spacer()
            Button("返回浏览") { searchResults = nil }
                .font(.footnote).foregroundStyle(theme.accent)
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    private func chip(name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.footnote.weight(selected ? .bold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? theme.accent : theme.card, in: Capsule())
                .foregroundStyle(selected ? .white : theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private func filtered(_ list: [FeedItem]) -> [FeedItem] {
        list.filter { DefaultSites.isAllowedItem(title: $0.title, typeName: $0.aggregateCategoryName) }
    }

    private func bootstrap() async {
        loading = true
        allSourcesDead = false
        items = []
        searchResults = nil
        page = 1
        reachedEnd = false
        selectedCategory = nil

        for (idx, site) in DefaultSites.tvDramaSources.enumerated() {
            let c = TVBoxSiteClient(site: site)
            let cats = (await c.categories()).filter { DefaultSites.isAllowedCategory($0.name) }
            guard !cats.isEmpty else { continue }
            let first = await mergedFirstPage(client: c, cats: cats)
            guard !first.isEmpty else { continue }
            sourceIndex = idx
            categories = cats
            selectedCategory = nil
            allMode = true
            items = first
            reachedEnd = true
            loading = false
            return
        }
        allSourcesDead = true
        loading = false
    }

    private func reload() async {
        loading = true
        page = 1
        reachedEnd = false
        if allMode {
            items = await mergedFirstPage(client: client, cats: categories)
            reachedEnd = true
        } else {
            let cat = selectedCategory ?? DefaultSites.preferredCategory(in: categories)
            selectedCategory = cat
            let first = filtered(await client.videos(categoryId: cat?.id, page: 1))
            items = first
            reachedEnd = first.count < 10
        }
        loading = false
    }

    private func mergedFirstPage(client: TVBoxSiteClient, cats: [SiteCategory]) async -> [FeedItem] {
        let targets = cats.filter { !DefaultSites.isShortDramaCategory($0.name) }
        var collected: [FeedItem] = []
        await withTaskGroup(of: [FeedItem].self) { group in
            for cat in targets {
                group.addTask { await client.videos(categoryId: cat.id, page: 1) }
            }
            for await batch in group { collected += filtered(batch) }
        }
        var known = Set<String>()
        let idDeduped = collected.filter { known.insert($0.id).inserted }
        var seen = Set<String>()
        let deduped = idDeduped.filter {
            seen.insert(Self.versionKey($0.title) + "|" + ($0.year ?? "")).inserted
        }
        return deduped.sorted { yearValue($0.year) > yearValue($1.year) }
    }

    static func versionKey(_ title: String) -> String {
        title.replacingOccurrences(
            of: "(国语|粤语|普通话|英语|日语|韩语|泰语|中字|双语|台配|配音|国语版|粤语版|HD|蓝光|BD|4K|1080P|720P|高清|完整版|未删减|修复版|典藏版)",
            with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func yearValue(_ y: String?) -> Int {
        Int(y?.prefix(4) ?? "") ?? 0
    }

    private func loadMore() async {
        guard !loadingMore, !reachedEnd, searchResults == nil, !allMode else { return }
        loadingMore = true
        let next = page + 1
        let more = filtered(await client.videos(categoryId: selectedCategory?.id, page: next))
        if more.isEmpty {
            reachedEnd = true
        } else {
            page = next
            var known = Set(items.map(\.id))
            items += more.filter { known.insert($0.id).inserted }
        }
        loadingMore = false
    }

    private func commitSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchTask = Task {
            let found = filtered(await client.search(q))
            await MainActor.run {
                guard !Task.isCancelled else { return }
                searchResults = found
            }
        }
    }
}
