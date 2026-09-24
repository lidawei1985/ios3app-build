import SwiftUI
import FilmCore

/// 全部分类页（大牌标配「全部频道 / 全部分类」）。
///
/// 为什么要它（2026-09-22 用户指令）：
/// 「导航要准、分类要全，不能一个分类里只有一部几部」——此前首页导航写死
/// `categories.prefix(20)`，**分类数一超过 20，后面的分类在 App 里就等于消失**；
/// 且分类顺序来自字典无序映射，用户看到的是乱序。本页给出：
///   - 全量分类（不截断）+ 每个分类的条目数（一眼看出哪个分类是空的/只有几部）
///   - 按条目数降序（热门在前），并可按名称排序
///   - 默认隐藏 0 条分类（可选显示，用于核对"源里有、我们这儿没有"）
///
/// 2026-09-22 二次校正（用户：「打开我的分类看到三个分类，应该都是属于伦理下面的」）：
/// 本页改成展示 **`NavCatalog` 归并后的大类**（伦理 / 三级 / 成人动漫…），
/// 每个大类下列出被并进来的原始源分类数，点进去就是大类全量内容。
public struct CategoryIndexView: View {
    @EnvironmentObject private var store: CatalogStore
    @Environment(\.filmTheme) private var theme

    @State private var showEmpty = false
    @State private var byName = false

    public init() {}

    /// 归并后的大类（唯一入口，勿绕过）。
    private var groups: [NavCatalog.Group] {
        NavCatalog.groups(categories: store.catalog.categories,
                          mode: TVBoxConfigStore.currentProductMode())
    }

    /// 按当前排序规则整理后的大类。
    private var rows: [NavCatalog.Group] {
        let all = groups
        let list = showEmpty ? all : all.filter { $0.count > 0 }
        return byName ? list.sorted { $0.title < $1.title }
                      : list.sorted { $0.count > $1.count }
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("共 \(groups.count) 个大类 · \(store.catalog.categories.count) 个源分类 · \(store.catalog.items.count) 条内容")
                        .font(.footnote).foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                    Spacer()
                    Button(byName ? "按数量" : "按名称") { byName.toggle() }
                        .font(.footnote).foregroundStyle(theme.accent)
                    Button(showEmpty ? "隐藏空分类" : "显示空分类") { showEmpty.toggle() }
                        .font(.footnote).foregroundStyle(theme.accent)
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)

                LazyVStack(spacing: 0) {
                    ForEach(rows) { g in
                        NavigationLink {
                            CategoryBrowseView(initialGroup: g.id)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(g.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(g.count > 0 ? theme.textPrimary : theme.textSecondary)
                                        .lineLimit(1)
                                    if !g.subs.isEmpty {
                                        Text("含 " + g.subs.prefix(6).map(\.label).joined(separator: " / ")
                                             + (g.subs.count > 6 ? " 等 \(g.subs.count) 项筛选" : ""))
                                            .font(.caption2).foregroundStyle(theme.textSecondary)
                                            .lineLimit(1)
                                    } else if g.catIDs.count > 1 {
                                        Text("合并 \(g.catIDs.count) 个源分类")
                                            .font(.caption2).foregroundStyle(theme.textSecondary)
                                    }
                                }
                                Spacer()
                                Text("\(g.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(g.count > 0 ? theme.textSecondary : theme.accent)
                                Image(systemName: "chevron.right")
                                    .font(.caption2).foregroundStyle(theme.textSecondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("全部分类")
        .navigationBarTitleDisplayMode(.inline)
    }
}
