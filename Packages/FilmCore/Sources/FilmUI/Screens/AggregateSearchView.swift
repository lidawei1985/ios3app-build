import SwiftUI
import FilmCore

/// TVBox「聚合搜索」：一次关键词并发搜全部点播源，按源分组展示（TVBox 原版同款能力）。
/// 流式出结果：每个源搜完立即归位显示，不等全量完成；并发 8 路，20s 超时由 client 自带。
public struct AggregateSearchView: View {
    let sites: [TVBoxSite]
    @EnvironmentObject private var router: DetailRouter
    @Environment(\.filmTheme) private var theme

    @State private var keyword = ""
    @State private var searched = false
    @State private var searching = false
    @State private var doneCount = 0
    /// site.id → 该源搜索结果（源顺序稳定，完成后按 sites 顺序归位展示）
    @State private var buckets: [String: [FeedItem]] = [:]

    public init(sites: [TVBoxSite]) {
        // 熔断的源不参与聚合搜索（冷却 10 分钟到期后自然放行半开探测，成功即复活）
        self.sites = sites.filter { !SourceHealth.shared.isSkipped($0.key) }
    }

    public var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField("片名 / 演员 / 关键词", text: $keyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await run() } }
                    Button {
                        Task { await run() }
                    } label: {
                        if searching { ProgressView() } else { Image(systemName: "magnifyingglass") }
                    }
                    .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            } footer: {
                Text("同时在 \(sites.count) 个点播源里搜索，按源分组展示（TVBox 聚合搜索同款）。")
            }

            if searching {
                Section {
                    HStack {
                        ProgressView()
                        Text("聚合搜索中 \(doneCount)/\(sites.count) 源…")
                            .font(.footnote).foregroundStyle(theme.textSecondary)
                    }
                }
            } else if searched && total == 0 {
                Section {
                    Text("全部源都没有搜到「\(keyword)」")
                        .font(.footnote).foregroundStyle(theme.textSecondary)
                }
            }

            ForEach(sites, id: \.id) { s in
                if let items = buckets[s.id], !items.isEmpty {
                    Section("\(s.name)（\(items.count)）") {
                        ForEach(items.prefix(30)) { item in
                            Button { router.open(item) } label: {
                                row(item)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("聚合搜索")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var total: Int { buckets.values.reduce(0) { $0 + $1.count } }

    private func row(_ item: FeedItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.footnote).lineLimit(1)
            HStack(spacing: 8) {
                if let y = item.year { Text(y).font(.caption2).foregroundStyle(theme.textSecondary) }
                if let r = item.play?.lines?.first?.name, !r.isEmpty {
                    Text(r).font(.caption2).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func run() async {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty, !searching else { return }
        searching = true
        searched = false
        doneCount = 0
        buckets = [:]
        await withTaskGroup(of: (TVBoxSite, [FeedItem]).self) { group in
            var inflight = 0
            var idx = 0
            let cap = min(8, max(sites.count, 1))
            while inflight < cap, idx < sites.count {
                let s = sites[idx]; idx += 1; inflight += 1
                group.addTask { (s, await TVBoxSiteClient(site: s).search(kw)) }
            }
            for await (s, items) in group {
                inflight -= 1
                buckets[s.id] = items      // 流式归位：搜完一个亮一个
                doneCount += 1
                if idx < sites.count {
                    let next = sites[idx]; idx += 1; inflight += 1
                    group.addTask { (next, await TVBoxSiteClient(site: next).search(kw)) }
                }
            }
        }
        searching = false
        searched = true
    }
}
