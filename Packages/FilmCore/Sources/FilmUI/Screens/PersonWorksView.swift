import SwiftUI
import FilmCore

/// 演员/导演作品页（大牌标配：详情页点演员名 → 该人的作品墙）。
/// 数据全部来自本地片库（零网络依赖），随目录变化自动重算。
public struct PersonWorksView: View {
    let person: String
    let role: String            // "主演" / "导演"
    @EnvironmentObject private var store: CatalogStore
    @Environment(\.filmTheme) private var theme

    @State private var works: [FeedItem] = []
    @State private var computing = true

    public init(person: String, role: String = "主演") {
        self.person = person
        self.role = role
    }

    public var body: some View {
        ScrollView {
            if computing {
                ProgressView().frame(maxWidth: .infinity, minHeight: 320)
            } else if works.isEmpty {
                EmptyStateView(icon: "person.crop.circle.badge.questionmark",
                               title: "暂无 \(person) 的作品",
                               subtitle: "片库更新后可能收录更多")
            } else {
                Text("本地片库 \(works.count) 部")
                    .font(.footnote).foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 10)
                PosterGrid(items: works, columns: 3)
                    .padding(.vertical, 12)
            }
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(person)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(person)|\(role)|\(store.catalog.items.count)") { await load() }
    }

    @MainActor
    private func load() async {
        computing = true
        let name = person
        let isDirector = role == "导演"
        let items = store.catalog.items
        let r: [FeedItem] = await Task.detached(priority: .userInitiated) {
            items.filter { it in
                if isDirector { return (it.directors ?? []).contains { $0 == name } }
                return (it.actors ?? []).contains { $0 == name }
            }
        }.value
        works = r
        computing = false
    }
}
