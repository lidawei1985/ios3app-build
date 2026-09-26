import SwiftUI
import FilmCore

/// 设置页（settings_v2 原型落地 2026-09-25；v14 用户钦定砍掉原型演示用变体切换器）：
/// · 顶部无框搜索（原型切换器只是设计稿预览开关，不是功能——搬进 APP 造成红条+布局混乱，已删）
/// · 首屏 = 绿点「当前生效」中枢卡（30 圆角发丝线壳，三行点选直换 + 继续浏览海报行）
/// · 全部分组收成透明玻璃胶囊入口 → 页内二级页（‹ 返回 + 居中标题 + N 项，发丝线壳装行）
/// · 强调色全部走 FilmTheme.accent —— 跟随产品「变色」系统与深浅色主题
public struct SettingsView: View {
    @EnvironmentObject private var store: CatalogStore
    @EnvironmentObject private var tvbox: TVBoxConfigStore
    @Environment(\.filmTheme) private var theme

    @State private var query = ""
    @State private var activePicker: StatusField?
    @State private var subGroup: SettingsGroup?

    public init() {}

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - 首屏骨架（顶部常驻：变体切换 + 搜索；下方滚动区）

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if normalizedQuery.isEmpty {
                        statusCard
                    }
                    if normalizedQuery.isEmpty {
                        groupEntries
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 40)
            }
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $activePicker) { field in
            StatusPickerSheet(field: field)
        }
        .overlay {
            if let g = subGroup {
                SubPageShell(group: g, itemCount: subItemCount(g), onBack: {
                    subGroup = nil
                }) {
                    destination(of: g)
                }
                .background(theme.background.ignoresSafeArea())
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: subGroup)
    }

    // MARK: 搜索（无框 + 发丝底横线 + 一键清空）

    private var searchField: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary.opacity(0.5))
                TextField("搜索设置，如 倍速、源、备份…", text: $query)
                    .font(.subheadline)
                    .foregroundStyle(theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Text("×")
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 12)
            Rectangle()
                .fill(theme.textSecondary.opacity(0.16))
                .frame(height: 0.5)
        }
        .padding(.horizontal, 14)
    }

    // MARK: 当前生效中枢卡（绿点标题 + 30 圆角发丝线壳）

    private var statusCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusDotColor.opacity(0.7), radius: 4)
                Text("当前生效")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 4)
            VStack(spacing: 0) {
                statusRow(title: "生效配置", value: activeConfigName) { activePicker = .config }
                statusDivider
                statusRow(title: "生效线路", value: activeLineName) { activePicker = .line }
                statusDivider
                statusRow(title: "解析源", value: activeParseName) { activePicker = .parse }
                statusDivider
                continueRow
            }
            .padding(.horizontal, 18)
            .overlay(
                RoundedRectangle(cornerRadius: 30)
                    .stroke(theme.textSecondary.opacity(0.16), lineWidth: 0.5)
            )
        }
        .padding(.top, 8)
    }

    private var statusDotColor: Color {
        Color(red: 0.20, green: 0.78, blue: 0.35)
    }

    private var statusDivider: some View {
        Rectangle()
            .fill(theme.textSecondary.opacity(0.16))
            .frame(height: 0.5)
    }

    /// 原型 .statrow：左灰键 + 右白粗值 + 细箭头
    private func statusRow(title: String, value: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary.opacity(0.55))
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 原型 .statgo：玻璃海报块 + 继续浏览（TVBox「下次进入」语义）
    @ViewBuilder
    private var continueRow: some View {
        if let last = lastBrowsedSite, !tvbox.displayResult.sites.isEmpty {
            NavigationLink {
                SiteBrowseView(site: last, sites: Array(tvbox.displayResult.sites))
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.accent.opacity(0.07))
                        .frame(width: 34, height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.textSecondary.opacity(0.16), lineWidth: 0.5)
                        )
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.subheadline)
                                .foregroundStyle(theme.accent)
                        )
                    Text("继续浏览 · \(last.name)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary.opacity(0.55))
                }
                .padding(.top, 6)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 玻璃胶囊分组入口（点进 = 页内二级页）

    private var groupEntries: some View {
        VStack(spacing: 11) {
            ForEach(SettingsGroup.allCases) { g in
                Button {
                    subGroup = g
                } label: {
                    groupPill(g)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 11)
    }

    /// 原型 .gpill：accent 9% 底 + 32% 描边 + 图标/箭头等宽光学居中
    private func groupPill(_ g: SettingsGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: g.icon)
                .font(.subheadline)
                .foregroundStyle(theme.accent)
                .frame(width: 20)
            Text(g.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity)
            Image(systemName: "chevron.right")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 20)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Capsule().fill(theme.accent.opacity(0.09)))
        .overlay(Capsule().stroke(theme.accent.opacity(0.32), lineWidth: 1))
        .contentShape(Capsule())
    }

    // MARK: 搜索结果（跨组直达，沿用分组索引）

    private var searchResults: some View {
        let hits = searchHits(for: normalizedQuery)
        return Group {
            if hits.isEmpty {
                Text("没找到「\(query)」相关设置\n换个词试试，如「源」「倍速」「备份」")
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
            } else {
                ForEach(hits) { hit in
                    NavigationLink { destination(of: hit.group) } label: { hitRow(hit) }
                        .buttonStyle(.plain)
                    statusDivider
                }
            }
        }
        .padding(.top, 6)
    }

    private func hitRow(_ hit: SearchHit) -> some View {
        HStack(spacing: 10) {
            Image(systemName: hit.group.icon)
                .font(.subheadline)
                .foregroundStyle(theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).font(.subheadline).foregroundStyle(theme.textPrimary)
                Text(hit.group.rawValue).font(.caption2).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// 跨组搜索索引：关键词 → 分组直达（二级页内的具体行在对应页里一眼可见）。
    /// 静态常量表（在函数体里现场构造大数组会拖垮类型检查）。
    private static let searchIndex: [SearchHit] = [
        SearchHit(keywords: "源 线路 配置 换源 解析 仓库 多仓 点播 直播", title: "当前生效 / 换源", group: .sources),
        SearchHit(keywords: "我的源 自定义 添加 cms m3u 直链", title: "我的源 · 添加点播/直播源", group: .sources),
        SearchHit(keywords: "配置历史 添加配置地址 刷新 tvbox json", title: "配置历史 · 添加配置 · 刷新", group: .sources),
        SearchHit(keywords: "内置 线路 恢复 实测", title: "内置配置线路", group: .sources),
        SearchHit(keywords: "聚合搜索 全部源 一次搜", title: "聚合搜索", group: .sources),
        SearchHit(keywords: "倍速 跳过片头 片头 后台 下一集 硬解码 解码 播放", title: "播放设置", group: .playback),
        SearchHit(keywords: "外观 深色 浅色 跟随系统 主题 白天 黑夜", title: "外观设置", group: .appearance),
        SearchHit(keywords: "备份 导出 导入 剪贴板 换机 恢复配置", title: "数据备份", group: .backup),
        SearchHit(keywords: "缓存 清理 图片 片库 空间 垃圾", title: "缓存下载", group: .cache),
        SearchHit(keywords: "关于 版本 构建 产品 内容 适配器 feed", title: "关于", group: .about),
    ]

    private func searchHits(for q: String) -> [SearchHit] {
        Self.searchIndex.filter {
            $0.keywords.lowercased().contains(q) || $0.title.lowercased().contains(q)
        }
    }

    private struct SearchHit: Identifiable {
        let keywords: String
        let title: String
        let group: SettingsGroup
        var id: String { title }
    }

    @ViewBuilder
    private func destination(of g: SettingsGroup) -> some View {
        switch g {
        case .sources: SourceGroupView()
        case .playback: PlaybackGroupView()
        case .appearance: AppearanceGroupView()
        case .backup: BackupGroupView()
        case .cache: CacheGroupView()
        case .about: AboutGroupView()
        }
    }

    /// 二级页右上角「N 项」（原型 .subcnt）；源与线路随配置动态计数
    private func subItemCount(_ g: SettingsGroup) -> String {
        switch g {
        case .sources: return "\(tvbox.displayResult.sites.count) 项"
        case .playback: return "5 项"
        case .appearance: return "1 项"
        case .backup: return "2 项"
        case .cache: return "1 项"
        case .about: return "5 项"
        }
    }

    // MARK: - 状态数据（首屏中枢卡与选择清单共用）

    private var activeConfigName: String {
        if let u = tvbox.activeURL, let s = tvbox.subscriptions.first(where: { $0.url == u }) { return s.name }
        if let u = tvbox.activeBuiltinRepoURL, let r = tvbox.builtinRepoOptions.first(where: { $0.url == u }) { return r.name }
        if let u = tvbox.activeRepoURL, let r = tvbox.displayResult.repos.first(where: { $0.url == u }) { return r.name }
        if tvbox.displayResult.sites.isEmpty { return "未选择（去「源与线路」启用）" }
        let b = builtinSiteCount
        return b > 0 ? "内置源可用（\(b) 内置 + \(tvbox.displayResult.sites.count - b) 线路）"
                     : "线路源可用（\(tvbox.displayResult.sites.count) 个）"
    }

    private var activeLineName: String {
        if let u = tvbox.activeBuiltinRepoURL,
           let r = tvbox.builtinRepoOptions.first(where: { $0.url == u }) { return r.name }
        return tvbox.builtinRepoOptions.isEmpty ? "无可用线路" : "未选择"
    }

    private var activeParseName: String {
        if let u = tvbox.activeRepoURL,
           let r = tvbox.displayResult.repos.first(where: { $0.url == u }) { return r.name }
        let n = tvbox.displayResult.repos.count
        return n > 0 ? "\(n) 仓待选" : "—"
    }

    /// 当前可见的内置点播源个数（"内置"二字的判据与删除菜单同源：key 带 `builtin:` 前缀）。
    private var builtinSiteCount: Int {
        tvbox.displayResult.sites.filter { $0.key.hasPrefix("builtin:") }.count
    }

    /// 上次浏览的源（TVBox「下次进入」语义）。
    private var lastBrowsedSite: TVBoxSite? {
        guard let d = UserDefaults.standard.data(forKey: "tvbox.lastBrowsedSite"),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let api = obj["api"] as? String else { return nil }
        return TVBoxSite(key: obj["key"] as? String ?? api,
                         name: obj["name"] as? String ?? "上次浏览",
                         api: api,
                         type: obj["type"] as? Int)
    }
}

// MARK: - 页内二级页壳（原型 .subhead：‹ accent 返回 + 居中标题 + N 项）

private struct SubPageShell<Content: View>: View {
    let group: SettingsGroup
    let itemCount: String
    let onBack: () -> Void
    @ViewBuilder let content: Content

    @Environment(\.filmTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(group.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity)
                Text(itemCount)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary.opacity(0.55))
                    .padding(.trailing, 14)
                    .frame(width: 60, alignment: .trailing)
            }
            .padding(.vertical, 10)
            ScrollView {
                content
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - 分组定义（标题统一 4 字，关于 2 字）

private enum SettingsGroup: String, CaseIterable, Identifiable {
    case sources = "源与线路"
    case playback = "播放设置"
    case appearance = "外观设置"
    case backup = "数据备份"
    case cache = "缓存下载"
    case about = "关于"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .sources: return "square.stack.3d.up.fill"
        case .playback: return "play.circle.fill"
        case .appearance: return "paintpalette.fill"
        case .backup: return "externaldrive.fill"
        case .cache: return "arrow.down.circle.fill"
        case .about: return "info.circle.fill"
        }
    }
}

// MARK: - 当前生效选择清单（原型底部选择单：毛玻璃圆角面板 + ✓ 当前行 + 取消胶囊）

private struct StatusPickerSheet: View {
    let field: StatusField
    @EnvironmentObject private var tvbox: TVBoxConfigStore
    @Environment(\.filmTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(field.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 13)
                .padding(.bottom, 9)
            options
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.textPrimary.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.background.opacity(0.72))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .presentationDetents([.medium, .large])
        .presentationBackground(.clear)
    }

    @ViewBuilder
    private var options: some View {
        switch field {
        case .config:
            if tvbox.subscriptions.isEmpty {
                emptyHint("暂无配置历史。到「源与线路」里用「添加配置地址」加一个。")
            }
            ForEach(tvbox.subscriptions) { sub in
                optRow(name: sub.name, detail: sub.url, active: sub.url == tvbox.activeURL) {
                    tvbox.activate(sub)   // TVBox 行为：点选 = 切换生效配置
                    dismiss()
                }
            }
        case .line:
            if tvbox.builtinRepoOptions.isEmpty {
                emptyHint("暂无内置线路（或已被全部删除）。")
            }
            ForEach(tvbox.builtinRepoOptions) { repo in
                optRow(name: repo.name, detail: repo.url, active: repo.url == tvbox.activeBuiltinRepoURL) {
                    tvbox.activateBuiltinRepo(repo)
                    dismiss()
                }
            }
        case .parse:
            if tvbox.displayResult.repos.isEmpty {
                emptyHint("当前配置没有解析出多仓。多仓配置解析后在这里直接点选加载。")
            }
            ForEach(tvbox.displayResult.repos) { r in
                optRow(name: r.name, detail: r.url, active: r.url == tvbox.activeRepoURL) {
                    tvbox.activateRepo(r)
                    dismiss()
                }
            }
        }
    }

    private func emptyHint(_ t: String) -> some View {
        Text(t)
            .font(.footnote)
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
    }

    /// 原型 .opt：当前行 accent 加粗 + ✓，行顶发丝线
    private func optRow(name: String, detail: String, active: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline)
                        .fontWeight(active ? .semibold : .regular)
                        .foregroundStyle(active ? theme.accent : theme.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.textSecondary.opacity(0.16))
                .frame(height: 0.5)
        }
    }
}


// MARK: - 状态字段定义（保留原枚举）

private enum StatusField: String, Identifiable {
    case config, line, parse
    var id: String { rawValue }

    var title: String {
        switch self {
        case .config: return "选择生效配置"
        case .line: return "选择生效线路"
        case .parse: return "选择解析仓库"
        }
    }
}

// MARK: - 二级页：源与线路（我的源 + 配置历史 + 内置线路 + 解析结果，功能原样迁移）

private struct SourceGroupView: View {
    @EnvironmentObject private var store: CatalogStore
    @EnvironmentObject private var tvbox: TVBoxConfigStore
    @Environment(\.filmTheme) private var theme

    @State private var newURL = ""
    @State private var newName = ""
    @State private var showAdd = false
    @State private var showAddSite = false
    @State private var newSiteName = ""
    @State private var newSiteAPI = ""
    @State private var showAddLive = false
    @State private var newLiveName = ""
    @State private var newLiveURL = ""
    @State private var testingChannel: LiveChannel?
    // 35包：自定义源添加反馈 + 一键直达（用户报「添加后找不到在哪用/不知去哪看」）
    @State private var addSiteMsg = ""
    @State private var addSiteOK = false
    @State private var probingSite = false
    @State private var lastAddedSite: TVBoxSite?
    @State private var addLiveMsg = ""
    @State private var addLiveOK = false
    @State private var probingLive = false
    @State private var goBrowseSite: TVBoxSite?
    @State private var sitesExpanded = false   // A2改版(2026-09-21)：长列表默认收起，本页只留生效1条+入口
    @State private var histExpanded = false    // 配置历史默认收起
    @State private var builtinExpanded = false // 内置线路默认收起

    var body: some View {
        List {
            mySourcesSection
            tvboxSection
            builtinReposSection
            let result = tvbox.displayResult
            if !result.isEmpty { parsedSection(result) }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("源与线路")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $goBrowseSite) { s in
            SiteBrowseView(site: s, sites: Array(tvbox.displayResult.sites))
        }
        .fullScreenCover(item: $testingChannel) { ch in
            LivePlayerScreen(channels: [ch],
                             showList: .constant(false),
                             onClose: { testingChannel = nil })
        }
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(isPresented: $showAddSite) { addSiteSheet }
        .sheet(isPresented: $showAddLive) { addLiveSheet }
    }

    // MARK: 我的源（自定义点播/直播独立列表 · 35包）
    // 用户钦定 2026-09-22：「自定义有自己的单独列表，像内置源那种，添加以后直接点击就能看，不用乱找」。

    private var mySourcesSection: some View {
        Section {
            if tvbox.customSites.isEmpty && tvbox.customLives.isEmpty {
                Text("还没有自定义源。点下面「添加」加一个，加完就出现在这里，点一下即可观看。")
                    .font(.footnote).foregroundStyle(theme.textSecondary)
            }

            ForEach(tvbox.customSites) { s in
                NavigationLink {
                    SiteBrowseView(site: s, sites: Array(tvbox.displayResult.sites))
                } label: {
                    sourceRow(icon: "play.square.stack.fill", tag: "点播", name: s.name, detail: s.api)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { tvbox.removeSite(s) } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }

            ForEach(tvbox.customLives) { g in
                Button {
                    NotificationCenter.default.post(name: .openLiveTab, object: nil)
                } label: {
                    sourceRow(icon: "dot.radiowaves.left.and.right", tag: "直播",
                              name: g.name, detail: g.m3uURLs.first ?? "")
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { tvbox.removeLive(g) } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }

            Button { showAddSite = true } label: {
                Label("添加点播源（CMS 接口地址）", systemImage: "plus.circle.fill")
            }
            .foregroundStyle(theme.accent)

            Button { showAddLive = true } label: {
                Label("添加直播源（M3U / TXT / JSON / 直链）", systemImage: "plus.circle.fill")
            }
            .foregroundStyle(theme.accent)
        } header: {
            Text("我的源 · 自定义（\(tvbox.customSites.count + tvbox.customLives.count)）")
        } footer: {
            Text("加完直接在这点：点播条 → 进片库看片；直播条 → 跳直播页。也会出现在浏览页「切换源」列表里。左滑可删除。")
        }
    }

    /// 统一的源行样式（图标 + 名称 + 地址 + 类型标）。
    private func sourceRow(icon: String, tag: String, name: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline)
                if !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            Text(tag)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(theme.accent.opacity(0.16), in: Capsule())
                .foregroundStyle(theme.accent)
        }
    }

    // MARK: TVBox 配置地址 · 配置历史（TVBox 原版语义：点选哪条哪条生效）

    private var tvboxSection: some View {
        Section {
            DisclosureGroup(isExpanded: $histExpanded) {
            ForEach(tvbox.subscriptions) { sub in
                Button {
                    tvbox.activate(sub)   // TVBox 行为：点选 = 切换生效配置
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: sub.url == tvbox.activeURL ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(sub.url == tvbox.activeURL ? theme.accent : theme.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.name).font(.subheadline.weight(.medium))
                                .foregroundStyle(theme.textPrimary).lineLimit(1)
                            Text(sub.url).font(.caption2).foregroundStyle(theme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            tvbox.remove(sub)
                        } label: {
                            Image(systemName: "trash").font(.footnote)
                        }
                    }
                }
            }
            } label: {
                HStack {
                    Label("配置历史（\(tvbox.subscriptions.count) 条）", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline)
                    Spacer()
                    if let u = tvbox.activeURL, let s = tvbox.subscriptions.first(where: { $0.url == u }) {
                        Text("生效：\(s.name)").font(.caption).foregroundStyle(theme.accent).lineLimit(1)
                    }
                }
            }
            Button {
                showAdd = true
            } label: {
                Label("添加配置地址（TVBox JSON / 多仓 / M3U）", systemImage: "plus.circle.fill")
            }
            .foregroundStyle(theme.accent)

            Button {
                Task { await tvbox.refreshAll() }
            } label: {
                HStack {
                    Label(tvbox.refreshing ? "正在解析…" : "刷新当前配置",
                          systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if tvbox.refreshing { ProgressView() }
                }
            }
            .foregroundStyle(theme.accent)
            .disabled(tvbox.refreshing || (tvbox.activeURL == nil && tvbox.activeBuiltinRepoURL == nil))

            if !tvbox.refreshMessage.isEmpty {
                // v16：拉取失败/兜底提示从灰小字升级为亮玻璃横幅（此前用户根本注意不到，
                // 「选了内置线路没反应」的真相=拉取超时静默切回直连精选，必须让人看见）
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").font(.caption)
                    Text(tvbox.refreshMessage).font(.caption).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.10)))
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            }
        } header: {
            Text("TVBox 配置 · 配置历史")
        } footer: {
            Text("TVBox 原版语义：点选历史条目切换生效配置；多仓配置在下方解析结果里点选仓库加载。github raw 自动走 jsDelivr 镜像。")
        }
    }

    // MARK: 内置线路（2026-09-20 盒子实测；按产品自动隔离：星幕=影视组 / 夜航=影视+成人组 / 心屋=无）

    private var builtinReposSection: some View {
        Section {
            if tvbox.builtinRepoOptions.isEmpty {
                // 此前整段隐藏 → 心屋用户看到的是「内置源消失」（2026-09-22 用户反馈）。
                // 现改为常显 + 说清原因：要么是儿童端设计如此，要么是被删光了（给出恢复入口）。
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").font(.footnote).foregroundStyle(theme.textSecondary)
                    Text(tvbox.currentMode == "child"
                         ? "儿童端不提供内置线路（设计如此：避免成人/违禁线路误入孩子的 App），下方点播源照常可用。"
                         : "内置线路已全部删除。若想用回来，点下面的「恢复内置线路」。")
                        .font(.footnote).foregroundStyle(theme.textSecondary)
                }
            } else {
                DisclosureGroup(isExpanded: $builtinExpanded) {
                    ForEach(tvbox.builtinRepoOptions) { repo in
                        HStack(spacing: 10) {
                            // 激活区：只负责"点选生效"
                            Button {
                                tvbox.activateBuiltinRepo(repo)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: repo.url == tvbox.activeBuiltinRepoURL ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(repo.url == tvbox.activeBuiltinRepoURL ? theme.accent : theme.textSecondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(repo.name).font(.subheadline.weight(.medium))
                                            .foregroundStyle(theme.textPrimary).lineLimit(1)
                                        Text(repo.url).font(.caption2).foregroundStyle(theme.textSecondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // 删除键移出激活按钮（此前嵌套在按钮内部 = SwiftUI 未定义命中，
                            // 点行有误删风险，是「内置源消失」的可疑来源之一，2026-09-22 拆开）
                            Button(role: .destructive) {
                                tvbox.removeBuiltinRepo(repo)
                            } label: {
                                Image(systemName: "trash").font(.footnote)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } label: {
                    HStack {
                        Label("内置配置线路（\(tvbox.builtinRepoOptions.count) 条实测）", systemImage: "square.stack.3d.up.fill")
                            .font(.subheadline)
                        Spacer()
                        if let u = tvbox.activeBuiltinRepoURL,
                           let r = tvbox.builtinRepoOptions.first(where: { $0.url == u }) {
                            Text("生效：\(r.name)").font(.caption).foregroundStyle(theme.accent).lineLimit(1)
                        }
                    }
                }
            }
            // 恢复入口：只恢复被删的**线路**（与点播源墓碑分离，不再串台）
            if tvbox.hasDeletedBuiltinRepos {
                Button {
                    tvbox.restoreBuiltinRepos()
                } label: {
                    Label("恢复内置线路（\(tvbox.deletedBuiltinRepoURLs.count) 条已删）",
                          systemImage: "arrow.uturn.backward.circle")
                        .font(.footnote)
                }
                .foregroundStyle(theme.accent)
            }
        } header: {
            Text("内置配置线路 · 盒子实测")
        } footer: {
            Text("一条线路 = 一份配置包（内含几十~几百个站点源，名字里的「N站」就是站数）。点选即解析生效，解析出的站点源进下方「点播源」列表——两者不是一回事：线路是包，点播源是包里的站。浏览页左上「源」胶囊里也能直接换线路，不用回设置。")
        }
    }

    // MARK: 解析结果（多仓选仓 / 点播源 / 直播组）

    private func parsedSection(_ result: TVBoxParseResult) -> some View {
        Section {
            if !result.repos.isEmpty {
                // TVBox 原版行为：多仓列表点选加载，选中仓高亮
                HStack {
                    Label("仓库（\(result.repos.count)）", systemImage: "square.stack.3d.up")
                        .font(.subheadline)
                    Spacer()
                    Button("全部收进配置历史") { tvbox.adoptRepos() }
                        .font(.caption).foregroundStyle(theme.accent)
                }
                ForEach(result.repos) { r in
                    Button {
                        tvbox.activateRepo(r)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: r.url == tvbox.activeRepoURL ? "checkmark.circle.fill" : "circle")
                                .font(.footnote)
                                .foregroundStyle(r.url == tvbox.activeRepoURL ? theme.accent : theme.textSecondary)
                            Text(r.name).font(.caption).foregroundStyle(theme.textPrimary).lineLimit(1)
                            Spacer()
                        }
                    }
                }
            }
            if !result.sites.isEmpty {
                if let last = lastBrowsedSite {
                    // TVBox「首页站源 / 下次进入」语义：一键回到上次浏览的源（A2 改版提为常显）
                    NavigationLink {
                        SiteBrowseView(site: last, sites: Array(result.sites))
                    } label: {
                        Label("上次浏览 · \(last.name)", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain)
                }
                // TVBox「聚合搜索」：全部点播源一次搜
                NavigationLink {
                    AggregateSearchView(sites: Array(result.sites.filter { $0.type != 3 }.prefix(30)))
                } label: {
                    Label("聚合搜索（前 30 个源）", systemImage: "magnifyingglass").font(.subheadline)
                }
                .buttonStyle(.plain)
                DisclosureGroup("点播源（\(result.sites.count)\(builtinSiteCount > 0 ? " · 含内置 \(builtinSiteCount)" : "")）", isExpanded: $sitesExpanded) {
                    // 恢复入口置顶常显：内置源被删过就一定有路可回，杜绝「内置源悄无声息消失」（2026-09-22）
                    if tvbox.hasDeletedBuiltins {
                        Button {
                            tvbox.restoreBuiltins()
                        } label: {
                            Label("恢复被删除的内置源（\(tvbox.deletedBuiltinKeys.count) 个）", systemImage: "arrow.uturn.backward.circle")
                                .font(.footnote.weight(.medium))
                        }
                        .foregroundStyle(theme.accent)
                    }
                    ForEach(result.sites.prefix(80)) { s in
                        // 原版 TVBox 思路：站点源可直接浏览（分类/列表/搜索/播放全走该源）
                        NavigationLink {
                            SiteBrowseView(site: s, sites: Array(result.sites))
                        } label: {
                            HStack(spacing: 6) {
                                if s.key.hasPrefix("builtin:") {
                                    Text("内置")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(theme.accent.opacity(0.16), in: Capsule())
                                        .foregroundStyle(theme.accent)
                                }
                                Text(s.name).font(.footnote).lineLimit(1)
                                Spacer()
                                Text(typeName(s.type)).font(.caption2).foregroundStyle(theme.textSecondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if s.key.hasPrefix("builtin:") {
                                Button(role: .destructive) {
                                    tvbox.removeSite(s)
                                } label: {
                                    Label("删除内置源「\(s.name)」", systemImage: "trash")
                                }
                            }
                        }
                    }
                    if result.sites.count > 80 {
                        Text("…共 \(result.sites.count) 个").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(result.lives) { group in
                DisclosureGroup("直播组：\(group.name)") {
                    ForEach(Array(group.m3uURLs.enumerated()), id: \.offset) { _, u in
                        Button {
                            Task {
                                if u.hasSuffix(".m3u") || u.lowercased().contains(".m3u") {
                                    let channels = await tvbox.expandM3U(u)
                                    testingChannel = channels.first   // 测播第一个频道
                                } else if let url = URL(string: u) {
                                    testingChannel = LiveChannel(id: u, name: group.name, url: url)
                                }
                            }
                        } label: {
                            HStack {
                                Text(u).font(.caption2).foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                                Spacer()
                                Text("测播").font(.caption).foregroundStyle(theme.accent)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("解析结果（当前生效配置）")
        } footer: {
            Text("多仓配置请先点选仓库；内置源长按可删除（可恢复）；自定义直播源会自动出现在「直播」页。")
        }
    }

    // MARK: 添加配置地址 sheet

    private var addSheet: some View {
        NavigationStack {
            Form {
                TextField("备注名（可留空）", text: $newName)
                TextField("配置地址 https://…", text: $newURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("确认添加并启用") {
                    if tvbox.add(name: newName, url: newURL) {
                        newName = ""; newURL = ""
                        showAdd = false
                        Task { await tvbox.refreshAll() }
                    }
                }
                .disabled(!newURL.trimmingCharacters(in: .whitespaces).hasPrefix("http"))
            }
            .navigationTitle("添加配置地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("取消") { showAdd = false } } }
        }
        .presentationDetents([.medium])
    }

    // MARK: 添加点播源 sheet

    private var addSiteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("站点名（可留空）", text: $newSiteName)
                    TextField("CMS 接口地址 https://…/api.php/provide/vod", text: $newSiteAPI)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("填对方的 CMS 点播接口（多数是 …/api.php/provide/vod）。添加时会自动测一次，直接告诉你通不通，不用自己猜。")
                }

                Section {
                    Button {
                        Task { await confirmAddSite() }
                    } label: {
                        HStack(spacing: 8) {
                            if probingSite { ProgressView().controlSize(.small) }
                            Text(probingSite ? "正在测试…" : "添加并测试").font(.body.weight(.medium))
                        }
                    }
                    .disabled(!canSubmitSite || probingSite)

                    if !addSiteMsg.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(addSiteMsg,
                                  systemImage: addSiteOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(addSiteOK ? theme.accent : Color.orange)
                            if addSiteOK, let s = lastAddedSite {
                                Button {
                                    showAddSite = false
                                    let target = s
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { goBrowseSite = target }
                                } label: {
                                    Label("立即去看 · \(s.name)", systemImage: "arrow.right.circle.fill")
                                        .font(.footnote.weight(.semibold))
                                }
                                .foregroundStyle(theme.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加点播源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { showAddSite = false; resetAddSite() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var canSubmitSite: Bool {
        newSiteAPI.trimmingCharacters(in: .whitespaces).hasPrefix("http")
    }

    private func resetAddSite() { addSiteMsg = ""; addSiteOK = false; lastAddedSite = nil }

    private func confirmAddSite() async {
        probingSite = true
        defer { probingSite = false }
        let outcome = tvbox.addSite(name: newSiteName, api: newSiteAPI)
        switch outcome {
        case .ok(let site):
            lastAddedSite = site
            addSiteOK = true
            addSiteMsg = "已添加「\(site.name)」，正在测试连通性…"
            newSiteName = ""; newSiteAPI = ""
            let err = await tvbox.probeSite(api: site.api)
            if let e = err {
                addSiteMsg = "已添加，但测试未通过：\(e)。仍可点进去试试（部分源对测试请求不友好）。"
            } else {
                addSiteMsg = "已添加并测试通过，已进「我的源」顶部，点一下就能看。"
            }
        default:
            addSiteOK = false
            addSiteMsg = outcome.message
        }
    }

    // MARK: 添加直播源 sheet

    private var addLiveSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("直播源名（可留空）", text: $newLiveName)
                    TextField("直播地址 https://…（.m3u / .txt / JSON / 直链）", text: $newLiveURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("支持 M3U 播放列表、TVBox 频道 txt、订阅 JSON，或单条频道直链。添加时会自动测一次并告诉你结果。")
                }

                Section {
                    Button {
                        Task { await confirmAddLive() }
                    } label: {
                        HStack(spacing: 8) {
                            if probingLive { ProgressView().controlSize(.small) }
                            Text(probingLive ? "正在测试…" : "添加并测试").font(.body.weight(.medium))
                        }
                    }
                    .disabled(!canSubmitLive || probingLive)

                    if !addLiveMsg.isEmpty {
                        Label(addLiveMsg,
                              systemImage: addLiveOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(addLiveOK ? theme.accent : Color.orange)
                    }
                    if addLiveOK {
                        Button {
                            showAddLive = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                NotificationCenter.default.post(name: .openLiveTab, object: nil)
                            }
                        } label: {
                            Label("去直播页看", systemImage: "arrow.right.circle.fill")
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(theme.accent)
                    }
                }
            }
            .navigationTitle("添加直播源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { showAddLive = false; resetAddLive() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var canSubmitLive: Bool {
        newLiveURL.trimmingCharacters(in: .whitespaces).hasPrefix("http")
    }

    private func resetAddLive() { addLiveMsg = ""; addLiveOK = false }

    private func confirmAddLive() async {
        probingLive = true
        defer { probingLive = false }
        let outcome = tvbox.addLive(name: newLiveName, url: newLiveURL)
        switch outcome {
        case .ok(let site):
            addLiveOK = true
            addLiveMsg = "已添加「\(site.name)」，正在测试…"
            newLiveName = ""; newLiveURL = ""
            let err = await tvbox.probeLive(url: site.api)
            if let e = err {
                addLiveMsg = "已添加，但测试未通过：\(e)。可去直播页确认，或换个地址再试。"
            } else {
                addLiveMsg = "已添加并测试通过，已进「我的源」，点下面按钮直接去直播页看。"
            }
        default:
            addLiveOK = false
            addLiveMsg = outcome.message
        }
    }

    /// 当前可见的内置点播源个数（"内置"二字的判据与删除菜单同源：key 带 `builtin:` 前缀）。
    private var builtinSiteCount: Int {
        tvbox.displayResult.sites.filter { $0.key.hasPrefix("builtin:") }.count
    }

    /// 上次浏览的源（TVBox「下次进入」语义）。
    private var lastBrowsedSite: TVBoxSite? {
        guard let d = UserDefaults.standard.data(forKey: "tvbox.lastBrowsedSite"),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let api = obj["api"] as? String else { return nil }
        return TVBoxSite(key: obj["key"] as? String ?? api,
                         name: obj["name"] as? String ?? "上次浏览",
                         api: api,
                         type: obj["type"] as? Int)
    }

    private func typeName(_ t: Int?) -> String {
        switch t {
        case 0: return "XML"
        case 1: return "JSON"
        case 3: return "Spider·需引擎"
        default: return "未知"
        }
    }
}

// MARK: - 二级页：播放设置（原型行样式：无框行 + 发丝线 + iOS 开关 + Menu 直选）

private struct PlaybackGroupView: View {
    @Environment(\.filmTheme) private var theme

    @AppStorage("settings.defaultRate") private var defaultRate = "1.0"
    @AppStorage("settings.skipIntroSeconds") private var skipIntro = 0
    @AppStorage("settings.backgroundPlay") private var backgroundPlay = true
    @AppStorage("settings.autoNextEpisode") private var autoNext = true
    @AppStorage("settings.hardwareDecode") private var hardwareDecode = true

    var body: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(["0.5", "0.75", "1.0", "1.25", "1.5", "2.0"], id: \.self) { r in
                    Button("默认 \(dropTrailingZero(r))x") { defaultRate = r }
                }
            } label: {
                valueRow(icon: "bolt", title: "默认倍速", value: "\(dropTrailingZero(defaultRate))x")
            }
            hairline
            Menu {
                ForEach([0, 5, 10, 15, 20, 30, 45, 60, 90], id: \.self) { s in
                    Button("跳过 \(s) 秒") { skipIntro = s }
                }
            } label: {
                valueRow(icon: "forward.end", title: "跳过片头", value: "\(skipIntro)s")
            }
            hairline
            toggleRow(icon: "moon.zzz", title: "后台继续播放", sub: "锁屏/切后台不断声", isOn: $backgroundPlay)
            hairline
            toggleRow(icon: "arrow.right.circle", title: "自动播下一集", sub: nil, isOn: $autoNext)
            hairline
            toggleRow(icon: "cpu", title: "硬解码", sub: "更省电（iOS 恒为开）", isOn: $hardwareDecode)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .overlay(
            RoundedRectangle(cornerRadius: 30)
                .stroke(theme.textSecondary.opacity(0.16), lineWidth: 0.5)
        )
    }

    /// 即改即用的说明（footer 语义收进页内一行小字）
    private func dropTrailingZero(_ s: String) -> String {
        s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.textSecondary.opacity(0.16))
            .frame(height: 0.5)
    }

    private func valueRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
            Image(systemName: "chevron.right")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary.opacity(0.55))
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func toggleRow(icon: String, title: String, sub: String?, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(theme.textPrimary)
                if let sub {
                    Text(sub)
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(theme.accent)
                .fixedSize()
        }
        .padding(.vertical, 12)
    }
}

// MARK: - 二级页：外观设置（原型 .seg 分段：描边圆角 + accent 选中块）

private struct AppearanceGroupView: View {
    @Environment(\.filmTheme) private var theme
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "paintpalette")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 22)
                Text("外观")
                    .font(.subheadline)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                segControl
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            VStack(alignment: .leading, spacing: 4) {
                Text("跟随系统时会随手机深浅色自动切换；播放页与直播页始终深色。")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 30)
                .stroke(theme.textSecondary.opacity(0.16), lineWidth: 0.5)
        )
    }

    private var segControl: some View {
        HStack(spacing: 2) {
            ForEach(AppearanceMode.allCases) { m in
                Button {
                    appearanceRaw = m.rawValue
                } label: {
                    Text(m.title)
                        .font(.caption)
                        .fontWeight(appearanceRaw == m.rawValue ? .semibold : .regular)
                        .foregroundStyle(appearanceRaw == m.rawValue ? theme.textPrimary : theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(appearanceRaw == m.rawValue ? theme.accent.opacity(0.18) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(theme.textSecondary.opacity(0.16), lineWidth: 0.5)
        )
    }
}

// MARK: - 二级页：数据备份（原型行样式：图标 + 标题 + 副标 + 箭头）

private struct BackupGroupView: View {
    @EnvironmentObject private var tvbox: TVBoxConfigStore
    @Environment(\.filmTheme) private var theme

    @State private var backupMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            actionRow(icon: "square.and.arrow.up", title: "导出配置", sub: "复制到剪贴板") {
                if let json = tvbox.exportState() {
                    UIPasteboard.general.string = json
                    backupMessage = "已复制到剪贴板（\(json.count) 字符），存到备忘录即可长期保存"
                } else {
                    backupMessage = "导出失败"
                }
            }
            hairline
            actionRow(icon: "square.and.arrow.down", title: "从剪贴板导入配置", sub: "换机/清数据后一键恢复") {
                let text = UIPasteboard.general.string ?? ""
                if tvbox.importState(text) {
                    backupMessage = "导入成功，正在刷新当前配置…"
                    Task { await tvbox.refreshAll() }
                } else {
                    backupMessage = "剪贴板里没有有效的配置备份"
                }
            }
            if !backupMessage.isEmpty {
                Text(backupMessage)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 30)
                .stroke(theme.textSecondary.opacity(0.16), lineWidth: 0.5)
        )
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.textSecondary.opacity(0.16))
            .frame(height: 0.5)
    }

    private func actionRow(icon: String, title: String, sub: String?, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(theme.textPrimary)
                    if let sub {
                        Text(sub)
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary.opacity(0.55))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 二级页：缓存下载（原型 .row.act：danger 行 accent 加粗）

private struct CacheGroupView: View {
    @EnvironmentObject private var store: CatalogStore
    @Environment(\.filmTheme) private var theme

    @State private var doneMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            Button {
                URLCache.shared.removeAllCachedResponses()
                store.clearSnapshot()
                doneMessage = "已清除。片库封面会重新下载，不影响收藏与播放记录。"
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundStyle(theme.accent)
                        .frame(width: 22)
                    Text("清除片库与图片缓存")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.accent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary.opacity(0.55))
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !doneMessage.isEmpty {
                Text(doneMessage)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 30)
                .stroke(theme.textSecondary.opacity(0.16), lineWidth: 0.5)
        )
    }
}

// MARK: - 二级页：关于（原型 .statrow：左灰键 + 右白粗值）

private struct AboutGroupView: View {
    @EnvironmentObject private var store: CatalogStore
    @Environment(\.filmTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            aboutRow(k: "产品", v: store.profile.appName)
            hairline
            aboutRow(k: "版本 / 构建", v: AppBuildInfo.mark)
            hairline
            aboutRow(k: "内容定位", v: store.profile.tagline)
            hairline
            aboutRow(k: "数据适配器", v: CatalogCache.adapterVersion)
            hairline
            aboutRow(k: "Feed 版本", v: store.ledger.version ?? "-")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .overlay(
            RoundedRectangle(cornerRadius: 30)
                .stroke(theme.textSecondary.opacity(0.16), lineWidth: 0.5)
        )
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.textSecondary.opacity(0.16))
            .frame(height: 0.5)
    }

    private func aboutRow(k: String, v: String) -> some View {
        HStack(spacing: 10) {
            Text(k)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Text(v)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 12)
    }
}
