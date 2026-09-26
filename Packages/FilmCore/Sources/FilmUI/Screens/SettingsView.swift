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
    @State private var sitesExpanded = false   // 点播源 chips 展开/收起（默认收，省屏）

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
                    .foregroundStyle(theme.textPrimary)
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
                sitesVizSection          // 用户钦定 2026-09-26：点播源可视化放「当前生效」里
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

    // MARK: 首屏·点播源可视化（钦定 2026-09-26：放「当前生效」里，chips 一眼看清，默认收起省屏）
    // 2026-09-26 分区改版（用户：「列表里没有分成人区和普通区，看不明白哪些是电影的哪些是成人的」）：
    // 展开后按 影视 / 混合 / 自定义 / 成人 四区分组渲染，每区带标题和数量。

    private var sitesVizSection: some View {
        let sites = tvbox.displayResult.sites
        // 分区：影视 → 混合 → 自定义 → 成人（顺序固定；空区不渲染）
        let zones: [(title: String, items: [TVBoxSite])] = {
            var film: [TVBoxSite] = [], mixed: [TVBoxSite] = [], custom: [TVBoxSite] = [], adult: [TVBoxSite] = []
            for s in sites {
                switch DefaultSites.vodZone(of: s) {
                case .film: film.append(s)
                case .mixed: mixed.append(s)
                case .custom: custom.append(s)
                case .adult: adult.append(s)
                }
            }
            return [("影视源 \(film.count)", film), ("混合源 \(mixed.count)", mixed),
                    ("自定义 \(custom.count)", custom), ("成人源 \(adult.count)", adult)]
                .filter { !$0.items.isEmpty }
        }()
        let collapsed = sites.prefix(8)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text("点播源")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                if !sites.isEmpty {
                    Button { sitesExpanded.toggle() } label: {
                        HStack(spacing: 2) {
                            Text(sitesExpanded ? "收起" : "全部 \(sites.count) 个")
                            Image(systemName: sitesExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            if sites.isEmpty {
                Text("暂无点播源——到「源与线路」添加配置或选一条内置线路即可解析出站点")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary.opacity(0.6))
            } else if !sitesExpanded {
                // 收起态：只露影视区前 8 个（默认不吵；成人区要点「全部」才见）
                FlowLayout(spacing: 6) {
                    ForEach(Array(collapsed)) { s in
                        siteChip(s)
                    }
                    if sites.count > 8 {
                        Button { sitesExpanded = true } label: {
                            Text("+\(sites.count - 8) 更多")
                                .font(.caption)
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(theme.textPrimary.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                // 展开态：分区渲染
                ForEach(zones, id: \.title) { zone in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(zone.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.textSecondary)
                        FlowLayout(spacing: 6) {
                            ForEach(zone.items) { s in
                                siteChip(s)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }

    /// 单个源 chip（内 = 内置影视源；成 = 成人区）
    private func siteChip(_ s: TVBoxSite) -> some View {
        NavigationLink {
            SiteBrowseView(site: s, sites: Array(tvbox.displayResult.sites))
        } label: {
            HStack(spacing: 4) {
                if s.key.hasPrefix("builtin:") {
                    Text(DefaultSites.vodZone(of: s) == .adult ? "成" : "内")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.textPrimary.opacity(0.85))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(theme.textPrimary.opacity(0.12), in: Capsule())
                }
                Text(s.name)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(theme.textPrimary.opacity(0.88))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(theme.textPrimary.opacity(0.06)))
            .overlay(Capsule().stroke(theme.textSecondary.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
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
                        .fill(theme.textPrimary.opacity(0.06))
                        .frame(width: 34, height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.textSecondary.opacity(0.16), lineWidth: 0.5)
                        )
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.subheadline)
                                .foregroundStyle(theme.textSecondary)
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

    /// 原型 .gpill：透明玻璃壳（用户钦定 2026-09-26「要透明不要红色」——不再用红色 accent 渲染胶囊）
    private func groupPill(_ g: SettingsGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: g.icon)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
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
        .background(Capsule().fill(theme.textPrimary.opacity(0.05)))
        .overlay(Capsule().stroke(theme.textSecondary.opacity(0.16), lineWidth: 0.5))
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
                .foregroundStyle(theme.textSecondary)
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
        if n > 0 { return "\(n) 仓待选" }
        // 空态说人话（用户实测「点开也是空的」）：多仓是配置里的可选结构，单线路/单配置没有
        return tvbox.displayResult.sites.isEmpty ? "无（未加载配置）" : "无（当前非多仓配置）"
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
                        .foregroundStyle(theme.textSecondary)
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
            // v17 关键修复：这里**不能包 ScrollView**——「源与线路」子页是 List，
            // List 套 ScrollView 会塌缩成零高度（用户实况：右上角「26 项」在、内容全空）。
            // 子页各自负责滚动：List 自滚；其余五个短 VStack 直接平铺。
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 40)
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
            // 2026-09-26 修复：线路多时弹层不能滚动（用户实测「只能看见屏幕已有的」）——包 ScrollView
            ScrollView {
                options
            }
            .frame(maxHeight: 420)
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
                emptyHint("当前生效配置里没有「多仓」结构——单线路/单配置本来就没有，不是故障。只有含多仓（sites 里带 repos）的配置才会在这里列出，点选即加载某个仓。")
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
                        .foregroundStyle(theme.textPrimary)
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
                        .foregroundStyle(theme.textPrimary)
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

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                mySourcesCard
                tvboxCard
                builtinReposCard
                let result = tvbox.displayResult
                if !result.isEmpty { parsedCard(result) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .background(theme.background.ignoresSafeArea())
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

    // MARK: 我的源（玻璃卡 · 用户钦定 2026-09-26 二级页改版：与首屏同风格，零红色）

    private var mySourcesCard: some View {
        card("我的源 · 自定义（\(tvbox.customSites.count + tvbox.customLives.count)）",
             icon: "person.crop.square.stack.fill",
             footer: "点播条 → 进片库看片；直播条 → 跳直播页。也会出现在浏览页「切换源」列表里。") {
            if tvbox.customSites.isEmpty && tvbox.customLives.isEmpty {
                emptyHint("还没有自定义源，点下面「添加」加一个，加完点一下即可观看。")
                hairline
            }
            ForEach(tvbox.customSites) { s in
                HStack(spacing: 10) {
                    Image(systemName: "play.square.stack.fill")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 20)
                    NavigationLink {
                        SiteBrowseView(site: s, sites: Array(tvbox.displayResult.sites))
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.subheadline)
                                    .foregroundStyle(theme.textPrimary).lineLimit(1)
                                Text(s.api).font(.caption2)
                                    .foregroundStyle(theme.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            tagCapsule("点播")
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(theme.textSecondary.opacity(0.55))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    delBtn { tvbox.removeSite(s) }
                }
                .padding(.vertical, 10)
                hairline
            }
            ForEach(tvbox.customLives) { g in
                Button {
                    NotificationCenter.default.post(name: .openLiveTab, object: nil)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name).font(.subheadline)
                                .foregroundStyle(theme.textPrimary).lineLimit(1)
                            Text(g.m3uURLs.first ?? "").font(.caption2)
                                .foregroundStyle(theme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        tagCapsule("直播")
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) { tvbox.removeLive(g) } label: {
                        Label("删除「\(g.name)」", systemImage: "trash")
                    }
                }
                hairline
            }
            addBtn("添加点播源（CMS 接口地址）") { showAddSite = true }
            hairline
            addBtn("添加直播源（M3U / TXT / JSON / 直链）") { showAddLive = true }
        }
    }

    // MARK: TVBox 配置 · 配置历史

    private var tvboxCard: some View {
        card("TVBox 配置 · 配置历史（\(tvbox.subscriptions.count) 条）",
             icon: "clock.arrow.circlepath",
             footer: "本页只管增删与刷新；切换生效在上一页「生效配置」行。github raw 自动走 jsDelivr 镜像。") {
            if tvbox.subscriptions.isEmpty {
                emptyHint("暂无配置历史，点下面「添加配置地址」加一个。")
            }
            ForEach(tvbox.subscriptions) { sub in
                HStack(spacing: 10) {
                    Image(systemName: sub.url == tvbox.activeURL ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(sub.url == tvbox.activeURL ? theme.textPrimary : theme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sub.name).font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.textPrimary).lineLimit(1)
                        Text(sub.url).font(.caption2)
                            .foregroundStyle(theme.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    if sub.url == tvbox.activeURL { tagCapsule("生效") }
                    delBtn { tvbox.remove(sub) }
                }
                .padding(.vertical, 10)
                hairline
            }
            addBtn("添加配置地址（TVBox JSON / 多仓 / M3U）") { showAdd = true }
            hairline
            Button {
                Task { await tvbox.refreshAll() }
            } label: {
                HStack {
                    Label(tvbox.refreshing ? "正在解析…" : "刷新当前配置",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    if tvbox.refreshing { ProgressView().tint(theme.textSecondary) }
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tvbox.refreshing || (tvbox.activeURL == nil && tvbox.activeBuiltinRepoURL == nil))
            if !tvbox.refreshMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").font(.caption)
                    Text(tvbox.refreshMessage).font(.caption).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Capsule().fill(theme.textPrimary.opacity(0.08)))
                .overlay(Capsule().stroke(theme.textSecondary.opacity(0.14), lineWidth: 0.5))
            }
        }
    }

    // MARK: 内置配置线路（chips + 长按删除 + 恢复）

    private var builtinReposCard: some View {
        card("内置配置线路 · 盒子实测（\(tvbox.builtinRepoOptions.count) 条）",
             icon: "square.stack.3d.up.fill",
             footer: "本页只管删除与恢复；点选生效在上一页「生效线路」行（会弹出可滚动列表）。一条线路 = 一份配置包，「N站」是站数。") {
            if tvbox.builtinRepoOptions.isEmpty {
                emptyHint(tvbox.currentMode == "child"
                    ? "儿童端不提供内置线路（避免成人/违禁线路误入孩子的 App），下方点播源照常可用。"
                    : "内置线路已全部删除。点「恢复内置线路」找回来。")
                if tvbox.hasDeletedBuiltinRepos {
                    restoreBuiltinBtn
                    hairline
                }
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(tvbox.builtinRepoOptions) { repo in
                        builtinChip(repo)
                    }
                }
                .padding(.vertical, 4)
                if let u = tvbox.activeBuiltinRepoURL,
                   let r = tvbox.builtinRepoOptions.first(where: { $0.url == u }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").font(.caption)
                        Text("生效线路：\(r.name)（切换在上一页「生效线路」）").font(.caption).lineLimit(1)
                        Spacer()
                    }
                    .foregroundStyle(theme.textPrimary.opacity(0.85))
                    .padding(.vertical, 6)
                }
                if tvbox.hasDeletedBuiltinRepos {
                    restoreBuiltinBtn
                }
            }
        }
    }

    private func builtinChip(_ repo: TVBoxSubscription) -> some View {
        let active = repo.url == tvbox.activeBuiltinRepoURL
        return HStack(spacing: 4) {
            HStack(spacing: 4) {
                if active {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                }
                Text(repo.name).lineLimit(1)
            }
            .font(.caption.weight(active ? .semibold : .regular))
            .foregroundStyle(active ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(active ? theme.textPrimary.opacity(0.14) : theme.textPrimary.opacity(0.06)))
            .overlay(Capsule().stroke(
                active ? theme.textPrimary.opacity(0.28) : theme.textSecondary.opacity(0.14),
                lineWidth: 0.5))
            delBtn { tvbox.removeBuiltinRepo(repo) }
        }
        .contextMenu {
            Button(role: .destructive) { tvbox.removeBuiltinRepo(repo) } label: {
                Label("删除线路「\(repo.name)」", systemImage: "trash")
            }
        }
    }

    private var restoreBuiltinBtn: some View {
        Button {
            tvbox.restoreBuiltinRepos()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle").font(.footnote)
                Text("恢复内置线路（\(tvbox.deletedBuiltinRepoURLs.count) 条已删）").font(.footnote)
                Spacer()
            }
            .foregroundStyle(theme.textPrimary.opacity(0.85))
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 解析结果（仓库 / 点播源可视化 / 直播组测播）

    private func parsedCard(_ result: TVBoxParseResult) -> some View {
        card("解析结果 · 当前生效配置", icon: "doc.text.magnifyingglass",
             footer: "只放本页专有的：多仓收进历史、直播源测播、恢复被删内置源。选源/看源清单都在上一页「当前生效」卡里。") {
            if !result.repos.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("多仓（\(result.repos.count)）", systemImage: "square.stack.3d.up")
                            .font(.subheadline)
                            .foregroundStyle(theme.textPrimary)
                        Text("切仓在上一页「解析源」行")
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary.opacity(0.75))
                    }
                    Spacer()
                    Button("全部收进配置历史") { tvbox.adoptRepos() }
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.vertical, 8)
                hairline
            }
            NavigationLink {
                AggregateSearchView(sites: Array(result.sites.filter { $0.type != 3 }.prefix(30)))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                    Text("聚合搜索（前 30 个源一次搜）").font(.subheadline)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.textSecondary.opacity(0.55))
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            hairline
            if tvbox.hasDeletedBuiltins {
                HStack(spacing: 8) {
                    Text("点播源 \(result.sites.count) 个（清单在上一页「当前生效」卡）")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    Button { tvbox.restoreBuiltins() } label: {
                        Text("恢复被删 \(tvbox.deletedBuiltinKeys.count)")
                            .font(.caption)
                            .foregroundStyle(theme.textPrimary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 8)
                hairline
            }
            ForEach(result.lives) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text("直播组：\(group.name)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textPrimary.opacity(0.85))
                        .padding(.vertical, 6)
                    ForEach(Array(group.m3uURLs.enumerated()), id: \.offset) { _, u in
                        Button {
                            Task {
                                if u.lowercased().contains(".m3u") {
                                    let channels = await tvbox.expandM3U(u)
                                    testingChannel = channels.first
                                } else if let url = URL(string: u) {
                                    testingChannel = LiveChannel(id: u, name: group.name, url: url)
                                }
                            }
                        } label: {
                            HStack {
                                Text(u).font(.caption2)
                                    .foregroundStyle(theme.textSecondary).lineLimit(1)
                                Spacer()
                                Text("测播").font(.caption)
                                    .foregroundStyle(theme.textPrimary.opacity(0.8))
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func siteChip(_ s: TVBoxSite, sites: [TVBoxSite]) -> some View {
        NavigationLink {
            SiteBrowseView(site: s, sites: sites)
        } label: {
            HStack(spacing: 4) {
                if s.key.hasPrefix("builtin:") {
                    Text("内")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.textPrimary.opacity(0.85))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(theme.textPrimary.opacity(0.12), in: Capsule())
                }
                Text(s.name).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(theme.textPrimary.opacity(0.88))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(theme.textPrimary.opacity(0.06)))
            .overlay(Capsule().stroke(theme.textSecondary.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if s.key.hasPrefix("builtin:") {
                Button(role: .destructive) { tvbox.removeSite(s) } label: {
                    Label("删除内置源「\(s.name)」", systemImage: "trash")
                }
            }
        }
    }

    // MARK: 新版卡壳与行组件（中性透明玻璃 · 零红色）

    private func card<Content: View>(_ title: String, icon: String, footer: String? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 7)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 16)
            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            } else {
                Spacer().frame(height: 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(theme.textPrimary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(theme.textSecondary.opacity(0.14), lineWidth: 0.5)
        )
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.textSecondary.opacity(0.14))
            .frame(height: 0.5)
    }

    private func addBtn(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").font(.subheadline)
                Text(title).font(.subheadline)
                Spacer()
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tagCapsule(_ t: String) -> some View {
        Text(t)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(theme.textPrimary.opacity(0.12), in: Capsule())
            .foregroundStyle(theme.textPrimary.opacity(0.85))
    }

    private func delBtn(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.footnote)
                .foregroundStyle(theme.textSecondary.opacity(0.7))
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func emptyHint(_ t: String) -> some View {
        Text(t)
            .font(.caption)
            .foregroundStyle(theme.textSecondary.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
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
                                .foregroundStyle(addSiteOK ? theme.textPrimary : theme.textSecondary)
                            if addSiteOK, let s = lastAddedSite {
                                Button {
                                    showAddSite = false
                                    let target = s
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { goBrowseSite = target }
                                } label: {
                                    Label("立即去看 · \(s.name)", systemImage: "arrow.right.circle.fill")
                                        .font(.footnote.weight(.semibold))
                                }
                                .foregroundStyle(theme.textPrimary)
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
                            .foregroundStyle(addLiveOK ? theme.textPrimary : theme.textSecondary)
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
                        .foregroundStyle(theme.textPrimary)
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
                .tint(theme.textPrimary)
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
                                .fill(appearanceRaw == m.rawValue ? theme.textPrimary.opacity(0.14) : Color.clear)
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
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 22)
                    Text("清除片库与图片缓存")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
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
