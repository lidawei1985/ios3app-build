import SwiftUI
import FilmCore

/// 搜索：本地目录检索（去抖 300ms）+ 结果海报墙。搜索历史最近 8 条。
public struct SearchView: View {
    @EnvironmentObject private var store: CatalogStore
    @Environment(\.filmTheme) private var theme

    @State private var query = ""
    @State private var results: [FeedItem] = []
    /// 命中人物标注（dedupId → 「演员 李丽珍」），让用户知道这条为什么出现（大牌做法）
    @State private var badges: [String: String] = [:]
    @State private var tvResults: [FeedItem] = []      // 电视剧网络源结果（星幕专属，公网 CMS）
    @State private var searching = false
    /// 网源搜索是否仍在进行（2026-10-03「搜索加速」观感修复）。
    /// 原来只用一个 `searching`，且它在**本地**搜完就归 false —— 本地没命中时界面会先闪一下
    /// 「没有找到「XXX」」空态，0.5s 后网源结果（onBatch）才补上来，观感是"搜不出来→突然又有了"，
    /// 用户对这段的体感就是"搜索慢"。现在网搜期间单独置位：空态只在**所有源都回完仍无结果**时出现。
    @State private var tvSearching = false
    @State private var recent: [String] = []
    /// 搜索联想候选（大牌做法：输入中就出候选，点一下即搜）
    @State private var suggestions: [Suggestion] = []
    @State private var showSuggestions = true
    @State private var searchTask: Task<Void, Never>?
    @State private var tvSearchTask: Task<Void, Never>?
    /// 热搜榜缓存（10-01 卡顿根修）：`hotWords` 原是**计算属性**——每次 body 求值都对 13 万条
    /// 做一次全量 `sorted`（比较器里还连调 votes/effectiveYear/rating），而 body 里它被读了
    /// **两次**（`!hotWords.isEmpty` + `enumerated()`）→ 每进一次搜索页、每敲一个字都跑两遍
    /// 全量排序＝几秒级主线程阻塞（用户报「搜索栏点了半天没反应」的直接根因）。
    /// 改为：进页面后台算一次存这里，body 只读缓存。
    @State private var hotWordsCache: [String] = []
    @AppStorage("film.recent.searches") private var recentRaw: String = ""

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("片名 / 首字母 / 演员", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { commitSearch() }
                if !query.isEmpty {
                    Button { query = ""; results = []; badges = [:]; tvResults = []; tvSearching = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            // v14：首页同款亮玻璃（白 10% + 亮边；超薄材质在深色下是黑膜，实测证伪）
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1))
            .padding(.horizontal, 16).padding(.top, 8)

            if showSuggestions && !query.isEmpty && !suggestions.isEmpty { suggestionsLayer }

            if results.isEmpty && query.isEmpty {
                if !recent.isEmpty { recentSection }
                // 片库为空时不显示热搜（不再用写死的老片名充数）
                if !hotWords.isEmpty { hotSection }
            }
            content
        }
        .background(TintBackgroundView())
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadRecent(); await loadHotWords() }
        .onChange(of: query) { _ in
            showSuggestions = true
            debounceSearch()
        }
    }

    @ViewBuilder
    private var content: some View {
        // 还在搜（本地 或 网源）且两边都还没出东西 → 加载态。
        // 关键：把网搜算进来，空态才不会在网源结果到达前抢先冒出来（见 `tvSearching` 注释）。
        let busy = (searching || tvSearching) && !query.isEmpty
        if busy && results.isEmpty && tvResults.isEmpty {
            LoadingView(text: "搜索中…")
        } else if query.isEmpty {
            EmptyStateView(icon: "magnifyingglass", title: "搜你想看的",
                           subtitle: "片名、演员、导演；也支持拼音首字母（如 lldq）")
        } else if results.isEmpty && tvResults.isEmpty {
            EmptyStateView(icon: "questionmark.folder", title: "没有找到「\(query)」",
                           subtitle: "试试更短的关键词")
        } else {
            ScrollView {
                if !results.isEmpty {
                    sectionDivider("自有片库")
                    PosterGrid(items: results, columns: 3, traceTag: "自有片库")
                        .padding(.bottom, 6)
                }
                if !tvResults.isEmpty {
                    // 三端通用的「源上直接搜」（2026-09-22：搜不到本地就穿透到源，用户：
                    // 「别不三级蜜桃成熟时我搜索是不是得能看到找到」）
                    sectionDivider("内置源结果 · 可直接播")
                    PosterGrid(items: tvResults, columns: 3, traceTag: "内置源")
                        .padding(.bottom, 6)
                }
                // 已经看到结果了、但仍有源在回：给一条**不阻塞**的细提示。
                // 不再用整屏加载态去挡用户（结果 0.5s 就出来了，没必要等 6s 预算跑完）。
                if tvSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("还在搜更多源…").font(.caption2)
                    }
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            }
        }
    }

    /// 搜索联想候选层：片名 / 演员，点击直接搜（大牌式输入即出候选）。
    private var suggestionsLayer: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { sug in
                Button {
                    query = sug.text
                    commitSearch()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: sug.kind == "片名" ? "magnifyingglass" : "person")
                            .font(.footnote).foregroundStyle(theme.textSecondary)
                        Text(sug.text).font(.subheadline).foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        if sug.kind != "片名" {
                            Text(sug.kind).font(.caption2).foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(theme.card, in: Capsule())
                        }
                        Spacer()
                        Image(systemName: "arrow.up.left").font(.caption2)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 40)
            }
        }
        .background(Color.clear)   // v14：实色块清掉，透出整页取色底
    }

    /// 分区隔条：上下发丝线夹住小字标（2026-09-25 用户钦点恢复——
    /// 「在下面有个把海报隔离开的 写着内置源结果」），自有片库与内置源结果一眼分清
    private func sectionDivider(_ title: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.textSecondary.opacity(0.16)).frame(height: 0.5)
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Rectangle().fill(theme.textSecondary.opacity(0.16)).frame(height: 0.5)
        }
        .padding(.top, 12)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium)).foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 10)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近搜索").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("清空") { recent = []; recentRaw = "" }
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(recent, id: \.self) { k in
                        Button { query = k; commitSearch() } label: {
                            Text(k).font(.footnote)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(theme.card, in: Capsule())
                                .foregroundStyle(theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 44)   // 横向 ScrollView 定高，防止 LazyHStack 撑爆布局
        }
        .padding(.top, 10)
    }

    /// 热搜榜 TOP10 —— 2026-09-30 用户：「热搜榜里的狂飙、三体能不能换成真实的热搜 这些是很久以前的影片」。
    /// 根因＝**写死的静态片名表**（2023 年的片子，永远不会变）。
    /// 正解＝改成本机片库的**真实数据**：按真实热度（评分人数）取当红片名，热度齐平时按新片年份、
    /// 再按评分；片库一变热搜当轮就变。片库还没加载出来时**不显示**这一块（宁缺毋滥，不再糊弄老片名）。
    /// 只被 body 读取的**缓存**（不再现场全量排序，见 `hotWordsCache` 声明处注释）。
    private var hotWords: [String] { hotWordsCache }

    /// 后台算一次热搜榜（36包卡顿根修）。全量排序 13 万条只在这里发生，且**不在主线程**。
    /// 用 `.utility` 而不是 `.userInitiated`：这是锦上添花的榜单，绝不能跟首屏/交互抢核。
    private func loadHotWords() async {
        guard hotWordsCache.isEmpty else { return }
        let snapshot = store.catalog.items
        guard !snapshot.isEmpty else { return }
        // 只把「纯数据」带进后台线程（不捕获 self，避免跨线程碰 View 状态）
        let words = await Task.detached(priority: .utility) { () -> [String] in
            var seen = Set<String>()
            var out: [String] = []
            for it in snapshot.sorted(by: { a, b in
                HomePolicy.votes(a) != HomePolicy.votes(b)
                    ? HomePolicy.votes(a) > HomePolicy.votes(b)
                    : (HomePolicy.effectiveYear(a) != HomePolicy.effectiveYear(b)
                       ? HomePolicy.effectiveYear(a) > HomePolicy.effectiveYear(b)
                       : HomePolicy.rating(a) > HomePolicy.rating(b))
            }) {
                let t = it.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, !seen.contains(t) else { continue }
                seen.insert(t)
                out.append(t)
                if out.count >= 10 { break }
            }
            return out
        }.value
        hotWordsCache = words
    }

    private var hotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("热搜榜", systemImage: "flame.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 16)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 10) {
                ForEach(Array(hotWords.enumerated()), id: \.offset) { idx, word in
                    Button {
                        query = word
                        commitSearch()
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(idx < 3 ? theme.accent : theme.textSecondary)
                            Text(word).font(.subheadline)
                                .foregroundStyle(theme.textPrimary).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 14)
    }

    // MARK: - 逻辑

    /// 打字防卡三件套：可取消去抖任务 + 后台线程过滤 + 过期结果丢弃。
    /// 此前每次键入都在主线程全量过滤几千条片库，且旧任务不取消、堆积后越打越卡。
    private func debounceSearch() {
        searching = !query.isEmpty
        // 清空输入 / 继续打字都要同步网搜位：清空→关，继续打→保持开（由新一轮 startTVSearch 接管）
        tvSearching = !query.isEmpty
        searchTask?.cancel()
        tvSearchTask?.cancel()
        let q = query
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            performSearch(q)
        }
        startTVSearch(q)
    }

    private func commitSearch() {
        showSuggestions = false
        searchTask?.cancel()
        tvSearchTask?.cancel()
        performSearch(query)
        startTVSearch(query)
        saveRecent(query)
    }

    private func performSearch(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; searching = false; return }
        let snapshot = store.catalog.items          // 主线程取快照
        Task.detached(priority: .userInitiated) {   // 重活扔后台
            let found = FeedAdapter.searchHits(snapshot, query: q)
            await MainActor.run {
                guard q == self.query else { return }   // 用户已继续输入：过期结果丢弃
                self.results = found.map(\.item)
                var b: [String: String] = [:]
                for h in found {
                    if let p = h.matchedPerson {
                        b[h.id] = "\((h.matchedRole ?? "演员")) \(p)"
                    }
                }
                self.badges = b
                self.searching = false
                self.suggestions = Self.makeSuggestions(from: found, query: q)
            }
        }
    }

    /// 网络源搜索（原「电视剧网络源搜索·星幕专属」→ 2026-09-22 扩到**三端**）。
    ///
    /// 为什么必须扩（用户原话）：
    ///  - 「别不三级蜜桃成熟时我搜索是不是得能看到找到」—— 本地片库只有 feed
    ///    （夜航 feed 里索倪那 14.5 万条一条没采），只搜本地就永远搜不到；
    ///  - 搜索必须能**穿透到被合并/二级筛选里那些分类**的片，而不是只在首页货架里找。
    ///
    /// 实现：按端选源池（夜航＝索倪+成人源 / 心屋＝共通源 / 星幕＝剧集源），
    /// 并发搜 → 结果过 `NavPolicy.allowsItem` 端隔离 → 多源合并去重（成人源多，取前 14 个）。
    private func startTVSearch(_ raw: String) {
        let mode = store.profile.mode
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { tvResults = []; tvSearching = false; return }
        tvSearching = true
        tvSearchTask = Task {
            // 复位网搜位：取消 / 过期 / 正常结束**每条退出路径**都要复位，
            // 否则「还在搜更多源…」会一直挂着不放（用户会以为搜索卡死）。
            // 只在仍是当前关键词时才复位，避免把新一次搜索刚置上的位误关。
            defer { Task { @MainActor in if q == self.query { self.tvSearching = false } } }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, q == self.query else { return }
            // 2026-10-01 用户钦定「全部带搜索都搜全部源内容」：不再 prefix(14) 截流，
            // 全量内置源分批并发（健康源优先、先到先上屏）。
            self.tvResults = []
            let hits = await GlobalSiteSearch.search(q, mode: mode, onBatch: { all in
                Task { @MainActor in
                    guard q == self.query else { return }
                    self.tvResults = Array(all.prefix(36))
                }
            })
            await MainActor.run {
                guard q == self.query else { return }   // 用户已继续输入：过期结果丢弃
                self.tvResults = Array(hits.prefix(36))
            }
        }
    }

    struct Suggestion: Identifiable, Equatable {
        let id: String
        let text: String
        let kind: String        // 片名 / 演员
    }

    /// 候选派生：片名优先，其次命中的人物（含拼音命中，如 llz → 演员 李丽珍；点击即搜）。
    static func makeSuggestions(from found: [FeedAdapter.SearchHit], query q: String) -> [Suggestion] {
        var out: [Suggestion] = []
        var seen = Set<String>()
        for h in found.prefix(40) where out.count < 6 {
            if seen.insert(h.item.title).inserted {
                out.append(Suggestion(id: "t|\(h.item.title)", text: h.item.title, kind: "片名"))
            }
        }
        guard out.count < 8 else { return out }
        // ① 检索已判定的命中人物（拼音/中文都覆盖，这是拼音搜演员的关键）
        for h in found where out.count < 8 {
            guard let p = h.matchedPerson, seen.insert(p).inserted else { continue }
            out.append(Suggestion(id: "p|\(p)", text: p, kind: h.matchedRole ?? "演员"))
        }
        // ② 兜底：中文包含命中的演员（老路径，防止人选被 limit 截断后漏掉）
        let needle = q.lowercased()
        outer: for h in found.prefix(80) {
            for a in (h.item.actors ?? []) where a.lowercased().contains(needle) {
                if seen.insert(a).inserted {
                    out.append(Suggestion(id: "a|\(a)", text: a, kind: "演员"))
                    if out.count >= 8 { break outer }
                }
            }
        }
        return out
    }

    private func loadRecent() {
        recent = recentRaw.split(separator: "\u{1F}").map(String.init)
    }
    private func saveRecent(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        recent.removeAll { $0 == trimmed }
        recent.insert(trimmed, at: 0)
        if recent.count > 8 { recent.removeLast(recent.count - 8) }
        recentRaw = recent.joined(separator: "\u{1F}")
    }
}
