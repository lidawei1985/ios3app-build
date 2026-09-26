import SwiftUI
import UIKit
import AVKit
import FilmCore

/// 直播页（大牌直连式，2026-09-20 重做）：
/// 进 Tab 直接全屏播放（上次频道/第一台），点屏幕出控制层，频道列表为叠加层；
/// 频道源 = feed 真源 M3U（live_engine 探活产物）+ 内置保底 + TVBox 自定义订阅，按分组合并去重。
/// 心屋（无直播）不会进入此页（MainTabView 按 profile.liveM3UPath 显隐）。
public struct LiveView: View {
    let livePath: String
    @EnvironmentObject private var store: CatalogStore
    @EnvironmentObject private var tvbox: TVBoxConfigStore
    @Environment(\.filmTheme) private var theme

    @State private var channels: [LiveChannel] = []
    @State private var loading = true
    @State private var loadFailed = false
    @State private var remoteLoaded = true   // 远端 feed 是否拿到真频道（false = 正在看离线保底）
    @State private var showList = false
    @State private var liveClosed = false     // 用户退出直播：停播+可反悔重开
    @State private var showSourcePicker = false
    @State private var bannerVisible = false   // 「订阅源失败」横幅：显示 6 秒自动消失（能播就不烦人）
    @State private var bannerHideTask: Task<Void, Never>?
    // 首次使用引导（只出一次）：点屏呼列表 / 上下滑换台 / 面板换源，一次教全
    @AppStorage("live.gestureHintShown") private var gestureHintShown = false
    @State private var showGestureHint = false
    @State private var hintHideTask: Task<Void, Never>?
    // TVBox 原版语义：一个直播源一套频道，随时点选切换（默认订阅/内置实测源/自定义源）
    @AppStorage("live.activeSource") private var activeSourceKey = "remote"
    // 三 App 各自独立 UserDefaults，单键即可；上次看的频道跨启动记忆
    @AppStorage("live.lastChannelName") private var lastChannelKey = ""

    private var loader: LiveLoader
    private var profileMode: String   // 产品模式（直播源隔离：夜航仅官方成人直播 2026-09-21）

    public init(profile: ProductProfile, livePath: String) {
        self.livePath = livePath
        profileMode = profile.mode
        loader = LiveLoader(bases: FeedBases(profile: profile))   // 与本产品 feed 同仓库同基址链
    }

    /// 上次看的频道优先，否则第一台。
    private var startIndex: Int {
        if !lastChannelKey.isEmpty,
           let idx = channels.firstIndex(where: { $0.name == lastChannelKey }) {
            return idx
        }
        return 0
    }

    public var body: some View {
        Group {
            if loading {
                LoadingView(text: "加载频道…")
            } else if liveClosed {
                closedScreen
            } else if channels.isEmpty {
                emptyOrError
            } else {
                ZStack {
                    LivePlayerScreen(channels: channels,
                                     startIndex: startIndex,
                                     showList: $showList,
                                     onRequestExit: exitLive,
                                     onPickSource: { showSourcePicker = true })
                    if showList {
                        channelListOverlay
                    }
                    if !remoteLoaded && bannerVisible {
                        // 默认订阅源失败横幅：明示已自动切源 + 给「换源」入口；6 秒自动消失
                        VStack {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                Text("订阅源失败，当前「\(currentSourceName)」")
                                    .font(.caption).lineLimit(1)
                                Spacer()
                                Button("换源") { showSourcePicker = true }
                                    .font(.caption.weight(.medium))
                                Button("重试") { Task { await load() } }
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .shadow(color: .black.opacity(0.7), radius: 3)
                            .padding(.top, 2)
                            Spacer()
                        }
                        .transition(.opacity)
                    }
                    if showGestureHint {
                        gestureHintOverlay
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)   // 直播沉浸全屏：藏底部 tab 栏（用户反馈 2026-09-20）
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("直播")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showSourcePicker) { sourcePicker }
    }

    /// 用户点返回 = 真退出：停播（视图移除触发 onDisappear）+ 跳回首页 tab。
    /// 想看再点「重新打开」，随时反悔；绝不留后台声音。
    private func exitLive() {
        showList = false
        liveClosed = true
        NotificationCenter.default.post(name: .liveExitToHome, object: nil)
    }

    private var closedScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv")
                .font(.system(size: 42)).foregroundStyle(.secondary)
            Text("直播已关闭").font(.headline).foregroundStyle(theme.textPrimary)
            Text("播放已完全停止，不会有后台声音")
                .font(.footnote).foregroundStyle(theme.textSecondary)
            Button {
                liveClosed = false
            } label: {
                Label("重新打开直播", systemImage: "play.fill")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 20).padding(.vertical, 11)
                    .background(theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(30)
    }

    // MARK: - 频道列表（小薇直播 TV 式全屏：序号+台名+分组，当前台高亮，点选即换）

    private var channelListOverlay: some View {
        // 60包（用户钦定 2026-09-23：「不行就列表放右侧 左侧给个返回键加剧名」）：
        // 频道面板由**左侧**改到**右侧**——原来面板贴在左边，正好盖住左上的「返回键 + 台名」，
        // 用户找不到返回。现在左侧留空给返回键与台名（常驻可见），面板从右侧滑出，点左侧空白收起。
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { showList = false }
            LiveChannelList(channels: channels,
                            sourceName: currentSourceName,
                            onPickSource: { showSourcePicker = true },
                            onPick: { ch in
                                lastChannelKey = ch.name
                                LiveSwitchBus.shared.request = ch.id   // 精确换到点选的这条线路
                                showList = false
                            },
                            onClose: { showList = false },
                            adultMode: profileMode == "adult")
                .frame(width: min(340, UIScreen.main.bounds.width * 0.62))
        }
        .transition(.move(edge: .trailing))
    }

    // MARK: - 选择直播源（TVBox 原版：全部直播源一屏点选，当前高亮）

    private var sourcePicker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sourceOptions) { opt in
                        Button { pickSource(opt.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(opt.name).font(.footnote)
                                        .foregroundStyle(theme.textPrimary).lineLimit(1)
                                    Text(opt.subtitle).font(.caption2)
                                        .foregroundStyle(theme.textSecondary).lineLimit(1)
                                }
                                Spacer()
                                if opt.id == activeSourceKey {
                                    Text("当前").font(.caption2).foregroundStyle(theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("直播源（\(sourceOptions.count)）")
                } footer: {
                    Text("点选即切换直播源（TVBox 原版功能）。内置源为实测可用的公开聚合源；自己的直播源在「设置 → 自定义直播源」添加，支持 M3U 与 TVBox txt 格式。")
                }
                Section {
                    Button {
                        showSourcePicker = false
                        NotificationCenter.default.post(name: .openAppSettings, object: nil)
                    } label: {
                        Label("去添加直播源", systemImage: "plus.circle.fill")
                            .foregroundStyle(theme.accent)
                    }
                }
            }
            .navigationTitle("选择直播源")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func pickSource(_ key: String) {
        showSourcePicker = false
        showList = false
        guard key != activeSourceKey else { return }
        activeSourceKey = key
        lastChannelKey = ""   // 新源没有旧台，从头开始
        Task { await load() }
    }

    // MARK: - 直播源（TVBox 原版语义：一个源一套频道，点选切换）

    private struct LiveSourceOption: Identifiable {
        let id: String
        let name: String
        let subtitle: String
    }

    /// 可选直播源：默认订阅 → 内置实测源 → 用户自定义（设置里加的每个源一条）。
    private var sourceOptions: [LiveSourceOption] {
        var out: [LiveSourceOption] = [LiveSourceOption(id: "remote",
                                                        name: "默认订阅源",
                                                        subtitle: "App 订阅直播（随包配置）")]
        for g in DefaultSites.builtinLiveSources(forMode: profileMode) {
            out.append(LiveSourceOption(id: "builtin:" + g.id, name: g.name,
                                        subtitle: profileMode == "adult" ? "官方成人直播" : "内置实测公开源"))
        }
        for g in tvbox.customLives {
            out.append(LiveSourceOption(id: "custom:" + g.id, name: g.name, subtitle: "我的自定义源"))
        }
        return out
    }

    /// 当前生效源名（横幅/列表头显示）。
    private var currentSourceName: String {
        sourceOptions.first(where: { $0.id == activeSourceKey })?.name ?? "默认订阅源"
    }

    /// 配置自带的直播组（生效订阅里的 lives；手动自定义组除外）。
    private var configLiveGroups: [TVBoxLiveGroup] {
        let manual = Set(tvbox.customLives.map(\.id))
        return tvbox.displayResult.lives.filter { !manual.contains($0.id) }
    }

    /// 加载指定源的频道。列表地址（m3u/txt）异步展开，直链频道直接入库。
    private func loadChannels(for key: String) async -> [LiveChannel] {
        // ③直播慢修复 2026-09-22：所有列表地址并行展开。
        // 原串行 for 循环 × 每地址多候选 × 15s 超时 = 一个坏地址拖死整个直播页。
        func expand(_ groups: [TVBoxLiveGroup]) async -> [LiveChannel] {
            let addresses = groups.flatMap { g in g.m3uURLs.map { (name: g.name, url: $0) } }
            return await withTaskGroup(of: [LiveChannel].self) { grp in
                for a in addresses {
                    grp.addTask {
                        // TVBoxConfigStore 为 @MainActor 类，静态方法在子任务里同样需 await
                        if await TVBoxConfigStore.isExpandableListAddress(a.url) {
                            return await self.tvbox.expandM3U(a.url)
                        } else if let url = URL(string: a.url) {
                            return [LiveChannel(id: a.url, name: a.name, url: url)]
                        }
                        return []
                    }
                }
                var chs: [LiveChannel] = []
                for await c in grp { chs += c }
                return chs
            }
        }
        if key == "remote" {
            var chs = await loader.load(path: livePath)
            chs += await expand(configLiveGroups)
            return chs
        }
        let prefix = key.contains(":") ? String(key[..<key.firstIndex(of: ":")!]) : ""
        let rest = prefix.isEmpty ? key : String(key.dropFirst(prefix.count + 1))
        if prefix == "builtin",
           let g = DefaultSites.builtinLiveSources(forMode: profileMode).first(where: { $0.id == rest }) {
            return await expand([g])
        }
        if prefix == "custom",
           let g = tvbox.customLives.first(where: { $0.id == rest }) {
            return await expand([g])
        }
        return []
    }

    /// 源池 → 有序频道表：所选源排最前（用户手选优先）→ 其余源依次补位 →
    /// URL 去重 + 同名台编线路号（CCTV1 / CCTV1·备2 / ·备3…）。跨源同名全部保留，
    /// 自动换源靠它们逐条接力（normalized 名相同即同台，·备N 不影响归一匹配）。
    /// 60包：从 load() 里抽出，因为流式首屏与最终全集都要用它。
    private func mergedChannels(_ pool: [(key: String, chs: [LiveChannel])]) -> [LiveChannel] {
        var ordered: [LiveChannel] = []
        if let sel = pool.first(where: { $0.key == activeSourceKey }) { ordered += sel.chs }
        for r in pool where r.key != activeSourceKey { ordered += r.chs }
        var seenURLs = Set<String>()
        var nameCount: [String: Int] = [:]
        var out: [LiveChannel] = []
        for ch in ordered where seenURLs.insert(ch.url.absoluteString).inserted {
            let base = ch.name.firstIndex(of: "·").map { String(ch.name[..<$0]) } ?? ch.name
            let clean = base.replacingOccurrences(of: " ", with: "")
            if let n = nameCount[clean] {
                nameCount[clean] = n + 1
                // 2026-09-22 修复：原来此处丢掉 group，同名多线路全落进「其他」桶
                out.append(LiveChannel(id: ch.id, name: "\(clean)·备\(n)", url: ch.url, group: ch.group))
            } else {
                nameCount[clean] = 1
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - 加载

    private func load() async {
        loading = true
        loadFailed = false
        // ③直播慢修复 2026-09-22：缓存秒开——上次成功抓到的频道立即上屏，
        // 网络聚合完成后整体替换；网络全挂时缓存兜底（优先于内置测试源）。
        var cacheBackup: [LiveChannel] = []
        if let cached = await loader.cachedChannels(path: livePath), !cached.isEmpty {
            cacheBackup = cached
            channels = cached
            loading = false
        } else {
            // 60包（用户：「直播依然需要等很久一直在缓存」）：**包内真直播快照立即上屏**——
            // 没有本地缓存时不再白屏等网络，进页面就有台可选可播（零网络秒开），远端随后刷新覆盖。
            let snap = LiveDefaults.embeddedChannels(forMode: profileMode)
            if !snap.isEmpty {
                channels = snap
                loading = false
            }
        }
        // 全源并行聚合（容灾升级 2026-09-21 用户钦定）：不再「第一个有货的源独占」，
        // 而是把所有源的频道合成一个池——同名台（CCTV1）跨源互为备用线路，
        // 播放中坏一条自动换下一条 CCTV1（autoHeal 同名优先），绝不跳到别的台。
        let opts = sourceOptions
        var pool: [(key: String, chs: [LiveChannel])] = []
        // 60包（2026-09-23 用户：「直播依然需要等很久一直在缓存」）：**流式首屏**——
        // 原实现是「所有源都回来才 channels = final」，6 个源（订阅+5 个内置 CDN）里
        // 只要有 1 个在手机上不通，就得干等它超时，用户看到的就是长时间「加载频道…」。
        // 现在：第一个源到货立即上屏起播，其余源后台继续聚合（全集到达后整体替换，
        // 正在播的台已 pinned 在播放器里，不会被换掉）。
        var onScreen = !channels.isEmpty
        await withTaskGroup(of: (String, [LiveChannel]).self) { grp in
            for opt in opts {
                grp.addTask { (opt.id, await self.loadChannels(for: opt.id)) }
            }
            for await (key, chs) in grp where !chs.isEmpty {
                pool.append((key: key, chs: chs))
                if !onScreen {
                    let quick = mergedChannels(pool)
                    if !quick.isEmpty {
                        channels = quick
                        loading = false
                        onScreen = true
                    }
                }
            }
        }
        // 全部源都失败 → 缓存频道兜底（③修复：有缓存不降级测试源、不亮失败横幅）
        var usedCacheBackup = false
        if pool.isEmpty && !cacheBackup.isEmpty { usedCacheBackup = true }
        // 默认订阅源是否有货：决定要不要亮「订阅源失败」横幅（显示 6 秒自动消失）
        // 缓存兜底生效 = 视为有货（频道实际可看，别吓用户）
        remoteLoaded = pool.contains { $0.key == "remote" } || usedCacheBackup
        scheduleBanner()
        var final = mergedChannels(pool)
        // 无缓存且全部源都失败 → 内置离线频道兜底（多为测试源，UI 明示可能不可播）
        // 夜航例外：通用兜底频道严禁混入成人产品（隔离 2026-09-21），失败就明示失败
        if final.isEmpty && !cacheBackup.isEmpty { final = cacheBackup }
        // 60包：兜底改用「包内真直播快照」（normal_live.m3u / adult_live.m3u）。
        // 原兜底是 LiveDefaults.embedded（北邮测试源 ivi.bupt.edu.cn）——用户实测那批在播循环测试片
        // （「浙江卫视一个镜头循环 N 次」），属于「假直播」，已从自动链路摘除。
        if final.isEmpty { final = LiveDefaults.embeddedChannels(forMode: profileMode) }
        channels = final
        loading = false
        loadFailed = final.isEmpty
        // 首次使用引导：拿到频道后出一次操作指南（点任意处或 8 秒后消失）
        if !final.isEmpty && !gestureHintShown {
            gestureHintShown = true
            withAnimation(.easeIn(duration: 0.3)) { showGestureHint = true }
            scheduleHintHide()
        }
    }

    /// 横幅调度：订阅源失败时显示，6 秒后自动淡出（用户反馈 2026-09-20：能播就别一直挂）。
    private func scheduleBanner() {
        bannerHideTask?.cancel()
        withAnimation { bannerVisible = !remoteLoaded && !loading }
        guard bannerVisible else { return }
        bannerHideTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { bannerVisible = false }
        }
    }

    // MARK: - 首次使用引导（手 = 遥控器：点屏呼面板 / 上下滑换台 / 面板换源）

    private var gestureHintOverlay: some View {
        VStack(spacing: 14) {
            Label("直播操作指南", systemImage: "hand.tap.fill")
                .font(.headline).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 9) {
                hintRow(icon: "hand.tap", text: "点屏幕 = 呼出 / 收起频道面板")
                hintRow(icon: "arrow.up.arrow.down", text: "上下滑动 = 换台（上滑下一台）")
                hintRow(icon: "antenna.radiowaves.left.and.right", text: "面板打开时顶部信号图标 = 换直播源")
            }
            Text("点任意位置开始观看").font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
        .padding(22)
        // 52包（用户：「不要出现黑框框了 啥按钮都加黑框 很难受啊」）：引导卡不再用重黑底，
        // 改淡底 + 细描边 —— 在画面上是"卡片"而不是"黑块"。
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.14), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.3)) { showGestureHint = false } }
    }

    private func hintRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.footnote).frame(width: 22)
            Text(text).font(.footnote)
        }
        .foregroundStyle(.white.opacity(0.92))
    }

    private func scheduleHintHide() {
        hintHideTask?.cancel()
        hintHideTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { showGestureHint = false }
        }
    }

    private var emptyOrError: some View {
        VStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("没有拿到任何频道").font(.headline).foregroundStyle(theme.textPrimary)
            Text("添加一个直播源即可开看\n支持 M3U 地址与 TVBox txt 格式（组名,#genre#）")
                .font(.footnote).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                NotificationCenter.default.post(name: .openAppSettings, object: nil)
            } label: {
                Label("去添加直播源", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            Button {
                // 60包：显式入口才用 generic embedded（北邮测试源）；这条路径由用户主动选择
                let snap = LiveDefaults.embeddedChannels(forMode: profileMode)
                channels = snap.isEmpty ? LiveDefaults.embedded : snap
                remoteLoaded = false
            } label: {
                Text("先看离线备用频道").font(.footnote).foregroundStyle(theme.accent)
            }
            Button("重试") { Task { await load() } }
                .font(.footnote).foregroundStyle(theme.textSecondary)
        }
        .padding(30)
    }
}

/// 频道列表总线补充：当前播放台名（列表高亮用）。
final class LiveSwitchBus: ObservableObject {
    static let shared = LiveSwitchBus()
    @Published var request: String?      // 目标频道 id
    @Published var requestIndex = 0      // 61包：同一 id 连点也要重新换（onChange 需值变化）
    @Published var nowPlaying = ""       // 当前播放台名（归一后），列表高亮
    @Published var nowPlayingID = ""     // 当前播放频道精确 id（同台名多线路时唯一高亮）
    /// 61包（用户：「换台不要卡」）——**预取提示表**：把「点屏呼出频道列表」当作换台前兆，
    /// 命中时提前对可见范围内的频道表做一次预热抓取（URLSession 连接/TLS/DNS 就绪 +
    /// 进磁盘缓存），用户真正点下去时命中缓存 → 起播明显更快。
    /// 只预热、不建播放器（零流量浪费、不干扰正在播的台）。
    @Published var prefetchTick = 0
}

/// 星幕频道面板（用户钦定 2026-09-20：贴屏幕左侧竖条，右侧透出视频）。
/// 顶部：面板题 + 直播源胶囊 + 关闭；分组 chips 横滚（全部/央视/卫视/体育…自动归类计数）；
/// 下面频道列表上下滑动（组内连续编号 + ▶正在播 红色高亮），点选精确换到该线路。
struct LiveChannelList: View {
    let channels: [LiveChannel]
    var sourceName: String = ""              // 当前直播源名（源入口按钮显示）
    var onPickSource: (() -> Void)? = nil    // 呼出「选择直播源」
    let onPick: (LiveChannel) -> Void
    let onClose: () -> Void
    /// 夜航（成人端）用「源站真实分组」做分类 chips（欧美/华语/时装秀…），与 TV 版夜航面板一致；
    /// 星幕仍走通用桶（央视/卫视/体育…）。2026-09-22 跨端一致性约定。
    var adultMode: Bool = false
    @ObservedObject private var bus = LiveSwitchBus.shared
    @Environment(\.filmTheme) private var theme
    @State private var selectedGroup: String? = nil   // nil = 全部频道
    @State private var expandedBase = Set<String>()   // 已展开备线的台（归一名）

    // MARK: 分组归类（频道面板式标准分组；按 group 名 + 台名关键词归桶）

    static let groupOrder = ["央视", "卫视", "体育", "新闻", "电影·剧场", "少儿", "音乐", "综艺", "纪录", "其他"]

    private func classify(_ ch: LiveChannel) -> String {
        // 夜航：直接用源站分组（欧美/华语/时装秀），与 TV 版夜航面板逐字一致
        if adultMode { return ch.group.isEmpty ? "其他" : ch.group }
        let bag = (ch.group + " " + ch.name).lowercased()
        if bag.contains("cctv") || bag.contains("cetv") || bag.contains("cgtn") || bag.contains("央视") { return "央视" }
        if bag.contains("卫视") { return "卫视" }
        if bag.contains("体育") || bag.contains("赛事") || bag.contains("足球") || bag.contains("篮球") || bag.contains("sport") { return "体育" }
        if bag.contains("新闻") || bag.contains("资讯") || bag.contains("news") { return "新闻" }
        if bag.contains("电影") || bag.contains("剧场") || bag.contains("影院") || bag.contains("影视") || bag.contains("movie") { return "电影·剧场" }
        if bag.contains("少儿") || bag.contains("卡通") || bag.contains("动画") || bag.contains("kids") || bag.contains("cartoon") { return "少儿" }
        if bag.contains("音乐") || bag.contains("music") { return "音乐" }
        if bag.contains("综艺") { return "综艺" }
        if bag.contains("纪录") || bag.contains(" documentary") { return "纪录" }
        return "其他"
    }

    private var classified: [(ch: LiveChannel, group: String)] {
        channels.map { ($0, classify($0)) }
    }

    /// 左侧 chips：有频道的标准分组按固定顺序（「全部频道」固定第一）。
    private var availableGroups: [String] {
        let counts = Dictionary(grouping: classified, by: \.group).mapValues(\.count)
        if adultMode {
            // 夜航：按出现顺序给真实分组（欧美/华语/时装秀），不把三类压成一个「其他」
            var seen = Set<String>()
            var out: [String] = []
            for c in classified where (counts[c.group] ?? 0) > 0 {
                if seen.insert(c.group).inserted { out.append(c.group) }
            }
            return out
        }
        return Self.groupOrder.filter { (counts[$0] ?? 0) > 0 }
    }

    private func groupCount(_ g: String?) -> Int {
        guard let g else { return channels.count }
        return classified.filter { $0.group == g }.count
    }

    /// 右列频道行：所选分类（nil=全部）。
    /// 61包（用户钦定 2026-09-23）：**默认只显示主源**（同台的 ·备N 折叠起来），
    /// 列表干净、不用在几十条重复台名里找；需要手动换源的台，点右侧「⇄ N」展开备线。
    private var rows: [(idx: Int, ch: LiveChannel)] {
        let base: [(ch: LiveChannel, group: String)]
        if let g = selectedGroup {
            base = classified.filter { $0.group == g }
        } else {
            base = classified
        }
        var hide = Set<String>()   // 已折叠的备线 id
        var counted: [(String, [String])] = []   // (归一名, 该组全部 id，按序)
        for (ch, _) in base {
            let k = normalize(ch.name)
            if let last = counted.last, last.0 == k {
                counted[counted.count - 1].1.append(ch.id)
            } else {
                counted.append((k, [ch.id]))
            }
        }
        for (k, ids) in counted where ids.count > 1 && !expandedBase.contains(k) {
            for id in ids.dropFirst() { hide.insert(id) }
        }
        return base.enumerated()
            .filter { !hide.contains($0.element.ch.id) }
            .map { ($0.offset + 1, $0.element.ch) }
    }

    /// 某条主源后面还有几条备线（用于「⇄ N」按钮）。
    private func backupCount(of ch: LiveChannel) -> Int {
        let k = normalize(ch.name)
        return channels.filter { normalize($0.name) == k }.count - 1
    }

    var body: some View {
        // TVBox 原版双栏（2026-09-21 用户钦定，位置贴屏幕左侧）：左窄列分类竖排 + 右宽列频道
        HStack(spacing: 0) {
            // 左列：分类
            ScrollView {
                LazyVStack(spacing: 0) {
                    catRow("全部", tag: nil)
                    ForEach(availableGroups, id: \.self) { g in
                        catRow(g, tag: g)
                    }
                }
            }
            .frame(width: 96)
            .background(Color.white.opacity(0.05))

            // 右列：当前分类频道
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.ch.id) { row in
                            channelRow(row).id(row.ch.id)
                        }
                    }
                }
                .onAppear {
                    if let cur = currentPlayingID { proxy.scrollTo(cur, anchor: .center) }
                }
                .onChange(of: selectedGroup) { _ in
                    if let cur = currentPlayingID { proxy.scrollTo(cur, anchor: .center) }
                }
            }
        }
        // 52包：频道面板遮罩 0.86 → 0.7（少一点"满屏黑"，面板与画面都看得清）。
        .background(Color.black.opacity(0.7).ignoresSafeArea())
    }

    /// 左列分类行：名 + 台数，选中高亮。
    private func catRow(_ title: String, tag: String?) -> some View {
        let isSel = selectedGroup == tag
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selectedGroup = tag }
        } label: {
            HStack {
                Text(title)
                    .font(.footnote.weight(isSel ? .semibold : .regular))
                    .foregroundStyle(isSel ? theme.accent : .primary)
                    .lineLimit(1)
                Spacer()
                Text("\(groupCount(tag))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
            .background(isSel ? theme.accent.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 当前播放频道 id（仅当它在当前 rows 里才有滚动意义）。
    private var currentPlayingID: String? {
        bus.nowPlayingID.isEmpty ? nil : bus.nowPlayingID
    }

    private func channelRow(_ row: (idx: Int, ch: LiveChannel)) -> some View {
        let isNow = bus.nowPlayingID == row.ch.id
            || (bus.nowPlayingID.isEmpty && bus.nowPlaying == normalize(row.ch.name))
        let isBackup = row.ch.name.contains("·备")
        let bk = backupCount(of: row.ch)
        let key = normalize(row.ch.name)
        return HStack(spacing: 0) {
            Button {
                onPick(row.ch)
            } label: {
                HStack(spacing: 10) {
                    Text(String(format: "%02d", row.idx))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isNow ? theme.accent : .secondary)
                        .frame(minWidth: 26, alignment: .leading)
                    Text(row.ch.name)
                        .font(.subheadline.weight(isNow ? .semibold : .regular))
                        .foregroundStyle(isNow ? theme.accent : .primary)
                        .lineLimit(1)
                    Spacer()
                    if isNow {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill").font(.caption2)
                            Text("正在播").font(.caption)
                        }
                        .foregroundStyle(theme.accent)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 61包：手动换源入口——同台有多条线路时，主源右侧给「⇄N」展开备线，点备线即换到那条。
            if bk > 0 && !isBackup {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if expandedBase.contains(key) { expandedBase.remove(key) }
                        else { expandedBase.insert(key) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                        Text("\(bk)").font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(theme.accent.opacity(0.9))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("换信号源")
            } else if isBackup {
                Text("备")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 6)
            }
        }
        .padding(.trailing, 4)
        .background(isNow ? Color.white.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
    }

    private func normalize(_ name: String) -> String {
        var n = name
        if let dot = n.firstIndex(of: "·") { n = String(n[..<dot]) }
        return n.replacingOccurrences(of: " ", with: "")
    }
}

// MARK: - 直播播放器（全功能，五重返回保险，自动换源）

/// 直播播放器：
/// - 嵌入模式（直播 Tab）：返回键 = 呼出/收起频道列表（经 showList binding）；
/// - 封面模式（设置测播）：返回键 = 五重保险关闭（closed 本地态 + onClose + dismiss + UIKit 兜底）；
/// - 播放失败自动换源：先试同名备用线路（·备N），再自动跳下一台，无人值守。
struct LivePlayerScreen: View {
    let channels: [LiveChannel]
    @Binding var showList: Bool
    var onRequestExit: (() -> Void)? = nil   // 嵌入模式：真退出直播（停播+跳首页），由宿主注入
    var onClose: (() -> Void)? = nil         // 封面模式（设置测播）：五重关闭
    var onPickSource: (() -> Void)? = nil    // 嵌入模式：呼出「选择直播源」（TVBox 菜单键语义）

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var index: Int
    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var tuning = false        // 起播/换台加载中（时间推进即出画）
    @State private var stallBanner = false   // 缓冲横幅（27号包 用户钦定：卡了先等恢复，不立刻跳台）
    @State private var everPlayed = false    // 当前链是否播起来过（28b：没播起来=坏链快切，不傻等）
    @State private var failFastTries = 0     // 坏链快速换备线计数（同台最多3条，全死才跳台）
    @State private var closed = false
    @State private var lastProgressAt = Date()
    // v17 源健康度：switchedAt=换线时刻（幻灯片检测豁免窗口）；recordedOK=已记成功的 URL；
    // slideTries=幻灯片贴地秒数（连续 3 秒缓冲水位 <1.5s 即降级换线）
    @State private var switchedAt = Date.distantPast
    @State private var recordedOK: URL?
    @State private var slideTries = 0
    @State private var watchdog: Task<Void, Never>?
    @State private var timeObs: Any?
    /// 原地重连计数（2026-09-22 用户：「直播一直卡着不动，一直缓冲中」）。
    /// 此前卡住只会去找「同名备用线路」，**该台只有一条线路时 autoHeal 直接 return** ——
    /// 于是永远停在「缓冲中」。现在改为先原地重连（同 URL 重新拉流），两次后才换线/跳台。
    @State private var reconnectTries = 0
    /// 60包：起播时**固定住的台**。频道表会在后台被流式/全集替换（秒开必需），
    /// 若 current 一直取 channels[index]，换表那一瞬就会指向另一个台（画面还在播老台，台名已变）。
    /// 固定住 = 表刷新绝不打断正在看的台；换台（点列表/上下滑）时才更新它。
    @State private var pinned: LiveChannel?
    /// 60包（用户钦定 2026-09-23：「点屏幕一下先出返回…你看怎么合理」）：进入直播先闪现 3 秒
    /// 控制层（返回键 + 台名），让用户一眼知道返回在哪；随后自动收起，点屏再呼出。
    @State private var controlsPeek = false
    @State private var peekTask: Task<Void, Never>?
    /// 61包（用户：「要先把返回键还给我！！！」）—— 窗口级返回键兜底。
    /// SwiftUI 按钮在 LiveContainer 里偶发被全屏手势层/视频层吞掉 tap（50/58 包记录过的老毛病）；
    /// 这里再挂一个**挂在 keyWindow 上的 UIKit 按钮**，物理免疫 hit-testing 被吃，
    /// 与 SwiftUI 那份显隐同步（同一语义：退出直播）。
    @State private var winBack: WindowBackButton?
    @ObservedObject private var switchBus = LiveSwitchBus.shared

    init(channels: [LiveChannel], startIndex: Int = 0,
         showList: Binding<Bool> = .constant(false),
         onRequestExit: (() -> Void)? = nil,
         onClose: (() -> Void)? = nil,
         onPickSource: (() -> Void)? = nil) {
        self.channels = channels
        _showList = showList
        self.onRequestExit = onRequestExit
        self.onClose = onClose
        self.onPickSource = onPickSource
        _index = State(initialValue: channels.isEmpty ? 0 : min(max(startIndex, 0), channels.count - 1))
    }

    private var current: LiveChannel? {
        // 60包：优先返回 pinned（正在播的那条），表被后台替换时不改台。
        if let pinned { return pinned }
        return channels.indices.contains(index) ? channels[index] : nil
    }

    var body: some View {
        if closed {
            Color.clear.allowsHitTesting(false)
        } else {
            playerBody
        }
    }

    private var playerBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                BareVideoContainer(player: player)
                    .ignoresSafeArea()
            }

            // 手势层：单击呼出/隐藏控制层；上下滑换台（电视 CH± 的手机版，用户钦定 2026-09-20）
            // 61包：列表打开时**关掉这层手势**——否则它在最上层，左侧返回键会被它吃掉
            // （用户反馈「列表在时返回键点不动」的老问题）。
            if !showList {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // 60包（用户钦定 2026-09-23）—— 「点屏幕」用**两态**，不用四步循环：
                        // 列表已移到右侧、不再压住左上角，所以一次点屏就能同时给出
                        // 「右侧频道列表 + 左上返回键/台名」；再点一次一起收起。
                        // （点四次那种循环要按好几下才能换台，反而烦。）
                        peekTask?.cancel()
                        controlsPeek = false
                        withAnimation(.easeInOut(duration: 0.22)) { showList.toggle() }
                        // 61包：用户点屏 = 准备换台的前兆 → 立刻预热附近台的 playlist，
                        // 等他点下去时命中缓存，换台更快（不建播放器、不占画面）。
                        if showList { prewarmVisible() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { v in
                                guard abs(v.translation.height) > abs(v.translation.width) else { return }
                                stepChannel(v.translation.height < 0 ? 1 : -1)   // 上滑=下一台，下滑=上一台
                            }
                    )
            } else {
                // 列表打开时点左侧空白 = 收起列表（保留原来的点空白关闭习惯）
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showList = false } }
                    Color.clear
                        .frame(width: min(340, UIScreen.main.bounds.width * 0.62))
                        .allowsHitTesting(false)
                }
            }

            if showList || controlsPeek {
                topBar
            }

            if failed {
                failureOverlay
            }


            // 缓冲横幅（27号包 用户钦定）：卡了显示「缓冲中，请稍等」+ 手动换源入口。
            // 61包（用户：「我要手动切换信号源」）——「换信号源」= **强制换到同台下一条线路**，
            // 不再走 autoHeal 的"没有备线就什么都不做"（那条路让单线路频道点了没反应）。
            // v13（2026-09-25 用户反馈「直播没有图像时无法返回」）——横幅第一位加「返回」：
            // 黑屏卡住时这条横幅是唯一稳定可见的 UI，返回键必须常驻在这。
            if stallBanner && !failed {
                HStack(spacing: 14) {
                    ProgressView().tint(.white)
                    Text(reconnectTries > 0 ? "正在重连信号…" : "缓冲中，请稍等…")
                        .font(.footnote).foregroundStyle(.white)
                    Button {
                        exitAction()
                    } label: {
                        Text("返回").font(.footnote.bold()).foregroundStyle(.yellow)
                    }
                    if nextLineExists {
                        Button {
                            forceNextLine()
                        } label: {
                            Text("换信号源").font(.footnote.bold()).foregroundStyle(.yellow)
                        }
                    }
                    Button {
                        lastProgressAt = Date()
                        peekTask?.cancel()
                        controlsPeek = false
                        withAnimation(.easeInOut(duration: 0.2)) { showList = true }
                        prewarmVisible()
                    } label: {
                        Text("频道列表").font(.footnote.bold()).foregroundStyle(.yellow)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .shadow(color: .black.opacity(0.7), radius: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 96)
                .transition(.opacity)
            }

        }
        .onAppear {
            startPlay()
            startWatchdog()
            // 60包：进直播先闪现 3 秒控制层（返回键 + 台名），让用户一眼看到「返回在哪」；随后自动收起。
            controlsPeek = true
            schedulePeekHide()
            // 61包：窗口级返回键兜底（与 SwiftUI 那份同显隐、同动作）
            installWindowBack()
        }
        .onChange(of: showList) { v in
            winBack?.setVisible(v || controlsPeek)
        }
        .onChange(of: controlsPeek) { v in
            winBack?.setVisible(v || showList)
        }
        .onDisappear {
            stopPlay()
            watchdog?.cancel()
            winBack?.remove()
            winBack = nil
        }
        .onChange(of: scenePhase) { phase in
            // 后台/切走必须静音：进后台暂停，回前台自动续播（直播不留后台声音）
            guard let p = player else { return }
            if phase == .background || phase == .inactive {
                p.pause()
            } else if phase == .active {
                p.play()
            }
        }
        .onChange(of: switchBus.request) { req in
            guard let req else { return }
            if let idx = channels.firstIndex(where: { $0.id == req }) {
                switchTo(idx)
            }
            switchBus.request = nil
        }
    }

    // MARK: - 控制层

    /// 控制层闪现调度（60包）：进直播先亮 3 秒，让用户看到返回键位置，之后自动收起。
    private func schedulePeekHide() {
        peekTask?.cancel()
        peekTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { controlsPeek = false }
        }
    }

    /// 窗口级返回键兜底安装（61包 用户钦定「先把返回键还给我」）。
    /// 动作与 SwiftUI 那份完全一致（退出直播）；装完按当前显隐状态对齐。
    private func installWindowBack() {
        guard winBack == nil else { return }
        let b = WindowBackButton.install { exitAction() }
        b.setVisible(showList || controlsPeek, animated: false)
        winBack = b
    }

    /// 返回键统一语义（两份按钮共用）= 退出直播（收列表用「点一下画面」，或列表状态点左侧空白）。
    private func exitAction() {
        if let exit = onRequestExit { exit() }
        else if let c = onClose { c() }
        else { close() }
    }

    private var topBar: some View {
        VStack {
            HStack(spacing: 6) {
                // 58包：返回键并回控制层（SwiftUI 普通按钮）——窗口级 WindowBackButton 在 LC
                // 里「有时不在/点不动」是老大难（50 包已在播放页根治），直播页同理论。
                // 语义固定 = 退出直播（收列表交给「点一下画面」手势，不再一按就收列表）。
                Button {
                    exitAction()
                } label: {
                    Image(systemName: "chevron.left").font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)     // 61包：防父级手势吃掉 tap（列表开着时返回键必须点得动）
                .accessibilityLabel("返回")
                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.name ?? "直播").font(.subheadline.weight(.medium))
                        .foregroundStyle(.white).lineLimit(1)
                    if let g = current?.group, !g.isEmpty {
                        Text(g).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                Spacer()
                if onPickSource != nil {
                    // TVBox「直播源」菜单：播放中随时换源
                    Button {
                        onPickSource?()
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right").font(.body)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("选择直播源")
                }
                if channels.count > 1 {
                    Button {
                        showList = true
                    } label: {
                        Image(systemName: "list.bullet").font(.body)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("频道列表")
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            Spacer()
        }
        // 54包：顶渐变删除（与播放页同批，黑纱根因）。文字可读性由投影保证。
    }

    // bottomBar 已移除（用户钦定 2026-09-20）：上下滑手势=换台，左侧面板=选台，
    // 按钮条鸡肋。换台入口只剩手势与面板，与电视遥控逻辑一致（手=遥控器）。

    private var failureOverlay: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("信号不佳，自动换源中…").font(.footnote).foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.7), radius: 3)
        }
        .padding(18)
    }

    /// 起播/换台加载提示：转圈直到画面真正出来（周期观察器发现时间推进即收）。
    private var tuningOverlay: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white).controlSize(.large)
            Text("正在连接信号…").font(.footnote).foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.7), radius: 3)
        }
        .padding(18)
    }

    // MARK: - 行为

    private func stepChannel(_ delta: Int) {
        guard !channels.isEmpty else { return }
        let next = (index + delta + channels.count) % channels.count
        switchTo(next)
    }

    private func switchTo(_ idx: Int) {
        guard channels.indices.contains(idx) else {
            showList = false
            return
        }
        if idx == index, pinned != nil {   // 已是当前台（列表点自己）：只收面板
            showList = false
            return
        }
        index = idx
        pinned = channels[idx]   // 60包：换台同步更新 pinned（表刷新仍不改台）
        failed = false
        switchedAt = Date()      // v17：幻灯片检测豁免窗口从换线时刻起算
        slideTries = 0
        if let ch = current { LiveLastChannel.save(ch.name) }
        // 61包（用户：「换台也是卡住…卡一会才能正常播放」）——换台动作要立刻在 UI 上成立：
        // ① 先把旧的播放器**彻底停掉**（pause + replaceCurrentItem(nil)），
        //    否则旧流的分片下载与解码会和新的抢带宽，新台起播被拖慢；
        // ② 立刻开始拉新流（不等列表收起、不等动画）。
        stopPlay()
        startPlay()
        // ③ 列表在**新流开播的同时**收起：换台生效是毫秒级，用户不会再怀疑"点了没反应"。
        showList = false
    }

    // MARK: - 播放与自动换源

    private func startPlay() {
        guard let ch = current else { return }
        pinned = ch          // 60包：首播也固定住（表后台刷新不改台）
        everPlayed = false
        // 旧会话清理（换台/重试前先拆观察者）
        if let t = timeObs { player?.removeTimeObserver(t); timeObs = nil }
        player?.pause()
        // 61包（用户：「换台也是卡住…卡一会才能正常播放」）——**旧流必须立刻断开**：
        // 只 pause 的话旧 AVPlayerItem 仍在后台下分片、仍占着解码器与连接，
        // 新流起来时两者抢带宽/抢解码 → 用户看到的正是"看得见内容但卡一会才正常"。
        player?.replaceCurrentItem(with: nil)
        // 59包（用户：「很多台非常慢才能播 不是源的问题」）：免费 IPTV 源普遍校验
        // User-Agent —— AVPlayer 默认身份（AppleCoreMedia）常被服务端慢响应/限流。
        // 带上 TVBox 系通用 okhttp/3.12（与探活脚本一致），源端按正常客户端对待。
        let asset = AVURLAsset(url: ch.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": "okhttp/3.12"]
        ])
        let item = AVPlayerItem(asset: asset)
        // 61包：**低延迟起播三连**（免费 IPTV 源普遍是 6~20 秒的大分片，
        // 起播慢的直接原因是"等整片下完才出画"）：
        //   ① 优先低码率变体（免费源高码率变体带宽不够时长时间黑屏）；
        //   ② 起播不预设缓冲目标（0 = 拿到首个可播分片就出画）；
        //   ③ 关掉 HLS 起播门槛（把"必须攒够几片"降为"有片就播"）。
        // v16 根治黑白交替（机制层）：2Mbps 下载限速 ≈ 慢源码率（PC 实测 4.8s/片）→ 缓冲永远
        // 攒不起来 → 每十几秒必饿死一次 → 看门狗强杀重连 → 黑屏循环。0 = 不限速，缓冲才存得下。
        item.preferredPeakBitRate = 0
        // v13（2026-09-25 实测数据根治「播几秒就黑」）：PC 端 60 秒逐秒测量证实
        // 免费源分片平均 4.8s 一片（最大断供 6.1s），零前向缓冲下播放时钟频繁停摆，
        // 守护 6s 亮横幅 / 12s 强杀重连 = 黑白交替死循环。
        // 修法：前向缓冲 0→20s——起播速度不变（首片即出画），后台持续攒 20s 余量，
        // 5s 级断供不再触发停摆。守护链保留作保险（真死链照常跳台）。
        item.preferredForwardBufferDuration = 20
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        let p = AVPlayer()
        // 28号包（用户反馈直播加载太慢）：直播流跳过"最小卡顿等待"，拿到流立即播
        p.automaticallyWaitsToMinimizeStalling = false
        p.replaceCurrentItem(with: item)
        p.playImmediately(atRate: 1.0)
        player = p
        UIApplication.shared.isIdleTimerDisabled = true
        lastProgressAt = Date()
        reconnectTries = 0
        failFastTries = 0
        failed = false
        tuning = true   // 加载提示：转圈直到时间推进（出画）
        LiveSwitchBus.shared.nowPlaying = normalized(ch.name)   // 列表高亮当前台
        LiveSwitchBus.shared.nowPlayingID = ch.id               // 精确到线路（同台名多线路唯一高亮）
        // 61包：预热下一台（用户上下滑/列表点下一条时命中已缓存的表，换台更快）。
        // 只抓一次 playlist 进 URLSession 缓存，不建播放器、不占用户看到的东西。
        prewarmNeighbor()
        // 状态观察：条目级失败立即触发自动换源
        p.currentItem?.observe(\.status, options: [.new]) { item, _ in
            Task { @MainActor in
                guard item === self.player?.currentItem else { return }
                if item.status == .failed { self.autoHeal() }
            }
        }
        // 周期观察：有进展就刷新看门狗时间戳
        timeObs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { _ in
            Task { @MainActor in
                self.lastProgressAt = Date()
                self.everPlayed = true                   // 播起来过 = 不是坏链
                self.failFastTries = 0
                self.reconnectTries = 0                  // 出画 = 重连成功，计数归零
                if self.tuning { self.tuning = false }   // 时间在走 = 画面已出
                // v17 健康度：这条源真播起来了 → +1（每条线路只记一次）
                if let u = self.current?.url, self.recordedOK != u {
                    LiveSourceHealth.shared.record(u, ok: true)
                    self.recordedOK = u
                }
                // v17 幻灯片检测（用户实况「一帧一帧卡着放」）：时间在走但缓冲水位
                // <1.5s = 下载追不上播放。连续 3 秒贴地直接降级换备线，不再等 12s
                // 完全卡死才动。起播 8s 内豁免（水位本来就在爬坡）。
                if self.everPlayed, Date().timeIntervalSince(self.switchedAt) > 8,
                   let item = p.currentItem,
                   let r = item.loadedTimeRanges.last?.timeRangeValue {
                    let ahead = (r.start + r.duration) - p.currentTime().seconds
                    if p.rate > 0 && ahead < 1.5 { self.slideTries += 1 } else { self.slideTries = 0 }
                    if self.slideTries >= 3, let u = self.current?.url {
                        LiveSourceHealth.shared.record(u, ok: false)
                        self.slideTries = 0
                        self.lastProgressAt = Date()
                        self.autoHeal(sameChannelOnly: true)
                    }
                }
                // 61包：**出画后不再抬高缓冲门槛**（60包以前抬到 8s + 打开 automaticallyWaitsToMinimizeStalling）。
                // 免费源分片普遍 6~20s，抬高门槛 = 每次出画都要重攒一大段，
                // 用户感受到的就是「卡一会儿才正常播放」。低延迟优先：维持 0 + 不等待。
                // 抗卡顿改由看门狗兜底（20s 无进展 → 原地重连 → 换备线），体验更稳。
            }
        }
    }

    /// 换台升温（61包）：预抓"下一台/上一台"的 playlist 进 URLSession 缓存。
    /// 依据：HLS 起播耗时大头在 DNS/TLS/首个 playlist，预热后点选可省掉这一跳。
    private func prewarmNeighbor() {
        for delta in [1, -1] {
            let i = (index + delta + channels.count) % channels.count
            guard channels.indices.contains(i) else { continue }
            prewarmURL(channels[i].url)
        }
    }

    /// 列表呼出时的批量升温（61包）：优先当前台之前的若干台（用户多在附近台切换）。
    private func prewarmVisible() {
        guard !channels.isEmpty else { return }
        var picked: [URL] = []
        for d in 1...8 {
            for s in [1, -1] {
                let i = (index + s * d + channels.count * 10) % channels.count
                if channels.indices.contains(i) { picked.append(channels[i].url) }
            }
        }
        for u in picked.prefix(12) { prewarmURL(u) }
    }

    private func prewarmURL(_ u: URL) {
        var req = URLRequest(url: u)
        req.setValue("okhttp/3.12", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 4
        req.cachePolicy = .useProtocolCachePolicy
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    /// 原地重连：同一 URL 重新拉流（不换台、不换线路）。
    ///
    /// 为什么必须有它（2026-09-22 用户实测反馈）：绝大多数「一直缓冲中」并不是流坏了，
    /// 而是连接/切片会话僵死 —— 重新拉一次就好。此前只有「换同名备用线路」一条路，
    /// 而索倪/星秀这类**单线路频道**根本没有备线，`autoHeal` 直接 return → 永远卡住。
    private func reconnectSameURL() {
        guard let ch = current else { return }
        guard let p = player else { startPlay(); return }
        let item = AVPlayerItem(url: ch.url)
        item.preferredForwardBufferDuration = 20   // v13：0→20s（同 startPlay，慢源断供扛得住）
        p.replaceCurrentItem(with: item)
        p.playImmediately(atRate: 1.0)
        lastProgressAt = Date()
        switchedAt = Date()      // v17：重连也重给 8s 爬坡豁免
        slideTries = 0
        tuning = true
        item.observe(\.status, options: [.new]) { it, _ in
            Task { @MainActor in
                guard it === self.player?.currentItem else { return }
                if it.status == .failed { self.autoHeal() }
            }
        }
    }

    private func stopPlay() {
        UIApplication.shared.isIdleTimerDisabled = false
        if let t = timeObs { player?.removeTimeObserver(t) }
        timeObs = nil
        player?.pause()
        player = nil
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                // 27号包（用户钦定 2026-09-21）：源慢缓冲 ≠ 信号断，8s 就切台被真机实测证伪（恶性跳台）。
                // 新策略：8s 亮「缓冲中」横幅等恢复；20s 换同台备用信号源；40s 仍黑才跳下一台（最后手段）。
                // 28b（用户钦定 2026-09-21）：坏链从头就是死的，「缓冲请稍等」没有意义。
                // 分两类：①从没播起来（everPlayed=false）→ 5 秒快速换同台备线（最多3条），全死跳台；
                //         ②播起来后卡住 → 才值得等：8s 亮缓冲框，20s 换同台备线，40s 跳台。
                let gap = Date().timeIntervalSince(lastProgressAt)
                if !everPlayed {
                    // 61包（用户：「还是会卡很久才会播 换台也是卡住」）——起播/换台的容忍时间下调：
                    // 分片已重建为小片（≤6s 优先）+ 列表升温，正常台 2s 内出画；
                    // 3s 还没出画就是这条线路不行，没必要让用户干等 5s，直接换。
                    // 61包下调到 3s；v14（用户复测「直播不好用」）回调到 8s：
                    // PC 实测慢源 4.8s/片，首帧常要 5~8s，3s 判死会把慢而活的线路全部错杀。
                    if gap > 8 {
                        lastProgressAt = Date()
                        failFastTries += 1
                        if failFastTries <= 3 { autoHeal(sameChannelOnly: true) }
                        else {
                            failFastTries = 0
                            if let u = current?.url { LiveSourceHealth.shared.record(u, ok: false) }
                            stepChannel(1)
                        }
                    }
                } else {
                    // 播起来后卡住（2026-09-22 修正「一直卡着不动一直缓冲中」）：
                    // 恢复链改为 **原地重连 ×2 → 同名备线 ×2 → 跳台**，而不是一步跳备线。
                    // 原地重连是关键：单线路频道（索倪/星秀）根本没有备线，旧逻辑下
                    // autoHeal 直接 return（什么都不做）→ 永远停在「缓冲中」。
                    // reconnectTries 只在**真正出画**时归零，所以上限必定达成、不会无限重连。
                    if gap > 6 { stallBanner = true }
                    if gap > 12 {
                        lastProgressAt = Date()
                        reconnectTries += 1
                        if reconnectTries <= 1 {
                            reconnectSameURL()                 // ① 同 URL 重新拉流
                        } else if reconnectTries <= 3 {
                            autoHeal(sameChannelOnly: true)    // ② 换同名备用线路（记败+选优在 autoHeal 内）
                        } else {
                            reconnectTries = 0
                            if let u = current?.url { LiveSourceHealth.shared.record(u, ok: false) }
                            stepChannel(1)                     // ③ 最后手段：跳下一台
                        }
                    }
                }
            }
        }
    }

    /// 自动换源：同名备用线路（·备N 归一后台名）优先 → 否则下一台。
    /// 该台是否还有别的线路（决定「换信号源」按钮是否给）。
    private var nextLineExists: Bool {
        guard let ch = current else { return false }
        let k = normalized(ch.name)
        return channels.contains { $0.id != ch.id && normalized($0.name) == k }
    }

    /// 手动换信号源（61包 用户钦定）：**强制**换到同台的下一条线路（环形）。
    /// 与 autoHeal 的区别：不看 everPlayed、不做"单线路就放弃"，用户点了就必须有动作
    /// ——没有别的线路时（本台只有一条）不给按钮，避免点了没反应。
    private func forceNextLine() {
        guard let ch = current else { return }
        let k = normalized(ch.name)
        let lineIdx = channels.indices.filter { normalized(channels[$0].name) == k }
        guard lineIdx.count > 1,
              let pos = lineIdx.firstIndex(of: index) else { return }
        // 从**当前实际在播的线路**往后找同台的下一条（pinned 可能不是 index，用 lineIdx 定位）
        let curPos = channels.indices.contains(index) && normalized(channels[index].name) == k
            ? index : (channels.firstIndex(where: { $0.id == ch.id }) ?? pos)
        let at = lineIdx.firstIndex(of: curPos) ?? pos
        let next = lineIdx[(at + 1) % lineIdx.count]
        lastProgressAt = Date()
        reconnectTries = 0
        switchTo(next)
    }

    private func autoHeal(sameChannelOnly: Bool = false) {
        guard let ch = current else { return }
        let base = normalized(ch.name)
        // v17：这条线被判死/降级 → 健康度 -2，坏源快速沉底
        LiveSourceHealth.shared.record(ch.url, ok: false)
        // 1) 同名备用线路——按健康度降序挑**最好**的那条（用户钦点：好源在第一位）
        let candidates = channels.indices.filter {
            channels[$0].id != ch.id && normalized(channels[$0].name) == base
        }
        if !candidates.isEmpty {
            let ranked = LiveSourceHealth.ranked(candidates.map { channels[$0].url })
            switchTo(candidates[ranked[0]])
            return
        }
        // 2) 27号包：sameChannelOnly=true 时绝不跳台（等待缓冲/用户手动换源）
        if sameChannelOnly { return }
        stepChannel(1)
    }

    private func normalized(_ name: String) -> String {
        var n = name
        if let dot = n.firstIndex(of: "·") { n = String(n[..<dot]) }
        return n.replacingOccurrences(of: " ", with: "")
    }

    // MARK: - 五重关闭保险（对齐点播播放器；封面模式专用）

    private func close() {
        guard !closed else { return }
        filmLog.info("live close: entered (window back tapped)")   // syslog 埋点
        closed = true                    // 保险 1：本地状态立即让出画面
        stopPlay()                       // 保险 2：先停播放
        onClose?()                       // 保险 3：宿主 binding 关闭
        dismiss()                        // 保险 4：SwiftUI 环境 dismiss
        DispatchQueue.main.async {       // 保险 5：UIKit 根控制器兜底（LC 环境）
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            scene?.keyWindow?.rootViewController?.dismiss(animated: true)
        }
    }
}

/// 兼容旧调用点（仅测试路径）：按名字记忆上次频道。
enum LiveLastChannel {
    static func save(_ name: String) {
        UserDefaults.standard.set(name, forKey: "live.lastChannelName")
    }
}

/// 裸视频容器（直播用）：AVPlayerViewController 关掉自带控制条，控制层全部自绘。
struct BareVideoContainer: UIViewControllerRepresentable {
    let player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.showsPlaybackControls = false
        vc.videoGravity = .resizeAspect
        vc.player = player
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}
