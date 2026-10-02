import Foundation

/// 导航大类归并层（2026-09-22 用户指令）。
///
/// 用户原话：
///  - 「我现在打开我的分类，我看到的是三个分类，这个不太对，应该都是属于伦理下面的，
///     像日本伦理、西方伦理这些」
///  - 「情色就是三级片啊，不应该是港台三级、三级、情色合并一个分类的吗」
///  - 「还有两性课堂不就是成人动漫吗」
///  - 「多源集合一个分类到我们的一个分类」（一个源一个分类 → 一个我们的大类）
///
/// 背景：`Catalog.categories` 是**中台 feed 原样给出的源分类**（日本伦理 / 韩国伦理 /
/// 西方伦理 / 两性课堂 / 情色 … 各占一格）。此前端侧只有「源浏览页」（SiteBrowseView）
/// 走了 `NavPolicy` 归并，而**首页导航 / 全部分类页 / 分类浏览页三处仍直读原始分类** →
/// 用户打开「分类」看到的就是一堆本该合并的碎分类。
///
/// 本文件把归并逻辑收敛成**唯一入口**：任何 UI 要展示分类，都先过 `NavCatalog.groups(...)`。
public enum NavCatalog {

    /// 二级筛选项（合并大类后组内的「地区 / 子类型」细分）。
    ///
    /// 用户：「合并了是不是得分区域？比如韩国/日本/港台……我想看那种得能找到，也就是筛选吧」。
    /// 同一短名可能来自多个源分类（「韩国伦理」+「韩国三级」→ 都叫「韩国」）→ 合并成一项。
    public struct Sub: Identifiable, Hashable {
        public let id: String          // 短名本身（韩国 / 日本 / 港台 / 西方…）
        public let label: String
        public let count: Int
        public let catIDs: [String]
    }

    /// 一个导航大类（下挂若干个原始源分类）。
    public struct Group: Identifiable, Hashable {
        public let id: String          // NavPolicy 的组 id（adult_ethics / normal_movie…）
        public let title: String       // 展示名（伦理 / 电影 / 三级…）
        public let count: Int          // 组内总条数
        public let catIDs: [String]    // 组内所有原始分类 id
        public let subs: [Sub]         // 二级筛选项
    }

    /// 原始分类 → 导航大类（按 `NavPolicy` 的端策略；顺序 = `NavPolicy` 的组顺序）。
    ///
    /// 不在 `NavPolicy` 组表里的（如夜航那 172 个题材类目 → 兜底「其他」）排在最后，
    /// 组内按条数降序，保证「其他」不会把正经大类挤下去。
    public static func groups(categories: [FeedCategoryStat], mode: String) -> [Group] {
        let policy = NavPolicy.navGroups(forMode: mode)
        var order: [String] = []
        var bag: [String: [FeedCategoryStat]] = [:]
        for c in categories {
            guard let t = NavPolicy.navTitle(forSourceCategory: c.name, mode: mode) else { continue }
            if bag[t] == nil { order.append(t) }
            bag[t, default: []].append(c)
        }
        let policyOrder = policy.map(\.title)
        let sortedTitles = order.sorted { a, b in
            let ia = policyOrder.firstIndex(of: a) ?? Int.max
            let ib = policyOrder.firstIndex(of: b) ?? Int.max
            if ia != ib { return ia < ib }
            return total(bag[a] ?? []) > total(bag[b] ?? [])
        }
        return sortedTitles.map { t in
            let cats = (bag[t] ?? []).sorted { $0.count > $1.count }
            let gid = policy.first(where: { $0.title == t })?.id ?? "other_\(t)"
            return Group(id: gid,
                         title: t,
                         count: total(cats),
                         catIDs: cats.map(\.id),
                         subs: subItems(of: cats, groupTitle: t))
        }
    }

    /// 组内二级筛选项：同名短名合并（韩国伦理 + 韩国三级 → 一个「韩国」）。
    private static func subItems(of cats: [FeedCategoryStat], groupTitle: String) -> [Sub] {
        var order: [String] = []
        var ids: [String: [String]] = [:]
        var counts: [String: Int] = [:]
        for c in cats {
            guard let label = NavPolicy.subLabel(c.name, groupTitle: groupTitle) else { continue }
            if ids[label] == nil { order.append(label) }
            ids[label, default: []].append(c.id)
            counts[label, default: 0] += c.count
        }
        return order.map { Sub(id: $0, label: $0, count: counts[$0] ?? 0, catIDs: ids[$0] ?? []) }
    }

    private static func total(_ cats: [FeedCategoryStat]) -> Int {
        cats.reduce(0) { $0 + $1.count }
    }
}
