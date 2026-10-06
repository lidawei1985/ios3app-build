import SwiftUI
import UIKit
import AVFoundation
import FilmCore

// MARK: - 直播页（v44 · 2026-10-03）
//
// 主人原话（逐条对齐，不许走回头路）：
//   ①「就是一个台放不出来」——起播必须真出画，且**长时间稳定出画**；
//   ②「有第一帧然后就一直切」——这就是 v43 起播链的**自杀式换线**：4 秒没前进就判死换线，
//      而本表主流是「6 秒一片、每片 2MB（≈2.7Mbps）」的 H.264 HLS：手机上首片下载动辄 3~6 秒，
//      4 秒宽限**必然**在首片还没落地时把它判死 → 换线重启 → 又只出一帧 → 无限循环。
//      → v44 换线判据重写（见 `check()`）：先给足 15 秒出画宽限；出过画再卡就「原地重连 ×2」，
//        两次不行才换本台下一条线；本台两轮都死就**停下明确告知**，绝不无限跳台刷屏。
//   ③「返回按钮也没了」「菜单跟以前不一样」——v42 的形态是用户钦定过的：
//      **左上常驻返回键 + 台名**，点屏一次同时给出「右侧频道列表」（左列分类 + 右列频道）。
//      v43 把返回键整个丢了（`onExit` 只声明没渲染），面板还从左滑出 → 全部还原。
//   ④「好源常在、坏了自换、缺了能知道」——端上黑匣子（LiveDiag）+ 本机自体检（LiveCollector）。
//
// 起播链（唯一数据源 = 包内已体检快表，进页零网络）：
//   tune → 彻底断旧流 → 按「本机实测耗时 → 端上健康分 → 表内原序」选线 → 起播 → 看门狗兜底。

public struct LiveView: View {
    let livePath: String
    private let profileMode: String
    private let feedBases: FeedBases
    /// 退出直播（回首页）。本页 statusBarHidden + 隐藏导航栏与 tab 栏，
    /// 不给返回入口就是「进去出不来」——v22 用户报过的原病，不许复发。
    private let onExit: () -> Void

    @State private var stations: [LiveStation] = []
    @State private var index = 0
    /// 当前线路在 `station.lines` 里的**原始下标**（不是排序位次，排位次随时会被实测结果改）。
    @State private var rawIndex = 0
    @State private var linePos = 0
    @State private var statusText: String? = "加载中…"
    @State private var buffering = false
    @State private var showList = false
    @State private var pickGroup: String? = nil
    /// 横屏顶栏显隐（原型 v3 钦定）：点屏呼出、3s 不动自动隐藏；列表开着不藏。竖屏保持常驻（零改动）。
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var isLandscape: Bool { vSizeClass == .compact }
    @State private var showControls = false
    @State private var controlsHideTask: Task<Void, Never>? = nil
    /// 自动隐藏时长（原型 v3 定 3s；主人未提异议按此出包）。
    private let controlsHideDelay: TimeInterval = 3
    @State private var player = AVPlayer()

    @State private var watchdog: Task<Void, Never>?
    @State private var probeTask: Task<Void, Never>?
    @State private var everPlayed = false       // 本页是否出过画（控制「加载中…」提示）
    @State private var linePlayed = false       // **当前这条线**是否真出过画
    /// 上一次读到的播放位置；**-1 = 还没建立基准**。
    /// 为什么必须是 -1 而不是 0：AVPlayer 起播时会先把 `currentTime` 置到**直播边缘**
    /// （实测 CCTV 系分片序列号能到 43188s），若基准是 0，看门狗第一次扫描就把这个
    /// 「初始跳变」误判成出画 —— 于是「出一帧就卡死」的线也被当成好线，白白反复重连。
    @State private var lastTime: Double = -1
    @State private var progressTicks = 0        // 连续「小步前进」次数（≥2 才算真出画）
    @State private var bigJumps = 0             // 「大跳」次数（DVR 录播窗口的签名）
    @State private var lastProgressAt = Date()
    @State private var tuneAt = Date()
    @State private var currentURL: URL?
    @State private var reconnectTries = 0       // 原地重连次数（同 URL 重拉）
    @State private var lineTries = 0            // 本台累计试线次数（日志用；判据见 triedURLs）
    /// **本台本轮已试过的线路 URL**（2026-10-03 换线机制重做）。
    ///
    /// 为什么不再用「位次 (linePos)」换线：`rankedLines` 每次都按最新实测/健康分**重排**，
    /// 用「当前位置 +1」取下一条，重排后会**指回刚失败的那条**——真机实测就是这么循环的：
    /// 黑匣子里连着三条 `换线(无数据) 第 1 次 → 3/5`，而每次起播的 URL 一模一样。
    /// 另外 `tuneRaw` 里原有的 `lineTries = 0` 让「本台试线上限」**完全失效**（每次都算第 1 次）。
    /// 现在改用 URL 集合：试过就进集合，选下一条时**直接排除** —— 与排序无关，结构上不可能回头。
    @State private var triedURLs: Set<String> = []
    @State private var hopTries = 0             // 跨台兜底次数（仅「从未出画」时用，上限 3）
    /// 单台最多试几条线（2026-10-03「秒播」）：超过就转补源 / 跨台兜底。
    private let maxLineTries = 6
    /// 本机自体检实测耗时（url → 列表+首片 ms，越小越快）。空 = 还没测出来。
    @State private var probeMs: [String: Int] = [:]
    /// 自体检的「世代号」：每次切台/换线 +1。体检是异步的，回来时**必须**核对世代号，
    /// 否则它拿着旧 index 反过来把画面抢回上一台（v44.1 实测：一秒内连起 6 次台）。
    @State private var probeGen = 0
    /// 本页已经「补过源」的台名（归一）：同一台在一页里只补一轮，防抖。
    @State private var refilledStations: Set<String> = []
    /// 正在补源的台名（UI 提示用，避免重复发起）。
    @State private var refillingStation: String?
    /// 面板巡检结果：**台名归一 key** → 本机实测活的线数（nil = 还没检）。
    /// 用台名而不是下标做 key：远端保鲜会整体换表，下标会指向**另一个台**（v44.2 踩过）。
    /// 主人要的「坏了缺了得能知道哪个不出图了」就落在这里 —— 打开面板就能看见，不用一个个点进去试。
    @State private var health: [String: Int] = [:]
    // 队列与在测标记同样按**台名归一 key**（v46 补齐）：换表后下标会指向别的台，
    // 而这三者必须同口径 —— 上一轮只改了 `health` 的 key 类型，漏了这两个，
    // 于是 `healthPending.contains(key)`（[Int].contains(String)）编译不过、白等一轮 CI。
    @State private var healthPending: [String] = []
    @State private var healthTesting: String?
    /// 表代号：远端保鲜**整体换表**时 +1。
    /// 为什么需要它：`index` 只是数组下标，换表后同一个 int 指向**另一个台**
    /// （v44.2 实测：自体检回来时读 `stations[myIndex].name`，打到日志里成了「黄花城水长城03」，
    /// 因为那时 stations 已被远端表替换）。异步任务回来必须同时核对「世代 + 表代号 + 下标」。
    @State private var tableGen = 0
    /// 画面比例（2026-10-03 主人「直播里没有屏幕比例和锁屏等按钮」）。
    /// 与点播播放器同一个 `AspectMode`（自适应 / 铺满 / 拉伸），点一下换一个、不弹面板。
    @State private var aspect: AspectMode = .fit
    /// 锁屏 = 钉住屏幕方向 + 屏蔽「上滑换台 / 点屏换面板」手势（与点播播放器的锁屏键同口径）。
    /// 顶栏按钮**不锁**（否则锁了没法解锁，就是「进去出不来」）。
    @State private var locked = false

    @AppStorage("settings.startupMode") private var startupMode = "low"
    @AppStorage("live.lastChannelName") private var lastChannelName = ""

    /// 起播缓冲（设置页可改）。**不抬到 1 秒那种极端值**：对 2MB/6s 的片子，
    /// 零缓冲 = 刚开始就卡死的直接原因（见 WindowBackButton 文档里 44/61 两轮的教训）。
    private var bufferSeconds: Double {
        switch startupMode {
        case "stable": return 8
        case "standard": return 4
        default: return 2
        }
    }
    /// 从未出画时给足的宽限（要能容下「建连 + 首片 2MB」）。
    ///
    /// 2026-10-03 主人「直播必须是秒播不能一直在这加载」→ 从 15s 收到 7s。
    /// 依据：本表主流是「6 秒一片 / 首片 2MB」的 H.264 HLS，手机上一片 3~6 秒；
    /// 一条线 7 秒还出不了画基本就是死线，再等只是让用户体验更糟。
    private let firstFrameGrace: TimeInterval = 7
    /// **零进展**提前判死：这么多秒内连一个字节都没缓冲到（`loadedTimeRanges` 仍为空）
    /// = 这条线根本没在回数据（死链 / 被墙 / 重定向失效），不必等满宽限。
    private let noDataGrace: TimeInterval = 3.5
    /// 出过画之后再卡的容忍时间（AVPlayer 自己会续拉，过早动手只会越弄越糟）。
    private let stallGrace: TimeInterval = 12

    public init(profile: ProductProfile, livePath: String, onExit: @escaping () -> Void = {}) {
        self.livePath = livePath
        profileMode = profile.mode
        feedBases = FeedBases(profile: profile)
        self.onExit = onExit
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LiveVideoLayer(player: player, gravity: aspect.gravity)
                .ignoresSafeArea()
                // 锁屏后屏蔽「点屏换面板 / 上滑换台」（锁屏的意义就是防误触）；
                // 顶栏**不锁** —— 否则锁了没入口解锁，又成「进去出不来」。
                // ★ v60 横竖屏统一（主人 2026-10-04「横竖屏一个面孔」）：
                //   点屏 = 呼出/收起控制栏（3s 自动隐藏），竖屏不再走「点屏开频道列表」的老分支
                //   （频道列表入口与横屏一样收在顶栏三钮里）。
                .onTapGesture {
                    if locked {
                        // 锁屏时点屏仍可**呼出**控制栏（否则「锁了+藏了」就没有解锁入口，
                        // 又成「进去出不来」）；列表/换台手势依旧屏蔽（锁屏的本意）。
                        pokeControls()
                        return
                    }
                    if showList {
                        closeList()
                    } else if showControls {
                        controlsHideTask?.cancel()
                        withAnimation(.easeOut(duration: 0.2)) { showControls = false }
                    } else {
                        pokeControls()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { v in
                            guard !locked else { return }
                            let dx = v.translation.width, dy = v.translation.height
                            if abs(dy) > abs(dx) {
                                step(dy < 0 ? 1 : -1)                 // 上滑=下一台，下滑=上一台
                            } else if dx > 80, v.startLocation.x < 80 {
                                exitLive()                            // 左边缘右滑 = 退出（iOS 习惯）
                            }
                        }
                )

            // 提示的显隐只看**当前这条线**有没有出过画（v44.2 修）：
            // 旧写法用「本页是否出过画」，于是一旦任何一台出过画，换台后即便黑屏也**没有任何提示**，
            // 用户看到的就是「点开是个黑洞，也不知道在加载还是死了」。
            // ★ v77（2026-10-05）主人第二轮点名「直播加载的黑框」——**彻底去底去框**。
            //   v60 曾把「黑实底 0.55 直角方框」换成 filmGlass(weight:.dark, tint 0.40)，
            //   但在纯黑视频层上深色玻璃读出来仍是一个方框（主人原话：
            //   「特意找过一次黑框 还在往里加」）。现在只留「加载圈 + 加载中… + 台名」，
            //   文字挂投影 —— 亮画面上也读得清，且**没有任何底色/边框**。
            if let statusText, !linePlayed || buffering {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(statusText).font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.85), radius: 6, y: 1)
                }
                .allowsHitTesting(false)
            }

            // ★ v60 横竖屏统一：顶栏只在 showControls 时出现（点屏呼出 / 3s 自动隐藏）。
            //   旧版竖屏常驻（原型 v3.2 遗留的「竖屏零改动」），与横屏两副面孔。
            if showControls {
                VStack(spacing: 0) { topBar; Spacer() }
                    .transition(.opacity)
            }

            if showList { channelPanel }
        }
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { boot() }
        .onDisappear {
            shutdown()
            controlsHideTask?.cancel()
        }
    }

    // MARK: - 顶栏（左上返回键 —— v42 钦定常驻，v60 横竖屏统一）

    private var topBar: some View {
        HStack(spacing: 8) {
            // ★ v60：返回键横竖屏统一 = 纯图标＋深投影（无边无底）。
            //   旧版竖屏是「‹ 返回」带字＋黑胶囊底，横屏才是纯箭头 —— 主人 2026-10-04
            //   钦定「横竖屏一个面孔 / 能不要框的不要框」，竖屏带字带底这一支整条删除。
            Button { exitLive() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 4, y: 1)
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回首页")

            // 列表打开时台名让位（信息收进面板头部），横竖屏同一口径。
            if stations.indices.contains(index), !showList {
                let st = stations[index]
                HStack(spacing: 6) {
                    LiveLogoBadge(url: st.logo, name: st.name, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(st.name).font(.subheadline.weight(.medium))
                            .foregroundStyle(.white).lineLimit(1)
                        // 固定频道号跟台名一起露出来（「#6 CCTV-5+」这种），用户一眼知道自己在哪一号。
                        Text("\(st.chno.map { "#\($0) " } ?? "")\(st.group) · 线路 \(linePos + 1)/\(st.lines.count)")
                            .font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                // v60：台名信息条 = 视频上浮层 → 玻璃档（虚化＋中性压暗），
                // 不再是黑实底胶囊 0.36（主人点名的「不透明 / 深灰信息条」）。
                .filmGlass(cornerRadius: 999, tint: 0.30, strokeOpacity: 0.12, weight: .dark)
                .allowsHitTesting(false)
            }
            Spacer(minLength: 4)
            // 2026-10-03 主人「直播里没有屏幕比例和锁屏等按钮」→ 与点播播放器同口径补齐：
            // 画面比例（点一下循环 自适应→铺满→拉伸）+ 锁屏（钉方向 + 防误触）。
            // v60：列表打开时三钮让位（收进面板自己的 ✕）；**横竖屏统一纯图标＋投影**。
            if !showList {
                circleButton("aspectratio", label: "画面比例：\(aspect.shortTitle)") { cycleAspect() }
                circleButton(locked ? "lock.fill" : "lock.open.fill",
                             label: locked ? "解锁屏幕" : "锁定屏幕") { toggleLock() }
                circleButton("list.bullet", label: "频道列表") { toggleList() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    /// 顶栏圆形按钮（统一 40×40；**横竖屏一律纯图标＋深投影**，无黑圆底）——顶栏三钮共用一套，避免三处手抄走形。
    private func circleButton(_ symbol: String, label: String,
                              action: @escaping () -> Void) -> some View {
        liveCircleButton(symbol, label: label, action: action)
    }

    /// 画面比例循环：自适应 → 铺满 → 拉伸 → 自适应（与点播播放器 `cycleAspect` 同口径：
    /// 点一下换一个模式，不弹面板 —— 用户钦定「正常不就是点一下换一个模式吗」）。
    private func cycleAspect() {
        let all = AspectMode.allCases
        let next = all[(all.firstIndex(of: aspect).map { $0 + 1 } ?? 0) % all.count]
        aspect = next
        LiveDiag.write("直播画面比例 → \(next.rawValue)/\(next.shortTitle)")
    }

    /// 锁屏：钉住屏幕方向（直播以横屏全屏观看为主 → 锁横屏）+ 屏蔽换台手势；解锁交还系统。
    /// 用的是与点播播放器锁屏键**同一个** `OrientationLock`（AppDelegate 读它，是唯一被保证生效的口子）。
    private func toggleLock() {
        locked.toggle()
        if locked {
            OrientationLock.shared.set(.landscape)
            withAnimation(.easeOut(duration: 0.18)) { showList = false }
        } else {
            OrientationLock.shared.set(nil)
        }
        LiveDiag.write("直播锁屏 \(locked ? "开(锁横屏)" : "关(交还系统)")")
    }

    // MARK: - 启动 / 收尾

    private func boot() {
        guard stations.isEmpty else { return }
        // v76.1 取证：建表 + 并回补源都在**主线程**（onAppear 里同步跑）→ 进直播第一下的手感全在这里
        let tb = Date()
        MainThreadMark.set("直播·建表（主线程）")
        stations = withRefilled(LiveStation.build(from: LiveDefaults.embeddedChannels(forMode: profileMode)))
        LiveDiag.write("直播·建表 用时=\(Int(-tb.timeIntervalSinceNow * 1000))ms 台=\(stations.count) " +
                       "线=\(stations.reduce(0) { $0 + $1.lines.count })")
        guard !stations.isEmpty else { statusText = "包内没有直播表"; return }
        LiveDiag.write("进入直播 v44 线路表=\(stations.reduce(0) { $0 + $1.lines.count }) 条 " +
                       "台=\(stations.count) 起播模式=\(startupMode)/\(Int(bufferSeconds))s")
        let start = startIndex()
        tune(to: start)
        startWatchdog()
        startSelfProbe()
        // v60 横竖屏统一后顶栏改为自动隐藏：进页先亮一次（3s 后自动收起），
        // 否则「顶栏藏在哪」就成了新的「进去找不到返回键」。
        pokeControls()
        Task { await refreshFromRemote() }
    }

    /// 把历次「端上自愈补源」补进来的线并回对应台（v45）。
    /// 为什么必须落盘再并回：补进来的线是**本机实测过能播的**，可信度高于表里没测过的线；
    /// 每次进页都丢掉它们 = 白补，用户看到的就是「昨天还能看的台今天又找不到源了」。
    private func withRefilled(_ list: [LiveStation]) -> [LiveStation] {
        var out = list
        var merged = 0
        for i in out.indices {
            let extra = LiveRefill.urls(for: out[i].name)
                .filter { LivePool.playableOnDevice($0) && !out[i].lines.contains($0) }
            if !extra.isEmpty {
                out[i].lines.append(contentsOf: extra)
                merged += extra.count
            }
        }
        if merged > 0 {
            LiveDiag.write("并回自愈补源 \(merged) 条（候选池 \(LivePool.stationCount) 台 / \(LivePool.lineCount) 条可用）")
        } else {
            LiveDiag.write("候选池 \(LivePool.stationCount) 台 / \(LivePool.lineCount) 条可用")
        }
        return out
    }

    /// 起播台怎么选（v44.1）：**不许默认第 0 台**。
    /// 表是按体检分重排过的，第 0 台可能是冷门国际台（实测撞上过 DVR 录播窗口，进页就是死画面）。
    ///   ① 上次看的台（名字模糊匹配，兼容旧表「CCTV-1 综合」这种带后缀的写法）；
    ///   ② 一批确定性高的热门台（CCTV-1 → CCTV-3 → CCTV-5 → 四大卫视）；
    ///   ③ 兜底第 0 台。
    private func startIndex() -> Int {
        func norm(_ s: String) -> String {
            var x = s.trimmingCharacters(in: .whitespaces)
            for suf in [" 综合", " 财经", " 综艺", " 体育", " 电影", " 新闻", "高清", "综合"] {
                if x.hasSuffix(suf) { x = String(x.dropLast(suf.count)) }
            }
            return x.trimmingCharacters(in: .whitespaces)
        }
        if !lastChannelName.isEmpty,
           let i = stations.firstIndex(where: { norm($0.name) == norm(lastChannelName) }) {
            return i
        }
        for want in ["CCTV-1", "CCTV-3", "CCTV-5", "湖南卫视", "东方卫视", "浙江卫视", "江苏卫视"] {
            if let i = stations.firstIndex(where: { norm($0.name) == want }) { return i }
        }
        return 0
    }

    private func shutdown() {
        watchdog?.cancel(); watchdog = nil
        probeTask?.cancel(); probeTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        // 清空台表：离开再回来要重新 boot（否则回来是一片死屏——播放器已断、看门狗已停）。
        stations = []
        everPlayed = false
        linePlayed = false
        statusText = "加载中…"
        buffering = false
        showList = false
        // 方向锁必须归位：锁屏键钉了横屏，离开直播页若不还，首页也会被钉在横屏（老病，不许复发）。
        locked = false
        OrientationLock.shared.set(nil)
    }

    private func exitLive() {
        LiveDiag.write("退出直播")
        shutdown()
        NotificationCenter.default.post(name: .liveExitToHome, object: nil)
        onExit()
    }

    // MARK: - 选线（本机实测优先）

    /// 本台线路排序：**本机实测耗时**优先（越小越快）→ 端上健康分 → 表内原序。
    /// 这是「谁播谁知道」的落地：PC 上体检通过 ≠ 手机上带得动。
    private func rankedLines(_ st: LiveStation) -> [Int] {
        let h = LiveSourceHealth.shared
        // 「秒播」的第一性原理：**第一条线就该是活线**。
        // ① 本次会话实测耗时（最新最准）→ ② **跨会话**体检镜像（上次真探到能出流，
        // 6 小时内有效）→ ③ 端上健康分（播得顺的 +1、判死的 -2）→ ④ 表内原序。
        // 少了 ②，第一次进某台时排序看不到任何体检成绩，只能按表内原序 → 第一条常是死线
        // → 用户看到的就是「一直在起播」（2026-10-03 主人反馈的正是这个）。
        func ms(_ u: URL) -> Int? {
            if let v = probeMs[u.absoluteString] { return v }
            if let r = LiveCollector.cached(u), r.ok,
               Date().timeIntervalSince(r.at) <= 6 * 3600 { return r.totalMs }
            return nil
        }
        return Array(st.lines.indices).sorted { a, b in
            let ua = st.lines[a], ub = st.lines[b]
            let ma = ms(ua), mb = ms(ub)
            switch (ma, mb) {
            case let (x?, y?):
                if x != y { return x < y }
            case (nil, .some): return false        // 已实测过的线优先于没测过的
            case (.some, nil): return true
            default: break
            }
            let ha = h.score(ua), hb = h.score(ub)
            return ha != hb ? ha > hb : a < b
        }
    }

    private func tune(to i: Int, pos: Int = 0) {
        guard stations.indices.contains(i) else { return }
        // 换台（不是同台换线）→ 试线记录重来。
        // ★★ 2026-10-03 真机 bug 收口：**这里绝对不许清 hopTries**。
        //   旧写法 `if i != index { triedURLs.removeAll(); hopTries = 0 }` 是「跨台兜底
        //   无限循环」的根源：finishAbandoned 靠 `hopTries < 6` 封顶，而它每次兜底都调
        //   `tune(to: nxt)`，一跳进新台 hopTries 就被清零 → 上限判据永远为假 → 台台跳过去、
        //   台台都「正在起播」，主人看到的就是「一直加载十几分钟不播」。
        //   （与 tuneRaw 里 `lineTries = 0` 是同一类「计数器被清零导致上限失效」的坑。）
        //   hopTries 只在**确实是用户主动换台**时归零：step() / 频道列表点击 / 换成出画。
        if i != index { triedURLs.removeAll() }
        let st = stations[i]
        let order = rankedLines(st).filter { !triedURLs.contains(st.lines[$0].absoluteString) }
        guard !order.isEmpty else { statusText = "本台没有可用线路"; return }
        tuneRaw(i, order[max(0, min(pos, order.count - 1))])
    }

    private func tuneRaw(_ i: Int, _ raw: Int, pos: Int? = nil) {
        guard stations.indices.contains(i), stations[i].lines.indices.contains(raw) else { return }
        let st = stations[i]
        index = i
        rawIndex = raw
        lastChannelName = st.name
        linePos = pos ?? (rankedLines(st).firstIndex(of: raw) ?? 0)
        reconnectTries = 0
        // ⚠️ 这里**不再**清 `lineTries` —— 换线不该重置「本台累计试线」，
        //    旧写法正是它让上限判据永远为假（真机日志每次都是「第 1 次」）。
        probeGen &+= 1
        startPlayback(url: st.lines[raw], name: st.name)
    }

    private func startPlayback(url: URL, name: String) {
        LiveDiag.write("起播 \(name) 线#\(rawIndex + 1)/\(stations.indices.contains(index) ? stations[index].lines.count : 0) url=\(url.absoluteString)")
        // 换台先彻底断旧流：旧流会抢带宽/抢解码器（v61 记录过的老毛病）。
        player.pause()
        player.replaceCurrentItem(with: nil)

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = bufferSeconds
        player.replaceCurrentItem(with: item)
        // ★ v70 秒播回滚（2026-10-05 00:4x 真机黑匣子铁证，主人原话「原来还能看就是慢 现在看不了了」）。
        //
        // v65 把 automaticallyWaitsToMinimizeStalling 改成 false 后，直播全线崩坏：
        //   livediag.txt 实录（281 条错误全是同一种）——
        //     「未出画 itemStatus=1 buffered=5.9s → 换线」「CCTV-4 -11833 Cannot Decode」
        //   数据明明在到（缓冲 5.9s、item readyToPlay），但 playImmediately+不等缓冲
        //   让 AVPlayer 顶在直播边缘出不了首帧，看门狗 7s/3.5s 就判死换线 → 无限跳台。
        //
        // 回滚到 v64 口径 = true（系统攒够 2~3 个分片再吐首帧，慢 3~8 秒但**能看**）。
        // 秒播诉求以后另想办法（比如只对已体检最快的线放宽），不再动这个总开关。
        player.automaticallyWaitsToMinimizeStalling = true
        player.playImmediately(atRate: 1.0)
        player.isMuted = false

        currentURL = url
        lastTime = -1
        progressTicks = 0
        bigJumps = 0
        lastProgressAt = Date()
        tuneAt = Date()
        linePlayed = false
        buffering = false
        // 新线必提示（换台黑屏时用户要知道在加载）。
        // ★ 2026-10-03：跨台兜底链上的换台要显示「自动换台 N/6」——否则用户只看到一个
        //   一直不动的「正在起播」，分不清是卡死还是在自动找台（主人反馈的原话就是
        //   「一直在这加载」）。hopTries 只在用户主动换台/出画时才归零（见 tune 注释）。
        statusText = hopTries > 0
            ? "加载中…  自动换台 \(hopTries)/6（\(name)）"
            : "加载中…  \(name)"
        tryAudioSession()
    }

    private func advanceLine(reason: String, hopChannel: Bool) {
        guard stations.indices.contains(index) else { return }
        let st = stations[index]
        if let u = currentURL {
            LiveSourceHealth.shared.record(u, ok: false)
            triedURLs.insert(u.absoluteString)      // 这条试过且失败 → 本轮不再回头
        }
        lineTries = triedURLs.count
        // 候选 = 本台**还没试过**的线（已按实测耗时/健康分排好）。
        // 用 URL 集合筛，天然免疫「重排后位次指回同一条」的老问题（真机实测过的循环换线）。
        let order = rankedLines(st).filter { !triedURLs.contains(st.lines[$0].absoluteString) }
        // 「秒播」上限（2026-10-03 主人「不能一直在这加载」）：最多试 6 条就转补源/兜底。
        // 旧写法 `cap = max(lines.count * 2, 2)` 对线多的台（20 条 → cap 40、每条等 15s）
        // 就是十几分钟停在「正在起播」。
        if let next = order.first, triedURLs.count < maxLineTries {
            LiveDiag.write("换线(\(reason)) \(st.name) 第 \(triedURLs.count) 条 → 线#\(next + 1)/\(st.lines.count)")
            tuneRaw(index, next)
            return
        }
        // ★ 端上自愈补源（v45）：本台表内线路都试完了 → **当场**从候选池给这台找一条能播的补进来。
        //   主人的要求是「不是整体替换，是这台坏了就给它补上，始终保持能用」——就是这里。
        if refillIfPossible(reason: reason) { return }
        finishAbandoned(st.name, reason: reason, hopChannel: hopChannel)
    }

    /// 本台表内线路穷尽后的收尾：能兜底就跨台兜底，否则**停下说清楚**（绝不无限跳台刷屏）。
    private func finishAbandoned(_ name: String, reason: String, hopChannel: Bool) {
        // 只在本台从未出过画时才跨台兜底，且上限 6 台。
        if hopChannel, !linePlayed, hopTries < 6, stations.count > 1 {
            hopTries += 1
            // ★ 2026-10-03 真机实测改：**别跳到另一个全死的台**。
            //   旧写法固定跳 index+1，实测在手机上会连着跳进一串「本机压根没活线」的台
            //   （CCTV-6→7→8→9→10→11 每台只撑 2~8 秒）→ 用户看到的就是「一直在起播」。
            //   现在：优先跳到**本机已知有活线**的台（本会话实测耗时 / 跨会话体检镜像都算）；
            //   一个都没有时才退回 index+1（表内顺序仍有意义）。
            var nxt = (index + 1) % stations.count
            for k in 1..<stations.count {
                let cand = (index + k) % stations.count
                let st2 = stations[cand]
                let good = st2.lines.contains { u in
                    if probeMs[u.absoluteString] != nil { return true }
                    if let r = LiveCollector.cached(u), r.ok,
                       Date().timeIntervalSince(r.at) <= 6 * 3600 { return true }
                    return LiveSourceHealth.shared.score(u) > 0
                }
                if good { nxt = cand; break }
            }
            LiveDiag.write("本台全死(\(reason)) \(name) → 跨台兜底 #\(hopTries)/6 → \(stations[nxt].name)")
            // 让用户看见「在自动找台」，而不是盯着一个像是卡死的「正在起播」。
            statusText = "加载中…  正在试第 \(hopTries)/6 个台（\(stations[nxt].name)）"
            tune(to: nxt)
            return
        }
        LiveDiag.write("本台放弃 \(name) 原因=\(reason) 已试 \(lineTries) 条")
        buffering = false
        statusText = "本台线路暂时都不可用 · 点屏幕换台"
    }

    // MARK: - 端上自愈补源（v45 · 主人钦定：「坏一条就换掉补齐」）

    /// 表内线路全坏 → 从候选池取该台候选 → **本机真测** → 最快的一条补进这台并立刻起播。
    /// 返回 true 表示「已经在补（本次不再走别的分支）」。
    ///
    /// 设计口径：
    ///   · 只补**当前这一台**，不动别的台、不整表替换；
    ///   · 候选必过 `LiveCollector` 三级判活（列表 200 + 无 ENDLIST + 首片真有字节）；
    ///   · 补进来的线落盘（`LiveRefill`），下次进页直接并回 —— 这就是「天天都能看」；
    ///   · 同一台一页只补一轮；补不到就老实说「本台线路暂时都不可用」。
    @discardableResult
    private func refillIfPossible(reason: String) -> Bool {
        guard stations.indices.contains(index) else { return false }
        return refillStation(index, name: stations[index].name, reason: reason, quiet: false)
    }

    /// 补源的实际执行体（**当前台播不出** 与 **面板巡检发现无信号** 共用这一套）。
    /// `quiet = true`（巡检触发）时不改任何界面/画面 —— 用户可能正在看别的台，
    /// 补源是后台维护动作，不能把画面抢走。
    @discardableResult
    private func refillStation(_ i: Int, name: String, reason: String, quiet: Bool) -> Bool {
        guard stations.indices.contains(i), stations[i].name == name else { return false }
        let key = LivePool.normalize(name)
        guard !refilledStations.contains(key), refillingStation == nil else { return false }
        let excluding = Set(stations[i].lines.map(\.absoluteString))
        let cands = LivePool.candidates(for: name, excluding: excluding, limit: 6)
        guard !cands.isEmpty else {
            LiveDiag.write("补源无候选 \(name)（池里没有这台 / 候选都已在表内）")
            return false
        }
        refilledStations.insert(key)
        refillingStation = key
        if !quiet {
            buffering = false
            statusText = "加载中…  正在自找备用源（\(name)）"
        }
        LiveDiag.write("补源开始 \(name) 候选 \(cands.count) 条（表内 \(stations[i].lines.count) 条已试完，原因=\(reason)）")
        Task { @MainActor in
            let res = await LiveCollector.shared.probe(cands)
            let aliveList = cands.compactMap { u -> (URL, Int)? in
                guard let r = res[u.absoluteString], r.ok else { return nil }
                return (u, r.listMs + r.segMs)
            }.sorted { $0.1 < $1.1 }
            if refillingStation == key { refillingStation = nil }
            // 体检期间用户可能已经换台/换线、或换了表 —— 不是同一台就别乱动。
            guard stations.indices.contains(i), stations[i].name == name else { return }
            guard let best = aliveList.first else {
                LiveDiag.write("补源失败 \(name) 候选 \(cands.count) 条全坏")
                refilledStations.remove(key)          // 放行：池子/网络变了还能再试
                if !quiet { finishAbandoned(name, reason: "补源失败", hopChannel: true) }
                return
            }
            stations[i].lines.append(best.0)
            LiveRefill.add(station: name, url: best.0)
            health[LivePool.normalize(name)] = aliveList.count   // 面板立刻反映「这台已被救活」
            LiveDiag.write("补源成功\(quiet ? "(巡检)" : "") \(name) 补入第 \(stations[i].lines.count) 条 " +
                           "候选 \(cands.count) 条中活 \(aliveList.count) 条 实测\(best.1)ms url=\(best.0.absoluteString)")
            if !quiet {
                // 补进来的线是**新的**（刚实测过能播）→ 试线记录重来，直接起播它。
                triedURLs.removeAll()
                lineTries = 0
                hopTries = 0
                tuneRaw(i, stations[i].lines.count - 1)
            }
        }
        return true
    }

    // MARK: - 面板巡检（「哪个台不出图了得能知道」——不用用户一个个点进去试）

    /// 打开频道面板时，对**看到的那台**做一次本机真测（最多 3 条线），把结果标在列表上。
    /// **串行**执行：一次只测一台，免得把正在播的流的带宽抢光。
    /// 实测全坏的台 → 当场触发一次补源（quiet 模式，不打断正在看的画面）。
    private func checkStation(_ st: LiveStation) {
        let key = LivePool.normalize(st.name)
        guard !key.isEmpty, health[key] == nil else { return }
        guard !healthPending.contains(key), healthTesting != key else { return }
        healthPending.append(key)
        pumpHealth()
    }

    private func pumpHealth() {
        guard healthTesting == nil, !healthPending.isEmpty else { return }
        let key = healthPending.removeFirst()
        guard let i = stations.firstIndex(where: { LivePool.normalize($0.name) == key }) else {
            pumpHealth(); return
        }
        let st = stations[i]
        let mine = Array(st.lines.prefix(3))
        healthTesting = key
        Task { @MainActor in
            let res = await LiveCollector.shared.probe(mine)
            let alive = mine.filter { res[$0.absoluteString]?.ok == true }.count
            health[key] = alive
            healthTesting = nil
            LiveDiag.write("面板巡检 \(st.name) 活线 \(alive)/\(mine.count)")
            if alive == 0 { refillStation(i, name: st.name, reason: "面板巡检无信号", quiet: true) }
            pumpHealth()
        }
    }

    private func step(_ delta: Int) {
        guard !stations.isEmpty else { return }
        let n = stations.count
        hopTries = 0
        tune(to: ((index + delta) % n + n) % n)
    }

    private func toggleList() {
        withAnimation(.easeInOut(duration: 0.22)) { showList.toggle() }
        // 打开列表时：顶栏保持可见（返回键留用），并停掉自动隐藏（列表开着不藏）——横竖屏同一口径。
        if showList { pokeControls() }
    }

    /// 收起频道列表并重启顶栏自动隐藏计时（横竖屏同一口径）。
    private func closeList() {
        withAnimation(.easeInOut(duration: 0.22)) { showList = false }
        pokeControls()
    }

    /// 呼出顶栏并安排 3s 自动隐藏（列表开着则不藏，等列表收起时再计时）——横竖屏同一口径。
    private func pokeControls() {
        withAnimation(.easeOut(duration: 0.18)) { showControls = true }
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(controlsHideDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // 列表开着、或已锁屏：不藏（锁定时控制栏必须留 unlocking 入口）
            guard !showList, !locked else { return }
            withAnimation(.easeOut(duration: 0.25)) { showControls = false }
        }
    }

    // MARK: - 看门狗（换线判据的唯一作者）

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                check()
            }
        }
    }

    private func check() {
        guard !showList, let item = player.currentItem else { return }

        if let err = item.error {
            let e = err as NSError
            LiveDiag.write("线路错误 \(currentName) \(e.domain):\(e.code) \(e.localizedDescription)")
            advanceLine(reason: "err \(e.code)", hopChannel: true)
            return
        }
        if item.status == .failed {
            LiveDiag.write("线路判死 \(currentName) status=.failed")
            advanceLine(reason: "status failed", hopChannel: true)
            return
        }

        // 出画判据（v44.1 修正）：只认「小步前进」，**不认大跳**。
        // 大跳 = AVPlayer 起播/重连时把位置置到直播边缘（或 DVR 窗口起点），此时一个字节都还没缓冲，
        // 旧写法（基准 0）会把它当成出画 → 坏线被当成好线 → 无限重连（实测 RTBalkan 一晚上都在重连）。
        let t = item.currentTime().seconds
        guard t.isFinite else { return }
        if lastTime < 0 {
            lastTime = t
            lastProgressAt = Date()
            LiveDiag.write("建立位置基准 \(currentName) 线#\(rawIndex + 1) t=\(String(format: "%.1f", t))s")
            return
        }
        let d = t - lastTime
        if d > 0.04, d < 3.0 {
            lastTime = t
            lastProgressAt = Date()
            progressTicks += 1
            if !linePlayed, progressTicks >= 2 {
                linePlayed = true
                reconnectTries = 0
                hopTries = 0
                // 出画 = 这条线在本机真能播 → 给好源加分（下次排序它就在前面 ⇒ 秒播）。
                // 2026-10-03 补：旧代码只在判死时 record(ok:false)，好源**从来没被加过分**，
                // 于是「越播越顺的源」在排序里体现不出来，每次进页还是可能先撞死线。
                if let u = currentURL { LiveSourceHealth.shared.record(u, ok: true) }
                LiveDiag.write("出画 \(currentName) 线#\(rawIndex + 1) t=\(String(format: "%.1f", t))s " +
                               "缓冲=\(String(format: "%.1f", item.loadedTimeRanges.first?.timeRangeValue.duration.seconds ?? -1))s")
            }
            if !everPlayed, linePlayed { everPlayed = true; statusText = nil }
            if buffering { buffering = false; statusText = nil }
            return
        }
        if d >= 3.0 {
            // 位置大跳：更新基准，但**不算出画**；同一线路出现两次且始终没真出画 = DVR 录播窗口。
            lastTime = t
            bigJumps += 1
            LiveDiag.write("位置跳变 \(Int(d))s \(currentName) 线#\(rawIndex + 1)（第 \(bigJumps) 次，不认作出画）")
            if bigJumps >= 2, !linePlayed {
                LiveDiag.write("DVR 录播窗口（无真前进）→ 换线 \(currentName)")
                advanceLine(reason: "dvr", hopChannel: true)
            }
            return
        }

        let stalled = Date().timeIntervalSince(lastProgressAt)

        if !linePlayed {
            // 从未出画：给足宽限再动手（首片 2MB 在手机上要好几秒）。
            let since = Date().timeIntervalSince(tuneAt)
            let buffered = item.loadedTimeRanges.first?.timeRangeValue.duration.seconds ?? -1
            // 「零进展」提前判死：这么多秒连一个字节都没缓冲到（buffered <= 0）
            // = 这条线根本没在回数据（死链 / 被墙 / 重定向失效），不必等满宽限 —— 这是「秒播」的另一半。
            let noData = since > noDataGrace && buffered <= 0
            if since > firstFrameGrace || noData {
                if let u = currentURL { LiveSourceHealth.shared.record(u, ok: false) }
                LiveDiag.write("\(String(format: "%.1f", since))s 未出画 \(currentName) 线#\(rawIndex + 1) " +
                               "itemStatus=\(item.status.rawValue) buffered=\(String(format: "%.1f", buffered))s")
                advanceLine(reason: noData ? "无数据" : "未出画", hopChannel: true)
            } else if since > 2.5 {
                statusText = "加载中…  \(currentName)"
            }
            return
        }

        // 出过画之后再卡：先等它自己恢复 → 不行就**原地重连**（同 URL 重拉，不换源）→ 两次后才换线。
        if stalled > stallGrace {
            if reconnectTries < 2 {
                reconnectTries += 1
                LiveDiag.write("卡顿 \(Int(stalled))s → 原地重连 #\(reconnectTries) \(currentName) url=\(currentURL?.absoluteString ?? "")")
                if let u = currentURL { startPlayback(url: u, name: currentName) }
            } else {
                LiveDiag.write("卡顿 \(Int(stalled))s → 换线 \(currentName)")
                advanceLine(reason: "卡顿", hopChannel: false)
            }
        } else if stalled > 2.5 {
            buffering = true
            statusText = "加载中…  \(currentName)"
        }
    }

    private var currentName: String {
        stations.indices.contains(index) ? stations[index].name : "?"
    }

    private func tryAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback)
        try? s.setActive(true)
    }

    // MARK: - 本机自体检（端上真测：谁播谁知道）

    /// 进页后台体检**当前台的线路**（不阻塞起播、不打断画面）：
    /// 拿到本机实测耗时后①写黑匣子 ②重排选线 ③还没出画时直接换到最快那条。
    private func startSelfProbe() {
        probeTask?.cancel()
        let gen = probeGen
        let myIndex = index
        let myTable = tableGen
        guard stations.indices.contains(myIndex) else { return }
        let myName = stations[myIndex].name
        probeTask = Task { @MainActor in
            guard stations.indices.contains(myIndex), stations[myIndex].name == myName else { return }
            let t0 = Date()
            let target = Array(stations[myIndex].lines.prefix(6))
            let res = await LiveCollector.shared.probe(target)
            // 只采信**本次这台**的结果：`LiveCollector.probe` 返回的是**全量历史 results**，
            // 直接 `res.values` 统计会把往次别的台的成绩算进来（v44.2 实测就打成「条=6 活=2」的虚数）。
            let mine = target.compactMap { u -> (String, LiveCollector.Result)? in
                guard let r = res[u.absoluteString] else { return nil }
                return (u.absoluteString, r)
            }
            var m = probeMs
            for (k, r) in mine where r.ok { m[k] = r.listMs + r.segMs }
            probeMs = m
            let alive = mine.filter { $0.1.ok }.count
            let fastest = mine.filter { $0.1.ok }
                .min { ($0.1.listMs + $0.1.segMs) < ($1.1.listMs + $1.1.segMs) }
            let fastTag = fastest.map { String($0.0.suffix(20)) + "/\($0.1.listMs + $0.1.segMs)ms" } ?? "-"
            LiveDiag.write("本机自体检 \(myName) 条=\(mine.count) 活=\(alive) " +
                           "用时=\(Int(Date().timeIntervalSince(t0) * 1000))ms 最快=\(fastTag)")
            // 应用条件（v45 再加「表代号」这条）：① 世代号没变（期间没人切台/换线）
            // ② **没有换过表**（换表后同一个 index 是另一个台）③ 还在同一台（名+下标都对上）
            // ④ 这条线还没出画 ⑤ 本页也还没出画 ⑥ 确实另有更快的活线。
            // 少任何一条都可能在用户已经看别的台时把画面抢回去。
            guard gen == probeGen, tableGen == myTable, index == myIndex,
                  stations[myIndex].name == myName,
                  !linePlayed, !everPlayed, let best = fastest?.0 else { return }
            let here = stations[myIndex]
            guard let bi = here.lines.firstIndex(where: { $0.absoluteString == best }), bi != rawIndex else { return }
            LiveDiag.write("按本机实测换到最快线 #\(bi + 1) \(myName)")
            tuneRaw(myIndex, bi)
        }
    }

    // MARK: - 后台保鲜（不阻塞、不打断）

    private func refreshFromRemote() async {
        let loader = LiveLoader(bases: feedBases)
        let tb = Date()
        let remote = await loader.load(path: livePath)
        guard !remote.isEmpty else { return }
        // v76.1 取证：保鲜后半段（建表 + 并回补源 + 赋值 stations）都在主线程，
        // 且 stations 是 @Published → 整页重渲染；这条日志量出「保鲜那次卡了多久」
        MainThreadMark.set("直播·远端保鲜落表（主线程）")
        var fresh = LiveStation.build(from: remote)
        guard fresh.count >= Int(Double(stations.count) * 0.9) else { return }
        let keep = stations.indices.contains(index) ? stations[index].name : lastChannelName
        let cur = currentURL
        fresh = withRefilled(fresh)          // 自愈补进来的线在这张表里也要在
        tableGen &+= 1                       // ★ 换表：异步任务（自体检）据此作废自己的结果
        health.removeAll()                   // 面板巡检结果按台名存，换表后重新检
        stations = fresh
        LiveDiag.write("远端保鲜生效：台 \(fresh.count)（抓取+建表+补源 共用时=\(Int(-tb.timeIntervalSinceNow * 1000))ms）")
        // 新表已含**正在播的这条 URL** 时不动画面：保鲜是后台行为，
        // 不该把用户正在看的台打断重起播（v44.2 实测每次进页都因此白闪一下）。
        if let i = fresh.firstIndex(where: { $0.name == keep }) {
            if let cur, let r = fresh[i].lines.firstIndex(of: cur) {
                index = i
                rawIndex = r
            } else if i != index {
                tune(to: i)
            }
        }
    }

    // MARK: - 频道面板（v42 形态：从**右侧**滑出，左列分类 + 右列频道）

    private var panelGroups: [String] {
        var out: [String] = []
        for st in stations where !out.contains(st.group) { out.append(st.group) }
        return out
    }

    private var shownStations: [LiveStation] {
        guard let g = pickGroup else { return stations }
        return stations.filter { $0.group == g }
    }

    /// 分类名清洗（v60 · C3）：直播表里 `group-title` 常带 emoji / 装饰符号前缀（「🍀辽宁」「·游戏…」），
    /// 竖屏老面板里因此出现「·游戏「…」这类半截带符号的截断。
    /// ★ 只清洗**显示名**；选中/过滤仍用原始 `tag`（否则 `pickGroup` 与表里的 group 对不上）。
    private func groupLabel(_ g: String) -> String {
        var s = g.trimmingCharacters(in: .whitespacesAndNewlines)
        let decorations = CharacterSet(charactersIn: "·•▪▫◆●■▲▼☆★◎→-—_|")
        var guardCount = 0
        while guardCount < 8, let f = s.unicodeScalars.first {
            guardCount += 1
            let deco = f.properties.generalCategory == .otherSymbol
                || f.properties.generalCategory == .modifierSymbol
                || f.properties.isEmojiPresentation
                || decorations.contains(f)
            if deco {
                s.removeFirst()
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                break
            }
        }
        return s.isEmpty ? g : s
    }

    /// 频道列表（**v60 横竖屏唯一实现**）。
    ///
    /// 根因（主人 2026-10-04「横竖屏一个面孔」「这个直播频道列表不透明」）：旧版是**两套实现**
    /// —— 竖屏 `legacyChannelPanel`（v42 贴边黑板：黑 0.55 + 黑 0.88 实底，盖住大半画面）与
    /// 横屏 `landscapeChannelPanel`（悬浮卡）。两套一在，形态/材质/交互就一定继续分叉，
    /// 所以这里**直接把竖屏那套整段删除**，只留悬浮玻璃卡一份，按横竖屏调整尺寸。
    private var channelPanel: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // 左侧空白：点一下收起（也把「返回键」的位置让出来）
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { closeList() }

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("频道列表").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        if stations.indices.contains(index) {
                            Text("· 正在播 \(stations[index].name)")
                                .font(.caption).foregroundStyle(.orange).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button { closeList() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5)
                    HStack(spacing: 0) {
                        // 分类列：竖排胶囊（带台数），固定列宽 → 截断长度一致（C3）
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 6) {
                                catChip("全部", tag: nil)
                                ForEach(panelGroups, id: \.self) { g in catChip(groupLabel(g), tag: g) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 8)
                        }
                        .frame(width: catColumnWidth)
                        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5)
                        ScrollViewReader { proxy in
                            ScrollView(showsIndicators: false) {
                                LazyVStack(spacing: 4) {
                                    ForEach(shownStations) { st in channelRow(st) }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 8)
                            }
                            .onAppear { proxy.scrollTo(index, anchor: .center) }
                        }
                    }
                }
                .frame(width: panelWidth(geo))
                // ★ 视频上浮层：玻璃档（虚化 + 中性压暗）——旧写法是 ultraThinMaterial + 白 0.08
                //   提亮（白提亮把视频透色洗成灰白实底，正是主人点名的「不透明」根因）。
                .filmGlass(cornerRadius: 20, tint: 0.36, strokeOpacity: 0.16, weight: .dark)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                .padding(.vertical, 12)
                .padding(.trailing, 14)
            }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// 面板宽度：横屏给宽一点（两列都有余量）；竖屏窄屏按比例收，但不小于 300（否则频道名全截断）。
    private func panelWidth(_ geo: GeometryProxy) -> CGFloat {
        isLandscape ? min(460, geo.size.width * 0.6) : min(360, max(300, geo.size.width * 0.86))
    }

    /// 分类列宽：横竖屏统一固定，避免「有的截六个字、有的截三个字」的参差（C3）。
    private var catColumnWidth: CGFloat { isLandscape ? 88 : 96 }

    /// 分类胶囊（竖排、带台数、选中橙描边）——v60 横竖屏共用一套。
    private func catChip(_ title: String, tag: String?) -> some View {
        let sel = pickGroup == tag
        let count = tag == nil ? stations.count : stations.filter { $0.group == tag }.count
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { pickGroup = tag }
        } label: {
            VStack(spacing: 2) {
                Text(title).font(.caption.weight(sel ? .semibold : .regular))
                    .foregroundStyle(sel ? Color.orange : .white.opacity(0.85))
                    .lineLimit(1)
                Text("\(count)").font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                if sel {
                    Capsule().fill(Color.orange.opacity(0.18))
                        .overlay(Capsule().stroke(Color.orange.opacity(0.55), lineWidth: 1))
                } else {
                    Capsule().fill(Color.white.opacity(0.08))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 频道行（v60 横竖屏唯一实现）：圆角行、当前台橙色高亮＋描边；健康点/线路数统一口径。
    private func channelRow(_ st: LiveStation) -> some View {
        let isNow = st.index == index
        let hkey = LivePool.normalize(st.name)
        return Button {
            hopTries = 0
            tune(to: st.index)
            closeList()
        } label: {
            HStack(spacing: 8) {
                LiveLogoBadge(url: st.logo, name: st.name, size: 26)
                Text(st.chno.map { String(format: "%02d", $0) } ?? "—")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isNow ? Color.orange
                                           : (st.chno == nil ? .white.opacity(0.22) : .white.opacity(0.62)))
                    .frame(minWidth: 22, alignment: .leading)
                Text(st.name).font(.subheadline.weight(isNow ? .semibold : .regular))
                    .foregroundStyle(isNow ? Color.orange : .white).lineLimit(1)
                Spacer(minLength: 2)
                if isNow {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption2).foregroundStyle(Color.orange)
                }
                if let a = health[hkey] {
                    HStack(spacing: 3) {
                        Circle().fill(a == 0 ? Color.red : Color.green)
                            .frame(width: 6, height: 6)
                        Text(a == 0 ? "无信号" : "活\(a)")
                            .font(.caption2)
                            .foregroundStyle(a == 0 ? Color.red.opacity(0.95) : Color.green.opacity(0.95))
                    }
                } else if healthTesting == hkey || healthPending.contains(hkey) {
                    Text("测…").font(.caption2).foregroundStyle(.white.opacity(0.35))
                }
                Text("\(st.lines.count)线").font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background {
                if isNow {
                    RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.5), lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(st.index)
        .onAppear { checkStation(st) }
    }

}

// MARK: - 台（同台多条线合一）

struct LiveStation: Identifiable {
    let id: String
    let index: Int          // 在总表中的位次（列表滚动/对齐用）
    let name: String        // 去掉「·备N」后的台名
    let group: String
    let logo: URL?
    /// **固定频道号**（表内 `tvg-chno`；2026-10-03 主人钦定名册，央视1~17 / 卫视 / 地面 / 教育购物）。
    /// nil = 不在固定名册里 → 排在名册之后，顺序沿用表内原序。
    /// 说明：`LiveChannel.chno` 一直都在解析，但**这里原先把它丢了** —— 于是「按号」从来没生效过。
    let chno: Int?
    /// **可变**：端上自愈补源会往这里追加「当场实测能播」的线（v45），
    /// 所以它不是 `let` —— 表内线路全坏时这台要能被补活，而不是被划掉。
    var lines: [URL]

    /// 把 m3u 行表合成「台」：表内同台线路相邻，按名字前缀（去掉 ·备N）归并。
    /// 归一后**按固定频道号重排**：名册台（有 chno）按号在前，其余保持表内原序在后。
    static func build(from raw: [LiveChannel]) -> [LiveStation] {
        var out: [LiveStation] = []
        var currentKey = ""
        var bufName = ""
        var bufGroup = ""
        var bufLogo: URL?
        var bufChno: Int?
        var bufLines: [URL] = []

        func flush() {
            guard !bufLines.isEmpty else { return }
            out.append(LiveStation(id: "st.\(out.count).\(bufName)",
                                   index: out.count,
                                   name: bufName, group: bufGroup.isEmpty ? "其他" : bufGroup,
                                   logo: bufLogo, chno: bufChno, lines: bufLines))
            bufLines = []
            bufLogo = nil
            bufChno = nil
        }

        for ch in raw {
            let key = baseName(ch.name)
            if key != currentKey {
                flush()
                currentKey = key
                bufName = key
                bufGroup = ch.group
            }
            if bufLogo == nil { bufLogo = ch.logo }
            if bufChno == nil { bufChno = ch.chno }
            if !bufLines.contains(ch.url) { bufLines.append(ch.url) }
        }
        flush()
        // 名册台按固定频道号排前；其余保持表内原序（用 index 兜底做全序，避免 sort 不稳定）。
        out.sort { a, b in
            switch (a.chno, b.chno) {
            case let (x?, y?): return x != y ? x < y : a.index < b.index
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.index < b.index
            }
        }
        return out.enumerated().map { i, st in
            LiveStation(id: st.id, index: i, name: st.name, group: st.group,
                        logo: st.logo, chno: st.chno, lines: st.lines)
        }
    }

    /// 台名归一：去掉「·备1 / -2 / ②」等备用标记，同名归一台。
    private static func baseName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "·备") { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of: "備") { s = String(s[..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    struct Group: Identifiable { let name: String; let stations: [LiveStation]; var id: String { name } }

    static func groups(of all: [LiveStation]) -> [Group] {
        var order: [String] = []
        var map: [String: [LiveStation]] = [:]
        for st in all {
            if map[st.group] == nil { order.append(st.group) }
            map[st.group, default: []].append(st)
        }
        return order.map { Group(name: $0, stations: map[$0] ?? []) }
    }
}

// MARK: - 视频层（AVPlayerLayer，自绘，不吃手势）

struct LiveVideoLayer: UIViewRepresentable {
    let player: AVPlayer
    /// 画面比例（2026-10-03 主人「直播里没有屏幕比例按钮」→ 补上，与点播播放器同口径）。
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.backgroundColor = .black
        v.attach(player, gravity: gravity)
        return v
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        uiView.attach(player, gravity: gravity)
    }

    static func dismantleUIView(_ uiView: PlayerHostView, coordinator: ()) {
        uiView.detach()
    }
}

final class PlayerHostView: UIView {
    private var layer_: AVPlayerLayer?

    func attach(_ player: AVPlayer, gravity: AVLayerVideoGravity = .resizeAspect) {
        // 同一 player 已挂上：只更新画面比例（**不许重建 layer**，否则切比例会黑一下）。
        if let l = layer_, l.player === player {
            if l.videoGravity != gravity { l.videoGravity = gravity }
            return
        }
        layer_?.removeFromSuperlayer()
        let l = AVPlayerLayer(player: player)
        l.videoGravity = gravity
        l.frame = bounds
        // 2026-10-03 修：原写 `layer = l` —— UIView.layer 是**只读**属性（编译不过），
        // 且即便能过也挂不上画面。正解是把自建 AVPlayerLayer 作为子层挂到视图的 backing layer 上。
        self.layer.addSublayer(l)
        layer_ = l
    }

    func detach() {
        layer_?.removeFromSuperlayer()
        layer_ = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer_?.frame = bounds
    }
}

// MARK: - 台标（表里给什么就显示什么；包内优先，零网络也全有）

/// 台标来源（主人 2026-10-03：「台标是表里的，从表里找」「全都要有」）：
///   ① 表里 `tvg-logo` 是本仓编号（`…/filmcollector-logos@main/NNNN.png`）→ 直接取**包内**同号 PNG
///      （随包 332 张，与 TV 端同一套），断网/弱网照样有，且秒显；
///   ② 表里是第三方可达 URL（gitee / tb.zbds.top 按名）→ 联网取；
///   ③ 都没有 → 首字牌（不留空白）。
struct LiveLogoBadge: View {
    let url: URL?
    let name: String
    let size: CGFloat

    @State private var bundled: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.12))
            if let bundled {
                Image(uiImage: bundled).resizable().scaledToFit().padding(size * 0.14)
            } else if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFit().padding(size * 0.14)
                    } else if case .failure = phase {
                        letter
                    } else {
                        Color.clear
                    }
                }
            } else {
                letter
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear(perform: probeBundled)
    }

    private var letter: some View {
        Text(String(name.prefix(1)))
            .font(.system(size: max(size * 0.42, 9), weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
    }

    /// 表里台标若为本仓 4 位编号 → 取包内同号 PNG（XcodeGen 两种落地布局都试）。
    private func probeBundled() {
        guard bundled == nil, let key = LiveLogos.key(for: url) else { return }
        for dir in ["LiveLogo", nil] as [String?] {
            if let p = Bundle.main.path(forResource: key, ofType: "png", inDirectory: dir),
               let img = UIImage(contentsOfFile: p) { bundled = img; return }
        }
    }
}

// MARK: - 设置页「试播频道」用的轻量播放器
//
// 同签名实现，只服务于「单台试播」：起播链与 LiveView **同口径**
// （15 秒出画宽限 / 12 秒卡顿 → 原地重连 ×2 → 换线），关闭键常驻（进去出不来是老病）。
public struct LivePlayerScreen: View {
    let channels: [LiveChannel]
    @Binding var showList: Bool
    let onClose: () -> Void

    @State private var stations: [LiveStation] = []
    @State private var index = 0
    @State private var rawIndex = 0
    @State private var linePos = 0
    @State private var status: String? = "加载中…"   // v77：与直播页同口径（去「正在起播」）
    @State private var buffering = false
    @State private var player = AVPlayer()
    @State private var watchdog: Task<Void, Never>?
    @State private var everPlayed = false
    @State private var linePlayed = false
    @State private var lastTime: Double = -1        // -1 = 尚未建立基准（见 LiveView 同项注释）
    @State private var progressTicks = 0
    @State private var bigJumps = 0
    @State private var lastProgressAt = Date()
    @State private var tuneAt = Date()
    @State private var reconnectTries = 0
    @State private var lineTries = 0
    /// 本台本轮已试过的线路 URL（与 LiveView 同款修法：用集合而不是位次换线）。
    @State private var triedURLs: Set<String> = []
    @AppStorage("settings.startupMode") private var startupMode = "low"
    /// 画面比例 / 锁屏（2026-10-03 主人「直播里没有屏幕比例和锁屏等按钮」→ 试播页同口径补齐）。
    @State private var aspect: AspectMode = .fit
    @State private var locked = false
    /// 原型 v3：横屏角标同口径纯图标（与直播页一致）。
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var isLandscape: Bool { vSizeClass == .compact }

    public init(channels: [LiveChannel], showList: Binding<Bool>, onClose: @escaping () -> Void) {
        self.channels = channels
        self._showList = showList
        self.onClose = onClose
    }

    private var bufferSeconds: Double {
        switch startupMode {
        case "stable": return 8
        case "standard": return 4
        default: return 2
        }
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LiveVideoLayer(player: player, gravity: aspect.gravity).ignoresSafeArea()

            // ★ v77：与直播页同口径 —— 去底去框，只留「加载圈 + 加载中… + 台名 + 投影」。
            if let status, !everPlayed || buffering {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(status).font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.85), radius: 6, y: 1)
                }
                .allowsHitTesting(false)
            }

            VStack {
                HStack(spacing: 10) {
                    // v60：横竖屏统一纯箭头（去「关闭」字、去胶囊底）——与直播页/详情页同口径。
                    Button { onClose() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 4, y: 1)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if stations.indices.contains(index) {
                        let st = stations[index]
                        HStack(spacing: 6) {
                            LiveLogoBadge(url: st.logo, name: st.name, size: 24)
                            Text(st.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            Text("线路 \(linePos + 1)/\(st.lines.count)")
                                .font(.caption2).foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        // v60：台名信息条 = 视频上浮层玻璃档（旧版直挂文字，底色靠视频透）。
                        .filmGlass(cornerRadius: 999, tint: 0.30, strokeOpacity: 0.12, weight: .dark)
                    }
                    Spacer()
                    liveCircleButton("aspectratio", label: "画面比例：\(aspect.shortTitle)") { cycleAspect() }
                    liveCircleButton(locked ? "lock.fill" : "lock.open.fill",
                                     label: locked ? "解锁屏幕" : "锁定屏幕") { toggleLock() }
                }
                .padding(.horizontal, 12).padding(.top, 6)
                Spacer()
            }
        }
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { boot() }
        .onDisappear { shutdown() }
    }

    /// 画面比例循环（与 LiveView / 点播播放器同口径：点一下换一个模式，不弹面板）。
    private func cycleAspect() {
        let all = AspectMode.allCases
        let next = all[(all.firstIndex(of: aspect).map { $0 + 1 } ?? 0) % all.count]
        aspect = next
        LiveDiag.write("试播画面比例 → \(next.rawValue)/\(next.shortTitle)")
    }

    /// 锁屏（钉横屏 + 防误触）；离开时必须解锁，否则首页也被钉在横屏。
    private func toggleLock() {
        locked.toggle()
        OrientationLock.shared.set(locked ? .landscape : nil)
        LiveDiag.write("试播锁屏 \(locked ? "开(锁横屏)" : "关(交还系统)")")
    }

    private func boot() {
        guard stations.isEmpty else { return }
        stations = LiveStation.build(from: channels)
        guard !stations.isEmpty else { status = "这条源没有可用线路"; return }
        LiveDiag.write("试播进入 台=\(stations.count) 线=\(stations.reduce(0) { $0 + $1.lines.count })")
        tune(0, pos: 0)
        startWatchdog()
    }

    private func shutdown() {
        watchdog?.cancel(); watchdog = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        locked = false
        OrientationLock.shared.set(nil)
    }

    private func tune(_ i: Int, pos: Int) {
        guard stations.indices.contains(i) else { return }
        if i != index { triedURLs.removeAll() }          // 换台 → 试线记录重来
        let st = stations[i]
        let order = LiveSourceHealth.ranked(st.lines)
            .filter { !triedURLs.contains(st.lines[$0].absoluteString) }
        guard !order.isEmpty else { return }
        let p = max(0, min(pos, order.count - 1))
        index = i
        rawIndex = order[p]
        linePos = p
        reconnectTries = 0
        start(url: st.lines[rawIndex], name: st.name)
    }

    private func start(url: URL, name: String) {
        LiveDiag.write("试播起播 \(name) 线#\(rawIndex + 1) url=\(url.absoluteString)")
        player.pause()
        player.replaceCurrentItem(with: nil)
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = bufferSeconds
        player.replaceCurrentItem(with: item)
        // v70 秒播回滚：与直播页同口径 —— 恢复 v64 的「等系统判不卡」，慢几秒但能出画。
        player.automaticallyWaitsToMinimizeStalling = true
        player.playImmediately(atRate: 1.0)
        lastTime = -1
        progressTicks = 0
        bigJumps = 0
        lastProgressAt = Date()
        tuneAt = Date()
        linePlayed = false
        buffering = false
        if !everPlayed { status = "加载中…  \(name)" }
    }

    private func nextLine(reason: String) {
        guard stations.indices.contains(index) else { return }
        let st = stations[index]
        // 与 LiveView 同口径（2026-10-03）：按**已试过的 URL 集合**选下一条，
        // 不用位次（重排后位次会指回同一条）；最多试 6 条就放弃。
        if let u = (player.currentItem?.asset as? AVURLAsset)?.url {
            triedURLs.insert(u.absoluteString)
        }
        lineTries = triedURLs.count
        let remain = LiveSourceHealth.ranked(st.lines)
            .filter { !triedURLs.contains(st.lines[$0].absoluteString) }
        if let first = remain.first, triedURLs.count < 6 {
            LiveDiag.write("试播换线(\(reason)) \(st.name) 第 \(triedURLs.count) 条 → 线#\(first + 1)/\(st.lines.count)")
            rawIndex = first
            linePos = 0
            reconnectTries = 0
            start(url: st.lines[first], name: st.name)
            return
        }
        LiveDiag.write("试播本台放弃 \(st.name) 原因=\(reason) 已试 \(triedURLs.count) 条")
        buffering = false
        status = "本台线路暂时都不可用"
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                guard let item = player.currentItem else { continue }
                if item.error != nil || item.status == .failed { nextLine(reason: "err"); continue }
                let t = item.currentTime().seconds
                guard t.isFinite else { continue }
                if lastTime < 0 { lastTime = t; lastProgressAt = Date(); continue }   // 首个样本只做基准
                let d = t - lastTime
                if d > 0.04, d < 3.0 {
                    lastTime = t
                    lastProgressAt = Date()
                    progressTicks += 1
                    if !linePlayed, progressTicks >= 2 { linePlayed = true; reconnectTries = 0 }
                    if !everPlayed, linePlayed { everPlayed = true; status = nil }
                    if buffering { buffering = false; status = nil }
                    continue
                }
                if d >= 3.0 { lastTime = t; bigJumps += 1                 // 大跳不认作出画（DVR/直播边缘）
                    if bigJumps >= 2, !linePlayed { nextLine(reason: "dvr") }
                    continue
                }
                let stalled = Date().timeIntervalSince(lastProgressAt)
                if !linePlayed {
                    // 与 LiveView 同口径（2026-10-03）：7 秒宽限；零进展（一个字节都没缓冲到）3.5 秒提前判死。
                    let since = Date().timeIntervalSince(tuneAt)
                    let buffered = player.currentItem?.loadedTimeRanges.first?.timeRangeValue.duration.seconds ?? -1
                    if since > 7 || (since > 3.5 && buffered <= 0) {
                        nextLine(reason: buffered <= 0 ? "无数据" : "未出画")
                    }
                    return
                }
                if stalled > 12 {
                    if reconnectTries < 2, let u = player.currentItem?.asset as? AVURLAsset {
                        reconnectTries += 1
                        LiveDiag.write("试播卡顿 \(Int(stalled))s → 原地重连 #\(reconnectTries)")
                        start(url: u.url, name: stations[index].name)
                    } else {
                        nextLine(reason: "卡顿")
                    }
                } else if stalled > 2.5 {
                    buffering = true
                    // v77：与直播页同口径 —— 卡顿提示也写「加载中… + 台名」（原来只写「缓冲中…」）。
                    status = stations.indices.contains(index) ? "加载中…  \(stations[index].name)" : "加载中…"
                }
            }
        }
    }
}

/// 直播类页面顶栏的圆形按钮（LiveView 与设置页试播**共用一套**，避免两处手抄走形）。
/// ★ v60（主人 2026-10-04「横竖屏一个面孔 / 能不要框的不要框」）：
/// **横竖屏一律纯图标＋深投影，没有黑圆底这一支**。旧的 `bare` 双形态参数已整体删除
/// —— 留着它就会有人再传 false 把灰圆底放回来（这正是「两副面孔」的复发路径）。
@ViewBuilder
private func liveCircleButton(_ symbol: String, label: String,
                              action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
            .shadow(color: .black.opacity(0.9), radius: 4, y: 1)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
}
