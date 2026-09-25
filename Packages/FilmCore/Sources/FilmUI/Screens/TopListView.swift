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
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(30).enumerated()), id: \.element.id) { idx, it in
                        Button { router.open(it) } label: {
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
        .refreshable { await store.syncAll() }
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
                return items.filter { HomePolicy.rating($0) > 0 }
                    .sorted {
                        HomePolicy.rating($0) != HomePolicy.rating($1)
                            ? HomePolicy.rating($0) > HomePolicy.rating($1)
                            : HomePolicy.votes($0) > HomePolicy.votes($1)
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
        computing = false
    }
}
