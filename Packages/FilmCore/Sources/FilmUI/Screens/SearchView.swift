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
    @State private var recent: [String] = []
    /// 搜索联想候选（大牌做法：输入中就出候选，点一下即搜）
    @State private var suggestions: [Suggestion] = []
    @State private var showSuggestions = true
    @State private var searchTask: Task<Void, Never>?
    @State private var tvSearchTask: Task<Void, Never>?
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
                    Button { query = ""; results = []; badges = [:]; tvResults = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16).padding(.top, 8)

            if showSuggestions && !query.isEmpty && !suggestions.isEmpty { suggestionsLayer }

            if results.isEmpty && query.isEmpty {
                if !recent.isEmpty { recentSection }
                hotSection
            }
            content
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadRecent() }
        .onChange(of: query) { _ in
            showSuggestions = true
            debounceSearch()
        }
    }

    @ViewBuilder
    private var content: some View {
        if searching && results.isEmpty && tvResults.isEmpty {
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
                    PosterGrid(items: results, columns: 3)
                        .padding(.bottom, 6)
                }
                if !tvResults.isEmpty {
                    // 三端通用的「源上直接搜」（2026-09-22：搜不到本地就穿透到源，用户：
                    // 「别不三级蜜桃成熟时我搜索是不是得能看到找到」）
                    sectionDivider("内置源结果 · 可直接播")
                    PosterGrid(items: tvResults, columns: 3)
                        .padding(.bottom, 6)
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
        .background(theme.background)
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

    /// 热搜榜 TOP10（影视热词，静态榜单 + 本地点击即搜）。
    private static let hotWords = [
        "狂飙", "三体", "流浪地球", "满江红", "消失的她",
        "孤注一掷", "长相思", "莲花楼", "庆余年", "繁花"
    ]

    private var hotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("热搜榜", systemImage: "flame.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 16)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 10) {
                ForEach(Array(Self.hotWords.enumerated()), id: \.offset) { idx, word in
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
        let pool: [TVBoxSite]
        switch mode {
        case "adult":
            // 索倪（混合源）在前：用户点名的成人分类全在它里面
            pool = Array((DefaultSites.builtinMixedVodSources + DefaultSites.builtinAdultVodSources)
                .prefix(14))
        case "child":
            pool = Array(DefaultSites.builtinVodSources(forMode: "child").prefix(8))
        default:
            // 星幕：剧集源 + 共通源（含索倪 4 万+ 电影）——搜电影也要能穿透
            pool = Array((DefaultSites.tvDramaSources
                          + DefaultSites.builtinVodSources(forMode: "normal")).prefix(12))
        }
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { tvResults = []; return }
        tvSearchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, q == self.query else { return }
            let hits: [FeedItem] = await withTaskGroup(of: [FeedItem]?.self) { group in
                for site in pool {
                    group.addTask {
                        let c = TVBoxSiteClient(site: site)
                        let r = await c.search(q).filter {
                            NavPolicy.allowsItem(title: $0.title,
                                                 sourceCategory: $0.aggregateCategoryName,
                                                 mode: mode)
                        }
                        return r.isEmpty ? nil : r
                    }
                }
                // 多源合并去重（先到先得，凑够 36 条即取消其余源）
                var acc: [FeedItem] = []
                var seen = Set<String>()
                for await r in group {
                    guard let r else { continue }
                    for it in r where acc.count < 36 {
                        let k = it.title + "|" + (it.year ?? "")
                        if seen.insert(k).inserted { acc.append(it) }
                    }
                    if acc.count >= 36 { group.cancelAll(); break }
                }
                return acc
            }
            await MainActor.run {
                guard q == self.query else { return }   // 用户已继续输入：过期结果丢弃
                self.tvResults = Array(hits.prefix(36))
                self.searching = false
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
