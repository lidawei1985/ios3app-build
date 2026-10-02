import SwiftUI
import FilmCore

/// 榜单页（大牌标配：热播榜 / 高分榜 / 新片榜）。
/// 名次 + 海报 + 标题 + 元信息；数据全部来自本地片库，切换即算（后台线程）。
public struct TopListView: View {
    public enum Board: String, CaseIterable, Identifiable {
        case hot, top, fresh
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .hot:   return "热播榜"
            case .top:   return "高分榜"
            case .fresh: return "新片榜"
            }
        }
    }

    @EnvironmentObject private var store: CatalogStore
    @EnvironmentObject private var router: DetailRouter
    @Environment(\.filmTheme) private var theme

    @State private var board: Board = .hot
    @State private var rows: [FeedItem] = []
    @State private var computing = true
    /// 高分榜兜底态（片库真评分不足时按热度排序）——用于给出说明，避免让人觉得"榜单不对"。
    @State private var topFallback = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Picker("榜单", selection: $board) {
                ForEach(Board.allCases) { b in Text(b.title).tag(b) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.top, 8)

            content
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("榜单")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(board.rawValue)|\(store.catalog.items.count)") { await load() }
    }

    private var content: some View {
        ScrollView {
            if computing && rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 320)
            } else if rows.isEmpty {
                // 2026-09-30 用户报「高分榜总是没有」：除了排序筛空，空榜单还会渲染成**整页空白**。
                // 这里补空态说明，不再给一片黑。
                VStack(spacing: 8) {
                    Image(systemName: "list.number")
                        .font(.largeTitle).foregroundStyle(theme.textSecondary.opacity(0.8))
                    Text("这个榜单暂时没有可上榜的影片")
                        .font(.subheadline).foregroundStyle(theme.textSecondary)
                    Text("下拉可刷新片库；片库同步完成后再看会更全")
                        .font(.caption2).foregroundStyle(theme.textSecondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                VStack(spacing: 0) {
                    if topFallback {
                        Text("当前片库评分数据不足，本榜按热度 + 新片排序")
                            .font(.caption2).foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.top, 8)
                    }
                    ForEach(Array(rows.prefix(30).enumerated()), id: \.element.id) { idx, it in
                        Button { router.open(it, from: "榜单") } label: {
                            HStack(spacing: 12) {
                                Text("\(idx + 1)")
                                    .font(.title3.weight(.heavy).monospacedDigit())
                                    .foregroundStyle(idx < 3 ? theme.accent : theme.textSecondary)
                                    .frame(width: 30)
                                PosterImage(urlString: it.bestPosterURL?.absoluteString)
                                    .frame(width: 54, height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(it.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    HStack(spacing: 6) {
                                        if let y = it.displayYear { metaTag(y) }
                                        if let c = it.aggregateCategoryName, !c.isEmpty { metaTag(c) }
                                        // 2026-09-23：榜单直接用真评分/真热度（此前是 qualityScore×10 的伪热度）
                                        let sc = HomePolicy.rating(it)
                                        if sc > 0 { metaTag(String(format: "评分 %.1f", sc)) }
                                        else if HomePolicy.votes(it) >= 1000 {
                                            metaTag("热度 \(HomePolicy.votesText(HomePolicy.votes(it)))")
                                        }
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 16)
                    }
                }
                .padding(.top, 6)
            }
        }
        .refreshable { await store.syncAll(force: true) }   // 用户下拉=明确要最新，强制全量
    }

    private func metaTag(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 4))
    }

    @MainActor
    private func load() async {
        computing = true
        let b = board
        let items = store.catalog.items.filter { $0.bestPosterURL != nil }
        let r: [FeedItem] = await Task.detached(priority: .userInitiated) {
            let currentYear = Calendar.current.component(.year, from: Date())
            func yearNum(_ i: FeedItem) -> Int { Int(i.displayYear ?? "") ?? 0 }
            switch b {
            case .hot:
                // 热播：**真热度**（评分人数）降序；无热度的自然沉底
                return items.sorted { HomePolicy.votes($0) > HomePolicy.votes($1) }
            case .top:
                // 高分：**真评分**降序（原为 qualityScore 综合分，与"高分"名不副实）
                let rated = items.filter { HomePolicy.rating($0) > 0 }
                    .sorted {
                        HomePolicy.rating($0) != HomePolicy.rating($1)
                            ? HomePolicy.rating($0) > HomePolicy.rating($1)
                            : HomePolicy.votes($0) > HomePolicy.votes($1)
                    }
                // 2026-09-30 用户报「高分榜总是出现没有的现象」：
                // 根因＝生产 feed 里**大量条目没有评分字段**（详情页同样显示"暂无评分"），
                // `filter { rating > 0 }` 会把整库筛空 → 榜单空白。
                // 正解＝真评分不足一屏时**退回"热度 + 新片"兜底排序**（榜单永不空），
                // 评分够一屏时仍严格按真评分（原来的语义不变）。
                if rated.count >= HomePolicy.minShelfItems { return rated }
                return items.sorted {
                    HomePolicy.votes($0) != HomePolicy.votes($1)
                        ? HomePolicy.votes($0) > HomePolicy.votes($1)
                        : (HomePolicy.effectiveYear($0) != HomePolicy.effectiveYear($1)
                           ? HomePolicy.effectiveYear($0) > HomePolicy.effectiveYear($1)
                           : HomePolicy.rating($0) > HomePolicy.rating($1))
                }
            case .fresh:
                // 新片：年份新→旧，同年按真热度
                return items.filter { yearNum($0) >= currentYear - 1 }
                    .sorted {
                        yearNum($0) != yearNum($1) ? yearNum($0) > yearNum($1)
                                                   : HomePolicy.votes($0) > HomePolicy.votes($1)
                    }
            }
        }.value
        rows = r
        // 2026-09-30：兜底态判据（片库里一部有评分的都没有 → 高分榜走的是热度排序）
        topFallback = (b == .top) && !r.isEmpty && r.allSatisfy { HomePolicy.rating($0) <= 0 }
        computing = false
    }
}
