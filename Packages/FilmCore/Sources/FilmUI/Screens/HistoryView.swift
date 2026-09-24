import SwiftUI
import FilmCore

/// 观看历史（60包 2026-09-23）。
/// 用户原话：「没有继续播放是不是少个历史按钮？」——57包删掉底部迷你播放条后，
/// 首页只剩「继续观看」货架（有历史才出现），没有**直达历史**的入口，用户以为功能没了。
/// 这里补一个从首页右上角一键直达的完整历史页：进度条 + 点开续播 + 左滑删单条 + 一键清空。
/// （「我的 → 历史」仍在，这里是首页快捷入口。）
///
/// 注意（60包 CI 教训）：
/// 1) `WatchEntry` 是 **`UserLibrary` 的嵌套类型**（不是 CatalogCache！），必须写全 `UserLibrary.WatchEntry`；
/// 2) body 不能堆太长链式表达式（Swift 类型检查会超时），故拆成 historyList / HistoryRow。
public struct HistoryView: View {
    @EnvironmentObject private var library: UserLibrary
    @Environment(\.filmTheme) private var theme

    public init() {}

    public var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            if library.history.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
        .navigationTitle("观看历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !library.history.isEmpty {
                    Button("清空") { library.clearHistory() }
                        .foregroundStyle(theme.accent)
                }
            }
        }
    }

    private var historyList: some View {
        List {
            ForEach(library.history) { entry in
                NavigationLink(value: entry.item) {
                    HistoryRow(entry: entry)
                }
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        library.removeHistoryEntry(id: entry.id)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("还没有观看记录")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            Text("看过的片子会自动出现在这里，点一下接着看")
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(30)
    }
}

/// 单条历史：海报 + 标题 + 观看进度 + 相对时间。
struct HistoryRow: View {
    let entry: UserLibrary.WatchEntry
    @Environment(\.filmTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(urlString: entry.item.bestPosterURL?.absoluteString)
                .frame(width: 62, height: 92)
                .cornerRadius(8)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                if entry.durationSeconds > 0 {
                    ProgressView(value: min(1, entry.progressSeconds / entry.durationSeconds))
                        .tint(theme.accent)
                    Text(Self.progressLabel(entry))
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                }
                Text(entry.playedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private static func progressLabel(_ e: UserLibrary.WatchEntry) -> String {
        "已看 \(mmss(e.progressSeconds)) / \(mmss(e.durationSeconds))"
    }

    private static func mmss(_ seconds: Double) -> String {
        let v = Int(max(0, seconds))
        return "\(v / 60):" + String(format: "%02d", v % 60)
    }
}
