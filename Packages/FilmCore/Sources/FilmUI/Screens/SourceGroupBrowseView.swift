import SwiftUI
import FilmCore

/// 内置源分组页（2026-09-25 用户钦点「内置源内容进分类」的落点之二）。
///
/// 两处入口：
///  1. **分类总览页**里由源分类新立的大类（我们原有分类没有的）→ 整页就是内置源内容；
///  2. **分类浏览页**底部入口行 →「这个大类里还有内置源的 N 个分类」点进来。
///
/// 页内结构：每条「源分类」一段 —— 段头（源名 · 分类名 + 全部→源浏览页）+ 首页海报墙。
/// 看更多/翻页/搜索走成熟的 `SiteBrowseView`（35包翻页、源内搜索、补图都在那边）。
public struct SourceGroupBrowseView: View {
    let title: String
    @ObservedObject private var src = SourceCategoryIndex.shared
    @Environment(\.filmTheme) private var theme

    public init(title: String) { self.title = title }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                let refs = src.refs(inGroup: title)
                if refs.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(src.status == .loading ? "内置源分类加载中…" : "该分类暂无内置源内容")
                            .font(.footnote).foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(refs) { r in
                        RefSection(ref: r, site: src.site(for: r.siteKey))
                    }
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .background(theme.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("内置源 · \(src.refs(inGroup: title).count) 个源分类")
                .font(.footnote).foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

/// 分类浏览页底部的「内置源」入口行：本大类下还有内置源分类时显示，点进分组页。
struct SourceGroupEntryLine: View {
    let title: String
    @ObservedObject private var src = SourceCategoryIndex.shared
    @Environment(\.filmTheme) private var theme

    var body: some View {
        let refs = src.refs(inGroup: title)
        if !refs.isEmpty {
            NavigationLink {
                SourceGroupBrowseView(title: title)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.caption).foregroundStyle(theme.accent)
                    Text("内置源 · \(refs.count) 个源分类")
                        .font(.footnote.weight(.medium)).foregroundStyle(theme.accent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 单条「源分类」段：首页海报 + 进源浏览页看全部。
struct RefSection: View {
    let ref: SourceCategoryIndex.Ref
    let site: TVBoxSite?
    @Environment(\.filmTheme) private var theme
    @State private var items: [FeedItem] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(site?.name ?? ref.siteKey)
                    .font(.footnote.weight(.semibold)).foregroundStyle(theme.textPrimary)
                Text(ref.catName)
                    .font(.caption2).foregroundStyle(theme.textSecondary)
                Spacer()
                if let site {
                    NavigationLink {
                        SiteBrowseView(site: site)
                    } label: {
                        Text("全部")
                            .font(.caption.weight(.medium)).foregroundStyle(theme.accent)
                    }
                }
            }
            .padding(.horizontal, 16)

            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            } else if items.isEmpty {
                Text("该分类暂时拉不到内容")
                    .font(.caption).foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 16)
            } else {
                PosterGrid(items: Array(items.prefix(12)), columns: 3)
            }
        }
        .task(id: ref.id) { await load() }
    }

    /// 首页内容（ac=list&pg=1）。**海报必须 enrichPosters**：
    /// 已知坑（34包取证）——ac=list 的 vod_pic 全空，图只在 ac=detail 返回，不补=整段空海报。
    private func load() async {
        guard let site else { loading = false; return }
        let client = TVBoxSiteClient(site: site)
        let pg = await client.listPage(categoryId: ref.catID, page: 1)
        var got = pg.items
        if !got.isEmpty {
            got = await client.enrichPosters(got, limit: 12)
        }
        items = got
        loading = false
    }
}
