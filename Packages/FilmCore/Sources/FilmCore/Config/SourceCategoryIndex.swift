import Foundation

/// 内置源分类聚合器（2026-09-25 用户钦点「内置源内容进分类」）。
///
/// 用户原话：「内置源内容能不能进分类？比如切换量子源，他的分类都会进到我们对应的分类；
/// 有的进没有的分类就直接出现新分类」。
///
/// 职责：把当前生效配置线路里**所有点播源**的分类表（ac=class，叶子）拉回来，
/// 逐个过 `NavPolicy.navTitleOrNewcomer` 映射成我们的大类：
///  - 命中现有大类（电影/电视剧/动漫/短剧/伦理…）→ 并进该大类（分类总览页在大类下标出「含内置源 N 类」）；
///  - 没有的分类 → **新分类**直接出现（分类总览页新增一行，点进去看内置源内容）；
///  - 红线/排除词拦下的（星幕的综艺体育、心屋的成人恐怖…）→ 不可见，不出新分类。
///
/// 条数策略：分类表本身不带条数 → 大类条数用 `listPage(pg:1)` 的 `total` 懒加载
/// （并发受控，后台补齐，先出「源」占位再变真数）。
@MainActor
public final class SourceCategoryIndex: ObservableObject {

    /// TaskGroup 子任务结果（Swift 6 下「带标签元组+Optional」直接做 of: 会类型歧义，
    /// v12b 编译失败根因 → 改具名 struct；空 cats 自然无贡献，连 nil 都不用）
    private struct SiteCatBatch {
        let key: String
        let name: String
        let cats: [SiteCategory]   // categories() 的原生返回类型（id=type_id / name=type_name）
    }

    /// 一条「源分类引用」：哪个源的哪个分类，被归进了哪个大类。
    public struct Ref: Identifiable, Hashable {
        public let siteKey: String
        public let siteName: String
        public let catID: String
        public let catName: String
        public let groupTitle: String
        /// true = 我们原有分类里没有、由源分类新立的大类。
        public let isNewCategory: Bool
        public var id: String { "\(siteKey)|\(catID)" }
    }

    @Published public private(set) var refs: [Ref] = []
    @Published public private(set) var status: Status = .idle

    public enum Status: Equatable { case idle, loading, ready, failed }

    public static let shared = SourceCategoryIndex()

    private init() {}

    // MARK: - 查询

    /// 某大类下的全部源分类引用（保持源顺序）。
    public func refs(inGroup title: String) -> [Ref] {
        refs.filter { $0.groupTitle == title }
    }

    /// 由源分类新立的大类标题（按首次出现顺序，feed 里没有的那些）。
    public var newcomerTitles: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in refs where r.isNewCategory && seen.insert(r.groupTitle).inserted {
            out.append(r.groupTitle)
        }
        return out
    }

    /// 大类是否含内置源内容（用于分类总览页标「含内置源」角标）。
    public func hasSource(inGroup title: String) -> Bool {
        refs.contains { $0.groupTitle == title }
    }

    /// siteKey → 站点对象（分组页「全部」跳源浏览页用）。
    public func site(for key: String) -> TVBoxSite? {
        siteByKey[key]
    }

    // MARK: - 加载

    /// 拉全部源的分类表并归堆。幂等：已 ready 且非 force 直接返回。
    public func load(force: Bool = false) async {
        if loaded && !force { return }
        loaded = true
        guard status != .loading else { return }
        status = .loading
        let mode = TVBoxConfigStore.currentProductMode()
        let sites = TVBoxConfigStore.shared.displayResult.sites
        guard !sites.isEmpty else { status = .failed; return }
        siteByKey = Dictionary(sites.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        var collected: [Ref] = []
        var seen = Set<String>()
        // 并发拉各源分类表（每源一个任务；分类表是小 JSON，量级安全）。
        await withTaskGroup(of: SiteCatBatch.self, body: { group in
            for site in sites {
                group.addTask { () -> SiteCatBatch in
                    let cats = await TVBoxSiteClient(site: site).categories()
                    return SiteCatBatch(key: site.key, name: site.name, cats: cats)
                }
            }
            for await r in group {
                for c in r.cats {
                    guard let t = NavPolicy.navTitleOrNewcomer(c.name, mode: mode),
                          seen.insert("\(r.key)|\(c.id)").inserted else { continue }
                    collected.append(Ref(siteKey: r.key, siteName: r.name,
                                         catID: c.id, catName: c.name,
                                         groupTitle: t.title, isNewCategory: t.isNew))
                }
            }
        })
        refs = collected
        status = collected.isEmpty ? .failed : .ready
        // 注：原计划懒加载各分类条数（loadTotals）；2026-09-25 用户钦点分类不带数字 → 已砍，省 N 次请求。
    }

    private var loaded = false
    /// siteKey → 站点（loadTotals 重建客户端用）。
    private var siteByKey: [String: TVBoxSite] = [:]

}
