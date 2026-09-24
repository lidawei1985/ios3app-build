import SwiftUI
import FilmCore

/// 海报卡片（2:3 比例稳定，标题两行截断，点击区域整卡）。
/// 长按出快捷菜单（大牌标配：收藏 / 分享）—— 2026-09-22 用户要求对齐主流视频 App。
public struct PosterCard: View {
    let item: FeedItem
    /// 「命中来源」标注（搜索结果里说明这条为何出现，如「演员 李丽珍」）
    var badge: String? = nil
    @Environment(\.filmTheme) private var theme
    @EnvironmentObject private var library: UserLibrary

    public init(item: FeedItem, badge: String? = nil) {
        self.item = item; self.badge = badge
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 2:3 盒子用 Color.clear 强制（clear 无固有比例，aspectRatio 必生效）；
            // 挂在图片上会被加载后图片的自带宽高比反向污染，横版封面会把卡片撑爆互相重叠
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .overlay {
                    PosterImage(urlString: item.poster?.url ?? item.backdrop?.url)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let year = item.displayYear {
                        Text(year)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(theme.accent.opacity(0.92), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(item.title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        // 长按快捷菜单（大牌标配）：收藏 / 分享，不用进详情页就能操作
        .contextMenu {
            Button {
                library.toggleFavorite(item)
            } label: {
                Label(library.isFavorite(item) ? "取消收藏" : "收藏",
                      systemImage: library.isFavorite(item) ? "heart.slash" : "heart")
            }
            Button {
                SharePresenter.share(item: item)
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// 横向海报货架（首页推荐栏；滚动顺畅 + 懒加载）。
public struct PosterRail: View {
    let title: String
    let items: [FeedItem]
    @Environment(\.filmTheme) private var theme

    public init(title: String, items: [FeedItem]) {
        self.title = title; self.items = items
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(items.prefix(30)) { item in
                        // 显式 destination：value 路由在旧式推入的页面里有 iOS 18 解析失效坑（推送即弹回）
                        NavigationLink { DetailView(item: item) } label: {
                            PosterCard(item: item)
                                .frame(width: 104)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// 竖版海报墙网格（分类/搜索结果复用；分页追加 + 懒加载）。
/// `badges`：可选的「命中来源」标注（dedupId → 文案，如「演员 李丽珍」），搜索结果页用它说明这条为何出现。
public struct PosterGrid: View {
    let items: [FeedItem]
    var columns: Int = 3
    var badges: [String: String] = [:]

    public init(items: [FeedItem], columns: Int = 3, badges: [String: String] = [:]) {
        self.items = items; self.columns = columns; self.badges = badges
    }

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 16) {
            ForEach(items) { item in
                // 显式 destination（同 PosterRail：绕开 value 路由在深层推入页的解析坑）
                NavigationLink { DetailView(item: item) } label: {
                    PosterCard(item: item, badge: badges[item.dedupId])
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }
}
