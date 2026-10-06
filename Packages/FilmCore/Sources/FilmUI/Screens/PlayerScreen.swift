import SwiftUI
import AVKit
import UIKit
import MediaPlayer
import FilmCore

/// 播放器拖动手势模式。
/// 双击快进/快退的视觉反馈（2026-09-30 用户：「你好好看看爱优腾怎么做的」）。
/// 爱优腾双击屏幕左/右侧时，会在**对应半屏**浮出一个圆形涟漪（箭头图标 + 秒数），
/// 一眼就知道刚才那两下是快进还是快退、退了多少。这里照做。
private struct SeekRippleFeedback: Equatable {
    let id = UUID()
    let forward: Bool
    let seconds: Int
}

private enum PlayerDragMode {
    case idle
    case seek
    case brightness
    case volume
    case close
    /// 抖音式切集（2026-09-23 用户：「播放的时候能像抖音那种滑动上下级吗？内置源怎么给他这个功能呢！」）：
    /// 右边缘竖向滑动 = 上滑下一集 / 下滑上一集。放右边缘是为了不抢既有的
    /// 「左半屏竖向=亮度、右半屏竖向=音量、横滑=进度」三个手势。
    case episode
}

/// 系统音量程序化控制（经由隐藏 MPVolumeView 锚点）。
enum PlayerVolumeController {
    static weak var hostView: MPVolumeView?

    static func current() -> Float {
        if let slider = hostView?.subviews.compactMap({ $0 as? UISlider }).first {
            return slider.value
        }
        return AVAudioSession.sharedInstance().outputVolume
    }

    static func set(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        if let slider = hostView?.subviews.compactMap({ $0 as? UISlider }).first {
            slider.setValue(clamped, animated: false)
        }
    }
}

/// 音量锚点视图（1x1 隐藏，仅用于让 MPVolumeView 进入视图层级）。
struct VolumeAnchorView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.isUserInteractionEnabled = false
        PlayerVolumeController.hostView = view
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

/// ★ v78.4 续播决策痕迹（详情页选路 → 播放器起播，全链一条线）。
///
/// 为什么要有它（主人 2026-10-05「怎么续播也出问题了 刚才我看到的位置 装完从第一集开始了」）：
/// 上一版只有播放器里的 `resume.traceLog`，只能看到「起播时 gate=false」，
/// **看不到详情页那一刻到底读到了什么**（历史有没有、加载完没完、选了哪条路），
/// 于是只能猜。这次把「谁点的、当时看没看到历史、最终传下去的 line」全部留痕，
/// 可从手机容器拉 `UserDefaults` 的 `resume.pickLog` 一锤定音。
///
/// 只写不读、失败静默 —— 不影响任何播放行为。
enum ResumeTrace {
    static func note(_ msg: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var log = UserDefaults.standard.stringArray(forKey: "resume.pickLog") ?? []
        log.append("\(stamp) \(msg)")
        if log.count > 80 { log.removeFirst(log.count - 80) }
        UserDefaults.standard.set(log, forKey: "resume.pickLog")
        UserDefaults.standard.set("\(stamp) \(msg)", forKey: "resume.pickLast")
        filmLog.info("resumePick: \(msg)")
    }
}

/// 播放器（全屏）：AVPlayer + 自绘控制层（对齐大牌影视 App 交互）。
/// - HLS(.m3u8)/MP4 直接吃生产源地址；失败显示重试（可切线路），不闪退不黑屏无提示；
/// - 单击显隐控制层（3.4s 自动隐藏）；双击左右半屏 ±10s；倍速经控制条「倍速」按钮选择；
/// - 横滑拖动快进快退（预览目标时间，松手生效）；左半屏上下滑调亮度、右半屏调系统音量；
/// - 屏幕上部下滑退出播放；进入自动横屏、退出恢复竖屏；倍速跨会话记忆；
/// - 倍速/线路面板、锁定（只留解锁钮）、横竖屏一键切换；
/// - 前后台切换自动暂停/恢复；播放中屏幕常亮；进度写播放历史（续播）。
public struct PlayerScreen: View {
    let item: FeedItem
    var startAtResume: Bool
    /// 显式关闭回调（LiveContainer 里 dismiss 环境可能失效，双保险）
    var onClose: (() -> Void)? = nil
    /// 选集数据（剧集传入：详情页 episodeGroups 原样传进来；电影/旧调用留空 = 无选集面板、不自动连播）
    var episodeGroups: [(line: String, eps: [(index: Int, name: String)])] = []
    /// 播放器内切集后回传集名（详情页用于换源对位保持同一集）
    var onEpisodeChange: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    /// ★ v78.4：进后台/被系统回收前把进度落盘（续播链路的「写」这一半）。
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: PlayerViewModel

    /// 2026-10-01 主人钦定：「跟着海报 还有那个倍数的也是跟着海报」。
    ///
    /// 面板色源 = **这部片的海报主色**，不是会动的视频画面（视频色明暗不定、不可控，浅画面还会洗白字）。
    /// 取色走 `HeroTintStore`：首页/详情页早已算过同一张海报并缓存 → **零额外下载**，
    /// 且与详情页 `heroTintBackground` 用的是**同一个 `HeroPalette`** → 进播放器颜色连成一片不跳色。
    @State private var palette: HeroPalette = .fallback

    @State private var showControls = true
    @State private var locked = false
    /// 2026-10-01 主人钦定：手势**第一次用要给提示**（「要不都不知道怎么用是什么」）。
    /// 只弹一次（AppStorage 记住），点任意处或 9 秒后自动消失。
    @AppStorage("filmui.gestureHintShown.v1") private var gestureHintShown = false
    @State private var showGestureHint = false
    @State private var gestureHintTask: Task<Void, Never>?
    @State private var showLinePanel = false
    @State private var showEpisodePanel = false
    // 51包：原画面比例面板已删（比例改为底栏点一下循环切换 cycleAspect）
    /// 长按加速结束时刻（用于挡住"松手被当成单击→误暂停"）
    @State private var lastBoostEnd = Date.distantPast
    /// 控制层上次「显示」的时刻（2026-09-30 用户报「点很多次都不能呼出」：
    /// 单击手势刚把控制层点亮的一瞬间，若紧接着再来一次点击，忽略其收起动作——
    /// 连点/双击的第一击就再也不会把刚出现的控制层立刻吃掉）。
    @State private var lastShowAt = Date.distantPast
    /// 双击快进/快退的半屏涟漪反馈（爱优腾同款）
    @State private var seekRipple: SeekRippleFeedback?
    @State private var seekRippleHideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var seekToast: String?
    /// v13（2026-09-25 用户钦点「按手机音量键能看见声音大小的条」）：
    /// MPVolumeView 锚点会抑制系统音量 HUD → 端上自绘音量条，
    /// KVO 监听系统音量变化（物理音量键）+ 右半屏拖动调音量时同步显示。
    @State private var volumeHUDValue: Double?
    @State private var volumeHUDHideTask: Task<Void, Never>?
    @State private var volumeObserver: NSKeyValueObservation?
    /// 静音键（用户钦点「播放器没有静音很不方便」）——只控 AVPlayer.isMuted，不动系统音量。
    @State private var isMuted = false
    /// 倍速选择条显隐（用户钦点：倍速要有进度条/档位条，不要只循环一个文字）
    @State private var showRateSelector = false
    /// 音量滑条显隐（用户钦点：音量要有进度条）
    @State private var showVolumeSlider = false
    @State private var sliderVolume: Double = 0.5
    @State private var hideTask: Task<Void, Never>?
    @State private var isLandscape = false
    @State private var dragMode: PlayerDragMode = .idle
    @State private var startBrightness: CGFloat = 1
    @State private var startVolume: Float = 0.5
    @State private var dragSeekTarget: Double = 0
    /// 关闭标志：纯本地状态，置位后立即隐藏全部 UI（LC 里封面关闭通道可能全部失效的最后保险）
    @State private var closed = false
    /// 视图是否已真正消失（onDisappear 置位）。用于 close() 的兜底重试判断 ——
    /// 旧实现先摘返回按钮再关闭，关闭失败就再也回不去（用户「想返回却不见了」的根因）。
    @State private var gone = false
    // 2026-09-28 钦点（TVBox 逻辑）：片头点一次记点→以后起播从记点开始；片尾记点→播到点自动跳结尾
    /// 窗口级返回按钮句柄（UIKit 层，LC 环境免疫 hit-testing 吞噬）
    // 50包：返回键并回控制层（topBar 内普通按钮），窗口级 WindowBackButton 停用——
    // 它靠异步抢窗口时机安装，「有的时候不在」；类文件保留（mark/filmLog 定义在此）。
    // 48包：居中三钮并回控制层（centerTransportRow），窗口级 WindowControlBar 停用——
    // 它与控制层显隐两条路，用户实测"暂停快进没了"即显隐对不上。类文件保留备回切。
    @State private var savedRate: Double = {
        // 设置页落地（2026-09-25）：默认倍速 = 播放器手动记忆 > 设置页「默认倍速」 > 1.0
        let remembered = UserDefaults.standard.double(forKey: "filmui.playerRate")
        if remembered > 0 { return remembered }
        let d = UserDefaults.standard.string(forKey: "settings.defaultRate").flatMap(Double.init) ?? 1.0
        return d > 0 ? d : 1.0
    }()

    public static let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    // 设置页落地（2026-09-25）：自动连播 / 后台播放由设置页接管
    @AppStorage("settings.autoNextEpisode") private var autoNextSetting = true
    @AppStorage("settings.backgroundPlay") private var backgroundPlay = true

    /// 后台继续播放：激活 playback 音频会话（UIBackgroundModes=audio 已在 project.yml 配置，
    /// 缺这步 = 会话不活跃，锁屏/切后台 AVPlayer 即停——此前后台播放失效的根因）。
    private func activateAudioSessionIfNeeded() {
        guard backgroundPlay else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    public init(item: FeedItem, startAtResume: Bool = false, startLine: Int = 0,
                extraLines: [URL] = [], extraSourceNames: [String] = [],
                onClose: (() -> Void)? = nil,
                episodeGroups: [(line: String, eps: [(index: Int, name: String)])] = [],
                onEpisodeChange: ((String) -> Void)? = nil) {
        self.item = item
        self.startAtResume = startAtResume
        self.onClose = onClose
        self.episodeGroups = episodeGroups
        self.onEpisodeChange = onEpisodeChange
        // ★ v78/v78.2：把「真正的线路块」交给播放模型当**切集范围 + 换源基准**
        //  （与选集面板同一份数据，不另算一套）。切集只在本块内 ±1；换源换到另一块的**同一集序号**。
        let epBlocks = Self.lineBlocks(from: episodeGroups)
        _model = StateObject(wrappedValue: PlayerViewModel(item: item, initialLine: startLine,
                                                           extraLines: extraLines,
                                                           extraSourceNames: extraSourceNames,
                                                           hasEpisodeList: !episodeGroups.isEmpty,
                                                           episodeLineBlocks: epBlocks))
    }

    /// ★ v78.2：把详情页「选集分组」切成**真正的线路块** —— 每块 = **一条播放线路的整季**。
    ///
    /// 为什么不能直接用 `episodeGroups`（旧 v78.1 写法）：面板按 `line.quality` 分组，
    /// 而**中台数据实测 `quality` 恒空**（16306 个多集条目里 `play.lines` 每条 = 一集、quality 全空）
    /// → 恒只有 1 组 → 一部剧的**多条线路会整季拼在同一组里**：
    /// ```
    /// 七武士    : 第1集…第11集 | 第02集 第03集…   ← 线路2 从这里重新开始
    /// 我的青春…  : 第1集…第6集  | 第2集 第3集…     ← 同样
    /// ```
    /// 唯一可靠的分线判据 = **集名里的序号回退**（1,2,3… 严格递增；一旦 `≤` 前一个 = 换了下一条线路）。
    /// 16306 个多集条目中有 1691 个（10.4%）是这种拼接结构。
    static func lineBlocks(from groups: [(line: String, eps: [(index: Int, name: String)])]) -> [[Int]] {
        var out: [[Int]] = []
        for g in groups {
            var cur: [Int] = []
            var last: Int? = nil
            for ep in g.eps {
                if let o = Self.episodeOrdinal(ep.name) {
                    if let l = last, o <= l, !cur.isEmpty {   // 序号回退 = 跨到了下一条线路的第 1 集
                        out.append(cur)
                        cur = []
                    }
                    last = o
                }
                cur.append(ep.index)                          // 无名集不打断判定（last 保持不变）
            }
            if !cur.isEmpty { out.append(cur) }
        }
        return out.filter { !$0.isEmpty }
    }

    /// 集名里的集序号（「第07集」→ 7、「第1集」→ 1、「EP12」→ 12）；无可解析数字 → nil。
    static func episodeOrdinal(_ name: String) -> Int? {
        guard let r = name.range(of: "[0-9]+", options: .regularExpression) else { return nil }
        return Int(name[r])
    }

    public var body: some View {
        if closed {
            // 关闭后的兜底：即使封面因容器环境关闭失败仍悬浮，也立即让出画面且不拦截触摸
            Color.clear.allowsHitTesting(false)
        } else {
            playerBody
        }
    }

    private var playerBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerContainerView(model: model, onTap: { loc, tapCount in
                // v24：这是**唯一**的触摸通道（SwiftUI 手势层已删，见上）。
                // 2026-10-01 手势提示：提示层允许触摸穿透（allowsHitTesting(false)），
                // 所以「点任意处关提示」也走这条通道 —— 关闭后本次点击**不再**顺带 toggle 控制层。
                if showGestureHint {
                    dismissGestureHint()
                    showControls = true
                    scheduleHide()
                    return
                }
                guard !locked else { return }   // 锁定时只认解锁按钮
                // v69d（2026-10-04 真机实测）：控制栏能出（UIKit 识别器通道）但**左上返回键点不动**
                // —— 返回键本体是 topBar 里的 SwiftUI Button，v24 把触摸通道挪到 UIKit 识别器后，
                // 它在 LC 全屏环境收不到触摸（50包注释「控制层里的按钮都点得动」的前提不成立）。
                // 修法＝控制层可见时，左上角 60x130pt 热区的单击直接触发 close()（与按钮同动作；
                // 控制层隐藏时左上角仍是普通 toggle，不会误关）。真机上 SwiftUI 按钮若正常，
                // 两路都进 close()，`closed` 幂等护栏兜住双触发。
                if tapCount == 1, showControls, loc.x < 60, loc.y < 130 {
                    close()
                    return
                }
                if tapCount == 2 {
                    doubleTapSeek(centerX: loc.x)
                } else {
                    tapScreen()
                }
            }, onLongPress: { began in
                guard !locked else { return }
                began ? boostBegan() : boostEnded()   // 长按加速
            }, onPan: { startLocation, translation, state in
                // v24：拖拽（亮度/音量/快进/下滑关闭/右缘切集）同样走 UIKit 通道。
                // 注意只认 changed/ended —— .began 位移≈0 会把 dragMode 锁成 .seek。
                guard !locked else { return }
                switch state {
                case 1: handleDragChanged(startLocation: startLocation, translation: translation)
                case 2: handleDragEnded(startLocation: startLocation, translation: translation)
                default: break
                }
            })
                .ignoresSafeArea()

            // v24 根修（2026-09-30 真机实测）：**删除全屏 SwiftUI 手势层**。
            // 旧层（aeb1aa2 引入）是视频的**兄弟视图**盖在上面 —— 命中测试会拦截触摸，
            // 下面 vc.view 上的 UIKit 识别器**永远收不到**；而 LC 又吞 SwiftUI 手势
            // → 两头全死 =「怎么点都不出控制层 / 返回锁屏全屏像消失」。单击/双击/长按/拖拽
            // 现在全部走 PlayerContainerView 的 UIKit 识别器（唯一能穿透 LC 的通道）。

            // 隐藏音量锚点：MPVolumeView 必须进入视图层级才能程序化调系统音量
            VolumeAnchorView()
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .allowsHitTesting(false)

            // 缓冲指示（网络慢/切线路时给出可感知反馈）
            // ★ v77：主人钦定文案口径「只需要写着加载中……」→ 与直播页统一为「加载中…」。
            //   本处本来就只有加载圈 + 文字投影（无底色/无边框），不涉及「黑框」问题。
            if model.isBuffering, !model.failed, !model.switchingLine {
                VStack(spacing: 10) {
                    ProgressView().tint(.white).controlSize(.large)
                    Text("加载中…").font(.footnote.weight(.medium)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.85), radius: 4, y: 1)
                }
                .padding(20)
            }

            // v13 音量提示条（用户钦点：按手机音量键能看见声音大小的条）
            // 爱腾优式：左侧竖向玻璃细条 + 喇叭图标；物理音量键与右半屏拖动共用。
            if let v = volumeHUDValue {
                VStack(spacing: 8) {
                    Image(systemName: (v <= 0.001 || isMuted) ? "speaker.slash.fill"
                                        : (v < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"))
                        .font(.system(size: 15)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 3)
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            Capsule().fill(.white.opacity(0.25))
                            Capsule().fill(.white).frame(height: geo.size.height * v)
                        }
                    }
                    .frame(width: 6, height: 140)
                }
                .padding(14)
                .playerGlass(cornerRadius: 999)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 22)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: volumeHUDValue)
                .allowsHitTesting(false)
            }

            // 2026-09-28 钦点：跳过片头不再浮在影片画面上（挡画面）——移到底栏功能排，见 bottomBar。

            // 下一集（片尾 90s 内浮现；与自动连播互为兜底）
            if showNextEpisode {
                Button { playNext() } label: {
                    Text("下一集 ▸").font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                        .contentShape(Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 18).padding(.bottom, 130)
            }

            // 2026-09-30 用户「还有那个锁屏应该在哪大小」：锁屏键从顶栏角落挪到
            // **屏幕左侧边缘、垂直居中**（爱优腾位置：横屏时左手拇指自然落点），
            // 锁定/解锁**同一个键原地切换**；锁定态下该键**不受控制层显隐影响**
            // —— 否则锁上以后控制层一隐藏就再也解不开（"锁死了"）。
            if locked {
                // 锁定态：解锁键**原地**（右侧垂直居中）切换，不换位置不乱跳
                lockControl
            } else if showControls {
                // 2026-10-01 主人「横竖屏锁还不一样 / 应该都放右侧」：
                // 锁屏键不再按方向分两套（横屏左中、竖屏右上），统一**右侧垂直居中**。
                lockControl
                topBar
                bottomBar
                // 48包（用户：「暂停快进怎么没了 要隐藏也没说不要暂停快进」）：
                // 爱腾优式——居中三钮是控制层的**一部分**，随控制层同显隐。
                // 旧实现是挂在系统窗口上的 UIKit 条，与控制层各走各的，显隐对不上=看起来"消失"。
                // 2026-09-30 用户「横屏你看看爱优腾怎么放的都什么按钮」：横屏的播放主控已并进
                // **底栏同一行**，居中这组再出现就是同一功能两处重复 → 仅竖屏保留。
                // ★ v78.3（主人 2026-10-05：「播放电视剧的时候我发现中间的暂停播放下一集上一集
                //   不见了只有底部还在」）——**回归根因之一**：
                //   旧条件是 `!model.failed`，而失败面板（下方 381 行）只在 `!isPlaying` 时才出现。
                //   于是「`failed == true` 但画面仍在走（timeControlStatus 还是 .playing）」这一档
                //   就成了黑区：**三钮整块消失、却没有任何失败提示** —— 主人看到的正是这个。
                //   而 `failed` 在本版本变得极易触发（见 `handlePlaybackFailure` 的 v78.2 判死），
                //   剧集源（量子资源 fail×18 / 电影天堂 fail×7，实机样本为证）一抖就命中。
                //   正解：**判据与失败面板完全对齐** —— 面板真显示时才收起三钮（避免与面板叠字），
                //   其余情况（含 failed 但画面还在走）三钮一律保留 —— 用户永远找得到「暂停/下一集」。
                if !(model.failed && !model.isPlaying) && !isLandscape { centerTransportRow }
            }

            // 倍速档位条（2026-09-28 用户钦点：倍速要有进度条/档位条）
            if showRateSelector {
                rateSelectorOverlay
            }

            // 音量滑条（2026-09-28 用户钦点：音量要有进度条）
            if showVolumeSlider {
                volumeSliderOverlay
            }

            // 双击快进/快退：对应半屏的圆形涟漪（爱优腾同款，落点与方向一一对应）
            seekRippleView
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: seekRipple)

            if let toast = seekToast {
                Text(toast)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 4, y: 1)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    // 2026-09-30：轻提示也不再"裸字浮在画面上" —— 与其余浮层同一套玻璃
                    .playerGlass(cornerRadius: 14, tint: 0.14)
            }

            if model.failed, !model.isPlaying { failureOverlay }   // 46包硬门禁：画面还在走就不许弹失败

            // 首次使用手势提示（放最上层；触摸穿透到底层 UIKit 识别器，见 overlay 内注释）
            if showGestureHint { gestureHintOverlay }
            if model.switchingLine {
                // 2026-09-23（用户：「暂停以后超大个黑框基本满屏了」+「那个框的闪动不正常一闪一闪的」）：
                // 原写法 = LoadingView 本身撑满全屏 + 再叠一层满屏黑 0.6 →
                // 每次切线路整屏黑一下；线路反复切换时就是"一闪一闪的大黑框"。
                // 改成**小卡片**提示，不再染黑整屏（大牌切线路也就一个居中提示）。
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("切换线路中…").font(.footnote).foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.7), radius: 3)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .playerGlass(cornerRadius: 14, tint: 0.18)
            }
        }
        // 2026-10-01 真机取证（用户截图 + 注入触摸实测）根修「按钮溢出/不明物」：
        //   症状：竖屏里出现「横屏那一整行」底栏 —— 顶栏分享被挤出屏幕右边缘（只剩 1px）、
        //   锁屏键跑到**左边缘垂直居中**且左半出屏、竖屏该有的两行形态完全不出现；
        //   底栏里进度条被压成 0 宽 → 只留一颗白色滑块球（用户问的"选集前面那个白圆圈"），
        //   当前时间/总时长文字被挤没。实测像素：返回键字形起点 x=0，分享最后一像素 x=1289/1290。
        //   真因：`setLandscape()` 是**乐观赋值** —— 先把 `isLandscape` 置 true，再向系统
        //   `requestGeometryUpdate(.landscapeRight)`。在 LiveContainer 里这条旋转请求不生效
        //   （屏幕始终 1290×2796 竖屏），于是「状态=横屏 / 屏幕=竖屏」→ 横屏排版塞进竖屏窗口。
        //   正解：**排版一律跟随容器真实宽高**（宽>高才算横屏）。旋转真成功时窗口会变宽 →
        //   自动切到横屏排法（行为不变）；旋转被限制时自动回落竖屏排法（不再溢出）。
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { syncLandscape(g.size) }
                    .onChange(of: g.size) { syncLandscape($0) }
            }
        )
        // 2026-10-01 主人钦定「跟着海报」：取这部片的海报主色（与 DetailView L140 同写法）。
        // HeroTintStore 内部有 cache —— 首页/详情页进来看过这张海报就已经算好，这里直接命中，不再下载。
        .task {
            palette = await HeroTintStore.shared.palette(for: item.poster?.url ?? item.backdrop?.url)
        }
        .onAppear {
            model.start(resume: startAtResume)
            // ★ v78：起播即把**当前这一集**回传给详情页（主人：「我选了第几集…却不显示」）。
            //   详情页的 `lastEpName` 因此恒等于真正在播的那一集 —— 从播放器返回后，
            //   选集格的高亮与表头的「当前：第N集」不会停在旧值（续播/自动换源也自动纠正）。
            if let e = currentEpisode { onEpisodeChange?(e.name) }
            if savedRate != 1.0 { model.setRate(savedRate) }
            sliderVolume = Double(PlayerVolumeController.current())
            // 2026-10-01 主人钦定（「锁屏时正常不是应该不在切换横竖屏吗」）：
            // 进播放**不再无条件强转横屏** —— 以前 onAppear 一律 setLandscape(true)，
            // requestGeometryUpdate 会连系统方向锁定一起顶掉（用户锁了屏照样被转成横屏）。
            // 现在：进来保持当前方向；想横屏 = 自己点底栏「全屏」（主动行为，与锁定无关）。
            scheduleHide()
            // 首次进入播放 → 弹一次手势说明（9 秒自动收，点任意处立刻收）
            if !gestureHintShown {
                showGestureHint = true
                hideTask?.cancel()
                gestureHintTask?.cancel()
                gestureHintTask = Task {
                    try? await Task.sleep(nanoseconds: 9_000_000_000)
                    if !Task.isCancelled {
                        withAnimation(.easeOut(duration: 0.25)) {
                            showGestureHint = false
                            gestureHintShown = true
                        }
                    }
                }
            }
            activateAudioSessionIfNeeded()
            // v13 音量提示条：KVO 监听系统音量（物理音量键）——MPVolumeView 锚点抑制了系统 HUD
            // 2026-10-01 根修（主人：「音量键不流畅且不同步」「最小不显示静音」「你看爱奇艺优酷腾讯这些」）：
            // 旧实现把 KVO 的 `change.newValue` **丢掉**，改回 `PlayerVolumeController.current()`
            // ——而那条路优先读 MPVolumeView 内置的 UISlider.value，**它的更新滞后于系统音量**
            // （KVO 先到、slider 后刷）。于是每次读数都停在**上一格**：
            //   ① 端上看着「按了键条子才动一下 / 跟不上手」= 不同步、不流畅；
            //   ② 一直按到最小，读数也停在**倒数第二格**，`v <= 0.001` 永远不成立
            //      → 静音图标（speaker.slash）永远不出现 = 「最小不显示静音」。
            // 正解：直接用系统在这次变化里给的真值 newValue —— 这就是音量本身，无需回读。
            volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { _, change in
                guard let v = change.newValue else { return }
                Task { @MainActor in showVolumeHUD(Double(v)) }
            }
            // 46包：撤掉「Build 20260922-xx」闪现——小白用户看不懂还截图问「这是啥玩意」；
            // 包版本核验走 LC 内二进制探针，不再打扰播放画面。
        }
        .onDisappear {
            gone = true
            model.stop()
            // 2026-10-01 四修：退出播放**必须先解方向锁**，否则 AppDelegate 一直照锁回答
            // （旧写法 locked=true 时 setLandscape 直接 return，锁会跟着带回主界面）。
            OrientationLock.shared.set(nil)
            locked = false
            setLandscape(false)
            volumeObserver?.invalidate()
            volumeObserver = nil
            volumeHUDHideTask?.cancel()
        }
        .onChange(of: scenePhase) { _, ph in
            // ★ v78.4（续播全链的另一半）：旧实现只在「正常退出播放器」（onDisappear→stop）时写进度，
            //   直接上划杀掉 App、或切后台太久被系统回收 → 这一集看到的进度整段丢失，
            //   下次进来只能续到更早的点。这里在**离开前台时**先落一次盘（只写历史，不动播放状态）。
            if ph == .background || ph == .inactive { model.flushProgress() }
        }
        .onChange(of: model.failed) { _ in
            // 失败面板出现时控件层保持可见（重试按钮在面板里）；居中三钮由
            // `if !model.failed` 自行隐藏，不会叠在失败卡片上。
            showControls = true
        }
        .onChange(of: model.isPlaying) { playing in
            // 48包：从居中按钮暂停/恢复后，控件层照大牌规律走——
            // 恢复播放 → 3.4s 自动隐藏；暂停 → 取消倒计时保持常显（能看清继续按钮）
            if playing {
                if showControls { scheduleHide() }
            } else {
                hideTask?.cancel()
            }
        }
    }

    // MARK: - 居中控制行（2026-09-28 钦定换位：剧集=上一集/暂停/下一集；10s 快退快进移到底栏）
    // 电影没有上一集/下一集概念 → 两侧置灰（**不换形态**，±10s 永远只在底栏）。

    /// 无底框：白色图标+投影（与 46 包去黑框同一套视觉）；放在 ZStack 最顶层保证可点
    /// （控制层子视图都在手势层之后，命中优先；同层里它排最后=最优先）。
    private var centerTransportRow: some View {
        HStack(spacing: 56) {
            // 统一布局（2026-09-28 用户再确认原话：「中间放上一集/暂停播放/下一集，下面放快进快退10S」）：
            // 不因电影/剧集切形态——电影无集可切 → 两侧**置灰不可点**（不是把 ±10s 挪回中间）。
            Button { playPrev() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(canPlayPrev ? 1 : 0.35))
                    .shadow(color: .black.opacity(0.8), radius: 8, y: 2)
                    .frame(width: 58, height: 58)
                    .contentShape(Rectangle())
            }
            .disabled(!canPlayPrev)
            .accessibilityLabel("上一集")
            Button { model.togglePlayPause() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 10, y: 2)
                    .frame(width: 84, height: 84)
                    .contentShape(Rectangle())
            }
            Button { playNext() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(model.hasNextEpisode ? 1 : 0.35))
                    .shadow(color: .black.opacity(0.8), radius: 8, y: 2)
                    .frame(width: 58, height: 58)
                    .contentShape(Rectangle())
            }
            .disabled(!model.hasNextEpisode)
            .accessibilityLabel("下一集")
        }
    }

    /// 居中左钮可点条件（有选集列表 且 本大源内还有上一集）；电影恒 false → 置灰。
    private var canPlayPrev: Bool {
        model.hasEpisodeList && model.prevEpisodeLine != nil
    }

    // MARK: - 顶栏

    private var topBar: some View {
        VStack {
            HStack(spacing: 10) {
                // 50包（用户：「没有返回键 消失了」「返回按钮也应该是跟你播放那些按钮是一个理论的」）：
                // 返回键改成控制层内的普通按钮 —— 和居中三钮/选集/倍速/换源同层同显隐。
                // 旧实现是挂在系统窗口上的 UIKit 浮层（WindowBackButton），进窗口时机对不上就
                // 「有的时候不在」（源码注释里早记了这个毛病，24×50ms 重试只是缓解不是根治）；
                // 而控制层里的按钮本机实测都点得动 → 同一套理论最可靠。
                Button { close() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("返回")
                // ★ v78：标题右拼当前集名（剧集才拼；电影/无选集时 = 原标题，逐字不变）。
                Text(episodeTitleLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                // 2026-10-01：顶栏的锁屏键**删除** —— 锁键已统一到右侧边缘垂直居中
                //（横竖屏同一个位置，见 `lockControl`），顶栏再留一个就是「同一功能两处」。
                // 2026-09-30 用户「你好好看看爱优腾怎么做的」：
                // 投屏 / 分享 放**右上角**（爱优腾同款），底栏只留与播放直接相关的键。
                RoutePickerView().frame(width: 30, height: 32)
                Button { sharePlayback(); hideTask?.cancel() } label: {
                    Image(systemName: "square.and.arrow.up").font(.body)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("分享")
                // 2026-09-30 用户「还有那个锁屏应该在哪大小」：顶栏这个锁键已**移除** ——
                // 爱优腾把锁屏放在**左侧边缘垂直居中**（见 `lockControl`），不在右上角。
                // 顶栏只留 返回 / 标题 / 投屏 / 分享 四件。
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            Spacer()
        }
        // 2026-09-30 用户报「竖屏返回看不到了 锁屏也看不到」：
        // 顶栏此前只吃 ZStack 的隐式安全区缩进；竖屏顶部是灵动岛/刘海，一旦缩进不足
        // 整条顶栏就被推进不可见区（返回键、锁屏键首当其冲）。这里显式再按安全区内缩一层，
        // 横竖屏都稳（.safeAreaPadding 需 iOS 17+，本工程 deploymentTarget = 17.0）。
        .safeAreaPadding(.top, 4)
        // 54包（用户钦定）：顶/底渐变整条删除 —— 96+120pt 在横屏上叠成
        // "整屏蒙一层黑纱"。文字/按钮可读性由投影（shadow）保证，渐变不再保留。
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Spacer()
            // 2026-09-30 用户「横屏你看看爱优腾怎么放的都什么按钮」：
            // 横屏与竖屏**不是同一种排法** → 按方向分支（爱优腾横屏是一整行，竖屏是"进度 + 键排"两行）。
            if isLandscape {
                landscapeBar
            } else {
            // 进度条
            HStack(spacing: 8) {
                Text(Self.format(model.currentTime)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                Slider(
                    value: Binding(
                        get: { scrubbing ? scrubValue : min(model.currentTime, max(model.duration, 0.1)) },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(model.duration, 0.1)
                ) { editing in
                    scrubbing = editing
                    if !editing { model.seek(to: scrubValue) }
                    scheduleHide()
                }
                .tint(.white)
                Text(Self.format(model.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 14)

            // 2026-09-30 用户：「快进快退不是在下面的吗？上面也不用啊 拖动不就是快进吗？」
            // → 底栏那组 ±10s 确实多余：①拖进度条就是快进；②双击屏幕左右两侧已经是 ±10s
            //   （doubleTapSeek 本来就挂在双击上）。播放主控交给**居中三钮**（上一集/暂停/下一集），
            //   底栏只管功能键 + 全屏，职责不再重叠。
            // 顺带根除「竖屏按钮溢出屏幕」：去掉 ±10s 后底栏只剩 8 个控件 ≈330pt，
            // 竖屏可用宽 398pt 一行就放得下 —— 不再需要拆两行（也不用按方向分支了）。
            // 2026-09-30 用户：「下面有那么多地方干嘛堆在一起分散开不好看吗？」
            // 旧形态 = `utilityButtons` + `fullscreenButton` **两个子视图各占一份**，
            // 靠 spacing 挤在正中间，两侧一大片留白。改成：所有底栏键放进**同一个 HStack**，
            // 每个键自己 `maxWidth: .infinity` → 自动**均分整行宽度**，横向铺开、视觉齐整。
            utilityButtons
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        // 54包：底渐变同步删除（同顶渐变，黑纱根因之一）。
        .sheet(isPresented: $showLinePanel) { linePanel }
        // 2026-09-30 用户报「选集打不开」根因：`episodePanel` 早就写好了，但**主体里从没渲染过**
        // （只有 `showEpisodePanel = true`，没有任何 if/sheet 消费这个标志）→ 点了什么都不出。
        // 正解＝与线路面板同款，挂一张 sheet 消费该标志。
        .sheet(isPresented: $showEpisodePanel) { episodePanel }
    }

    /// 横屏底栏（2026-09-30 用户「横屏你看看爱优腾怎么放的都什么按钮」）。
    ///
    /// 爱优腾横屏的排法＝**一整行**：最左是播放主控（上一集 / 播放暂停 / 下一集），
    /// 接着当前时间 → 进度条（吃掉剩余宽度）→ 总时长，最右一排功能键（选集 / 倍速 /
    /// 换源 / 画面 / 静音 / 全屏）。
    /// 竖屏那套「居中三钮 + 底栏再一排键」在横屏下会**同一功能出现两处**，所以横屏用本行、
    /// 并把 `centerTransportRow` 关掉（见 `playerBody`）。
    private var landscapeBar: some View {
        HStack(spacing: 14) {
            // ── 左：播放主控 ──
            compactIcon("backward.end.fill", label: "上一集", enabled: canPlayPrev) { playPrev() }
            compactIcon(model.isPlaying ? "pause.fill" : "play.fill",
                        label: model.isPlaying ? "暂停" : "播放") {
                model.togglePlayPause()
            }
            compactIcon("forward.end.fill", label: "下一集", enabled: model.hasNextEpisode) { playNext() }

            // ── 中：进度 ──
            Text(Self.format(model.currentTime))
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : min(model.currentTime, max(model.duration, 0.1)) },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(model.duration, 0.1)
            ) { editing in
                scrubbing = editing
                if !editing { model.seek(to: scrubValue) }
                scheduleHide()
            }
            .tint(.white)
            Text(Self.format(model.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))

            // ── 右：功能键 ──
            if episodeCount > 1 {
                // v78：选集键带「当前第几集」角标（主人：「选集按钮上却不显示」）。
                compactIcon("list.bullet.rectangle",
                            label: "选集 \(currentEpisodeLabel)",
                            badge: currentEpisode?.ordinal) {
                    showEpisodePanel = true
                    hideTask?.cancel()
                }
            }
            compactIcon("speedometer", label: "倍速 \(rateLabel)") {
                showRateSelector.toggle()
                hideTask?.cancel()
            }
            if model.sourceGroups.count > 1 {
                compactIcon("arrow.triangle.2.circlepath",
                            label: "换源 \(model.currentSourceIndex + 1)/\(model.sourceGroups.count)") {
                    // v67 换源分层：一键换的是**大源**（CMS 源站），进新大源自动用它的第一条小源
                    let target = model.switchToNextSource() ?? ""
                    // v69：toast 不露源站名，只报「源N」（N = 质量顺位）
                    showSeekToast(target.isEmpty ? "已换源" : "已切到源\(model.currentSourceIndex + 1)")
                    scheduleHide()
                }
            }
            compactIcon("aspectratio", label: "画面比例：\(model.aspect.shortTitle)") { cycleAspect() }
            compactMuteButton
            compactIcon("arrow.down.right.and.arrow.up.left", label: "退出全屏") {
                setLandscape(false)
                showSeekToast("已切到竖屏")
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    /// 横屏底栏的紧凑图标键：**定宽 38pt、不参与均分**（横屏键多，均分会把每个键压得过窄）。
    /// `enabled == false` 时置灰不可点（电影无集可切时上一集/下一集就是灰的）。
    /// `badge`（v78）：图标右上角的小数字角标 —— 选集键拿它显示「当前第几集」。
    private func compactIcon(_ systemName: String, label: String, enabled: Bool = true,
                             badge: Int? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
                    .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                if let b = badge { iconBadge(b) }
            }
            .frame(width: 38, height: 36)
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// 图标角标（v78 主人：「我选了第几集…选集按钮上却不显示」）——贴在图标右上方的小胶囊。
    /// 只改视觉，不动任何点击区域与交互。
    private func iconBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 3.5)
            .padding(.vertical, 0.5)
            .background(Capsule().fill(Color.accentColor))
            .overlay(Capsule().stroke(.black.opacity(0.35), lineWidth: 0.5))
            .fixedSize()
            .offset(x: 9, y: -6)
    }

    /// 横屏底栏的静音键（紧凑版；长按仍是呼出音量滑条）。
    private var compactMuteButton: some View {
        Button { toggleMute() } label: {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                .frame(width: 38, height: 36)
                .contentShape(Rectangle())
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            sliderVolume = Double(PlayerVolumeController.current())
            showVolumeSlider = true
            showRateSelector = false
            hideTask?.cancel()
        })
        .accessibilityLabel(isMuted ? "取消静音" : "静音")
    }

    // MARK: - 底栏控件分组（横竖屏共用）

    // 2026-09-30 用户钦点删除：底栏「±10s 主控组」(transportButtons) 已移除 ——
    // 用户原话「拖动不就是快进吗」。快进/快退仍有两条入口：拖进度条 + 双击屏幕左右两侧
    // （doubleTapSeek）。播放主控统一由居中三钮（上一集/暂停/下一集）负责。

    /// 底栏功能键（**横向均分整行**）。选集 / 倍速 / 换源 / 画面比例 / 静音 / 全屏。
    /// 2026-09-30 用户钦点「播放器按钮化还在显示文字」：一律纯图标，语义走 accessibilityLabel。
    /// 2026-09-30 用户「下面有那么多地方干嘛堆在一起」：全部键同处一个 HStack，
    /// 每个键 `maxWidth: .infinity` → 自动按可用宽度**等分**，铺开整行。
    @ViewBuilder private var utilityButtons: some View {
        HStack(spacing: 0) {
            if episodeCount > 1 {
                // 大牌式播放中直接切集：不用退回详情页
                // v78：带当前集角标 + 无障碍标签带集名。
                barIcon("list.bullet.rectangle",
                        label: "选集 \(currentEpisodeLabel)",
                        badge: currentEpisode?.ordinal) {
                    showEpisodePanel = true
                    hideTask?.cancel()
                }
            }
            // 倍速：图标化（当前档位由档位条高亮 + 轻提示给出，不再用文字当按钮）
            barIcon("speedometer", label: "倍速 \(rateLabel)") {
                showRateSelector.toggle()
                hideTask?.cancel()
            }
            // 跳过片头/片尾不再进底栏（2026-09-28：竖屏底栏按钮太多会堆叠）。
            if model.sourceGroups.count > 1 {
                // 大牌式一键换源（v67 分层）：换的是**大源**（CMS 源站），保留进度，不弹列表
                barIcon("arrow.triangle.2.circlepath",
                        label: "换源 \(model.currentSourceIndex + 1)/\(model.sourceGroups.count)") {
                    let target = model.switchToNextSource() ?? ""
                    // v69：toast 不露源站名，只报「源N」（N = 质量顺位）
                    showSeekToast(target.isEmpty ? "已换源" : "已切到源\(model.currentSourceIndex + 1)")
                    scheduleHide()
                }
            }
            // 51包：点一下循环换模式，右下角飘一条轻提示，不弹面板、不挡画面。
            barIcon("aspectratio", label: "画面比例：\(model.aspect.shortTitle)") {
                cycleAspect()
            }
            // 2026-09-30 用户钦点「静音按钮怎么变成了音量控制」：
            // 喇叭图标恢复为**纯静音开关**；音量滑条改为**长按**喇叭呼出。
            Button { toggleMute() } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                sliderVolume = Double(PlayerVolumeController.current())
                showVolumeSlider = true
                showRateSelector = false
                hideTask?.cancel()
            })
            .accessibilityLabel(isMuted ? "取消静音" : "静音")
            // 2026-09-30 用户「你好好看看爱优腾怎么做的」：投屏 / 分享 已移到**右上角**（topBar），
            // 底栏只留与播放直接相关的键。全屏键与功能键同排均分（原先单独一份挤在边上）。
            fullscreenButton
        }
    }

    /// 全屏 / 退出全屏（腾讯式四角箭头：外扩=进入，内收=退出）。
    @ViewBuilder private var fullscreenButton: some View {
        Button {
            setLandscape(!isLandscape)
            // 2026-10-01：文案不再"预报"，改为**等旋转真正落地再读实际状态**——
            // LiveContainer 里这条旋转请求会被宿主挡掉，旧写法会弹"已切到横屏"却还是竖屏（说谎）。
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                showSeekToast(isLandscape ? "已切到横屏全屏" : "本机旋转被限制，未能切横屏")
                scheduleHide()
            }
        } label: {
            Image(systemName: isLandscape ? "arrow.down.right.and.arrow.up.left"
                                          : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(isLandscape ? "退出全屏" : "全屏")
    }


    private var rateLabel: String {
        model.rate == 1.0 ? "倍速" : String(format: "%.1fx", model.rate)
    }

    /// 底栏图标按钮（2026-09-30 用户钦点「播放器按钮化」：底栏一律纯图标，不再出文字）。
    /// 双重 `maxWidth: .infinity`：外层让**按钮**吃掉均分到的一份、内层让**点击区**铺满整份
    /// （只给内层会出现"看着分散、实际只有图标能点"）。
    /// `badge`（v78）：同 `compactIcon` —— 图标右上角数字角标（选集键显示当前第几集）。
    /// 角标挂在**图标本身上**（ZStack 只包住图标），所以均分整行时它仍紧贴图标、不会被甩到行尾。
    private func barIcon(_ systemName: String, label: String, badge: Int? = nil,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                if let b = badge { iconBadge(b) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
    }

    /// 静音开关（只动 AVPlayer.isMuted，不碰系统音量）——底栏喇叭图标与音量条左侧共用。
    private func toggleMute() {
        isMuted.toggle()
        model.player?.isMuted = isMuted
        showSeekToast(isMuted ? "已静音" : "已取消静音")
    }

    /// 选集总集数（跨线路取最大组）。
    private var episodeCount: Int {
        episodeGroups.map { $0.eps.count }.max() ?? 0
    }

    // MARK: - v78 当前集回显（主人 2026-10-05：「我看电视剧 我选了第几集 但是选集按钮上却不显示
    //        播放时播放器上也看不到 播放器上的剧集表里也看不到是第几集！这个应该是所有影视类APP都有的吧！」）

    /// 当前正在播的那一集（下标 / 集名 / 在该线路里的序号）。
    ///
    /// 判据 = `model.currentLine`（= `allLines` 下标）在选集分组里按 `ep.index` 反查——
    /// 与选集面板高亮用的是**同一个** `ep.index`，所以不会出现「面板高亮 A、按钮显示 B」两处打架。
    /// 重建（换源/切集/自动容灾）都只是读 `model.currentLine`，**不新增任何状态**、零副作用。
    private var currentEpisode: (index: Int, name: String, ordinal: Int)? {
        for g in episodeGroups {
            if let i = g.eps.firstIndex(where: { $0.index == model.currentLine }) {
                return (g.eps[i].index, g.eps[i].name, i + 1)
            }
        }
        // ★ v78.2：聚合源上的集**不在** `episodeGroups` 里（面板只含片源自带线路的集）——
        //   回落到「线路块内位置」，同样给出「第N集」；否则这些集在顶栏标题 / 选集键角标 /
        //   面板表头全是空白（用户换了源之后就看不到自己在第几集）。
        if let p = model.currentBlockPos {
            return (model.currentLine, "第\(p + 1)集", p + 1)
        }
        return nil
    }

    /// 当前集名（无选集 → 空串，用于无障碍标签拼接）。
    private var currentEpisodeLabel: String {
        currentEpisode?.name ?? ""
    }

    /// 顶栏标题：剧集拼上当前集名；电影 / 无选集时**逐字不变**（= `item.title`，零回归）。
    private var episodeTitleLine: String {
        guard let e = currentEpisode else { return item.title }
        return "\(item.title) · \(e.name)"
    }

    /// 片尾 90s 内且还有下一集 → 浮现「下一集」（自动连播的手动兜底）。
    private var showNextEpisode: Bool {
        model.hasEpisodeList
            && model.duration > 0
            && model.nextEpisodeLine != nil
            && model.duration - model.currentTime < 90
            && model.duration - model.currentTime > 0
    }

    /// 倍速档位条（2026-09-28 用户钦点：倍速要有进度条/档位条）。
    /// 爱腾优同款：底部浮出一排档位胶囊，当前档位高亮，点选即生效。
    private var rateSelectorOverlay: some View {
        VStack(spacing: 8) {
            Text("倍速").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 8) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    let selected = abs(model.rate - r) < 0.01
                    Button {
                        model.setRate(r)
                        UserDefaults.standard.set(r, forKey: "filmui.playerRate")
                        showRateSelector = false
                        scheduleHide()
                    } label: {
                        Text(r == 1.0 ? "正常" : String(format: "%.1fx", r))
                            .font(.footnote.weight(selected ? .bold : .regular))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selected ? .white.opacity(0.25) : .clear, in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .playerGlass(cornerRadius: 16, palette: palette)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 78)
    }

    /// 音量横向滑条（2026-09-28 用户钦点：音量要有进度条）。
    /// 底部浮出横向 Slider + 静音切换，拖动时同步系统音量与左侧竖向 HUD。
    private var volumeSliderOverlay: some View {
        HStack(spacing: 12) {
            Button {
                isMuted.toggle()
                model.player?.isMuted = isMuted
                showSeekToast(isMuted ? "已静音" : "已取消静音")
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            Slider(value: $sliderVolume, in: 0...1) { _ in
                PlayerVolumeController.set(Float(sliderVolume))
                showVolumeHUD(sliderVolume)
            }
            .tint(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .playerGlass(cornerRadius: 16, palette: palette)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 40)
        .padding(.bottom, 78)
    }

    /// 画面比例循环切换（51包，大牌做法）：自适应 → 铺满 → 拉伸 → 自适应…
    /// 点一下换一个模式并飘轻提示，不弹面板（用户：「正常不就是点一下换一个模式吗」）。
    private func cycleAspect() {
        let all = AspectMode.allCases
        let next = all[(all.firstIndex(of: model.aspect).map { $0 + 1 } ?? 0) % all.count]
        model.setAspect(next)
        showSeekToast("画面：\(next.shortTitle)")
        scheduleHide()
    }

    private func playNext() {
        // ★ v78：走 `nextEpisodeLine`（本大源组内下一集），不再用 `allLines.index(after:)`——
        //   后者在主源最后一集会跨进下一个聚合源的第 1 集（主人：「点下一集直接回到了第一集」）。
        guard let next = model.nextEpisodeLine else {
            showSeekToast("已是最后一集")
            return
        }
        model.playEpisode(next)
        if let name = episodeName(at: next) {
            onEpisodeChange?(name)
            showSeekToast("正在播放：\(name)")
        } else {
            showSeekToast("下一集")
        }
        scheduleHide()
    }

    /// 2026-09-28 钦点：居中三钮换位后补上一集（与 playNext 对称）。
    private func playPrev() {
        guard let prev = model.prevEpisodeLine else {
            showSeekToast("已是第一集")
            return
        }
        model.playEpisode(prev)
        if let name = episodeName(at: prev) {
            onEpisodeChange?(name)
            showSeekToast("正在播放：\(name)")
        } else {
            showSeekToast("上一集")
        }
        scheduleHide()
    }

    /// 按线路下标找集名（选集面板/切集提示共用）。
    /// v78.2：面板里没有的集（= 聚合源上的集）回落到「线路块内位置」→ 提示里也能报出「第N集」。
    private func episodeName(at index: Int) -> String? {
        for g in episodeGroups {
            if let ep = g.eps.first(where: { $0.index == index }) { return ep.name }
        }
        return model.ordinalLabel(forLine: index)
    }

    /// 选集面板（大牌式：分组 chips + 网格；当前集高亮）。
    private var episodePanel: some View {
        // 2026-09-30 用户：「我指的是集数整个面板大小 不是1 2 3那个 是 123底下那个面板」。
        // 旧实现 ＝ NavigationStack + .medium（≈半屏），导航栏那行还白吃 ~50pt 高度，
        // 叠起来就是一整块"占了半个屏幕的黑板"。改法：
        //   ① 去掉导航栏，换成一行紧凑表头（标题 + 关闭），省下约 50pt；
        //   ② 初始高度由 .medium(≈0.5) 收到 .fraction(0.38)，需要时仍可上拖到 .large。
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("选集").font(.headline)
                Text("共 \(episodeCount) 集").font(.caption).foregroundStyle(.secondary)
                // v78（主人：「播放器上的剧集表里也看不到是第几集」）：表头直接写「正在播放 第N集」。
                if let e = currentEpisode {
                    Text("正在播放 \(e.name)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button { showEpisodePanel = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 34)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // v78：面板一打开就**滚到当前集**——旧实现停在顶部，40 集里正在播第 30 集时
            // 高亮格在屏外，用户体感就是「看不到是第几集」（主人本次反馈的第三条）。
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(episodeGroups.enumerated()), id: \.offset) { _, g in
                        VStack(alignment: .leading, spacing: 10) {
                            if episodeGroups.count > 1 {
                                Text("线路：\(g.line)").font(.footnote.bold())
                                    .foregroundStyle(.secondary)
                            }
                            // 2026-09-30 用户：「选集里面多少集多大框好不好 明明一半大小就够弄那么大」
                            // 旧参数 minimum: 64 在竖屏 430pt 上只排 6 列、每格 ≈60pt 宽（内容常只有「1」「2」），
                            // 空得离谱。改 minimum: 34（每行 ≈11 格）、纵向内边距 9→7、字号 caption2、
                            // 长集名自动缩字 —— 密度翻倍且不挤。
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], spacing: 6) {
                                ForEach(g.eps, id: \.index) { ep in
                                    Button {
                                        showEpisodePanel = false
                                        // 2026-09-30 用户「面板…点不上」：原有一句
                                        // `guard ep.index != model.currentLine else { return }`，
                                        // 只要点到的正是**当前正在播的那条**就**静默返回**（面板关了、
                                        // 屏幕没任何动静）→ 体感就是"点不上"。改为照常重播并给提示，
                                        // 点哪一集都有明确反馈。
                                        model.playEpisode(ep.index)
                                        onEpisodeChange?(ep.name)
                                        showSeekToast("正在播放：\(ep.name)")
                                        scheduleHide()
                                    } label: {
                                        Text(ep.name)
                                            .font(.caption2.weight(.medium))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.75)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 7)
                                            // 2026-09-30 用户：「全局都是毛玻璃为什么要用黑框」。
                                            // 未选中格原用 systemGray6 —— 不透明实心灰，在毛玻璃面板上
                                            // 就是一块块"实心方块"（深色态下尤其像黑框）。改成白色低透明，
                                            // 让面板材质透上来，与播放器其余浮层同一套语言。
                                            .background(model.currentLine == ep.index
                                                        ? Color.white.opacity(0.30)
                                                        : Color.white.opacity(0.10),
                                                        in: RoundedRectangle(cornerRadius: 7))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 7)
                                                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                                            )
                                            .foregroundStyle(model.currentLine == ep.index
                                                             ? Color.accentColor : .primary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                // 2026-09-23 抖音式切集的可发现性：不写提示没人知道右滑能换集
                Text("提示：在播放画面**右侧边缘**竖滑 —— 上滑看下一集 / 下滑看上一集")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
                // v78：面板一开就滚到当前集 —— 旧实现停在顶部，正在播第 30 集时高亮格在屏外，
                //   用户体感就是「看不到是第几集」（主人本次第三条反馈）。放到下一轮 runloop，
                //   等 LazyVGrid 真把格子建出来再滚，避免滚到空处。
                .onAppear {
                    guard let e = currentEpisode else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(e.index, anchor: .center)
                        }
                    }
                }
            }
        }
        // 2026-09-30 用户：「整个面板大小…明明一半大小就够弄那么大」→ 初始只占 38% 屏高
        .presentationDetents([.fraction(0.38), .large])
        // 2026-09-30 用户：「选集面板也用了黑框」「我要的是毛玻璃」。
        // 面板自身没写黑底 —— 是播放器外层强制 `colorScheme: .dark`，sheet 就跟着吃系统深色底
        // （看起来就是一块死黑）。这里显式换成毛玻璃，后面的画面能透上来，与播放器其余浮层一致。
        // 2026-10-01 用户「把选集那个也弄了」→ 主人再钦定「跟着海报」：
        // 底色不再挂材质（材质会抽干颜色），改叠这部片的海报主色 `palette.deep`（跟详情页同色源）。
        .glassSheet(palette: palette)
    }

    // 52包：原「播放倍速」面板整块删除 —— 用户「倍数也是进菜单的！！！！」
    // → 与画面比例同款：底栏点一下循环换档（cycleRate），不弹菜单、不挡画面。

    /// 倍速循环切换（52包，大牌做法）：正常 → 1.25 → 1.5 → 2.0 → 0.75 → 正常…
    /// 按钮自身就是当前档位；点一下换下一档 + 右下角轻提示。
    private func cycleRate() {
        let all = Self.rates
        let idx = all.firstIndex { abs($0 - model.rate) < 0.01 } ?? all.firstIndex(of: 1.0) ?? 0
        let next = all[(idx + 1) % all.count]
        savedRate = next
        UserDefaults.standard.set(next, forKey: "filmui.playerRate")
        model.setRate(next)
        showSeekToast(next == 1.0 ? "倍速：正常" : String(format: "倍速：%.2gx", next))
        scheduleHide()
    }

    // 51包：原「画面比例」面板整块删除 —— 用户「正常不就是点一下换一个模式吗…还弹出个菜单
    // 满屏都挡死了」→ 改底栏循环切换（cycleAspect），不再有面板与 sheet。


    private var linePanel: some View {
        // 同选集面板：① 去掉 NavigationStack 大标题栏 → 一行紧凑表头；② 初始高度收到 34%；
        // ③ 毛玻璃（不再是一块死黑）。
        VStack(spacing: 0) {
            HStack {
                Text("切换线路").font(.headline)
                Spacer()
                Button { showLinePanel = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 34)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            lineList
        }
        .presentationDetents([.fraction(0.34), .large])
        // 与选集面板同一档：不挂材质 + 叠海报主色（2026-10-01 主人钦定「跟着海报」）。
        .glassSheet(palette: palette)
    }

    private var lineList: some View {
        // v67 换源分层：面板按**大源**分组（组头 = 源站名），组内列出该源的全部小源——
        // 主人口径「先换大源，大源里有小源就自动切小源」，列表层级与之一一对应。
        List {
            ForEach(Array(model.sourceGroups.enumerated()), id: \.offset) { gi, g in
                Section {
                    ForEach(g.lines, id: \.self) { idx in
                        lineRow(idx, url: model.allLines[idx])
                            // 毛玻璃面板里的行不能再铺自己的不透明底，否则又成"一行行黑框"
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack(spacing: 6) {
                        // ★ v69 显示口径（主人 2026-10-04「不要出现名字网址之类的 只显示源1源2源3」）：
                        //   组头只给「源N」，**不露源站名/网址**；N = 质量优先级顺位（源1=最快最稳）。
                        //   真实品牌仍留在 model.sourceGroups.name 里给质量账本记账，不上屏。
                        Text("源\(gi + 1)").font(.footnote.bold())
                        if g.lines.contains(model.currentLine) {
                            Text("当前").font(.caption2).foregroundStyle(Color.accentColor)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .scrollIndicators(.hidden)
        .listStyle(.plain)
        // List 自带不透明背景会盖住上面的毛玻璃 → 显式让出背景
        .scrollContentBackground(.hidden)
    }

    private func lineRow(_ idx: Int, url: URL) -> some View {
        Button {
            model.switchToLine(idx)
            showLinePanel = false
        } label: {
            HStack {
                Text(model.lineLabel(forLine: idx)).foregroundStyle(.primary)
                if idx == model.currentLine {
                    Text("播放中").font(.caption2).foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text(url.host ?? "").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// 锁屏键（2026-09-30 用户「还有那个锁屏应该在哪大小」；2026-10-01 主人「应该都放右侧」）。
    ///
    /// **位置**：屏幕**右侧边缘、垂直居中** —— 横屏竖屏**同一种排法**（不再按方向分两套）。
    /// 锁定前后是**同一个键原地切换**（用户早先也提过「点完锁屏怎么还跑别处去了」——原地才不"跳"）。
    /// 左边缘保持干净（那是亮度拖动的落点区，见 handleDragChanged）。
    ///
    /// **大小**：38pt 玻璃圆 + 16pt 图标（约等于底栏图标量级）。再大就抢画面、
    /// 再小横屏远看按不准；点击区用 `contentShape` 补到 38×38 实心。
    private var lockControl: some View {
        VStack {
            Spacer()
            HStack { Spacer(); lockButton.padding(.trailing, 14) }
            Spacer()
        }
    }

    private var lockButton: some View {
        Button {
            locked.toggle()
            // 2026-10-01 主人「点了锁屏还是切横竖屏」：锁定＝连屏幕方向一起锁，
            // 不只是挡手势。锁 → 把当前方向钉死；解锁 → 交还系统并按真实宽高立刻收口。
            if locked { lockOrientationToCurrent() } else { unlockOrientation() }
            showControls = true
            scheduleHide()
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .playerGlass(cornerRadius: 19, tint: 0.16)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(locked ? "解锁" : "锁定")
    }

    /// 首次使用手势提示（2026-10-01 主人钦定「这些手势是不是该有个第一次使用提示」）。
    ///
    /// 只弹一次（AppStorage 记账）：点任意处关（走 UIKit 单击通道，见 playerBody 的 onTap），
    /// 或 9 秒自动收。整层 `allowsHitTesting(false)` —— 触摸**必须**穿透到底层
    /// `AVPlayerViewController.view` 的 UIKit 识别器（v24：LiveContainer 里 SwiftUI 手势会被吞），
    /// 由 onTap 统一处理关闭，所以这里绝不能自己吃点击。
    private var gestureHintOverlay: some View {
        VStack(spacing: 10) {
            Text("手势说明")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 7) {
                gestureHintRow("hand.tap.fill", "单击屏幕", "显示 / 隐藏控制栏")
                gestureHintRow("gobackward.10", "双击左半屏", "快退 10 秒")
                gestureHintRow("goforward.10", "双击右半屏", "快进 10 秒")
                gestureHintRow("forward.fill", "长按屏幕", "2 倍速（松手恢复）")
                gestureHintRow("sun.max.fill", "左半屏上下滑", "调亮度")
                gestureHintRow("speaker.wave.3.fill", "右半屏上下滑", "调音量")
                gestureHintRow("arrow.left.and.right", "左右滑", "拖动进度")
                gestureHintRow("arrow.up.arrow.down", "右边缘上下滑", "上一集 / 下一集")
                gestureHintRow("xmark.circle", "屏幕最上方下滑", "退出播放")
            }
            Text("点任意处关闭 · 只显示这一次")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .playerGlass(cornerRadius: 16, tint: 0.22)
        .frame(maxWidth: 330)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func gestureHintRow(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 20)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            Spacer(minLength: 8)
            Text(desc).font(.caption).foregroundStyle(.white.opacity(0.8))
        }
    }

    private func dismissGestureHint() {
        gestureHintTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            showGestureHint = false
            gestureHintShown = true
        }
    }

    private var failureOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.yellow.opacity(0.9))
            Text("播放失败").font(.headline).foregroundStyle(.white)
            Text("当前线路不可用，可重试或切换其他线路")
                .font(.footnote).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 12) {
                Button { model.retry() } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 22).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                if model.allLines.count > 1 {
                    Button { showLinePanel = true } label: {
                        Label("切换线路", systemImage: "arrow.triangle.swap")
                            .padding(.horizontal, 22).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }
        }
        .padding(32)
        .shadow(color: .black.opacity(0.85), radius: 7, y: 2)
        // 52包（用户：「这个框得删掉！！」「不要出现黑框框了 啥按钮都加黑框 很难受啊」）：
        // 失败提示不再用满屏黑底卡片 —— 图标+白字+投影直接浮在画面上，无底框。
    }

    // MARK: - 行为

    /// 单击屏幕 = 呼出/收起控制层（2026-09-23 用户钦定大牌式：点一下出按钮、再点一下收起；
    /// 暂停/继续只由居中的播放按钮负责）。此前「单击=直接暂停」改为本行为。
    /// 播放中呼出后 3.4s 自动隐藏；暂停时呼出保持可见（能看清继续按钮）。
    private func tapScreen() {
        // 长按加速松手后 0.35s 内的"单击"是长按的尾巴，忽略
        if Date().timeIntervalSince(lastBoostEnd) < 0.35 { return }

        // 2026-10-01 主人钦定「爱优腾不都是这样的吗」：**点一下出、再点一下收**，
        // 无条件 toggle —— 不再有"1.2 秒内连点被吞"这类宽限（上一版把人的连点节奏
        // 当成误触挡掉了，用户感知就是"点了没反应 / 时灵时不灵"）。
        // 双击由 Coordinator 在 0.28s 时间窗里自行判定（不是两次单击），
        // 所以这里纯 toggle 不会和「双击快进」打架。
        withAnimation(.easeOut(duration: 0.18)) { showControls.toggle() }
        showRateSelector = false
        showVolumeSlider = false
        if showControls {
            lastShowAt = Date()
            if model.isPlaying {
                scheduleHide()        // 播放中：3.4s 后自动收起（大牌同款）
            } else {
                hideTask?.cancel()    // 暂停态保持常显（能看清继续按钮）
            }
        } else {
            hideTask?.cancel()
        }
    }

    /// 长按开始加速：HUD 提示 2×（暂停状态不生效）
    private func boostBegan() {
        model.beginBoost()
        guard model.boostActive else { return }
        seekToast = "2× 加速中"
    }

    /// 松手恢复原速
    private func boostEnded() {
        guard model.boostActive else { return }
        model.endBoost()
        lastBoostEnd = Date()
        seekToast = nil
    }

    /// 分享（大牌标配：系统分享面板，带片名 + 播放地址）—— 统一走 SharePresenter
    private func sharePlayback() {
        SharePresenter.share(item: item, playURL: model.currentURL?.absoluteString)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !scrubbing, !showLinePanel, !showEpisodePanel, !showRateSelector, !showVolumeSlider else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { showControls = false }
        }
    }

    /// 50包：syncBackButtonVisibility 已随窗口级返回浮层一并停用——
    /// 返回键现在是 topBar 里的普通按钮，显隐天然随控制层。

    // MARK: - 退出与拖动手势

    private func close() {
        guard !closed else { return }
        closed = true
        filmLog.info("player close: entered (control-layer back tapped)")   // syslog 埋点
        hideTask?.cancel()
        // 2026-09-28 再修「返回关详情页」：
        // 之前 immediate 兜底在 LC 里太激进——SwiftUI 的 fullScreenCover 还没开始 dismiss，
        // UIKit 兜底就先 dismiss，时机错层导致详情页一起被带掉。
        // 正解：先同步「回竖屏 + binding 关播放器」给反馈；UIKit 兜底只留 1.2s 后 retry。
        setLandscape(false)              // 1) 先请求回竖屏（不要等动画完）
        onClose?()                       // 2) 宿主 binding 关闭 → fullScreenCover 正常 dismiss
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)   // 让关闭动画先起
            model.stop()                 // 停播放、灭掉常亮
        }
        // 用户反馈「想返回却不见了」：旧实现在这里就把 backBtn 摘了 —— 一旦关闭失败，
        // 按钮已没了，用户永远回不去。现在**保留按钮**，1.2s 后仍在呈现才 UIKit 兜底；
        // 真正消失由 onDisappear 收尾（gone = true + 摘按钮）。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !gone else { return }
            filmLog.error("player close: still presenting after 1.2s → retry dismiss")
            onClose?()
            dismissPlayerLayer(reason: "retry-1.2s")
        }
    }

    /// 退出播放器的 **UIKit 兜底层**（保险 5）。**只关「播放器」这一层**。
    ///
    /// 呈现链（本 App 固定形状）：
    /// `rootViewController` ─presented→ `详情卡(sheet，HomeView .sheet(item:))`
    ///                     ─presented→ `播放器(fullScreenCover)`
    ///
    /// 因此正解＝`详情卡.dismiss(animated:)`（关掉详情卡之上的播放器），
    /// 而**不是** `rootViewController.dismiss()`（那是关详情卡本身）。
    ///
    /// 历史 bug（用户反馈「播放返回总是自动关详情页」）：原实现在两处兜底都直接
    /// `rootViewController?.dismiss()`。播放器被 `dismiss()`/`onClose()` 关掉之后，
    /// 这刀就落到「详情卡」上——播放器关了，详情页也一起没了。
    /// 关键防线：**详情卡之上已无播放器时，什么都不做**（播放器其实已经关了）。
    @MainActor
    private func dismissPlayerLayer(reason: String) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.keyWindow?.rootViewController,
              let detailHost = root.presentedViewController else {
            filmLog.info("player close[\(reason)]: 无详情呈现层 → 跳过（不擅自 dismiss 根）")
            return
        }
        guard detailHost.presentedViewController != nil else {
            // 详情卡之上没有播放器 = 播放器已关。此处若再 dismiss 就会关掉详情页 = 历史 bug。
            filmLog.info("player close[\(reason)]: 播放器层已消失 → 跳过补刀（保住详情页）")
            return
        }
        detailHost.dismiss(animated: true)   // 只关「详情卡之上那一层」＝播放器
    }

    // v24：拖拽不再走 SwiftUI DragGesture（LC 吞手势 + 兄弟层拦截，见 playerBody 注释），
    // 由 PlayerContainerView 的 UIPanGestureRecognizer 驱动下面的两个处理函数。

    /// 拖拽进行中（state: began/changed 统一入口）。参数来自 UIPanGestureRecognizer：
    /// startLocation=手势起点（pt）、translation=累计位移（pt）。
    private func handleDragChanged(startLocation: CGPoint, translation: CGSize) {
        if dragMode == .idle {
            let dx = abs(translation.width)
            let dy = abs(translation.height)
            let screenH = UIScreen.main.bounds.height
            let screenW = UIScreen.main.bounds.width
            if translation.height > 60, dy > dx, startLocation.y < screenH * 0.2 {
                dragMode = .close      // 屏幕上部下滑 = 退出播放
                return
            }
            // 抖音式切集：右边缘（右侧 22% 宽）× 上部 20% 以下，竖向起手即锁定本模式
            if episodeCount > 1, dy > dx, dy > 24,
               startLocation.x > screenW * 0.78,
               startLocation.y > screenH * 0.2 {
                dragMode = .episode
                return
            }
            hideTask?.cancel()
            if dx >= dy {
                dragMode = .seek
                dragSeekTarget = min(max(model.currentTime, 0), max(model.duration, 0.1))
            } else if startLocation.x < screenW / 2 {
                dragMode = .brightness
                startBrightness = UIScreen.main.brightness
            } else {
                dragMode = .volume
                startVolume = PlayerVolumeController.current()
            }
        }
        switch dragMode {
        case .seek:
            let raw = abs(Double(translation.width))
            let moved = raw < 60 ? raw : 60 + (raw - 60) * 3   // 前 60pt 1s/pt，之后加速
            let signed = translation.width < 0 ? -moved : moved
            let limit = max(model.duration, 0.1)
            dragSeekTarget = min(max(model.currentTime + signed, 0), limit)
            seekToast = (translation.width < 0 ? "◀ " : "▶ ") + Self.format(dragSeekTarget)
        case .brightness:
            let target = min(max(startBrightness - translation.height / 500, 0), 1)
            UIScreen.main.brightness = target
            seekToast = "亮度 \(Int(target * 100))%"
        case .volume:
            let target = min(max(startVolume - Float(translation.height) / 500, 0), 1)
            PlayerVolumeController.set(target)
            seekToast = "音量 \(Int(target * 100))%"
            showVolumeHUD(Double(target))
        case .episode:
            // 上滑（translate 负）= 下一集；下滑 = 上一集。实时给方向提示，松手才真正切换。
            // ★ v78：预览名与真正切换走**同一套判据**（本大源内的相邻集）—— 旧写法用
            //   `currentLine±1`，在主源最后一集会预告成「下一集 = 另一个源的第 1 集」。
            let up = translation.height < 0
            let worth = abs(translation.height) >= 60
            let target = up ? model.nextEpisodeLine : model.prevEpisodeLine
            if !worth {
                seekToast = up ? "↑ 上滑下一集" : "↓ 下滑上一集"
            } else if let t = target {
                seekToast = (up ? "↑ 下一集 " : "↓ 上一集 ") + (episodeName(at: t) ?? "")
            } else {
                seekToast = up ? "已是最后一集" : "已是第一集"
            }
        case .close, .idle:
            break
        }
    }

    private func handleDragEnded(startLocation: CGPoint, translation: CGSize) {
        if dragMode == .seek {
            model.seek(to: dragSeekTarget)
            showSeekToast("跳转 " + Self.format(dragSeekTarget))
        } else if dragMode == .close {
            close()
        } else if dragMode == .episode {
            // 抖动阈值 60pt：够远才切，避免"想点一下"被误判成换集
            if translation.height <= -60 {
                switchEpisode(by: 1)
            } else if translation.height >= 60 {
                switchEpisode(by: -1)
            } else {
                clearToastLater()
            }
        } else {
            clearToastLater()
        }
        dragMode = .idle
        scheduleHide()
    }

    /// 抖音式切集：by = +1 下一集 / -1 上一集。复用播放器的选集通道（`model.playEpisode`），
    /// 因此**内置源与中台 feed 走的是同一条路**——只要详情页把分集列表带进来（剧集/内置源补拉都有），
    /// 上下滑就能切；电影（无分集）不响应，不会误触。
    private func switchEpisode(by offset: Int) {
        guard episodeCount > 1 else { return }
        // ★ v78：与「下一集/上一集」同一套判据 —— **只在本大源内**走，绝不跨源跳第 1 集。
        let target = offset > 0 ? model.nextEpisodeLine : model.prevEpisodeLine
        guard let target else {
            showSeekToast(offset > 0 ? "已是最后一集" : "已是第一集")
            return
        }
        model.playEpisode(target)
        if let name = episodeName(at: target) {
            onEpisodeChange?(name)
            showSeekToast((offset > 0 ? "下一集：" : "上一集：") + name)
        } else {
            showSeekToast(offset > 0 ? "下一集" : "上一集")
        }
    }

    private func clearToastLater() {
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            seekToast = nil
        }
    }

    private func doubleTapSeek(centerX: CGFloat) {
        // 以横竖屏当前宽度中线判定左右半屏
        let mid = UIScreen.main.bounds.width / 2
        let forward = centerX >= mid
        if forward { model.skip(10) } else { model.skip(-10) }
        // 2026-09-30 用户「你好好看看爱优腾怎么做的」：
        // 双击不再只飘一行居中小字，改成爱优腾同款——**对应半屏**浮出圆形涟漪
        // （goforward.10 / gobackward.10，即箭头 + 秒数），落点与方向一一对应。
        let fb = SeekRippleFeedback(forward: forward, seconds: 10)
        seekRipple = fb
        seekRippleHideTask?.cancel()
        seekRippleHideTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled, self.seekRipple?.id == fb.id { self.seekRipple = nil }
        }
    }

    /// 双击涟漪（左半屏＝快退、右半屏＝快进），带缩放浮现动画。
    @ViewBuilder private var seekRippleView: some View {
        if let fb = seekRipple {
            HStack {
                if fb.forward { Spacer() }
                VStack(spacing: 4) {
                    Image(systemName: fb.forward ? "goforward.10" : "gobackward.10")
                        .font(.system(size: 34, weight: .semibold))
                    Text("\(fb.seconds) 秒").font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .playerGlass(cornerRadius: 48)
                .transition(.scale(scale: 0.72).combined(with: .opacity))
                if !fb.forward { Spacer() }
            }
            .padding(.horizontal, 46)
            .allowsHitTesting(false)
        }
    }

    private func showSeekToast(_ text: String) {
        seekToast = text
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            seekToast = nil
        }
    }

    /// v13 音量提示条：显示竖向音量条，1.2s 无操作自动隐藏。
    /// 物理音量键（KVO）与右半屏拖动共用同一入口。
    private func showVolumeHUD(_ v: Double) {
        volumeHUDValue = min(max(v, 0), 1)
        volumeHUDHideTask?.cancel()
        volumeHUDHideTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { volumeHUDValue = nil }
        }
    }

    private func setLandscape(_ on: Bool) {
        // 锁定态下不切方向（爱优腾同款：锁了就是锁了，转屏也没反应）。
        if locked { showSeekToast("已锁定，先解锁再切横竖屏"); return }
        isLandscape = on
        LiveDiag.write("方向·用户切=\(on ? "横" : "竖")")     // v78.3 取证埋点（与 syncLandscape 那条配对）
        let mask: UIInterfaceOrientationMask = on ? .landscapeRight : .portrait
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
        // 2026-10-01：这条旋转请求**可能被拒**（系统方向锁定 / LiveContainer 限制）。
        // 旧写法乐观置位后不再收口 →「状态=横屏 / 屏幕=竖屏」→ 横屏排版塞进竖屏窗口
        // （顶栏分享被挤出屏、锁屏键被裁、进度条压成 0 宽只留一颗白球）。
        // 转不转得动都按**真实窗口宽高**收口一次。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            let size = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow })?.bounds.size
                ?? UIScreen.main.bounds.size
            syncLandscape(size)
        }
    }

    /// 2026-10-01 根修：把 `isLandscape` 拉回**容器真实宽高**。
    /// 旋转请求可能被宿主（LiveContainer）/ 系统竖屏锁定挡掉 —— 那时状态若仍是"横屏"，
    /// 横屏排版就会被塞进竖屏窗口，出现「顶栏分享被挤出屏、锁屏键在左边缘被裁、
    /// 进度条压成 0 宽只剩一颗白球」这些溢出。以真实宽高为准即可两头都对。
    ///
    /// 2026-10-01 追加（主人「点了锁屏还是切横竖屏」）：
    /// **锁定态下直接冻结** —— 不跟着窗口宽高改 `isLandscape`。
    /// 原实现只让 `locked` 挡住手势（`guard !locked else { return }`），方向照切不误，
    /// 于是"锁了屏一转手机还是变横屏"。爱优腾的锁定＝连方向一起锁，这里补齐。
    private func syncLandscape(_ size: CGSize) {
        guard !locked else { return }          // ← 锁定态：布局方向冻结在锁定那一刻
        guard size.width > 0, size.height > 0 else { return }
        let land = size.width > size.height
        if land != isLandscape {
            // ★ v78.3 取证埋点（主人报「居中三钮不见了只有底部还在」的第二候选根因）：
            //   `isLandscape` 若被判成横屏，会**同时**造成「居中三钮不渲染（354 行）+ 底栏换成
            //   横屏整行（固定宽 600+pt 塞进竖屏窗口 → 最左侧的上一集/暂停/下一集被挤出屏幕）」，
            //   现象与主人描述吻合。此前无任何记录可判 —— 现在方向一变就落黑匣子
            //   （`Documents/livediag.txt`，PC 侧 `_livediag_pull.py` 直接拉）。
            isLandscape = land
            LiveDiag.write("方向=\(land ? "横" : "竖") 容器=\(Int(size.width))x\(Int(size.height))")
        }
    }

    /// 锁定态：把当前方向**钉死**（竖就只许竖、横就只许横）。
    ///
    /// 2026-10-01 四修（主人：「锁屏横竖屏锁不住啊 横屏锁屏正常是不是不会出现竖屏现象」）：
    /// 前三修只调 `requestGeometryUpdate` —— 那只是**请求**，被系统竖屏锁 / 宿主忽略就没用。
    /// 现在写进 `OrientationLock`（AppDelegate 用它回答 `supportedInterfaceOrientationsFor`），
    /// 系统**每次要转屏都会先问这里** → 锁横屏后物理转动不再翻成竖屏。
    /// 方向以**真实窗口宽高**判定（`isLandscape` 可能被冻结过，不可信）。
    private func lockOrientationToCurrent() {
        let size = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?.bounds.size ?? UIScreen.main.bounds.size
        OrientationLock.shared.set(size.width > size.height ? .landscape : .portrait)
    }

    /// 解锁：把方向交还给系统（除倒置外的全方向），并按真实宽高立刻收口一次。
    private func unlockOrientation() {
        OrientationLock.shared.set(nil)
        let size = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?.bounds.size ?? UIScreen.main.bounds.size
        syncLandscape(size)
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// AirPlay 投屏按钮（大牌标配）—— 系统原生 AVRoutePickerView，点击弹出设备列表
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// 画面比例档位（2026-09-22 用户反馈「没有画面比例/自适应，有些影片不能全屏观看」）：
/// 自适应=完整画面（可能留黑边）；铺满=裁掉黑边填满屏幕（主流默认观感）；拉伸=变形填满（老片源常用）。
public enum AspectMode: String, CaseIterable, Identifiable {
    case fit, fill, stretch
    public var id: String { rawValue }

    /// 底部栏短标签
    var shortTitle: String {
        switch self {
        case .fit: return "自适应"
        case .fill: return "铺满"
        case .stretch: return "拉伸"
        }
    }

    /// 面板里的完整说明
    var detailTitle: String {
        switch self {
        case .fit: return "自适应 · 完整画面（可能留黑边）"
        case .fill: return "铺满屏幕 · 裁掉黑边（推荐）"
        case .stretch: return "拉伸填满 · 画面会变形"
        }
    }

    var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }
}

/// AVPlayerViewController 桥接（自带控制条关闭，全部由上层自绘控制层接管）。
/// 2026-09-20 增强：挂 UIKit 级 UITapGestureRecognizer 单击/双击兜底 ——
/// LiveContainer 容器吞 SwiftUI 手势（与「点返回毫无反应」同根因），tap 事件下沉到
/// vc.view 的 UIKit recognizer 仍可到达；正常 iOS 上层手势命中后事件不到达底层，天然不双触发。
struct PlayerContainerView: UIViewControllerRepresentable {
    @ObservedObject var model: PlayerViewModel
    /// UIKit tap 兜底回调（location + tapCount）
    var onTap: ((CGPoint, Int) -> Void)? = nil
    /// 长按加速回调（true=按下开始, false=松手结束）
    var onLongPress: ((Bool) -> Void)? = nil
    /// v24：拖拽回调（startLocation pt, 累计 translation pt, state 0=began 1=changed 2=ended）
    var onPan: ((CGPoint, CGSize, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onLongPress: onLongPress, onPan: onPan)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = model.player
        vc.showsPlaybackControls = false
        // 57包（用户多次钦点「不要这个黑框」）：系统 Live Text 识别钮——
        // allowsVideoFrameAnalysis 默认 true，视频画面检测到文字就在右下角浮
        // 「取景框+横线」灰圆钮；片源烧满字幕/广告字导致它常驻。关掉即根治。
        if #available(iOS 16.0, *) { vc.allowsVideoFrameAnalysis = false }
        vc.videoGravity = model.aspect.gravity     // 画面比例随用户选择
        // 恢复交互（此前 false 是为防吞上层手势；SwiftUI 手势层在其上层，正常路径仍优先命中）
        vc.view.isUserInteractionEnabled = true
        // 2026-09-30 用户报「点很多次都不能呼出」+「有时候点会出现快进10S和正在加载的那个圈」：
        // 旧结构 `single.require(toFail: double)` = 单击必须**等双击判定窗口（≈0.3s）**过去才生效；
        // 连点时双击识别器不断重置等待窗口 → 单击**永远轮不到**（体感"怎么点都不出来"），
        // 而你补点的第二下又被判成双击 → 误触发「快进10s」+ seek 引发的缓冲圈。三个症状同一个根。
        // 正解＝只挂一个单击识别器，双击由**两次点击的时间窗**在 Coordinator 里自行判定，
        // 单击零延迟上报。
        let single = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleSingle(_:)))
        single.numberOfTapsRequired = 1
        // 长按=加速（大牌标配）：与单击互斥，避免长按松手被当成单击而暂停
        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.allowableMovement = 40
        single.require(toFail: longPress)
        // v24：拖拽识别器（亮度/音量/快进/下滑关闭/右缘切集的唯一通道）
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        vc.view.addGestureRecognizer(single)
        vc.view.addGestureRecognizer(longPress)
        vc.view.addGestureRecognizer(pan)
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== model.player { vc.player = model.player }
        if vc.videoGravity != model.aspect.gravity {   // 用户在面板改比例 → 立即生效
            vc.videoGravity = model.aspect.gravity
        }
        context.coordinator.onTap = onTap
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onPan = onPan
    }

    final class Coordinator: NSObject {
        var onTap: ((CGPoint, Int) -> Void)?
        var onLongPress: ((Bool) -> Void)?
        var onPan: ((CGPoint, CGSize, Int) -> Void)?
        /// 上次单击时刻（自定义双击判定，避免 require(toFail:) 让单击干等 0.3s）
        private var lastTapAt = Date.distantPast
        private let doubleWindow: TimeInterval = 0.28
        /// 拖拽起点（.began 时刻的落点，pt / view 坐标）
        private var panStart: CGPoint = .zero
        init(onTap: ((CGPoint, Int) -> Void)?, onLongPress: ((Bool) -> Void)?,
             onPan: ((CGPoint, CGSize, Int) -> Void)?) {
            self.onTap = onTap
            self.onLongPress = onLongPress
            self.onPan = onPan
        }
        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began: onLongPress?(true)
            case .ended, .cancelled, .failed: onLongPress?(false)
            default: break
            }
        }
        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            // UIPanGestureRecognizer.translation(in:) 返回 CGPoint，转成 CGSize 再上报
            let t = g.translation(in: g.view)
            let size = CGSize(width: t.x, height: t.y)
            switch g.state {
            case .began:
                panStart = g.location(in: g.view)
                onPan?(panStart, .zero, 0)
            case .changed:
                onPan?(panStart, size, 1)
            case .ended:
                onPan?(panStart, size, 2)
            case .cancelled, .failed:
                break
            default: break
            }
        }
        @objc func handleSingle(_ g: UITapGestureRecognizer) {
            // 单击：**立即**上报（零延迟 — 用户「响应速度」）。
            // 若与上一次点击相隔 < 0.28s，则判定这一击是"双击的第二下"，改报双击。
            let loc = g.location(in: g.view)
            let now = Date()
            if now.timeIntervalSince(lastTapAt) < doubleWindow {
                lastTapAt = .distantPast      // 消耗掉，避免三击被连算成两次双击
                onTap?(loc, 2)
            } else {
                lastTapAt = now
                onTap?(loc, 1)
            }
        }
    }
}

/// 播放会话模型。
@MainActor
public final class PlayerViewModel: NSObject, ObservableObject {

    @Published public private(set) var failed = false
    @Published public private(set) var switchingLine = false
    @Published public private(set) var currentLine = 0
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var rate: Double = 1.0
    @Published public private(set) var isBuffering = false

    /// 画面比例（自适应/铺满/拉伸）—— 外部改动请用 setAspect(_:)。
    /// 2026-09-28 用户钦点：默认打开影片必须是**原始比例**（可能有黑边），想铺满自己点比例钮切。
    /// 2026-09-30 用户再报「播放影片时初始状态应该是原始屏幕大小不是铺满和拉伸」——
    /// 根因＝**这个值会持久化**：只要之前点过一次「铺满」，之后每部影片打开都还是铺满（感知成"改不动"）。
    /// 正解＝初始一律 `.fit`，**不再从 UserDefaults 读取**；本次播放内仍可随时切（见 setAspect）。
    @Published public private(set) var aspect: AspectMode = .fit

    /// 切换画面比例（**仅本次播放有效**，不跨影片沿用）
    public func setAspect(_ m: AspectMode) {
        guard aspect != m else { return }
        aspect = m
        filmLog.info("player: aspect -> \(m.rawValue)")
    }

    private static func migrateAspectSetting() {
        // 2026-09-30：初始比例已改为「一律 .fit、不读持久化」，这里只做一次性清键，
        // 免得老 key 里的「铺满」以后被别处误读。
        let migratedKey = "filmui.playerAspectMigratedV2"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        UserDefaults.standard.removeObject(forKey: "filmui.playerAspect")
        UserDefaults.standard.removeObject(forKey: "filmui.playerAspectV2")
        UserDefaults.standard.set(true, forKey: migratedKey)
    }

    public private(set) var player: AVPlayer?
    private let item: FeedItem
    private var timeObserver: Any?
    private var observers: [NSKeyValueObservation] = []
    public private(set) var resumeSeconds: Double = 0
    /// 待执行的续播定点（AVPlayerItem readyToPlay 后再 seek；立即 seek 会被丢弃 → 表现为"从头播"）
    private var pendingResume: Double = 0
    /// 续播定点是否正在进行（防 KVO 与周期观察两路重入叠探）
    private var resumeSeekInFlight = false
    private var lastRecorded = 0.0
    private var lastProgressSeconds = 0.0
    private var lastProgressAt = Date()
    private var autoSwitchCount = 0
    private var reconnectTries = 0        // 46包：同线路原地重连计数（网络抖动不直接判死）
    private var userPaused = false        // 46包：用户主动暂停时看门狗不生效（暂停≠卡死）
    private var startedAt = Date()        // 46包：起播 10s 宽限（起播慢≠失败）
    private let initialLine: Int          // 详情页选集进入时的起始集（playCandidates 下标）
    private let extraLines: [URL]         // 详情页聚合的外部源线路（同名片跨 CMS 源）
    /// 与 extraLines 平行的大源名（v67 换源分层；缺项回退「外部源」）
    private let extraSourceNames: [String]

    // MARK: - v69 源质量采样（主人 2026-10-04「一定要把优先级搞好」）
    /// 本次起播的发起时刻（成功样本的计时起点；`play(line:)` 里刷新）。
    private var qualityProbeAt: Date?
    /// 本次起播对应的大源品牌（写入账本的键）。
    private var qualityProbeBrand: String = ""
    /// 本次起播是否已记过成功（一次 play 只记一次，暂停/恢复不重复计）。
    private var qualityProbeRecorded = false
    /// 是否剧集（选集面板传入）——决定自动连播与「下一集」按钮的可用性
    let hasEpisodeList: Bool
    /// ★ v78.2：**真正的线路块**（每个元素 = 一条播放线路的整季集，值为 allLines 下标）。
    /// 由 `PlayerScreen.lineBlocks(from:)` 把详情页那份 `episodeGroups` **切好**后传进来
    /// （按集名序号回退分线，因为中台 `quality` 恒空、分组不可用）—— 与用户看到的选集面板
    /// **同一份数据**。只覆盖「片源自带线路」部分；聚合源的块由 `switchBlocks` 从
    /// `sourceGroups` 补齐，两者合成**唯一的切集/换源基准**。
    private let episodeLineBlocks: [[Int]]
    private var notifObservers: [NSObjectProtocol] = []

    // MARK: - v61 插播广告段跳过（2026-10-04）
    /// 识别出的插播广告区间。**识别不到 = 空数组 = 一秒都不跳**（用户钦定：宁可漏，绝不可误伤正片）。
    private var adRanges: [AdBreakDetector.Range] = []
    /// 同一条广告段只跳一次（0.5s 周期观察会反复回调，不做去重会反复 seek 抖动）
    private var lastAdSkippedEnd: Double = -1
    /// 识别任务令牌：切线路/重连后作废旧回调，避免旧线路的广告区间串到新线路上
    private var adDetectToken = 0

    public init(item: FeedItem, initialLine: Int = 0, extraLines: [URL] = [],
                extraSourceNames: [String] = [], hasEpisodeList: Bool = false,
                episodeLineBlocks: [[Int]] = []) {
        self.item = item
        self.initialLine = max(0, initialLine)
        self.extraLines = extraLines
        self.extraSourceNames = extraSourceNames
        self.hasEpisodeList = hasEpisodeList
        self.episodeLineBlocks = episodeLineBlocks
        // stored property 不能引用 Self，迁移放在 init 里：老 fill 设置强制清为 fit。
        Self.migrateAspectSetting()
        if let saved = UserDefaults.standard.string(forKey: "filmui.playerAspectV2"),
           let m = AspectMode(rawValue: saved) {
            aspect = m
        }
    }

    /// 全部可播线路 = 条目自带（默认线路优先）+ 聚合外部源（去重）。
    public var allLines: [URL] {
        item.playCandidates + extraLines.filter { !item.playCandidates.contains($0) }
    }

    // MARK: - 换源分层（v67，主人 2026-10-04「切换源应该是先换大源，大源里有小源就自动切小源」）

    /// 片源自带线路所属的大源名（中台 origin.sourceName，如「暴风资源(电影采集)」；空回退「片源」）。
    public var ownSourceName: String {
        let s = (item.origin?.sourceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "片源" : s
    }

    /// 大源分组：[(大源名, 该组的 allLines 下标)]，**组序 = 换源顺序**，组内 = 小源（自动容灾内轮）。
    /// 顺序 = 片源组在前，其后按聚合时的大源出现顺序。
    public var sourceGroups: [(name: String, lines: [Int])] {
        let own = item.playCandidates
        var order: [String] = []
        var map: [String: [Int]] = [:]
        func push(_ name: String, _ i: Int) {
            let n = name.isEmpty ? "外部源" : name
            if map[n] == nil { order.append(n) }
            map[n, default: []].append(i)
        }
        for i in own.indices { push(ownSourceName, i) }
        var k = 0                                    // extras 在 allLines 里的连续下标
        for (j, u) in extraLines.enumerated() where !own.contains(u) {
            let nm = j < extraSourceNames.count ? extraSourceNames[j] : ""
            push(nm, own.count + k)
            k += 1
        }
        // ★ v69 源质量优先级（主人 2026-10-04「一定要把优先级搞好」）：
        //   按质量账本把「起播最快且最稳」的大源顶到第一顺位 —— 默认线路/换源顺序/线路面板
        //   三处同时生效，用户点开即看、根本不用换源。
        //   无任何样本时 `orderedBrands` 原序返回 → 与旧版行为 100% 一致（新装零回归）。
        let ordered = SourceQualityRank.shared.orderedBrands(order)
        return ordered.map { ($0, map[$0] ?? []) }
    }

    /// 某条线路（allLines 下标）所属的大源品牌名（采样写账本用）。
    private func qualityBrandName(forLine line: Int) -> String {
        sourceGroups.first { $0.lines.contains(line) }?.name ?? ownSourceName
    }

    /// 当前所处大源组的序号（0 基）。
    public var currentSourceIndex: Int {
        let groups = sourceGroups
        return groups.firstIndex { $0.lines.contains(currentLine) } ?? 0
    }

    /// 当前大源名。
    public var currentSourceName: String {
        let groups = sourceGroups
        return groups[currentSourceIndex].name
    }

    /// ★ v78.2 **换源（保集）** = 换到另一个源播放**同一集**（循环）。
    ///
    /// 旧实现取 `next.lines[0]` = 下一个源（组）的**第 1 集** → 用户点「换源」/源失败自动换源时
    /// 被带回第 1 集（主人 2026-10-05：「不播放的源直接跳集**不是在换源**」）。
    /// 正解 = 在**同一集序号位置**上横向换块：
    ///   · 当前块内位置 `pos`（= 第几集），目标块取第 `pos` 个；目标源集数不足 → 落它的最后一集；
    ///   · 电影/无真分集（没有「集」这个维度）→ 目标块一律取第一条。
    /// 进度照旧保留（`switchToLine` 会把当前秒数带过去），因为换的是**同一集**的另一个源。
    /// 顺序上先走完 `sourceGroups` 内的块（= 同一大源的多条线路），再跨大源 —— 与 v67 分层口径一致。
    @discardableResult
    public func switchToNextSource() -> String? {
        let blocks = switchBlocks
        guard blocks.count > 1 else { return nil }
        guard let bi = blocks.firstIndex(where: { $0.contains(currentLine) }) else { return nil }
        let pos = blocks[bi].firstIndex(of: currentLine) ?? 0
        let target = blocks[(bi + 1) % blocks.count]
        guard let land = hasEpisodeList ? target[min(pos, target.count - 1)] : target.first,
              land != currentLine else { return nil }
        switchToLine(land)          // 换的是「同一集的另一个源」→ 保留进度（switchToLine 已带秒数）
        return sourceGroups.first { $0.lines.contains(land) }?.name
    }

    // MARK: - 生命周期

    public func start(resume: Bool) {
        UIApplication.shared.isIdleTimerDisabled = true     // 播放中屏幕常亮
        // ★ v78.4 续播全链加固（主人 2026-10-05「怎么续播也出问题了 刚才我看到的位置 装完从第一集开始了」）：
        //   把「续播到哪一集 + 从哪一秒」的判定**整体挪到起播这一刻**，不再吃详情页点击瞬间的结果。
        //   真机证据（`resume.traceLog` 10-03~10-05 共 40 条）：**无一条 gate=true**，
        //   而同一行里 `entry` 却有值（如 `entry=1589.7`）—— 说明点击时读空了、起播时已就绪。
        //   两条竞态都在这里被消掉：
        //     ① 历史是**异步解码**的（2026-09-30 启动提速改造）→ 决策点后移即天然看到已就绪数据；
        //     ② 「>30 秒才算看过」的门槛也移到这里判，不再因一瞬间的空数组把续播意图丢掉。
        //   `seenBefore` 为假（没看过/看得太短）→ 一律从头播，与旧行为一致。
        let entry = UserLibrary.shared.historyEntry(for: item)
        let seenBefore = (entry?.progressSeconds ?? 0) > 30
        // 起始集：详情页选集/选源进入时直落该下标；越界兜底回第 1 候选
        var line = allLines.indices.contains(initialLine) ? initialLine : 0
        if resume, let e = entry, seenBefore {
            resumeSeconds = e.progressSeconds
            // 起始集以**历史那一集**为准 —— 详情页若因竞态算成了 0（或越界回退），在这里自纠。
            if e.lineIndex >= 0, allLines.indices.contains(e.lineIndex) {
                line = e.lineIndex
            }
        }
        // 2026-10-01 取证（主人两报「续播没生效」）：决策全链落痕，可从手机容器拉出来核。
        // gate=详情页给的续播意图；entry=实取到的历史秒数；line=最终起播下标(详情页传入值)；entryLine=历史那一集。
        traceResume("start gate=\(resume) entry=\(entry?.progressSeconds ?? -1) use=\(resumeSeconds) " +
                    "line=\(line)(传\(initialLine)) entryLine=\(entry?.lineIndex ?? -1) all=\(allLines.count)")
        // ★ v78 根修（主人 2026-10-05 实测：「我选第7集播放 然后我点下一集直接回到了第一集」）——
        //   **`play(line:)` 只负责起播，从不回写 `currentLine`**。旧 `start()` 只调 `play(line:)`，
        //   于是「从详情页选第 N 集进来」时 `currentLine` 恒停在默认值 0：
        //     ① 选集面板高亮 / 顶栏集名 / 选集键角标 全部指向**第 1 集**（主人本次三条反馈的共同来源）；
        //     ② 「下一集」= `index(after: 0)` → 播 `allLines[1]`，而带 `defaultURL` 的片
        //        `playCandidates[1]` 正是**第 1 集** → 主人看到的「点下一集回到第一集」；
        //     ③ 播放历史 `lineIndex` 也一直记成 0 → 下次「继续观看」从第 1 集起（续播同样错位）。
        //   正解：起播前先把 `currentLine` 落到真正要播的那一条，所有派生显示/切集/记账都以它为准。
        currentLine = line
        play(line: line)
    }

    /// 续播痕迹（写 UserDefaults，随 App 容器落盘 → 探针脚本可拉取核验）。
    private func traceResume(_ msg: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        UserDefaults.standard.set("\(stamp) \(msg)", forKey: "resume.lastTrace")
        var log = UserDefaults.standard.stringArray(forKey: "resume.traceLog") ?? []
        log.append("\(stamp) \(msg)")
        if log.count > 40 { log.removeFirst(log.count - 40) }
        UserDefaults.standard.set(log, forKey: "resume.traceLog")
        filmLog.info("resume: \(msg)")
    }

    /// ★ v78.4：立刻把当前进度写进播放历史（App 进后台/可能被回收前调用）。
    /// 只做「写历史」这一件事 —— 不停播放、不摘观察者、不改任何播放状态。
    public func flushProgress() { recordProgress() }

    public func stop() {
        UIApplication.shared.isIdleTimerDisabled = false    // 退出自动恢复系统默认
        recordProgress()
        detachObservers()
        player?.pause()
        player = nil
        SourceQualityRank.shared.dumpForProbe()             // v69：退出播放写一份明文样本供探针核验
    }

    public func retry() {
        failed = false
        autoSwitchCount = 0
        reconnectTries = 0
        userPaused = false
        startedAt = Date()
        lastProgressAt = Date()
        play(line: currentLine)
    }

    /// ⚠️ v78.2：保留旧签名，但**不再在平铺列表里 `+1`** —— `allLines` 是「本片全部集 ++
    /// 各聚合源的整季」的拼接，`+1` 在本源末集会跨进**下一个源的第 1 集**（= 跳集）。
    /// 现在直接走「**保集换源**」。当前仓库内已无调用点（历史遗留 API），改动只为杜绝误用。
    public func switchToNextLine() {
        _ = switchToNextSource()
    }

    public func switchToLine(_ line: Int) {
        let count = allLines.count
        guard count > 1, line != currentLine, line >= 0, line < count else { return }
        // 2026-10-01 三修：续播定点未落地时保持原点位（别被 currentTime=0 冲掉）。
        resumeSeconds = pendingResume > 0
            ? pendingResume
            : (player.flatMap { $0.currentTime().seconds.isFinite ? $0.currentTime().seconds : 0 } ?? resumeSeconds)
        switchingLine = true
        currentLine = line
        failed = false
        reconnectTries = 0           // 46包：换线路后重新计数
        play(line: currentLine)
    }

    // MARK: - 选集（大牌式播放中直接切集 + 自动连播）

    /// 切集：从头播放（不继承上一集进度）；比 switchToLine 宽松（允许同位重切、单线路剧集可用）。
    public func playEpisode(_ line: Int) {
        guard allLines.indices.contains(line) else { return }
        resumeSeconds = 0
        currentLine = line
        failed = false
        switchingLine = false
        autoSwitchCount = 0
        reconnectTries = 0           // 46包
        play(line: line)
    }

    /// 是否还有下一集（剧集模式专用）。
    ///
    /// ★ v78（主人 2026-10-05 实测：「我选第7集播放 然后我点下一集直接回到了第一集」）——
    /// **根因**：`allLines` = 本片全部集 ++ 各聚合源的全部集（`aggregateSources` 把每个外部源
    /// 的 `playCandidates` **整串**并进来），是一条**拼接**列表、并不连续。旧实现
    /// `currentLine + 1 < allLines.count` 在主源最后一集处恰好指向**下一个源的第 1 集**
    /// → 体感就是「点下一集回第 1 集」。
    /// **正解**：剧集切集一律**限定在当前所处大源组内**（组内顺序 = 该源自己的集序）。
    public var hasNextEpisode: Bool {
        hasEpisodeList && nextEpisodeLine != nil
    }

    /// ★ v78.2 **线路块序列** —— 每块 = 一条播放线路的整季（allLines 下标，升序），
    /// 顺序 = 换源顺序。这是「集」与「源」两个维度的**唯一权威基准**：
    ///   · **块内 ±1 = 切集**（下一集/上一集/竖滑/自动连播）；
    ///   · **跨块同位置 = 换源**（换到另一个源播**同一集**）。
    ///
    /// 为什么必须显式建这一层（主人 2026-10-05 实测「**不播放的源直接跳集不是在换源**」）：
    /// `allLines` 把「源 × 集」两个维度拍平成一维，而中台数据的一个源**贡献的是整季**
    /// （实测 `play.lines` 每集一条、`quality` 恒空 → 一个源的全部集在 allLines 里连续）。
    /// 于是旧代码里那两个「换源」动作全都成了跳集：
    ///   · `handlePlaybackFailure` 取 `sourceGroups[g].lines[pos+1]` → 那是**同一源的下一集**；
    ///   · `switchToNextSource` 取 `next.lines[0]` → 那是**下一个源的第 1 集**。
    /// 构造 = 遍历 `sourceGroups`（顺序 = 质量顺位）：
    ///   ① 该组若含详情页真分集表的块 → 用那些块（组内多线路/多季各成一块）；
    ///   ② 组内剩余下标按**连续段**切块（同一线路的集在 allLines 里天然连续）。
    /// 惰性缓存：`item`/`extraLines`/`episodeLineBlocks` 全程不变，算一次即可
    ///（本属性会被 View body 经 `hasNextEpisode`/`prevEpisodeLine`/`canPlayPrev` 高频读取，
    /// 不缓存会在每帧重算 `sourceGroups`；缓存后顺序在本次播放会话内稳定，内部口径必然一致）。
    private var cachedSwitchBlocks: [[Int]]?
    private var switchBlocks: [[Int]] {
        if let c = cachedSwitchBlocks { return c }
        var out: [[Int]] = []
        let eb = episodeLineBlocks.filter { !$0.isEmpty }
        // ★ 有无「集」这个维度，块的定义**必须不同**（否则会互相弄坏）：
        //   · 剧集（hasEpisodeList）→ 块 = 一条线路的整季（连续段），**跨块同位置 = 换源**；
        //   · 电影 / 中台「只有换源线路」的条目 → 一条 URL 就是一条小源，
        //     组内**每条各成一块** —— 这样换源 = 「同源内逐条轮小源、轮尽再跨源」，
        //     与 v67 既有行为**逐字一致**（这几类条目的容灾行为零变化）。
        func split(_ idx: [Int]) -> [[Int]] {
            hasEpisodeList ? Self.splitContiguous(idx) : idx.sorted().map { [$0] }
        }
        for g in sourceGroups {
            let gSet = Set(g.lines)
            let subs = eb.filter { $0.allSatisfy { gSet.contains($0) } }
            if subs.isEmpty {
                out.append(contentsOf: split(g.lines))
            } else {
                out.append(contentsOf: subs)
                let covered = Set(subs.flatMap { $0 })
                let rest = g.lines.filter { !covered.contains($0) }
                if !rest.isEmpty { out.append(contentsOf: split(rest)) }
            }
        }
        cachedSwitchBlocks = out
        return out
    }

    /// 把下标数组按「连续」切成若干段（[0,1,2,7,8] → [[0,1,2],[7,8]]）。
    private static func splitContiguous(_ idx: [Int]) -> [[Int]] {
        var out: [[Int]] = []
        var cur: [Int] = []
        for i in idx.sorted() {
            if let l = cur.last, i != l + 1 { out.append(cur); cur = [] }
            cur.append(i)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// ★ v78.2：该下标在**线路块内**的集名（「第k集」）；无集维度（电影）或不在块内 → nil。
    ///
    /// 用途有二：① 线路面板的行标题（旧写法一律叫「线路 N」——而中台一个源贡献整季，
    /// 实测一个条目 200 集，面板会列出「线路1…线路200」，把「集」显示成「线路」）；
    /// ② 选集面板之外回显（聚合源上的集**不在** `episodeGroups` 里，v78 的回显在那里是空白，
    /// 现在同样能给出「第N集」）。
    public func ordinalLabel(forLine line: Int) -> String? {
        guard hasEpisodeList,
              let bi = switchBlocks.firstIndex(where: { $0.contains(line) }),
              let p = switchBlocks[bi].firstIndex(of: line) else { return nil }
        return "第\(p + 1)集"
    }

    /// 线路面板的行标题：块内有多集 → 「第k集」；否则退回「线路 N」。
    /// 仅改**显示文字**：点击行为仍是 `switchToLine(idx)`（用户显式点哪条就播哪条），一字未动。
    public func lineLabel(forLine line: Int) -> String {
        ordinalLabel(forLine: line) ?? "线路 \(line + 1)"
    }

    /// 当前线路在其块内的位置（= 第几集，0 基）；不在任何块 → nil。
    public var currentBlockPos: Int? {
        guard let b = switchBlocks.first(where: { $0.contains(currentLine) }) else { return nil }
        return b.firstIndex(of: currentLine)
    }

    /// 当前线路所属的**块**（= 切集允许走的范围）。
    /// 兜底（理论上到不了）：`switchBlocks` 尚未覆盖该下标时回落所在大源组。
    private var currentEpisodeBlock: [Int] {
        if let b = switchBlocks.first(where: { $0.contains(currentLine) }), !b.isEmpty {
            return b
        }
        return sourceGroups.first(where: { $0.lines.contains(currentLine) })?.lines ?? []
    }

    /// 同源**下一集**下标（nil = 这份集列表已经没下一集了）。
    public var nextEpisodeLine: Int? {
        let b = currentEpisodeBlock
        guard let p = b.firstIndex(of: currentLine), p + 1 < b.count else { return nil }
        return b[p + 1]
    }

    /// 同源**上一集**下标（nil = 已是本源第一集）。
    public var prevEpisodeLine: Int? {
        let b = currentEpisodeBlock
        guard let p = b.firstIndex(of: currentLine), p > 0 else { return nil }
        return b[p - 1]
    }

    /// 播放结束 → 自动连播下一集（剧集模式；电影播完停在结尾，与大牌一致）。
    private func handlePlaybackDidFinish() {
        isBuffering = false
        // 设置页落地（2026-09-25）：「自动播下一集」开关接管剧集连播（关 = 播完停在结尾）
        // 注意：本函数在 PlayerViewModel（非 View）里，@AppStorage 不可见，须直读 UserDefaults
        let autoNext = UserDefaults.standard.object(forKey: "settings.autoNextEpisode") as? Bool ?? true
        guard autoNext else { return }
        // ★ v78：自动连播同样**只在本大源内**走 —— 否则放完主源最后一集会直接跳进
        //   下一个聚合源的第 1 集（与「点下一集回第1集」同一个根因）。到本源头就停住。
        guard hasNextEpisode, let next = nextEpisodeLine else { return }
        playEpisode(next)
    }

    // MARK: - 控制层指令

    public func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            userPaused = true
            player.pause()
        } else {
            userPaused = false
            player.play()
        }
    }

    public func skip(_ seconds: Double) {
        guard let player else { return }
        let target = max(0, player.currentTime().seconds + seconds)
        let dur = player.currentItem?.duration.seconds ?? 0
        let clamped = dur.isFinite && dur > 0 ? min(target, dur - 1) : target
        player.seek(to: CMTime(seconds: max(0, clamped), preferredTimescale: 600))
    }

    public func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    public func setRate(_ r: Double) {
        rate = r
        player?.rate = Float(r)          // 播放中直接改速率；暂停时静默记录
    }

    // MARK: - 长按加速（大牌标配：长按 2x，松手回原速）

    @Published public private(set) var boostActive = false
    private var boostSavedRate: Double = 1.0

    /// 长按开始：仅播放中生效，临时 2x（不改用户设置的倍速，不写 UserDefaults）
    public func beginBoost() {
        guard isPlaying, !boostActive else { return }
        let saved = rate
        boostSavedRate = saved
        boostActive = true
        player?.rate = 2.0
        filmLog.info("player: boost ON (2.0x, was \(saved))")
    }

    /// 长按结束：恢复原倍速
    public func endBoost() {
        guard boostActive else { return }
        boostActive = false
        let back = boostSavedRate
        player?.rate = Float(back)
        filmLog.info("player: boost OFF (back to \(back))")
    }

    /// 当前播放地址（分享/投屏用）
    public var currentURL: URL? {
        let urls = allLines
        guard urls.indices.contains(currentLine) else { return urls.first }
        return urls[currentLine]
    }

    // MARK: - 内部

    private func play(line: Int) {
        let urls = allLines
        guard urls.indices.contains(line) else {
            failed = true
            return
        }
        let url = urls[line]
        // ★ v69 源质量采样：每次发起起播都重置计时（成败分别由 timeControlStatus / 失败自愈落账）
        qualityProbeAt = Date()
        qualityProbeBrand = qualityBrandName(forLine: line)
        qualityProbeRecorded = false
        userPaused = false           // 主动起播/重连 = 用户意图是播放
        failed = false               // 46包：每次起播/重连先清失败态（误报失败面板的保险丝）
        switchingLine = false
        player?.pause()
        detachObservers()            // 旧会话观察者必须先拆，避免悬挂
        let p = AVPlayer(url: url)
        p.allowsExternalPlayback = true
        if rate != 1.0 { p.rate = Float(rate) }
        // 2026-10-01 三修：显式赋值（旧写法只在 >0 时覆盖）——否则上一次遗留的
        // `pendingResume` 会在「切集从头播」时被误用，把新一集跳到旧一集的点位上。
        pendingResume = resumeSeconds > 0 ? resumeSeconds : 0
        resumeSeekInFlight = false
        player = p
        registerObservers()          // 每个新 AVPlayer 都要重挂（重试/切线路后失败态才可感知）
        startAdDetection(for: url)   // v61：异步识别本线路的插播广告段（识别不到就不做任何事）
        isBuffering = true
        p.play()
        if reconnectTries == 0 { startedAt = Date() }   // 只有真起播算宽限，重连不算
    }

    /// v69：一次起播只记一条成功样本（耗时 = 发起播放 → 首次真正 .playing）。
    private func recordQualitySuccessIfNeeded() {
        guard !qualityProbeRecorded, let at = qualityProbeAt else { return }
        qualityProbeRecorded = true
        SourceQualityRank.shared.recordSuccess(qualityProbeBrand, startSeconds: Date().timeIntervalSince(at))
    }

    private func detachObservers() {        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        observers.forEach { $0.invalidate() }
        observers.removeAll()
    }

    private func registerObservers() {
        guard let player else { return }
        // 播放结束：剧集自动连播下一集（大牌式；此前播完直接卡死在最后一帧 = 「不自动换下一集」根因）
        if let currentItem = player.currentItem {
            let token = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handlePlaybackDidFinish() }
            }
            notifObservers.append(token)
        }
        // AVPlayerItem 级错误观察：源站挂掉/流失效在这里报 failed，
        // AVPlayer.status 永远保持 readyToPlay —— 只看它会"缓冲中"卡到天荒地老
        if let currentItem = player.currentItem {
            // 2026-10-01 三修（主人仍报「续播没生效」）：`options` 加 **`.initial`**。
            // 只用 `.new` 时，若 item 在**观察挂上之前**就已经 readyToPlay（缓存的 playlist
            // / 快速 CDN），这条回调**永远不会触发** → 续播定点从没执行过 → 每次都从头。
            // `.initial` 让观察一挂上就用**当前值**回调一次，把这个窗口彻底堵死。
            observers.append(currentItem.observe(\.status, options: [.new, .initial]) { [weak self] it, _ in
                Task { @MainActor in
                    guard let self else { return }
                    // 2026-09-30 用户报「详情里显示上次播放时间，进去却从头播」：
                    // 根因＝`AVPlayer(url:)` 之后**立刻** seek，此刻 item 尚未 readyToPlay，
                    // 这一刀会被丢弃（或被随后起播的 0 覆盖）→ 看到的就是"从头开始"。
                    // 正解＝把续播点位记在 `pendingResume`，等 **item 真正 readyToPlay** 再定点。
                    //
                    // 2026-10-01 二修（主人：「上次播放进度怎么又不能了 又从头播放了」）：
                    // 「等 readyToPlay 再 seek」这个方向是对的，但那一版**容差给了 `.zero`**。
                    // 远端 HLS 上精确 seek 要求该时刻所在分片已经就绪；没就绪时 AVPlayer 会
                    // **丢弃这一刀**（或被紧接着的起播 0 覆盖）→ 端上仍是「详情页写着续播 mm:ss，
                    // 进去还是从头」。正解三条：① 容差交回系统（±0.5s，HLS 容忍到邻近可 seek 点即可）；
                    // ② **以 seek 完成回调为准**，finished=false 就重试（最多 3 次）；
                    // ③ 确认落点后才清 `pendingResume`，不再"先清后做"（清了但没跳成就彻底丢了）。
                    if it.status == .readyToPlay, self.pendingResume > 0 {
                        self.seekToResume(it, seconds: self.pendingResume, attempt: 0)
                    }
                    guard it.status == .failed else { return }
                    filmLog.error("player: item FAILED err=\(it.error?.localizedDescription ?? "nil") url=\(it.asset as? AVURLAsset != nil ? "ok" : "?")")
                    self.isBuffering = false
                    self.handlePlaybackFailure()
                }
            })
        }
        observers.append(player.observe(\.status, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                switch p.status {
                case .failed:
                    filmLog.error("player: AVPlayer FAILED err=\(p.error?.localizedDescription ?? "nil")")
                    self?.failed = true
                    self?.switchingLine = false
                case .readyToPlay:
                    self?.failed = false
                    self?.switchingLine = false
                default: break
                }
            }
        })
        observers.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                self?.isPlaying = (p.timeControlStatus == .playing)
                // 缓冲态唯一真源：waiting = 转圈，playing/paused = 收起
                //（此前 isBuffering 只在 play() 置 true 无人复位，导致"缓冲中"永久卡屏）
                self?.isBuffering = (p.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                if p.timeControlStatus == .playing {
                    self?.switchingLine = false
                    self?.recordQualitySuccessIfNeeded()   // v69：首次真正起播 → 落一条成功样本
                }
            }
        })
        // 0.5s 高频观察：驱动控制层时间轴；历史落盘仍按 15s 节流；兼做卡死看门狗
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                let sec = t.seconds
                if sec.isFinite { self.currentTime = sec }
                self.skipInsertedAdIfNeeded(at: sec)   // v61：播放头进入广告段即跳过
                if let d = self.player?.currentItem?.duration.seconds, d.isFinite { self.duration = d }
                // 看门狗（46包重做）：①画面推进即自动撤销失败/切换误报；②暂停不判死、
                // 起播 10s 宽限；③卡死 18s 先原地重连×2 再换线路，全试过才判失败
                if sec - self.lastProgressSeconds > 0.4 {
                    self.lastProgressSeconds = sec
                    self.lastProgressAt = Date()
                    if self.failed || self.switchingLine {
                        self.failed = false
                        self.switchingLine = false
                        self.reconnectTries = 0
                        self.autoSwitchCount = 0
                    }
                } else if self.isBuffering, !self.failed, !self.userPaused,
                          Date().timeIntervalSince(self.startedAt) > 10,
                          Date().timeIntervalSince(self.lastProgressAt) > 18 {
                    self.lastProgressAt = Date()
                    self.handlePlaybackFailure()
                }
                if sec - self.lastRecorded >= 15 {
                    self.lastRecorded = sec
                    self.recordProgress()
                }
                // 2026-10-01 三修兜底：万一 KVO 那一路没赶上（挂观察前就已 ready / 被系统吞），
                // 只要还欠着一次续播定点、且 item 已就绪，这里每 0.5s 补一次，直到落地。
                // v61：续播点若正好落在广告段里 → 先推到广告段之后再定点（否则一进去就先看广告）
                if self.pendingResume > 0,
                   let hit = self.adRanges.first(where: {
                       self.pendingResume >= $0.start - 0.5 && self.pendingResume < $0.end
                   }) {
                    self.pendingResume = hit.end + 0.05
                }
                if self.pendingResume > 0, !self.resumeSeekInFlight,
                   let it = self.player?.currentItem, it.status == .readyToPlay {
                    self.seekToResume(it, seconds: self.pendingResume, attempt: 0)
                }
            }
        }
    }

    /// 播放失败自愈（46包重做 + v78.2 保集换源）：先原地重连同一线路×2（网络抖动不判死），
    /// 再**逐个换源（换的是另一个源的同一集）**；全部块轮完才亮失败面板。
    /// ★ v67 分层口径仍成立：`switchBlocks` 的顺序 = 同一大源的多条线路在前、其后才是下一个大源，
    ///   所以「先同源线路、轮尽再跨源」是自动满足的 —— 且**不再靠「组内下标 +1」实现**
    ///  （那在中台数据里等于「下一集」，就是主人报的「不播放的源直接跳集」）。
    private func handlePlaybackFailure() {
        if reconnectTries < 2 {
            reconnectTries += 1
            filmLog.info("player: stall → 原地重连 x\(self.reconnectTries) line=\(self.currentLine)")
            // 2026-10-01 三修：续播定点尚未落地时**不许把点位冲成 0** ——
            // 旧写法取 currentTime（此时还在 0）→ resumeSeconds=0 → 重连后 pendingResume=0
            // → 续播彻底丢失。欠着定点就一直欠着。
            resumeSeconds = pendingResume > 0 ? pendingResume : max(currentTime, 0)
            play(line: currentLine)   // 同一线路重拉（reconnectTries>0 → 不重置 startedAt 宽限）
            return
        }
        reconnectTries = 0
        // ★ v69 源质量采样：原地重连 ×2 仍救不回来 → 记这个**大源**一次失败（跨启动累积）
        SourceQualityRank.shared.recordFailure(qualityBrandName(forLine: currentLine))
        autoSwitchCount += 1
        // ★ v78.2（主人 2026-10-05：「**不播放的源直接跳集不是在换源**」）——
        //   旧写法取 `sourceGroups[g].lines[pos + 1]`，注释写的是「同大源内换下一条小源」，
        //   但**中台数据的一个源贡献的是整季**（`play.lines` 每集一条、quality 恒空），
        //   所以「组内相邻下标」= **同一源的下一集** → 表现就是「源播不了就跳集」。
        //   正解 = 一律走 `switchToNextSource()`（**换到另一个源的同一集**）。
        //   轮次上限改用**块数**（= 线路数），不再用 allLines.count（那是集数，会多轮上百次）。
        guard autoSwitchCount <= max(switchBlocks.count, 1) else {
            LiveDiag.write("播放失败·换源轮尽 \(item.title) line=\(currentLine)/\(allLines.count) 块数=\(switchBlocks.count)")
            failed = true
            return
        }
        // ★ v78.3（主人 2026-10-05 报「中间的暂停播放下一集上一集不见了只有底部还在」）——
        //   **本处是那次消失的源头**：v78.2 在这里写了 `else { failed = true }`
        //   ——「本片没有别的源可换」时**直接判死**。两个后果：
        //     ① 判死后看门狗（`else if self.isBuffering, !self.failed, …`）**不再周期性自愈**，
        //        网络抖一下也要用户手动点「重试」；
        //     ② `failed == true` 又让居中三钮被 `!model.failed` 整块收起（见 354 行）=
        //        「按钮凭空消失」。
        //   旧行为（v78.2 之前）= **不判死、保持原地、等下个 18s 周期重走「重连×2 → 换源」**。
        //   恢复旧行为（并把轮次计数归零，让每轮都是完整流程）——「宁可不治也不能错治」。
        guard switchToNextSource() != nil else {
            autoSwitchCount = 0
            LiveDiag.write("播放失败·无源可换(原地等待) \(item.title) line=\(currentLine)/\(allLines.count) 块数=\(switchBlocks.count)")
            return
        }
    }

    /// 续播定点（2026-10-01）：有容差 + 以完成回调为准 + 重试。
    /// 为什么不能只发一刀就算了：远端 HLS 的 seek 在目标分片未就绪时会返回 `finished == false`
    /// 并**原地不动**；旧实现既不看回调、也不重试，于是「续播」在慢源上一次都没生效过。
    private func seekToResume(_ item: AVPlayerItem, seconds t: Double, attempt: Int) {
        guard !resumeSeekInFlight else { return }     // 防周期观察重入叠探
        resumeSeekInFlight = true
        traceResume("seek start t=\(Int(t)) attempt=\(attempt + 1) status=\(item.status.rawValue)")
        item.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                  toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
                  toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                if finished {
                    self.pendingResume = 0
                    self.resumeSeekInFlight = false
                    self.currentTime = t
                    self.traceResume("seek DONE -> \(Int(t))s（第 \(attempt + 1) 次）")
                    filmLog.info("player: 续播定点完成 -> \(Int(t))s（第 \(attempt + 1) 次）")
                } else if attempt < 2 {
                    self.resumeSeekInFlight = false
                    self.traceResume("seek retry \(attempt + 2) -> \(Int(t))s")
                    filmLog.info("player: 续播 seek 未完成，重试第 \(attempt + 2) 次 -> \(Int(t))s")
                    self.seekToResume(item, seconds: t, attempt: attempt + 1)
                } else {
                    self.pendingResume = 0
                    self.resumeSeekInFlight = false
                    self.traceResume("seek GIVEUP -> \(Int(t))s")
                    filmLog.error("player: 续播 seek 三次均未完成，放弃 -> \(Int(t))s")
                }
            }
        }
    }

    // MARK: - v61 插播广告段（2026-10-04）

    /// 异步识别本线路播放列表里的插播广告段。
    ///
    /// 只在**识别成功**时才写入 `adRanges`；识别不到（绝大多数源）→ 保持空数组 → 一秒都不跳。
    /// 判据见 `AdBreakDetector`：广告分片路径带 `adjump` 特征（正片是 `0000000.ts` 连续编号）。
    private func startAdDetection(for url: URL) {
        adRanges = []
        lastAdSkippedEnd = -1
        adDetectToken += 1
        let token = adDetectToken
        // 设置页开关（默认开）
        let enabled = UserDefaults.standard.object(forKey: "settings.skipInsertedAds") as? Bool ?? true
        guard enabled else {
            filmLog.info("adskip: 设置已关闭，不识别")
            return
        }
        guard url.absoluteString.lowercased().contains(".m3u8") else {
            filmLog.info("adskip: 非 m3u8 线路，跳过识别")
            return
        }
        AdBreakDetector.detect(playlistURL: url) { [weak self] outcome in
            Task { @MainActor in
                guard let self, token == self.adDetectToken else { return }
                self.adRanges = outcome.ranges
                if outcome.ranges.isEmpty {
                    filmLog.info("adskip: 未命中 → 不跳（\(outcome.reason)）")
                } else {
                    let desc = outcome.ranges
                        .map { "\(Int($0.start))-\(Int($0.end))s" }
                        .joined(separator: ", ")
                    filmLog.info("adskip: 命中 \(outcome.ranges.count) 段 [\(desc)]（\(outcome.reason)）")
                }
            }
        }
    }

    /// 播放头进入广告区间 → 越到段尾。只对**识别出的**区间生效；用户主动暂停时不打扰。
    private func skipInsertedAdIfNeeded(at sec: Double) {
        guard !adRanges.isEmpty, sec.isFinite, !userPaused else { return }
        guard let hit = adRanges.first(where: { sec >= $0.start - 0.35 && sec < $0.end - 0.25 }) else { return }
        guard abs(hit.end - lastAdSkippedEnd) > 0.01 else { return }   // 同一段只跳一次
        lastAdSkippedEnd = hit.end
        let target = hit.end + 0.05
        filmLog.info("adskip: 跳过广告段 \(Int(hit.start))s→\(Int(hit.end))s，seek -> \(Int(target))s")
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func recordProgress() {
        guard let player, let duration = player.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }
        let progress = player.currentTime().seconds
        guard progress.isFinite else { return }
        UserLibrary.shared.recordWatch(item, progress: progress, duration: duration, lineIndex: currentLine)
    }
}

// MARK: - 深色播放器里的「真·毛玻璃」

/// 为什么需要它（2026-09-30 用户第二次拍桌：「倍速还是黑框！你全局检查过吗？」）：
///
/// `.ultraThinMaterial` 的观感**取决于 colorScheme** —— 播放器外层强制 `.environment(\.colorScheme, .dark)`，
/// 材质于是解析成**深灰**，压在黑色视频上看着仍然就是一块黑框。也就是说：
/// 「加了 ultraThinMaterial」**不等于**「用户看到毛玻璃」——这是上一版没解决的真根因。
///
/// 正解＝在材质之上再叠一层**极淡的白色提亮** + 更亮的**细描边** + 投影，
/// 做出"一层玻璃浮在画面上"的层次（爱优腾的浮层都是这个观感：不是纯黑底，而是半透 + 亮边）。
private struct PlayerGlassBackground: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Double
    /// 2026-10-01 主人钦定「跟着海报」：**传了就完全不挂材质**，改叠海报主色（`palette.deep`）。
    /// `nil` = 保持既有「材质 + 中性压暗」行为 —— 其余 5 个调用点（音量 HUD / 底栏小钮 / 中央大钮）
    /// 一个都没动，只有倍速条、音量条、选集 sheet、线路 sheet 这 4 处走新档。
    var palette: HeroPalette? = nil
    /// 海报色占比（仅 `palette != nil` 时生效）。0.62 = 六成海报色、四成透出画面。
    var alpha: Double = 0.62

    func body(content: Content) -> some View {
        // 2026-10-01 用户：「player 那也要用我们这种吗？看那个更合适一点 你觉得呢」
        //   结论＝**播放器不能照搬设置页的 `.clear`（不挂材质）**：设置页面板背后是静态取色底，
        //   不挂材质=完全跟底；而这里背后是**会动的视频、明暗不定** —— 不挂材质时浅画面白字直接糊掉。
        //   但旧写法（.thinMaterial + 白提亮渐变）正是「倍速还是黑框 / 灰框」的根因：
        //   深色 colorScheme 下 thinMaterial 解析成深灰，再叠白色渐变 → 洗成一块灰。
        //   正解（爱优腾浮层观感）：**虚化 + 均匀压暗**。换成更透的 ultraThinMaterial（画面透得上来），
        //   把"白提亮"换成"中性压暗"（黑在最暗处，不会洗灰），亮发丝边 + 投影保留"浮在画面上"的层次。
        //   tint 语义随之从「白提亮量」变为「压暗量」；下限 0.30 保证任何画面（含雪景/白墙）下白字可读。
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // ★ 2026-10-01 主人钦定「跟着海报」——**跟海报档与挂材质档互斥**，根因是：
        //   `Material`（不论 .thin / .ultraThin）都会把**底下颜色的饱和度抽干**，
        //   面板必然落成中性灰（真机实测：四张主色完全不同的海报，挂材质后全落在 #2B2C2D，
        //   而“不挂材质 + 叠海报色”四张分别是 #0E1A3E / #431D18 / #0F2729 / #340C32）。
        //   所以：要跟随海报变色，就**不能再挂任何材质**，颜色只能靠自己叠上去。
        //   浅画面下白字可读性由调用点的字描边/投影兜（本文件各浮层已带 text-shadow）。
        let followingPoster = palette != nil
        return content
            .background {
                if let p = palette {
                    shape.fill(p.deep.alpha(alpha))
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.black.opacity(max(tint, 0.30)))
                    }
                }
            }
            .overlay {
                shape.stroke(Color.white.opacity(followingPoster ? 0.22 : 0.30),
                             lineWidth: followingPoster ? 0.6 : 0.7)
            }
            .shadow(color: .black.opacity(followingPoster ? 0.32 : 0.30),
                    radius: followingPoster ? 14 : 12, y: followingPoster ? 5 : 4)
    }
}

extension View {
    /// 深色播放器专用毛玻璃（原理见 `PlayerGlassBackground`）。
    ///
    /// `palette`（2026-10-01 主人钦定「跟着海报 还有那个倍数的也是跟着海报」）：
    /// 非 nil 时**不挂材质**、改叠该海报的 `deep` 主色；nil = 旧观感不变。
    func playerGlass(cornerRadius: CGFloat = 16, tint: Double = 0.16,
                     palette: HeroPalette? = nil, alpha: Double = 0.62) -> some View {
        modifier(PlayerGlassBackground(cornerRadius: cornerRadius, tint: tint,
                                       palette: palette, alpha: alpha))
    }

    /// 弹层（sheet）专用毛玻璃。
    ///
    /// 与 `playerGlass` 同因：sheet 自带的 `presentationBackground(.ultraThinMaterial)` 在深色下同样偏黑，
    /// 所以统一换成 `FilmGlassBackground`。全 App 弹层共用此一处，避免"改了 A 忘了 B"。
    ///
    /// `weight`（2026-10-01 新增）——用户：「我确定去掉了这个能成 那就把选集那个也弄了 还有那个倍数
    /// 播放那个都一起弄了」：
    ///   · 默认 `.regular` ＝ 既有观感**不变**（LibraryView / LiveView / SettingsView / SiteBrowseView 的
    ///     弹层背后是静态取色底，照旧）；
    ///   · **播放器里的弹层传 `.dark`** —— 它们背后是**会动的视频**、明暗不定：
    ///     既不能照搬设置页的 `.clear`（不挂材质时浅画面白字直接糊掉），
    ///     也不能继续用 `.regular`（深色 colorScheme 下 thinMaterial 解析成深灰 + 上面那层白提亮
    ///     渐变 → 洗成一块灰，这正是用户两次拍桌「选集也是黑框 / 灰框」的同一个根因）。
    ///     `.dark` ＝ 虚化（ultraThinMaterial）+ **中性压暗**，见 `FilmGlassWeight`。
    /// `tint` 语义随档位：`.regular` = 白提亮量；`.dark` = 压暗量。
    /// `palette`（2026-10-01 主人钦定「跟着海报」）：非 nil 时同样**不挂材质**，
    /// 整面铺海报 `deep` 主色（剩下的比例透出后面的视频）；nil = 旧观感不变。
    func glassSheet(tint: Double = 0.10, weight: FilmGlassWeight = .regular,
                    palette: HeroPalette? = nil, alpha: Double = 0.62) -> some View {
        // 2026-09-30 用户钦定：菜单底 = 主页详情页同款透明玻璃（FilmGlassBackground），
        // 透出背后内容跟着变色 —— 不再是深色模式材质的偏黑实底。
        presentationBackground {
            if let p = palette {
                // 跟海报档：同 `PlayerGlassBackground` —— 要跟海报就**不能挂材质**（材质会抽干颜色）。
                p.deep.alpha(alpha).ignoresSafeArea()
            } else {
                FilmGlassBackground(cornerRadius: 0, tint: tint, strokeOpacity: 0, weight: weight)
                    .ignoresSafeArea()
            }
        }
    }
}
