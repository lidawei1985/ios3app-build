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
    /// v60（审计 B6）：输入框聚焦态描边（聚焦转 accent 红）。
    @FocusState private var fieldFocused: Bool

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // v60（审计 C1）：横屏下系统导航栏塌缩但「搜索」标题照画 → 两个字直接压在输入框上
            //（l_搜索 真机截图实证）。修法＝撤掉系统标题，标题改**自绘独立行**：
            // 标题在上、输入框在下，横竖屏同一面孔。
            // 配套：首页搜索入口改为切到搜索 tab（见 HomeView.searchEntry），不再 push，
            // 避免本页无导航栏后 push 进来丢返回键。
            Text("搜索")
                .font(.headline.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
                .padding(.bottom, 10)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("片名 / 首字母 / 演员", text: $query)
                    .focused($fieldFocused)
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
            // v60（审计 B6）：白 0.10 平底在深底上就是「深灰实底」→ `.clear` 玻璃档
            //（不挂材质、不去色，取色底透出）；聚焦态描边转 accent 红。
            .filmGlass(cornerRadius: 12, tint: 0.07, strokeOpacity: 0.12, weight: .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(fieldFocused ? theme.accent.opacity(0.55) : Color.white.opacity(0.14),
                            lineWidth: fieldFocused ? 1 : 0.5)
            )
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
        // v60（审计 C1）：系统导航栏撤掉（标题已自绘，见 body 顶部注释）。
        .toolbar(.hidden, for: .navigationBar)
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
            // 2026-10-17：拼音查不到时给一句能落地的话，别让用户以为搜索坏了。
            // 实测背景：采集源的 wd= 只匹配**片名**、且只认中文（wd=李丽珍 → 4 源全 0；
            // wd=llz → 全 0；wd=蜜桃成熟时 → 2~4 条）。所以拼音能否命中，取决于本地是否
            // 已经「见过」这部片（本地片库 / 浏览过的源标题）。没见过就只能打中文。
            if PinyinIndex.isPinyinQuery(query) {
                EmptyStateView(icon: "textformat.abc",
                               title: "拼音没匹配到「\(query)」",
                               subtitle: "源站只认中文片名。直接打中文试试，比如「蜜桃」或「蜜桃成熟时」")
            } else {
                EmptyStateView(icon: "questionmark.folder", title: "没有找到「\(query)」",
                               subtitle: "试试更短的关键词")
            }
        } else {
            ScrollView(showsIndicators: false) {
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
        // v83 保险丝：本地过滤位硬上限 20s。此前只有网搜位（tvSearching）有兜底——
        // 真机实测（2026-10-11 16:42）拼音冷键场景 searchHits 现算 30~40s，
        // 转圈挂住的是 searching 位、没有任何东西会把它关掉。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if q == self.query { self.searching = false }
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            performSearch(q)
        }
        // v87：纯拼音查询（llz/rdh）不在这里直发源搜——采集源只认中文，
        // wd=llz 实测 78 源只回 4 条不相干垃圾（PC 侧全源压测 2026-10-11）。
        // 等 performSearch 本地命中人名后，用「人名中文名」补一轮源搜（见 performSearch）。
        if !PinyinIndex.isPinyinQuery(q) { startTVSearch(q) }
    }

    private func commitSearch() {
        showSuggestions = false
        searchTask?.cancel()
        tvSearchTask?.cancel()
        performSearch(query)
        // 同上：拼音查询的源搜由 performSearch 命中人名后接手（点联想「李丽珍 演员」
        // 走到这里时 query 已是中文，不受影响）。
        if !PinyinIndex.isPinyinQuery(query) { startTVSearch(query) }
        saveRecent(query)
    }

    private func performSearch(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; searching = false; return }
        let snapshot = store.catalog.items          // 主线程取快照
        // 2026-10-17：拼音桥接要用「演员名全集」做反向拼音匹配，主线程先取键快照
        // （persons.json 几万演员；只拷 key，几毫秒，避免后台闭包碰 store）
        let personNames = Array(store.personAvatars.keys)
        Task.detached(priority: .userInitiated) {   // 重活扔后台
            let found = FeedAdapter.searchHits(snapshot, query: q)
            // 拼音查询的「翻译」也放后台：几万演员名逐个算拼音键，主线程做会卡输入
            let isPy = PinyinIndex.isPinyinQuery(q)
            let bridged = isPy ? Self.bridgeKeys(pinyin: q, found: found, personNames: personNames) : []
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
                // ★ 2026-10-17 拼音桥接（主人：「换了索倪源……以前能搜到 LLZ 的蜜桃成熟时，现在搜不到，
                //   也不显示内置源搜索结果」）——两个独立病因：
                //   ① MacCMS 的 `wd=` **只认中文**：实测 wd=蜜桃 → 非凡 6 / 猫眼 11 / 红牛3 17 条，
                //      而 wd=llz → 全 0 条。所以纯拼音丢给源必然 0 结果；
                //   ② 索倪源站把搜索接口封了（wd= 恒 403，6 种 UA 全中，浏览 ac=list 正常）——
                //      这条由 SearchGate 在运行期识别并跳过，不在本函数处理。
                //   旧版只桥接「人名」，且要求本地片库先命中那个人；本地没有该片（成人/冷门片不进 feed）
                //   就什么也桥不出来 → 用户看到「一条都没有」。现在人名 + 片名 + 演员表三路都试。
                if isPy {
                    if bridged.isEmpty { self.startTVSearch(q) }
                    else { self.startTVSearchBridge(bridged) }
                }
            }
        }
    }

    /// 把纯拼音查询翻成可以喂给采集源的中文关键词（2026-10-17）。
    ///
    /// 采集源只认中文，所以「LLZ」这类查询必须先在本地翻成中文，否则 78 个源全是 0 条。
    /// 三路兜底，先准后全：
    ///  ① 本地命中的人物（llz → 李丽珍）—— 最准；
    ///  ② 本地命中的中文片名（mtscs → 蜜桃成熟时）—— 直接命中片名；
    ///  ③ 前两路全空时，用**演员头像表**（persons.json，几万演员名）做反向拼音匹配。
    ///     这是关键补位：成人片/冷门片不进本地 feed，但演员名常在 persons.json 里，
    ///     于是 llz 仍能翻成「李丽珍」再去公网源搜。
    /// 返回空数组 = 翻不出来，调用方退回「原拼音直接搜」（行为与旧版一致）。
    static func bridgeKeys(pinyin q: String, found: [FeedAdapter.SearchHit],
                           personNames: [String], limit: Int = 2) -> [String] {
        var keys: [String] = []
        // ① 本地命中的中文片名（mtscs → 蜜桃成熟时）—— 最准，直接是源认的搜索词
        for h in found where keys.count < limit {
            let t = h.item.title.trimmingCharacters(in: .whitespaces)
            guard PinyinIndex.hasHan(t), !keys.contains(t) else { continue }
            keys.append(t)
        }
        // ② 本地标题拼音库反查（浏览过的源片名都攒在里面）。
        //    实测：采集源 `wd=` 只匹配片名、不匹配演员，所以「拼音 → 中文片名」才是唯一有效路径。
        //    这就是「以前打 LLZ 能看到蜜桃成熟时」在今天还能复现的关键：只要这片被浏览过。
        if keys.count < limit {
            for t in TitlePinyinCache.lookup(pinyin: q, limit: limit - keys.count)
            where !keys.contains(t) {
                keys.append(t)
            }
        }
        // ③ 实在翻不出片名，再退回「拼音 → 演员名」（本地片库可能按演员命中）。
        if keys.isEmpty && !personNames.isEmpty {
            let needle = PinyinIndex.normalize(q)
            guard needle.count >= 2 else { return [] }
            var hits: [(tier: Int, name: String)] = []
            for name in personNames {
                let t = PinyinIndex.personTier(name, needle: needle)
                if t != .none { hits.append((t.rawValue, name)) }
                if hits.count >= 2000 { break }     // 上限保护：热门音再长也够用
            }
            hits.sort { $0.tier > $1.tier || ($0.tier == $1.tier && $0.name.count < $1.name.count) }
            for h in hits.prefix(limit) where !keys.contains(h.name) { keys.append(h.name) }
        }
        return keys
    }

    /// 多关键词桥接搜索：把 bridgeKeys 翻出来的中文词**依次**喂给全源搜索。
    ///
    /// 为什么顺序而不并发：单次 `GlobalSiteSearch.search` 内部已经有 10 个源在飞，
    /// 再并几路就会把自家出网链路打爆 —— 这正是 v94 修掉的「好源集体假超时」根因。
    /// 每个关键词 5s 预算，第一个词命中就立刻上屏，后面的词只做补充。
    private func startTVSearchBridge(_ keys: [String]) {
        let mode = store.profile.mode
        guard !keys.isEmpty else { return }
        tvSearching = true
        let anchor = query
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            if anchor == self.query { self.tvSearching = false }
        }
        tvSearchTask = Task {
            defer { Task { @MainActor in if anchor == self.query { self.tvSearching = false } } }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, anchor == query else { return }
            self.tvResults = []
            var acc: [FeedItem] = []
            var seen = Set<String>()
            for k in keys {
                guard !Task.isCancelled, anchor == query else { return }
                let hits = await GlobalSiteSearch.search(k, mode: mode, budget: 5.0)
                for it in hits {
                    if seen.insert(it.title + "|" + (it.year ?? "")).inserted { acc.append(it) }
                }
                if !acc.isEmpty {
                    let snap = Array(acc.prefix(36))
                    await MainActor.run { if anchor == self.query { self.tvResults = snap } }
                }
                if acc.count >= 36 { break }
            }
            await MainActor.run {
                guard anchor == self.query else { return }
                self.tvResults = Array(acc.prefix(36))
            }
        }
    }

    /// 网络源搜索（原「电视剧网络源搜索·星幕专属」→ 2026-09-22 扩到**三端**）。
    ///
    /// 为什么必须扩（用户原话）：
    ///  - 「别不三级蜜桃成熟时我搜索是不是得能看到找到」—— 本地片库只有 feed
    ///    （成人端 feed 里索倪那 14.5 万条一条没采），只搜本地就永远搜不到；
    ///  - 搜索必须能**穿透到被合并/二级筛选里那些分类**的片，而不是只在首页货架里找。
    ///
    /// 实现：按端选源池（成人端＝索倪+成人源 / 心屋＝共通源 / 星幕＝剧集源），
    /// 并发搜 → 结果过 `NavPolicy.allowsItem` 端隔离 → 多源合并去重（成人源多，取前 14 个）。
    private func startTVSearch(_ raw: String) {
        let mode = store.profile.mode
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { tvResults = []; tvSearching = false; return }
        tvSearching = true
        // v82 保险丝：网搜位硬上限 20s —— 预算哨兵（GlobalSiteSearch v82）之下网搜最多 6s+源超时，
        // 任何未预期路径挂死也保证「搜索中…/还在搜更多源…」不会永久挂着不放。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if q == self.query { self.tvSearching = false }
        }
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
