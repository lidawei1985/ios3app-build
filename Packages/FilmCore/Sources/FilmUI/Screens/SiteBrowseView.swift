import SwiftUI
import FilmCore

/// TVBox 点播源浏览页（原版 TVBox 思路：选中一个 site 源，分类/列表/搜索/播放全走该源）。
/// 分类 chips（单选）→ 海报墙（滚动分页，ac=list&t=&pg=，播放地址进详情补拉）→ 复用 DetailView/PlayerScreen。
/// 「选择线路」（TVBox 原版功能）：顶部常驻入口，随时弹出全部线路点选切换。
public struct SiteBrowseView: View {
    /// 入参站点池（不可变；「还没换配置线路」时它是权威来源）
    private let initialSites: [TVBoxSite]
    @State private var site: TVBoxSite
    @State private var showSourcePicker = false
    @State private var pickerQuery = ""
    @State private var switchingLine = false
    /// 换配置线路后解析出的新站点池（非空即覆盖 initialSites）
    @State private var refreshedSites: [TVBoxSite] = []
    @Environment(\.filmTheme) private var theme

    @State private var categories: [SiteCategory] = []
    @State private var selectedCategory: SiteCategory? = nil
    /// 导航组（2026-09-22 用户钦定「多源集合一个分类到我们的一个分类」）：
    /// 源分类先按端策略归入同名大类，点开一组 = 该大类下所有源分类合并展示（内容多、不空壳）。
    @State private var selectedBucket: NavBucket? = nil
    /// 组内二级筛选（合并大类后的「地区/子类型」细分）。
    /// 用户 2026-09-22：「合并了是不是得分区域？比如韩国/日本/港台……我想看那种得能找到，也就是筛选吧」
    @State private var subCategory: SiteCategory? = nil
    @State private var items: [FeedItem] = []
    @State private var page = 1
    @State private var loading = false
    @State private var loadingMore = false
    @State private var reachedEnd = false
    /// 翻页元信息（35包·用户钦定「点开一个分类最多三四十部，还是没有翻页功能导致的」）
    @State private var pageCount = 0      // 上游给的权威总页数（0=没给）
    @State private var totalCount = 0     // 上游给的权威总条数（0=没给）
    @State private var paging = false     // 翻页请求中（防连点）
    @State private var skipNote: String?  // 「该分类空 → 已自动跳到 X」轻提示（35包·空分类自动跳过）
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var searchResults: [FeedItem]?
    @State private var searchTask: Task<Void, Never>?
    /// 空态自动重试护栏：同一「源+分类」只自动重试一次（35包，防死循环转圈）
    @State private var autoRetryKey = ""

    private var client: TVBoxSiteClient { TVBoxSiteClient(site: site) }
    private var retryKey: String { "\(site.key)|\(selectedBucket?.title ?? selectedCategory?.id ?? "_")" }

    /// 当前产品模式（星幕 normal / 心屋 child / 夜航 adult）——源浏览的端隔离闸门用它。
    /// 用户钦定 2026-09-22：「港台三级伦理这些必须是夜航，其他的 APP 不能给」。
    private var mode: String { TVBoxConfigStore.currentProductMode() }

    /// 一个导航组（同名大类合并后的展示单位）。
    private struct NavBucket: Identifiable, Hashable {
        let title: String
        let cats: [SiteCategory]
        var id: String { title }
    }

    /// 分类 → 导航组：按 `NavPolicy` 先把本端不要的源分类摘掉（成人分类只留夜航 /
    /// 星幕不要综艺体育短剧 / 心屋只留儿童向），再把同名大类并成一组。
    private var buckets: [NavBucket] {
        var order: [String] = []
        var map: [String: [SiteCategory]] = [:]
        for c in categories {
            // 2026-09-25 并轨：navTitleOrNewcomer —— 命中我们的大类就并进去，
            // 没有的分类直接新立一组（用户钦点「他的分类都会进到我们对应的分类；
            // 有的进没有的分类就直接出现新分类」），不再丢弃任何过了红线的源分类。
            guard let t = NavPolicy.navTitleOrNewcomer(c.name, mode: mode) else { continue }
            if map[t.title] == nil { order.append(t.title) }
            map[t.title, default: []].append(c)
        }
        return order.map { NavBucket(title: $0, cats: map[$0] ?? []) }
    }

    /// 条目级端隔离（标题 + 源分类双判；与 `FeedAdapter.isolationReject` 同口径）。
    private func scopedItems(_ arr: [FeedItem]) -> [FeedItem] {
        arr.filter {
            NavPolicy.allowsItem(title: $0.title,
                                 sourceCategory: $0.originalCategoryName ?? $0.origin?.category,
                                 mode: mode)
        }
    }

    /// 当前生效的加载单元：选中二级筛选时＝该二级分类单独一桶，否则＝整个大类。
    private var activeBucket: NavBucket? {
        guard let b = selectedBucket else { return nil }
        if let sub = subCategory { return NavBucket(title: "\(b.title) · \(sub.name)", cats: [sub]) }
        return b
    }

    /// 组内二级筛选项（地区 / 子类型短名；通用项返回 nil 已被「全部」覆盖）。
    private func subItems(of b: NavBucket) -> [(cat: SiteCategory, label: String)] {
        b.cats.compactMap { c in
            guard let l = NavPolicy.subLabel(c.name, groupTitle: b.title) else { return nil }
            return (c, l)
        }
    }

    public init(site: TVBoxSite, sites: [TVBoxSite]? = nil) {
        self.initialSites = sites ?? [site]
        _site = State(initialValue: site)
    }

    /// 当前可用点播源池：换过配置线路用新解析出的，否则用入参。
    /// （用 computed 而非 @State 直存，避免 View 实例复用时 @State 不重初始化）
    private var allSites: [TVBoxSite] { refreshedSites.isEmpty ? initialSites : refreshedSites }

    public var body: some View {
        VStack(spacing: 0) {
            siteHeader
            searchBar            // 35包：源内搜索入口（原 searchText/searchResults 只写了数据层，没有输入框）
            categoryBar
            subBar
            content
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(site.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSourcePicker) { sourcePicker }
        .task {
            rememberLastSite()   // TVBox「首页站源 / 下次进入」语义：记住上次浏览的源
            await bootstrap()
        }
    }

    /// 记录本次浏览的源，设置页「上次浏览」一键直达。
    private func rememberLastSite() {
        let dict: [String: Any] = ["key": site.key, "name": site.name,
                                   "api": site.api, "type": site.type ?? 1]
        if let d = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(d, forKey: "tvbox.lastBrowsedSite")
        }
    }

    private var siteHeader: some View {
        // A2 改版（2026-09-21 用户钦定）：整条头部 = 源胶囊，点开即一键换源（TVBox 换首页语义）
        Button { showSourcePicker = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").font(.footnote).foregroundStyle(theme.accent)
                Text("源 · \(site.name)").font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(theme.accent)
                if allSites.count > 1 {
                    Text("一键切换").font(.caption2).foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(theme.card, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: - 源内搜索（35包补齐入口：内置源/自定义源浏览页里直接搜本站片名）
    // 用户报「内置源和自定义源内的搜索没有」→ 数据层 TVBoxSiteClient.search 早已存在，
    // 但页面从未渲染输入框，等于没入口。这里补搜索框 + 触发 + 结果补图。

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.footnote).foregroundStyle(theme.textSecondary)
            TextField("在「\(site.name)」里搜片名", text: $searchText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote).foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Button("搜索") { Task { await runSearch() } }
                .font(.footnote.weight(.semibold)).foregroundStyle(theme.accent)
                .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // 2026-09-25 用户钦点：搜索框统一导航条式透明玻璃（毛玻璃+发丝框），透出变色底
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func runSearch() async {
        let kw = searchText.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        if site.type == 3 {
            searchResults = []
            loadError = nil
            return
        }
        loading = true
        loadError = nil
        let r = await client.search(kw)
        searchResults = scopedItems(r)
        loading = false
        enrichResults(r)
    }

    /// 搜索结果补图（与列表同策略：ac=list 无图 → 并发 detail 补，按 dedupId 合并，不整体覆盖）。
    private func enrichResults(_ list: [FeedItem]) {
        guard list.contains(where: { ($0.poster?.url ?? "").isEmpty }) else { return }
        Task { @MainActor in
            let enriched = await client.enrichPosters(list)
            var pics: [String: String] = [:]
            for it in enriched {
                if let u = it.poster?.url, !u.isEmpty { pics[it.dedupId] = u }
            }
            guard !pics.isEmpty, let cur = searchResults else { return }
            searchResults = cur.map { it in
                if (it.poster?.url ?? "").isEmpty, let u = pics[it.dedupId] { return it.withPoster(u) }
                return it
            }
        }
    }

    // MARK: - 选择线路（TVBox 原版：全部线路一屏点选，Spider 明示需引擎）

    private var sourcePicker: some View {
        NavigationStack {
            List {
                Section {
                    // A2 改版：80+ 源找源靠搜不靠滚
                    TextField("搜索源名称 / 接口地址", text: $pickerQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .listRowBackground(Color.clear)
                }
                let q = pickerQuery.trimmingCharacters(in: .whitespaces).lowercased()
                let pre = q.isEmpty ? allSites
                    : allSites.filter { $0.name.lowercased().contains(q) || $0.api.lowercased().contains(q) }
                // 熔断的源沉底（不隐藏——保留入口便于冷却后半开探测自愈）
                let filtered = pre.filter { SourceHealth.shared.sortKey($0.key) == 0 }
                    + pre.filter { SourceHealth.shared.sortKey($0.key) == 1 }
                let cms = filtered.filter { $0.type != 3 }
                let spiders = filtered.filter { $0.type == 3 }
                // 2026-09-26 分区（用户：「看不明白哪些是电影的哪些是成人的」）：
                // 点播源按 影视 / 混合 / 自定义 / 成人 分组，成人区永远排最后。
                let zoneGroups: [(title: String, items: [TVBoxSite])] = {
                    var g: [DefaultSites.VodZone: [TVBoxSite]] = [:]
                    for s in cms { g[DefaultSites.vodZone(of: s), default: []].append(s) }
                    let order: [(DefaultSites.VodZone, String)] = [
                        (.film, "影视源"), (.mixed, "混合源（影视+成人分类）"),
                        (.custom, "自定义源"), (.adult, "成人源"),
                    ]
                    return order.compactMap { z, t in
                        g[z].map { (t + " \($0.count)", $0) }
                    }
                }()
                if cms.isEmpty {
                    Section {
                        Text(q.isEmpty ? "没有可用的点播源" : "没有匹配「\(pickerQuery)」的点播源")
                            .font(.footnote).foregroundStyle(theme.textSecondary)
                            .listRowBackground(Color.clear)
                    } header: {
                        // 术语归一（35包）：这里列的是「点播源」（站点），不再叫"线路"——
                        // 与设置页「配置线路」（一份配置包）区分，用户曾问「两个列表为啥分开」
                        Text("点播源 · 共 \(allSites.count)")
                    } footer: {
                        Text("点选立即切换整站内容并记住（下次直接进这个源）。")
                    }
                } else {
                    ForEach(zoneGroups, id: \.title) { zone in
                        Section {
                            ForEach(zone.items) { s in
                                Button { switchSite(s) } label: {
                                    HStack {
                                        Image(systemName: s.id == site.id ? "checkmark.circle.fill" : "circle")
                                            .font(.footnote)
                                            .foregroundStyle(s.id == site.id ? theme.accent : theme.textSecondary)
                                        Text(s.name).font(.subheadline).foregroundStyle(theme.textPrimary).lineLimit(1)
                                        Spacer()
                                        if allSites.count > 12 {
                                            Text(typeLabel(s.type)).font(.caption2).foregroundStyle(theme.textSecondary)
                                        }
                                    }
                                    .listRowBackground(Color.clear)
                                }
                            }
                        } header: {
                            Text(zone.title)
                        } footer: {
                            if zone.items.contains(where: { DefaultSites.vodZone(of: $0) == .adult }) {
                                Text("成人源仅夜航可见；影视源看片、成人源看成人内容，分区不会混。")
                            }
                        }
                    }
                }
                // 内置实测「配置线路」也放进一键切换
                // （用户钦定 2026-09-22：「内置27条实测为什么不在继续浏览的一键切换里」）
                let repos = TVBoxConfigStore.shared.builtinRepoOptions
                if !repos.isEmpty {
                    Section {
                        ForEach(repos) { repo in
                            Button { switchConfigLine(repo) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: repo.url == TVBoxConfigStore.shared.activeBuiltinRepoURL
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.footnote)
                                        .foregroundStyle(repo.url == TVBoxConfigStore.shared.activeBuiltinRepoURL
                                                         ? theme.accent : theme.textSecondary)
                                    Text(repo.name).font(.subheadline).foregroundStyle(theme.textPrimary).lineLimit(1)
                                    Spacer()
                                    if switchingLine { ProgressView().scaleEffect(0.7) }
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("换配置线路（内置实测 \(repos.count) 条）")
                    } footer: {
                        Text("一条线路 = 一份配置包（内含几十~几百个站点源）。点选后自动解析，上方「点播源」列表随即换成新线路的源。")
                    }
                }
                if !spiders.isEmpty {
                    Section {
                        ForEach(spiders) { s in
                            HStack {
                                Text(s.name).font(.subheadline).foregroundStyle(theme.textSecondary).lineLimit(1)
                                Spacer()
                                Text("需引擎 · 开发中").font(.caption2).foregroundStyle(theme.textSecondary)
                            }
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Spider 源（\(spiders.count) · 需引擎）")
                    } footer: {
                        Text("Spider 爬虫源需要内置执行引擎，移植开发中，暂不可浏览。")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("切换源")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func typeLabel(_ t: Int?) -> String {
        switch t {
        case 0: return "XML"
        case 1: return "JSON"
        case 3: return "Spider"
        default: return ""
        }
    }

    private func switchSite(_ s: TVBoxSite) {
        showSourcePicker = false
        guard s.id != site.id else { return }
        site = s
        categories = []
        selectedCategory = nil
        selectedBucket = nil
        subCategory = nil
        searchResults = nil
        Task { await bootstrap() }
    }

    /// 换「配置线路」：激活内置线路 → 等解析完 → 用新站点池替换。
    /// 用户钦定 2026-09-22：「内置27条实测为什么不在继续浏览的一键切换里」——
    /// 原来换线路只能回设置页，浏览中换不了。现在浏览页源胶囊里直接可达。
    private func switchConfigLine(_ repo: TVBoxSubscription) {
        guard !switchingLine else { return }
        switchingLine = true
        Task {
            let cfg = TVBoxConfigStore.shared
            cfg.activateBuiltinRepo(repo)
            await cfg.refreshAll()
            SourceHealth.shared.reset()   // 新线路另一批源，健康账清零
            let fresh = cfg.displayResult.sites
            if !fresh.isEmpty {
                refreshedSites = fresh
                // 当前浏览的源不在新线路里 → 自动落到第一个可用源（不然「换了线路还在看旧源」）
                if !fresh.contains(where: { $0.id == site.id }),
                   let first = fresh.first(where: { $0.type != 3 }) {
                    site = first
                    categories = []
                    selectedCategory = nil
                    selectedBucket = nil
                    subCategory = nil
                    searchResults = nil
                    await bootstrap()
                }
            }
            switchingLine = false
            showSourcePicker = false
        }
    }

    /// 组内二级筛选条（2026-09-22 用户：「合并了是不是得分区域？韩国/日本/港台…想找得能找到」）：
    /// 大类合并后，组内源分类名天然带维度（韩国伦理/日本伦理/港剧/动作片）——
    /// 剥成短标签做筛选，点「韩国」就只剩韩国的。只有 1 个细项时不显示（没得筛）。
    @ViewBuilder
    private var subBar: some View {
        if let b = selectedBucket {
            let subs = subItems(of: b)
            if subs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        subChip(name: "全部", selected: subCategory == nil) {
                            subCategory = nil
                            Task { await loadBucket(b, page: 1) }
                        }
                        ForEach(subs, id: \.cat.id) { pair in
                            subChip(name: pair.label, selected: subCategory?.id == pair.cat.id) {
                                let isOn = subCategory?.id == pair.cat.id
                                subCategory = isOn ? nil : pair.cat
                                Task {
                                    if isOn {
                                        await loadBucket(b, page: 1)
                                    } else {
                                        await loadBucket(NavBucket(title: b.title, cats: [pair.cat]), page: 1)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .frame(height: 38)
            }
        }
    }

    private func subChip(name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.caption.weight(selected ? .bold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? theme.accent.opacity(0.9) : theme.card, in: Capsule())
                .foregroundStyle(selected ? .white : theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                chip(name: "全部", selected: selectedCategory == nil && selectedBucket == nil) {
                    selectedCategory = nil
                    selectedBucket = nil
                    subCategory = nil
                    Task { await reload() }
                }
                // 分组优先（2026-09-22）：源分类先归同名大类，点开即「电影/电视剧/动漫/4K专区/…」
                // 这样每一组里都是几十~上百部，不会出现「一个分类只有两部」的尴尬。
                if !buckets.isEmpty {
                    ForEach(buckets) { b in
                        chip(name: b.title, selected: selectedBucket?.title == b.title) {
                            let turnOff = selectedBucket?.title == b.title
                            selectedBucket = turnOff ? nil : b
                            selectedCategory = nil
                            subCategory = nil
                            Task {
                                if turnOff { await reload() } else { await loadBucket(b, page: 1) }
                            }
                        }
                    }
                } else {
                    ForEach(categories) { cat in
                        chip(name: cat.name, selected: selectedCategory?.id == cat.id) {
                            selectedCategory = selectedCategory?.id == cat.id ? nil : cat
                            selectedBucket = nil
                            subCategory = nil
                            Task { await reload() }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(height: 50)   // 横滚定高（防 VStack 贪婪分屏）
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            LoadingView(text: "加载 \(site.name) …")
        } else if let error = loadError {
            VStack(spacing: 12) {
                EmptyStateView(icon: "exclamationmark.triangle", title: "该源暂时不可用", subtitle: error)
                Button("换个源试试") { Task { await bootstrap() } }
                    .font(.footnote).foregroundStyle(theme.accent)
            }
        } else {
            browseList
        }
    }

    private var browseList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            Color.clear.frame(height: 0).id("browseTop")
            if searchResults != nil { searchHeader }
            let display = searchResults ?? items
            if display.isEmpty {
                if searchResults != nil {
                    EmptyStateView(icon: "film", title: "该源没有搜到", subtitle: "换个关键词试试")
                } else if autoRetryKey != retryKey {
                    // 红线（2026-09-22 用户钦定）：任何情况不出现分类空态文案。
                    // 分类拉空 → 自动回退「全部」并重载；全源拉空 → 自动重新引导。
                    // 35包修：原 `.task` 无护栏——bootstrap 置 loading=true 会把本视图从层级摘掉，
                    // 回来时 .task 再触发 → 空列表源死循环转圈（永久「加载中…」）。
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("加载中…").font(.footnote).foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .task {
                        guard autoRetryKey != retryKey else { return }
                        autoRetryKey = retryKey
                        if selectedCategory != nil { selectedCategory = nil; await reload() }
                        else { await bootstrap() }
                    }
                } else {
                    // 重试后仍空 = 该源确实没内容：按红线不出分类空态文案，改为引导换源
                    VStack(spacing: 12) {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "该源暂时没有内容",
                                       subtitle: "换一条线路，或稍后再试")
                        Button("换个源试试") { showSourcePicker = true }
                            .font(.footnote).foregroundStyle(theme.accent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
            } else {
                if let note = skipNote, searchResults == nil {
                    // 自动跳过提示（35包）：让用户知道「不是坏了，是这个分类源站没内容」
                    Label(note, systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 10)
                }
                if searchResults == nil, totalCount > 0 || pageCount > 0 {
                    // 总量/页码明示（35包）：原来只有底部隐式「上滑加载更多」，
                    // 用户不知道这个分类其实有几千部，误以为「只有三四十部」。
                    // 尾巴加「源站就这么少」：个别叶子分类上游确实只有 1~几部
                    // （用户 2026-09-22 报「那道源里就一部电影」），明示不是 App 丢条目。
                    Text((totalCount > 0
                         ? "共 \(totalCount) 部 · 第 \(page)\(pageCount > 0 ? "/\(pageCount)" : "") 页"
                         : "第 \(page) 页")
                         + (totalCount > 0 && totalCount <= 5 ? "（源站这个分类就这么少）" : ""))
                        .font(.caption).foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 10)
                }
                PosterGrid(items: display, columns: 3)
                    .padding(.vertical, 12)
                if searchResults == nil { paginationBar }
            }
        }
        .refreshable { await reload() }
        // 翻页后回到顶部（否则停留在上一页的滚动位置，看着像没换）
        .onChange(of: page) { _, _ in
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("browseTop", anchor: .top) }
        }
        }
    }

    /// 翻页条（35包·用户钦定「还是没有翻页功能导致的」）：
    /// 之前只有隐式「上滑加载更多」，既看不到总量也翻不动页。
    private var paginationBar: some View {
        VStack(spacing: 10) {
            Text(pageCount > 0
                 ? "第 \(page) / \(pageCount) 页" + (totalCount > 0 ? " · 共 \(totalCount) 部" : "")
                 : "第 \(page) 页" + (totalCount > 0 ? " · 共 \(totalCount) 部" : ""))
                .font(.footnote.weight(.medium)).foregroundStyle(theme.textPrimary)
            HStack(spacing: 12) {
                Button {
                    Task { await gotoPage(page - 1) }
                } label: {
                    Label("上一页", systemImage: "chevron.left")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(page <= 1 || paging)

                if paging { ProgressView().scaleEffect(0.8) }

                Button {
                    Task { await gotoPage(page + 1) }
                } label: {
                    Label("下一页", systemImage: "chevron.right")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(paging || (pageCount > 0 && page >= pageCount))
            }
            .padding(.horizontal, 16)
            if pageCount == 0 {
                Text("该源没提供总页数，按「下一页」继续翻即可")
                    .font(.caption2).foregroundStyle(theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16).padding(.bottom, 28)
    }

    private var searchHeader: some View {
        HStack {
            Text("搜到 \(searchResults?.count ?? 0) 条").font(.footnote).foregroundStyle(theme.textSecondary)
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

    // MARK: - 数据

    private func bootstrap() async {
        loading = true
        loadError = nil
        items = []
        page = 1
        reachedEnd = false
        // Spider 爬虫源：需要内置执行引擎（移植开发中），明示而非假装空列表
        if site.type == 3 {
            loading = false
            loadError = "这是 Spider 爬虫源（\(site.api)），需要内置执行引擎才能出内容，移植开发中。点右上「选择线路」换一条可用线路。"
            return
        }
        if categories.isEmpty {
            categories = await client.categories()
        }
        selectedBucket = nil
        selectedCategory = nil
        subCategory = nil
        // 第一页：不带分类（全站最新）
        let first = await client.listPage(categoryId: nil, page: 1)
        items = scopedItems(first.items)
        page = 1
        pageCount = first.pageCount
        totalCount = first.total
        reachedEnd = first.pageCount > 0 ? 1 >= first.pageCount : first.items.count < 10
        loading = false
        enrichCurrent()
    }

    private func reload() async {
        // 分组模式（同名大类合并 / 二级筛选）：一次拉组内全部源分类，合并展示
        if let b = activeBucket {
            await loadBucket(b, page: 1)
            return
        }
        loading = true
        loadError = nil
        page = 1
        reachedEnd = false
        skipNote = nil
        var cat = selectedCategory
        var first = await client.listPage(categoryId: cat?.id, page: 1)
        // 35包·空分类自动跳过（用户钦定 2026-09-22：「分类里比如电影就一部…那道源里就一部电影」）：
        // 上游**确实**存在空分类（实测：无尽资源「电影/动漫/资讯/头条/体育赛事」、
        // 360资源「篮球/反转爽剧」=0 条；金鹰资源则无一空分类）。
        // 停在空分类上只会出空态（违反「不出现分类空态文案」红线），也没意义 ——
        // ① 从胶囊条摘掉这颗死分类（自愈，不发额外探测请求，不给源站加压）
        // ② 自动顺延到下一个**有内容**的分类（最多探 6 个），并轻提示跳到了哪
        // first.ok 守卫：只有上游**成功应答且为空**才判死；网络抖动不摘分类
        // （那种情况交给空态自动重试，不会误删好分类）。
        if let dead = cat, first.ok, first.items.isEmpty, !categories.isEmpty {
            let start = categories.firstIndex { $0.id == dead.id } ?? -1
            categories.removeAll { $0.id == dead.id }
            var moved: SiteCategory?
            if start >= 0, !categories.isEmpty {
                for step in 0..<min(6, categories.count) {
                    let cand = categories[(start + step) % categories.count]
                    let r = await client.listPage(categoryId: cand.id, page: 1)
                    if r.ok, !r.items.isEmpty { cat = cand; first = r; moved = cand; break }
                }
            }
            if let moved {
                skipNote = "「\(dead.name)」源站暂无内容，已自动跳到「\(moved.name)」"
            } else {
                // 连探都没内容 → 退回「全部」，别把用户卡在死分类里
                skipNote = "该分类源站暂无内容，已回到「全部」"
                cat = nil
            }
        }
        selectedCategory = cat
        items = scopedItems(first.items)
        pageCount = first.pageCount
        totalCount = first.total
        reachedEnd = first.pageCount > 0 ? 1 >= first.pageCount : first.items.count < 10
        loading = false
        enrichCurrent()
    }

    /// 翻页（替换式；用户钦定 2026-09-22：「点开一个分类最多三四十部，还是没有翻页功能导致的」）。
    /// 原实现只有隐式「上滑加载更多」，用户既不知道总量也翻不动页。
    private func gotoPage(_ n: Int) async {
        guard !paging, n >= 1 else { return }
        if let b = activeBucket {
            if pageCount > 0, n > pageCount { return }
            if n == page, !items.isEmpty { return }
            await loadBucket(b, page: n)
            return
        }
        if pageCount > 0, n > pageCount { return }
        if n == page, !items.isEmpty { return }
        paging = true
        loadError = nil
        let r = await client.listPage(categoryId: selectedCategory?.id, page: n)
        if r.items.isEmpty {
            // 越过末页：把总页数钉在当前页，避免无限空翻
            if n > 1 { pageCount = n - 1 }
            if pageCount == 0 { pageCount = 0 }
        } else {
            page = n
            items = scopedItems(r.items)
            if r.pageCount > 0 { pageCount = r.pageCount }
            if r.total > 0 { totalCount = r.total }
            reachedEnd = pageCount > 0 && page >= pageCount
        }
        paging = false
        enrichCurrent()
    }

    /// 载入一个导航组（同名大类合并）：把组内每个源分类的第 n 页逐个拉回来合并去重。
    ///
    /// 渐进式渲染：每拿到一个分类就先 append 进列表（首批约 1s 亮相），后面的慢慢补，
    /// 用户不用盯着转圈等 8 个分类全回来。
    /// 组的总页数取组内各分类页数的**最小值**（保证每一页都能翻到东西，不会翻到半空）。
    private func loadBucket(_ b: NavBucket, page n: Int) async {
        loading = (n == 1)
        paging = (n > 1)
        loadError = nil
        skipNote = nil
        items = []
        pageCount = 0
        totalCount = 0
        var seen = Set<String>()
        var pageCounts: [Int] = []
        let cli = client
        // 兜底组（夜航「其他」）可能含上百个源分类（实测成人源 172 个题材类目）——
        // 首屏只取前 12 个，其余靠二级筛选条精确进入（点某个题材只看那一个）。
        let cats = Array(b.cats.prefix(12))
        // 4K 同片升画质（2026-09-22 用户钦定：「如果能把已有的重复的替换成 4K 的就更好了」）：
        // 星幕浏览非 4K 组时，先拉一遍 4K 专区，同片（归一化片名一致）直接用 4K 版顶掉。
        var k4Index: [String: FeedItem] = [:]
        if mode == "normal", b.title != "4K专区",
           let k4 = buckets.first(where: { $0.title == "4K专区" }) {
            for cat in k4.cats {
                let r = await cli.listPage(categoryId: cat.id, page: n)
                for it in r.items {
                    let key = NavPolicy.canonicalTitle(it.title)
                    if !key.isEmpty, k4Index[key] == nil { k4Index[key] = it }
                }
            }
        }
        for cat in cats {
            let r = await cli.listPage(categoryId: cat.id, page: n)
            if r.pageCount > 0 { pageCounts.append(r.pageCount) }
            totalCount += r.total
            var fresh: [FeedItem] = []
            for it in r.items where seen.insert(it.dedupId).inserted { fresh.append(it) }
            let kept = scopedItems(fresh).map { it -> FeedItem in
                guard !k4Index.isEmpty else { return it }
                return k4Index[NavPolicy.canonicalTitle(it.title)] ?? it
            }
            if !kept.isEmpty {
                items.append(contentsOf: kept)
                loading = false          // 首批到位就先亮出来
            }
        }
        page = n
        pageCount = pageCounts.min() ?? 0
        reachedEnd = pageCount > 0 && n >= pageCount
        loading = false
        paging = false
        enrichCurrent()
    }

    /// 原「上滑自动追加下一页」已被**显式翻页条**取代（35包）：
    /// 追加模式没有页码概念，用户既看不到总量也翻不动页 → 改为 `gotoPage(_:)` 替换式翻页。
    /// 保留 reachedEnd 供分页条禁用判断使用。

    /// 列表补图（34包根修「内置源海报不显示」）：ac=list 的 vod_pic 全空（图只在 ac=detail），
    /// 后台并发补 detail 取图，命中按 dedupId 合并回当前列表——不整体覆盖，
    /// 防补图期间翻页追加的条目被丢。
    private func enrichCurrent() {
        let snapshot = items
        guard snapshot.contains(where: { ($0.poster?.url ?? "").isEmpty }) else { return }
        Task { @MainActor in
            let enriched = await client.enrichPosters(snapshot)
            var pics: [String: String] = [:]
            for it in enriched {
                if let u = it.poster?.url, !u.isEmpty { pics[it.dedupId] = u }
            }
            guard !pics.isEmpty else { return }
            items = items.map { it in
                if (it.poster?.url ?? "").isEmpty, let u = pics[it.dedupId] { return it.withPoster(u) }
                return it
            }
        }
    }
}
