import SwiftUI
import FilmCore

/// 分类浏览：**导航大类 chips**（已多源合并）→ 组内二级筛选（地区/子类型）→ 年份 → 排序 → 分页海报墙。
///
/// 2026-09-22 用户指令（本页三次校正）：
///  1. 「我现在打开我的分类，我看到的是三个分类，这个不太对，应该都是属于伦理下面的，
///      像日本伦理、西方伦理这些」→ 分类 chips 不再直读 feed 原始分类，改走 `NavCatalog` 归并大类。
///  2. 「情色就是三级片啊，不应该是港台三级、三级、情色合并一个分类的吗」
///     「还有两性课堂不就是成人动漫吗」→ 归并口径在 `NavPolicy` 词表里（本页自动生效）。
///  3. 「而且还不能翻页」→ 底部加**真页码翻页**（上一页 / 页码 / 下一页），不再只有单调的「加载更多」。
///
/// 2026-09-23 用户指令：「分类里没有国家地区筛选找片太难找了」→ 新增独立的**地区筛选行**
/// （国产/中国香港/中国台湾/日本/韩国/美国/欧洲/泰国/印度/其他），数据来自中台 feed 的 `area` 字段
/// （源站 vod_area 归一化，覆盖率 99%+），与「类型/年份/排序」正交叠加，可任意组合。
public struct CategoryBrowseView: View {
    @EnvironmentObject private var store: CatalogStore
    @Environment(\.filmTheme) private var theme
    /// 整页取色底（2026-09-23 落「方案 A」）：跟随主视觉当前海报色，和首页连成一片。
    @ObservedObject private var tint = HeroTintStore.shared

    @State private var selectedGroupID: String? = nil
    @State private var selectedSubID: String? = nil
    @State private var selectedYear: String? = nil
    @State private var selectedSort: SortMode = .overall
    /// 排序键缓存（dedupId → 预提取键）：排序时零字符串解析 → 点一下即刻重排。
    /// 2026-09-23 用户「分类里面有排序按钮却用不了点击没有任何效果」修复之一。
    @State private var keyCache: [String: SortKey] = [:]
    /// 换档后把列表滚回顶部的信号（停在原位置看起来就像没生效）。
    @State private var sortScrollTick = 0
    /// 地区筛选（nil = 全部）—— 2026-09-23 用户指令。
    @State private var selectedArea: String? = nil
    @State private var page = 1
    /// 年份行「更早」展开（方案 A：年份只列前 12 个带计数，点「更早」展全）—— 2026-09-23。
    @State private var yearsExpanded = false

    /// 一个年份筛选项（带真实条数）—— 方案 A 的「年份带计数」。
    struct YearCount: Identifiable, Hashable {
        let year: String
        let count: Int
        var id: String { year }
    }

    /// 一个地区筛选项（Swift 不支持 tuple 的 keyPath，故用具名结构）。
    struct AreaCount: Identifiable, Hashable {
        let name: String
        let count: Int
        var id: String { name }
    }

    /// 预提取的排序键（`sortKey(of:)` 产出并缓存进 `keyCache`）。
    ///
    /// 拆出来单存的意义：排序时只需比较两个 `Int`/`Double`，
    /// **零字符串解析、零字典查 `quality_score`** → 点一下即刻重排（真机可感）。
    struct SortKey: Hashable {
        /// 年份（1900–2027 之外一律归 0，脏年份不上顶）。
        let year: Int
        /// 真热度：`HomePolicy.votes` 票数，无票回退 `hits`。
        let hot: Double
    }

    /// 归并后的大类（`NavCatalog` 唯一入口）。
    @State private var groupsCache: [NavCatalog.Group] = []
    @State private var filteredCache: [FeedItem] = []
    @State private var yearsCache: [YearCount] = []
    /// 当前大类范围内真实存在的地区及条数（决定地区 chip 出哪些、显示多少部）。
    @State private var areasCache: [AreaCount] = []
    @State private var computing = true
    /// 入口分类只解析一次（首屏把「日本伦理」定位到「伦理 · 日本」）。
    @State private var consumedEntry = false

    /// 排序档（综合 / 最新 / 最热）—— 2026-09-22 大牌对齐审计 P0④
    public enum SortMode: String, CaseIterable, Identifiable {
        case overall, latest, hot
        public var id: String { rawValue }
        var title: String {
            switch self {
            case .overall: return "综合"
            case .latest:  return "最新"
            case .hot:     return "最热"
            }
        }
    }

    private let entryCategoryID: String?
    private let pageSize = 60
    /// 列表顶部锚点（换排序后滚回此处）。
    private static let topAnchor = "categoryBrowseTop"

    /// - Parameters:
    ///   - initialCategory: 原始源分类 id（首页「分类」chip 带进来）→ 自动定位到它所属的大类。
    ///   - initialGroup: 大类 id（分类总览页带进来）。
    public init(initialCategory: String? = nil, initialGroup: String? = nil) {
        self.entryCategoryID = initialCategory
        _selectedGroupID = State(initialValue: initialGroup)
        _consumedEntry = State(initialValue: initialGroup != nil)
    }

    /// 当前产品模式（星幕 normal / 心屋 child / 夜航 adult）—— 归并与隔离都按它走。
    private var mode: String { TVBoxConfigStore.currentProductMode() }

    private var activeGroup: NavCatalog.Group? {
        guard let id = selectedGroupID else { return nil }
        return groupsCache.first { $0.id == id }
    }

    private var activeSub: NavCatalog.Sub? {
        guard let g = activeGroup, let s = selectedSubID else { return nil }
        return g.subs.first { $0.id == s }
    }

    public var body: some View {
        VStack(spacing: 0) {
            poolBar
            categoryBar
            subBar
            areaBar
            yearBar
            sortBar
            content
        }
        .background(tintBackground.ignoresSafeArea())
        .navigationTitle(activeGroup?.title ?? "分类")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: recomputeKey) { await recompute() }
        .onChange(of: store.catalog.items.count) { _ in refreshGroups() }
    }

    /// 整页取色底（方案 A 落地）：对齐原型分类页 `__catTint` —— mid α.40 → deep×0.94（0.31 处）→ 近黑收口。
    /// 与首页同一个 `HeroTintStore.shared.current`，所以从首页进分类页颜色是连着的，不跳色。
    private var tintBackground: some View {
        let p = tint.current
        return LinearGradient(stops: [
            .init(color: p.mid.alpha(0.40), location: 0.00),
            .init(color: p.deep.scaled(0.94).color, location: 0.31),
            .init(color: Color(hex: "#0A0A0D") ?? .black, location: 0.76)
        ], startPoint: .top, endPoint: .bottom)
        .animation(.easeInOut(duration: 0.9), value: tint.current)
    }

    // MARK: - 大类 / 二级项

    /// 归类（分类总数只有几十~几百，主线程算足够快，且避免并发隔离问题）。
    private func refreshGroups() {
        // 去重加固（2026-09-23 用户：「分类里居然弄出两个电视剧」）：
        // 同一 title 只保留条数最多的那一个 —— 数据侧一旦出现同名/同义大类，也不会同屏出现两个同名入口。
        var seenTitle = Set<String>()
        groupsCache = NavCatalog.groups(categories: store.catalog.categories, mode: mode)
            .sorted { $0.count > $1.count }
            .filter { seenTitle.insert($0.title).inserted }
        // 入口分类解析：把原始分类定位到「它被并进的大类 + 对应的二级项」
        if !consumedEntry, let e = entryCategoryID {
            consumedEntry = true
            if let g = groupsCache.first(where: { $0.catIDs.contains(e) }) {
                selectedGroupID = g.id
                if let sub = g.subs.first(where: { $0.catIDs.contains(e) }) { selectedSubID = sub.id }
            }
        }
    }

    private var forcedEntryKey: String { "\(entryCategoryID ?? "_")|\(selectedGroupID ?? "_")|\(selectedSubID ?? "_")" }

    /// 重算键**不含 selectedSort** —— 排序与过滤彻底解耦：
    /// 换档只做一次内存重排（毫秒级）；旧实现每换一档都要整趟「全量过滤 + 年份/地区统计」，
    /// 期间又没有任何进度提示 → 真机上表现为"点了没有任何效果"。
    private var recomputeKey: String {
        "\(forcedEntryKey)|\(selectedYear ?? "_")|\(selectedArea ?? "_")|\(store.catalog.items.count)|\(groupsCache.count)"
    }

    // MARK: - 内容

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id(Self.topAnchor)   // 滚回顶部的锚点

                if computing && filteredCache.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 420)
                } else if filteredCache.isEmpty {
                    // 红线（2026-09-22 用户钦定）：任何情况不出现分类空态文案。
                    // 走到这里=目录本身为空（首启断网且无快照）→ 加载态 + 自动重试同步。
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("片库加载中…").font(.footnote).foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 420)
                    .task { await store.syncAll() }
                } else {
                    HStack(spacing: 6) {
                        Text("共 \(filteredCache.count) 部")
                            .font(.caption).foregroundStyle(theme.textSecondary)
                        // 当前排序档**显式写出来** —— 换档立刻可见的反馈（以前点完屏幕上毫无提示）
                        Text("· 按「\(selectedSort.title)」")
                            .font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
                        Spacer()
                        Text("第 \(page)/\(pageCount) 页")
                            .font(.caption.monospacedDigit()).foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, 16).padding(.top, 8)

                    PosterGrid(items: pageSlice, columns: 3)
                        .padding(.vertical, 12)

                    // 内置源并轨入口（2026-09-25 钦点）：本大类下还有内置源的分类 → 点进看源内容
                    SourceGroupEntryLine(title: activeGroup?.title ?? "")

                    pager
                }
            }
            .onChange(of: sortScrollTick) { _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
            }
        }
        .onChange(of: selectedGroupID) { _ in page = 1 }
        .onChange(of: selectedSubID) { _ in page = 1 }
        .onChange(of: selectedYear) { _ in page = 1 }
        .onChange(of: selectedArea) { _ in page = 1 }
        .onChange(of: selectedSort) { _ in
            // ★ 排序与过滤解耦（2026-09-23 修复）：换档只重排**已算好的**列表 → 点击即时生效。
            page = 1
            if !filteredCache.isEmpty {
                filteredCache = Self.sortedList(filteredCache, using: keyCache, by: selectedSort)
            }
            sortScrollTick += 1
        }
    }

    /// 当前页切片（本地全量已算好，翻页只是换窗口 —— 秒翻，不重新过滤）。
    private var pageSlice: [FeedItem] {
        let start = min(max(0, (page - 1) * pageSize), filteredCache.count)
        let end = min(start + pageSize, filteredCache.count)
        return start < end ? Array(filteredCache[start..<end]) : []
    }

    private var pageCount: Int {
        max(1, (filteredCache.count + pageSize - 1) / pageSize)
    }

    /// 页码序列（nil = 省略号）。
    private var pagerItems: [Int?] {
        let total = pageCount
        if total <= 7 { return (1...total).map { Optional($0) } }
        var out: [Int?] = [1]
        let lo = max(2, page - 2), hi = min(total - 1, page + 2)
        if lo > 2 { out.append(nil) }
        if lo <= hi { for i in lo...hi { out.append(i) } }
        if hi < total - 1 { out.append(nil) }
        out.append(total)
        return out
    }

    /// ★ 真翻页（2026-09-22 用户：「而且还不能翻页」）。
    private var pager: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                pageButton("上一页", enabled: page > 1) { page = max(1, page - 1) }
                ForEach(Array(pagerItems.enumerated()), id: \.offset) { _, n in
                    if let n {
                        pageNumberButton(n)
                    } else {
                        Text("…").font(.footnote).foregroundStyle(theme.textSecondary)
                    }
                }
                pageButton("下一页", enabled: page < pageCount) { page = min(pageCount, page + 1) }
            }
            HStack(spacing: 14) {
                pageButton("首页", enabled: page > 1) { page = 1 }
                pageButton("末页", enabled: page < pageCount) { page = pageCount }
                Text("第 \(page) / \(pageCount) 页 · 每页 \(pageSize) 部")
                    .font(.caption2).foregroundStyle(theme.textSecondary)
            }
            .padding(.bottom, 24)
        }
        .padding(.top, 6)
    }

    private func pageButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(enabled ? 0.10 : 0.04)))
                .foregroundStyle(enabled ? theme.textPrimary : theme.textSecondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func pageNumberButton(_ n: Int) -> some View {
        Button {
            page = n
        } label: {
            Text("\(n)")
                .font(.footnote.weight(n == page ? .bold : .regular).monospacedDigit())
                .frame(minWidth: 26)
                .padding(.vertical, 7)
                // 2026-09-23 编译事故修正：`Capsule().fill(...)` 是 **View**，不能塞进 AnyShapeStyle
                // （`error: initializer 'init(_:)' requires that 'some View' conform to 'ShapeStyle'`）。
                // 玻璃态要「fill + overlay + stroke」多层 → 只能用闭包形式 .background { }。
                .background {
                    if n == page {
                        Capsule().fill(.white.opacity(0.22))
                            .overlay(Capsule().stroke(.white.opacity(0.36), lineWidth: 1))
                    } else {
                        Capsule().fill(.white.opacity(0.08))
                    }
                }
                .foregroundStyle(n == page ? .white : theme.textPrimary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 数据

    @MainActor
    private func recompute() async {
        if groupsCache.isEmpty { refreshGroups() }
        computing = true
        let catalog = store.catalog
        let ids: [String]? = activeSub?.catIDs ?? activeGroup?.catIDs
        let year = selectedYear
        let area = selectedArea
        let result: (list: [FeedItem], years: [YearCount],
                     areas: [AreaCount], areaValid: Bool, keys: [String: SortKey])
            = await Task.detached(priority: .userInitiated) {
            var list = ids == nil ? catalog.items : catalog.items(inCategories: ids!)
            // 年份分布（带真实条数，方案 A「年份带计数 + 更早」）—— 统计先于过滤，保证每枚 chip 点了必有片
            var yearCount: [String: Int] = [:]
            for it in list {
                if let y = it.displayYear, y.count <= 4 { yearCount[y, default: 0] += 1 }
            }
            // 地区分布（先统计再过滤：保证每个 chip 点了必有内容）—— 2026-09-23 用户指令
            var areaCount: [String: Int] = [:]
            for it in list {
                let a = (it.area?.isEmpty == false) ? it.area! : "其他"
                areaCount[a, default: 0] += 1
            }
            // 地区筛选（与分类/年份正交；0 条的地区该大类下不出现，故选中项必定有效）
            var areaValid = true
            if let area {
                let af = list.filter { ((($0.area ?? "").isEmpty) ? "其他" : ($0.area ?? "")) == area }
                if af.isEmpty { areaValid = false } else { list = af }
            }
            if let year {
                let yf = list.filter { $0.year == year }
                // 红线（2026-09-22 用户钦定）：年份过滤致空 → 自动忽略年份，永不空态
                if !yf.isEmpty { list = yf }
            }
            // 红线：分类过滤致空 → 回退全量目录，任何情况不出分类空态文案
            if list.isEmpty { list = catalog.items }
            // ★ 排序键预提取（后台一次性算好）—— 返回的是**未排序**的过滤结果，
            // 由主线程按当前档位排序：这样 recompute 期间用户改档也不会被旧档覆盖。
            var keys: [String: SortKey] = [:]
            keys.reserveCapacity(list.count)
            for it in list { keys[it.dedupId] = Self.sortKey(of: it) }
            // 地区 chip 排序：先按中台口径固定顺序，其余按条数
            let order = NavPolicy.regionOrder
            let areas = areaCount.map { AreaCount(name: $0.key, count: $0.value) }
                .sorted { a, b in
                    let ia = order.firstIndex(of: a.name) ?? Int.max
                    let ib = order.firstIndex(of: b.name) ?? Int.max
                    if ia != ib { return ia < ib }
                    return a.count > b.count
                }
            return (list, yearCount.map { YearCount(year: $0.key, count: $0.value) }
                        .sorted { (Int($0.year) ?? 0) > (Int($1.year) ?? 0) },
                    areas, areaValid, keys)
        }.value
        keyCache = result.keys
        filteredCache = Self.sortedList(result.list, using: result.keys, by: selectedSort)
        yearsCache = result.years
        areasCache = result.areas
        if !result.areaValid { selectedArea = nil }
        if page > pageCount { page = pageCount }
        computing = false
    }

    // MARK: - 排序（2026-09-23 修复「排序按钮点了没效果」）

    /// 排序键：年份（脏数据归零）+ 真热度。修复两处真机失效：
    ///  ① 旧「最热」用 `qualityScore` —— 生产 feed 里该键名是 **`quality_score`**（下划线），
    ///     模型未做 CodingKeys 映射 → 解码恒为 nil → 排序键全 0 → **一条都不动**（点了没反应）。
    ///     且中台口径早有定论：qualityScore 是「完整度综合分」不是热度
    ///     （用户 2026-09-23：「热门的片2018的！」）→ 改用 `HomePolicy.votes` 真热度票数，
    ///     无票数回退 `hits`（源站点击）。
    ///  ② 旧「最新」把源站脏年份（2028/2030/2031，实测 39 条）排到最顶 → 一屏垃圾片。
    ///     只认 1900–2027（当前年 +1）。
    static func sortKey(of i: FeedItem) -> SortKey {
        let raw = Int(i.displayYear ?? "") ?? 0
        let year = (raw >= 1900 && raw <= 2027) ? raw : 0
        let v = Double(HomePolicy.votes(i))
        let hot = v > 0 ? v : Double(max(0, i.hits ?? 0))
        return SortKey(year: year, hot: hot)
    }

    /// 排序：综合 = 片库原序（不动）；最新 = 年份降序；最热 = 真热度降序。
    /// **确定性**：键相同时按 `dedupId` 兜底，同一次输入必得同一顺序（可被判据脚本验证）。
    static func sortedList(_ list: [FeedItem], using keys: [String: SortKey],
                           by mode: SortMode) -> [FeedItem] {
        guard mode != .overall else { return list }
        let zero = SortKey(year: 0, hot: 0)
        return list.sorted { a, b in
            let ka = keys[a.dedupId] ?? zero
            let kb = keys[b.dedupId] ?? zero
            switch mode {
            case .overall:
                return false
            case .latest:
                if ka.year != kb.year { return ka.year > kb.year }
                if ka.hot != kb.hot { return ka.hot > kb.hot }
                return a.dedupId < b.dedupId
            case .hot:
                if ka.hot != kb.hot { return ka.hot > kb.hot }
                if ka.year != kb.year { return ka.year > kb.year }
                return a.dedupId < b.dedupId
            }
        }
    }

    // MARK: - 筛选栏

    /// 数据自检行（2026-09-23 用户：「85000 的片库按理来说不应该每个分类那么少的影片」「印度片就一部」）。
    ///
    /// 「分类里少片」有两个完全不同的根因，肉眼分不清：
    ///   ① 端侧只拿到首屏小包（全量分片没同步上来）→ 本行显示的数字会很小；
    ///   ② 分类映射丢条目（词表没覆盖）→ 本行数字正常、但分类少。
    /// 把真实片库规模显式写出来，一眼分辨，不用再靠猜。
    private var poolBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive").font(.system(size: 10))
            Text("片库 \(store.catalog.items.count) 条 · \(groupsCache.count) 个分类")
                .font(.caption2)
            Spacer()
            if case .syncing(let p, let t) = store.phase, t > 0 {
                Text("同步中 \(p)/\(t)").font(.caption2)
            }
        }
        .foregroundStyle(theme.textSecondary.opacity(0.85))
        .padding(.horizontal, 16).padding(.top, 6)
    }

    /// 一级：合并后的导航大类（一个源一个分类 → 我们的一个大类）。行标题「类型」对齐爱优腾。
    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                chipLabel(name: "类型")
                chip(name: "全部", selected: selectedGroupID == nil) {
                    selectedGroupID = nil
                    selectedSubID = nil
                }
                ForEach(groupsCache) { g in
                    chip(name: g.title, selected: selectedGroupID == g.id) {
                        selectedGroupID = selectedGroupID == g.id ? nil : g.id
                        selectedSubID = nil
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(height: 50)   // 定高：横滚 ScrollView 在 VStack 里高度贪婪，不定高会和海报墙对半分屏
    }

    /// 二级：组内「地区 / 子类型」（韩国 / 日本 / 港台 / 西方…）。
    @ViewBuilder
    private var subBar: some View {
        if let g = activeGroup, !g.subs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    chip(name: "全部", selected: selectedSubID == nil) { selectedSubID = nil }
                    ForEach(g.subs) { s in
                        chip(name: s.label, selected: selectedSubID == s.id) {
                            selectedSubID = selectedSubID == s.id ? nil : s.id
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .frame(height: 46)
        }
    }

    /// 地区筛选行（2026-09-23 用户指令「分类里没有国家地区筛选找片太难找了」）。
    ///
    /// 只列**当前大类里真实有内容**的地区（带条数），所以点了一定有片；
    /// 顺序按 `NavPolicy.regionOrder`（国产/中国香港/中国台湾/日本/韩国/美国/欧洲/泰国/印度/其他）。
    @ViewBuilder
    private var areaBar: some View {
        if areasCache.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    chipLabel(name: "地区")
                    chip(name: "全部", selected: selectedArea == nil) { selectedArea = nil }
                    ForEach(areasCache) { a in
                        chip(name: a.name, selected: selectedArea == a.name) {
                            selectedArea = selectedArea == a.name ? nil : a.name
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .frame(height: 46)
        }
    }

    /// 排序行：`排序` 是**行标题**（不可点），后面三枚才是档位按钮。
    ///
    /// 2026-09-23 用户「分类里面有排序按钮却用不了点击没有任何效果」：
    /// 旧实现的「排序」本身是个按钮，点了只是把档位**复位**成「综合」——已选综合时点它毫无变化
    /// → 真机手感就是"死的"。改成标题 + 三档可点，点哪档立刻重排并滚回顶部。
    private var sortBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                chipLabel(name: "排序")
                ForEach(SortMode.allCases) { m in
                    chip(name: m.title, selected: selectedSort == m) { selectedSort = m }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .frame(height: 44)
    }

    /// 行标题样式（与 `chip` 同规格占位，但**不可点**、无选中态）。
    private func chipLabel(name: String) -> some View {
        Text(name)
            .font(.footnote)
            .lineLimit(1)
            .foregroundStyle(theme.textSecondary.opacity(0.7))
            .padding(.vertical, 7)
    }

    /// 年份行（方案 A：**带计数 + 「更早」**）—— 2026-09-23 用户选型「A 爱奇艺·腾讯式」。
    ///
    /// 只列前 12 个年份（最新在前），点「更早」展开全部年份；每枚 chip 显示该年真实条数，
    /// 点了一定有片（统计先于过滤）。年份为**纯数字排序**（旧实现字符串排序会让 "1998" > "2026" 错位）。
    private var yearBar: some View {
        Group {
            if !yearsCache.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        chipLabel(name: "年份")
                        chip(name: "全部", selected: selectedYear == nil) { selectedYear = nil }
                        ForEach(yearsExpanded ? yearsCache : Array(yearsCache.prefix(12))) { y in
                            chip(name: y.year, selected: selectedYear == y.year) {
                                selectedYear = selectedYear == y.year ? nil : y.year
                            }
                        }
                        if !yearsExpanded && yearsCache.count > 12 {
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) { yearsExpanded = true }
                            } label: {
                                HStack(spacing: 3) {
                                    Text("更早")
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                }
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(.white.opacity(0.14)))
                                .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 8)
                }
                .frame(height: 46)
            }
        }
    }

    private func chip(name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.footnote.weight(selected ? .bold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 7)
                // 2026-09-25 用户钦点：分类按钮统一**导航条式透明玻璃**（ultraThinMaterial 毛玻璃
                // + 发丝描边），跟随变色系统（accent）。选中=accent 字+accent 描边；未选=素字淡框。
                .background {
                    if selected {
                        Capsule().fill(.ultraThinMaterial)
                            .overlay(Capsule().stroke(theme.accent.opacity(0.55), lineWidth: 1))
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
                    }
                }
                .contentShape(Capsule())   // 整枚胶囊都可点（硬化命中区，防横滚手势吞点击）
        }
        .buttonStyle(.plain)
    }
}
