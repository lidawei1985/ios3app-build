import SwiftUI
import UIKit
import FilmCore

/// 我的：收藏 / 播放历史 / 版本信息 / 数据台账（数量守恒可视化）。
public struct LibraryView: View {
    @EnvironmentObject private var store: CatalogStore
    @EnvironmentObject private var library: UserLibrary
    @EnvironmentObject private var router: DetailRouter
    @Environment(\.filmTheme) private var theme

    @State private var segment = 0
    @State private var showLedgerDetail = false
    @State private var pushSettings = false   // 直播页「去添加直播源」programmatic 推入

    public init() {}

    public var body: some View {
        List {
            // v14：系统分段选择器（灰色实心）→ 玻璃胶囊双按钮（跟随变色系统）
            HStack(spacing: 8) {
                segmentChip("收藏", 0)
                segmentChip("历史", 1)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))

            if segment == 0 {
                favoritesRows
            } else {
                historyRows
                if !library.history.isEmpty {
                    Button(role: .destructive) {
                        library.clearHistory()
                    } label: {
                        Label("清空播放历史", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                    .listRowBackground(Color.clear)
                }
            }

            Section("更多") {
                LabeledRow(label: "离线缓存", value: "暂无可下载内容")
                    .listRowBackground(Color.clear)
                Button {
                    if let url = URL(string: "mailto:feedback@filmcollector.tv?subject=\(store.profile.appName)%20用户反馈") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("帮助与反馈").font(.subheadline)
                        .foregroundStyle(theme.textPrimary)
                }
                .listRowBackground(Color.clear)
            }

            Section("数据") {
                LabeledRow(label: "收录影片", value: "\(store.catalog.items.count)")
                    .listRowBackground(Color.clear)
                LabeledRow(label: "片库总量（feed）", value: "\(store.ledger.sourceCount)")
                    .listRowBackground(Color.clear)
                LabeledRow(label: "隔离拦截", value: "\(store.ledger.isolationDroppedCount)")
                    .listRowBackground(Color.clear)
                LabeledRow(label: "重复去重", value: "\(store.ledger.duplicateIDCount)")
                    .listRowBackground(Color.clear)
                Button("数量台账明细") { showLedgerDetail = true }
                    .foregroundStyle(theme.accent)
                    .listRowBackground(Color.clear)
                Button("手动刷新片库") {
                    Task { await store.syncAll() }
                }
                .foregroundStyle(theme.accent)
                .listRowBackground(Color.clear)
            }

            Section("关于") {
                LabeledRow(label: "产品", value: store.profile.appName)
                    .listRowBackground(Color.clear)
                LabeledRow(label: "内容定位", value: store.profile.tagline)
                    .listRowBackground(Color.clear)
                LabeledRow(label: "数据适配器", value: CatalogCache.adapterVersion)
                    .listRowBackground(Color.clear)
                LabeledRow(label: "Feed 版本", value: store.ledger.version ?? "-")
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(theme.textPrimary)
                }
            }
        }
        .navigationDestination(isPresented: $pushSettings) { SettingsView() }
        .onReceive(NotificationCenter.default.publisher(for: .openAppSettings)) { _ in
            pushSettings = true
        }
        .sheet(isPresented: $showLedgerDetail) { LedgerSheet(ledger: store.ledger) }
    }

    /// v14：玻璃胶囊段选按钮（导航条式：超薄材质 + 发丝线，选中 accent 描边）
    private func segmentChip(_ title: String, _ tag: Int) -> some View {
        Button {
            segment = tag
        } label: {
            Text(title).font(.subheadline)
                .fontWeight(segment == tag ? .semibold : .regular)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(segment == tag ? theme.accent.opacity(0.55) : .white.opacity(0.14), lineWidth: 0.5))
                .foregroundStyle(segment == tag ? theme.textPrimary : theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var favoritesRows: some View {
        Group {
            if library.favorites.isEmpty {
                emptyRow(icon: "heart", text: "还没有收藏，去首页逛逛吧")
            } else {
                ForEach(library.favorites) { item in
                    Button { router.open(item) } label: { LibraryRow(item: item) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    private var historyRows: some View {
        Group {
            if library.history.isEmpty {
                emptyRow(icon: "clock", text: "暂无观看记录")
            } else {
                ForEach(library.history) { entry in
                    Button { router.open(entry.item) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            LibraryRow(item: entry.item)
                            if entry.durationSeconds > 0 {
                                ProgressView(value: min(1, entry.progressSeconds / entry.durationSeconds))
                                    .tint(theme.accent)
                            }
                            Text(entry.playedAt.formatted(.relative(presentation: .named)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
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
        }
    }

    private func emptyRow(icon: String, text: String) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title).foregroundStyle(.secondary)
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 30)
        .listRowBackground(Color.clear)
    }
}

struct LibraryRow: View {
    let item: FeedItem
    @Environment(\.filmTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(urlString: item.poster?.url ?? item.backdrop?.url)
                .frame(width: 48, height: 72)
                .cornerRadius(6)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(theme.textPrimary)
                Text([item.displayYear, item.aggregateCategoryName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct LabeledRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// 数量台账明细（§七：每级数量、丢弃、原因全透明）。
struct LedgerSheet: View {
    let ledger: DataLedger
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("链路数量") {
                    LabeledRow(label: "SOURCE（feed manifest）", value: "\(ledger.sourceCount)")
                        .listRowBackground(Color.clear)
                    LabeledRow(label: "FEED（实拉解码）", value: "\(ledger.feedFetchedCount)")
                        .listRowBackground(Color.clear)
                    LabeledRow(label: "APP CATALOG（入库）", value: "\(ledger.catalogCount)")
                        .listRowBackground(Color.clear)
                    LabeledRow(label: "首屏轻量包", value: "\(ledger.homeCount)")
                        .listRowBackground(Color.clear)
                }
                Section("丢弃/异常（含原因）") {
                    LabeledRow(label: "隔离拦截（安全网）", value: "\(ledger.isolationDroppedCount)")
                        .listRowBackground(Color.clear)
                    ForEach(ledger.isolationReasons.sorted(by: >), id: \.key) { k, v in
                        LabeledRow(label: "  ↳ \(k)", value: "\(v)")
                            .listRowBackground(Color.clear)
                    }
                    LabeledRow(label: "重复 ID 去重", value: "\(ledger.duplicateIDCount)")
                        .listRowBackground(Color.clear)
                    LabeledRow(label: "解码失败", value: "\(ledger.decodeErrorCount)")
                        .listRowBackground(Color.clear)
                    LabeledRow(label: "空海报（保留+占位）", value: "\(ledger.emptyPosterCount)")
                        .listRowBackground(Color.clear)
                    LabeledRow(label: "无播放源（保留）", value: "\(ledger.noPlayURLCount)")
                        .listRowBackground(Color.clear)
                    LabeledRow(label: "未知分类（保留）", value: "\(ledger.unknownCategoryCount)")
                        .listRowBackground(Color.clear)
                }
                Section {
                    if ledger.shrinkDetected {
                        Label("检测到数量缩水（<80%），请检查 feed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Label("数量守恒校验通过", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                } footer: {
                    Text("版本：\(ledger.version ?? "-")　更新：\(ledger.updatedAt.map { $0.formatted() } ?? "-")")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("数据台账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}
