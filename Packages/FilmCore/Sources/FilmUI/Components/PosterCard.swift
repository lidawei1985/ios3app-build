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

/// 按 dedupId 保序去重。
///
/// 2026-10-02「点 1 得 2」结构性加固：`ForEach` 的身份就是 `dedupId`，
/// 一旦列表里出现**重复身份**（同一部片来自不同源、历史里存了两条……），
/// SwiftUI 的 diff 会复用/串台，格子看到的是 A、点下去跑的却可能是同 id 的 B。
/// 去重后身份唯一，这一整类病连根拔掉。
private func dedupKeepOrder(_ items: [FeedItem]) -> [FeedItem] {
    var seen = Set<String>()
    var out: [FeedItem] = []
    out.reserveCapacity(items.count)
    for it in items where seen.insert(it.dedupId).inserted { out.append(it) }
    return out
}

/// 横向海报货架（首页推荐栏；滚动顺畅 + 懒加载）。
public struct PosterRail: View {
    let title: String
    let items: [FeedItem]
    /// 点击痕迹标注（2026-10-02「点 1 得 2」取证：定位是哪个货架）
    var traceTag: String = ""
    @EnvironmentObject private var router: DetailRouter
    @Environment(\.filmTheme) private var theme

    public init(title: String, items: [FeedItem], traceTag: String = "") {
        self.title = title; self.items = items; self.traceTag = traceTag
    }

    /// 去重后的真实渲染列表（身份唯一，见 `dedupKeepOrder`）
    private var shown: [FeedItem] { dedupKeepOrder(items) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                // 2026-10-02「点 1 得 2」再修：ForEach 身份用 dedupId（经 dedupKeepOrder
                // 去重后已唯一），比下标更稳；下标身份会让 SwiftUI 把同一格视图复用给
                // 不同 item，Button action 闭包可能还抓着旧 item。
                LazyHStack(spacing: 10) {
                    // 2026-10-02「点 1 得 2」再修：ForEach 身份用 dedupId（经 dedupKeepOrder
                    // 去重后已唯一），比下标更稳；下标身份会让 SwiftUI 把同一格视图复用给
                    // 不同 item，Button action 闭包可能还抓着旧 item。
                    ForEach(Array(shown.prefix(30).enumerated()), id: \.element.dedupId) { i, item in
                        // 详情卡弹层（2026-09-25 钦定）：底部圆角卡片，不再整页推入
                        Button { router.open(item, from: "\(traceTag.isEmpty ? title : traceTag)#\(i)") } label: {
                            PosterCard(item: item)
                                .frame(width: 104)
                        }
                        .buttonStyle(.plain)
                        // 2026-10-03 与 PosterGrid 同根因：横向货架最左侧卡片也可能被屏幕左缘手势区吞 tap。
                        .contentShape(Rectangle())
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
    /// 点击痕迹标注（2026-10-02「点 1 得 2」取证：区分自有片库 / 内置源结果）
    var traceTag: String = ""
    @EnvironmentObject private var router: DetailRouter

    public init(items: [FeedItem], columns: Int = 3, badges: [String: String] = [:],
                traceTag: String = "") {
        self.items = items; self.columns = columns; self.badges = badges
        self.traceTag = traceTag
    }

    /// 去重后的真实渲染列表（身份唯一，见 `dedupKeepOrder`）
    private var shown: [FeedItem] { dedupKeepOrder(items) }

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 16) {
            // 2026-10-02「点 1 得 2」再修：身份用 dedupId（去重后唯一），比下标更稳。
            ForEach(Array(shown.enumerated()), id: \.element.dedupId) { i, item in
                // 详情卡弹层（同 PosterRail）
                Button { router.open(item, from: "\(traceTag.isEmpty ? "grid" : traceTag)#\(i)") } label: {
                    PosterCard(item: item, badge: badges[item.dedupId])
                }
                .buttonStyle(.plain)
                // 2026-10-03 主人：电视剧页第一列卡片经常点不动 / 像没点到。
                // 真机 taptrace 证实 Button action 根本没触发，推测是 iOS 屏幕左缘系统返回手势区
                // 把落在第一列的轻触当拖拽吞掉。contentShape 保证整卡都是命中区，配合 leading
                // 内边距增大让第一列中心离开手势区。
                .contentShape(Rectangle())
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
    }
}
