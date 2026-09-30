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
    @StateObject private var model: PlayerViewModel

    @State private var showControls = true
    @State private var locked = false
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
                extraLines: [URL] = [], onClose: (() -> Void)? = nil,
                episodeGroups: [(line: String, eps: [(index: Int, name: String)])] = [],
                onEpisodeChange: ((String) -> Void)? = nil) {
        self.item = item
        self.startAtResume = startAtResume
        self.onClose = onClose
        self.episodeGroups = episodeGroups
        self.onEpisodeChange = onEpisodeChange
        _model = StateObject(wrappedValue: PlayerViewModel(item: item, initialLine: startLine,
                                                           extraLines: extraLines,
                                                           hasEpisodeList: !episodeGroups.isEmpty))
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
                guard !locked else { return }   // 锁定时只认解锁按钮
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
            if model.isBuffering, !model.failed, !model.switchingLine {
                VStack(spacing: 10) {
                    ProgressView().tint(.white).controlSize(.large)
                    Text("缓冲中…").font(.footnote).foregroundStyle(.white.opacity(0.8))
                        .shadow(color: .black.opacity(0.7), radius: 3)
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
                // 锁定态：横屏左中解锁键；竖屏右上解锁键（爱优腾位）。
                if isLandscape { lockControl } else { lockControl(topRight: true) }
            } else if showControls {
                // 2026-09-30：锁屏键分方向 —— 竖屏在顶栏右上（爱优腾同款），
                // 横屏保持左侧垂直居中；竖屏不再额外渲染左中锁键（找不到+易误触）。
                if isLandscape { lockControl }
                topBar
                bottomBar
                // 48包（用户：「暂停快进怎么没了 要隐藏也没说不要暂停快进」）：
                // 爱腾优式——居中三钮是控制层的**一部分**，随控制层同显隐。
                // 旧实现是挂在系统窗口上的 UIKit 条，与控制层各走各的，显隐对不上=看起来"消失"。
                // 2026-09-30 用户「横屏你看看爱优腾怎么放的都什么按钮」：横屏的播放主控已并进
                // **底栏同一行**，居中这组再出现就是同一功能两处重复 → 仅竖屏保留。
                if !model.failed && !isLandscape { centerTransportRow }
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
        .onAppear {
            model.start(resume: startAtResume)
            if savedRate != 1.0 { model.setRate(savedRate) }
            sliderVolume = Double(PlayerVolumeController.current())
            setLandscape(true)
            scheduleHide()
            activateAudioSessionIfNeeded()
            // v13 音量提示条：KVO 监听系统音量（物理音量键）——MPVolumeView 锚点抑制了系统 HUD
            volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { _, _ in
                Task { @MainActor in showVolumeHUD(Double(PlayerVolumeController.current())) }
            }
            // 46包：撤掉「Build 20260922-xx」闪现——小白用户看不懂还截图问「这是啥玩意」；
            // 包版本核验走 LC 内二进制探针，不再打扰播放画面。
        }
        .onDisappear {
            gone = true
            model.stop()
            setLandscape(false)
            volumeObserver?.invalidate()
            volumeObserver = nil
            volumeHUDHideTask?.cancel()
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

    /// 居中左钮可点条件（有选集列表 且 不是第一集）；电影恒 false → 置灰。
    private var canPlayPrev: Bool {
        model.hasEpisodeList && model.currentLine > 0
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
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                // 2026-09-30 用户「锁屏呢？横屏正常竖屏不行」：竖屏锁屏 = 爱优腾同款放**右上角**
                //（横屏保持左侧垂直居中，见 playerBody 分支；竖屏不再渲染左中锁键）。
                if !isLandscape {
                    Button {
                        locked.toggle()
                        showControls = true
                        scheduleHide()
                    } label: {
                        Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            .frame(width: 40, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(locked ? "解锁" : "锁定")
                }
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
                compactIcon("list.bullet.rectangle", label: "选集") {
                    showEpisodePanel = true
                    hideTask?.cancel()
                }
            }
            compactIcon("speedometer", label: "倍速 \(rateLabel)") {
                showRateSelector.toggle()
                hideTask?.cancel()
            }
            if model.allLines.count > 1 {
                compactIcon("arrow.triangle.2.circlepath",
                            label: "换源 \(model.currentLine + 1)/\(model.allLines.count)") {
                    model.switchToNextLine()
                    showSeekToast("已换源 \(model.currentLine + 1)/\(model.allLines.count)")
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
    private func compactIcon(_ systemName: String, label: String, enabled: Bool = true,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
                .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                .frame(width: 38, height: 36)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
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
                barIcon("list.bullet.rectangle", label: "选集") {
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
            if model.allLines.count > 1 {
                // 大牌式一键换源：直接循环切下一条线路（保留进度），不弹列表
                barIcon("arrow.triangle.2.circlepath",
                        label: "换源 \(model.currentLine + 1)/\(model.allLines.count)") {
                    model.switchToNextLine()
                    showSeekToast("已换源 \(model.currentLine + 1)/\(model.allLines.count)")
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
    private func barIcon(_ systemName: String, label: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
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

    /// 片尾 90s 内且还有下一集 → 浮现「下一集」（自动连播的手动兜底）。
    private var showNextEpisode: Bool {
        model.hasEpisodeList
            && model.duration > 0
            && model.currentLine + 1 < model.allLines.count
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
        .playerGlass(cornerRadius: 16)
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
        .playerGlass(cornerRadius: 16)
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
        guard model.hasNextEpisode else { return }
        let next = model.allLines.index(after: model.currentLine)
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
        guard model.currentLine > 0 else { return }
        let prev = model.allLines.index(before: model.currentLine)
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
    private func episodeName(at index: Int) -> String? {
        for g in episodeGroups {
            if let ep = g.eps.first(where: { $0.index == index }) { return ep.name }
        }
        return nil
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

            ScrollView {
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
        }
        // 2026-09-30 用户：「整个面板大小…明明一半大小就够弄那么大」→ 初始只占 38% 屏高
        .presentationDetents([.fraction(0.38), .large])
        // 2026-09-30 用户：「选集面板也用了黑框」「我要的是毛玻璃」。
        // 面板自身没写黑底 —— 是播放器外层强制 `colorScheme: .dark`，sheet 就跟着吃系统深色底
        // （看起来就是一块死黑）。这里显式换成毛玻璃，后面的画面能透上来，与播放器其余浮层一致。
        // 2026-10-01 用户「把选集那个也弄了」：与 `playerGlass`（倍速档位条）统一走 `.dark` 档 ——
        // 虚化 + 中性压暗，不再靠「白提亮」跟深色材质打架洗出灰块。
        .glassSheet(tint: 0.30, weight: .dark)
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
        // 与选集面板同一档（`.dark`）：背后是会动的视频，虚化 + 中性压暗。
        .glassSheet(tint: 0.30, weight: .dark)
    }

    private var lineList: some View {
        List {
            ForEach(Array(model.allLines.enumerated()), id: \.offset) { pair in
                lineRow(pair.offset, url: pair.element)
                    // 毛玻璃面板里的行不能再铺自己的不透明底，否则又成"一行行黑框"
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
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
                Text("线路 \(idx + 1)").foregroundStyle(.primary)
                if idx == model.currentLine {
                    Text("播放中").font(.caption2).foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text(url.host ?? "").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// 锁屏键（2026-09-30 用户「还有那个锁屏应该在哪大小」）。
    ///
    /// **位置**：屏幕**左侧边缘、垂直居中** —— 爱优腾同款。理由：横屏时这是左手拇指的
    /// 自然落点，比顶栏右上角好按得多；而且锁定前后是**同一个键**（用户 2026-09-30 早先
    /// 也提过「点完锁屏怎么还跑左面去了保持原地」——原地切换才不"跳"）。
    ///
    /// **大小**：38pt 玻璃圆 + 16pt 图标（约等于底栏图标量级）。再大就抢画面、
    /// 再小在横屏远看按不准；点击区用 `contentShape` 补到 38×38 实心。
    @ViewBuilder private var lockControl: some View { lockControl(topRight: false) }

    /// 锁屏键浮层：默认**左侧垂直居中**（横屏爱优腾位）；topRight=true = **右上角**（竖屏爱优腾位）。
    private func lockControl(topRight: Bool) -> some View {
        VStack {
            if topRight {
                HStack { Spacer(); lockButton.padding(.trailing, 14) }
                Spacer()
            } else {
                Spacer()
                HStack { lockButton.padding(.leading, 14); Spacer() }
                Spacer()
            }
        }
    }

    private var lockButton: some View {
        Button {
            locked.toggle()
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
        if showControls {
            // 2026-10-01 真机实测取证（pymobiledevice3 注入触摸 + 时间戳连拍，非猜测）：
            //   单击**确实能**唤出控制层 —— 点完 +2.5s 的帧里底栏白像素占比 0.0378（可见），
            //   +4.9s 的帧回到 0.0000（已被 3.4s 自动隐藏收走）。所以「唤不出」不是触摸不通。
            //   真凶＝「点一下开 / 再点一下关」的 toggle 撞上人连点的节奏：
            //   实测间隔 1.0s 连点两下 → 结束后控制层消失（奇数下可见、偶数下归零）。
            //   上一轮 0.35s 宽限太窄，人的连点间隔典型在 0.4~1.5s，正好全落在 toggle 上。
            // 束法（保留钦定的"再点一下收起"）：宽限放宽到 1.2s，且宽限内**也刷新计时**，
            //   连点必然保持可见；想真收起 = 单点后 ≥1.2s 再点，或等 3.4s 自动隐藏。
            if Date().timeIntervalSince(lastShowAt) < 1.2 {
                lastShowAt = Date()
                if model.isPlaying { scheduleHide() }
                return
            }
            showControls = false      // 已显示且稳定 ≥1.2s → 视为"再点一下收起"
            showRateSelector = false
            showVolumeSlider = false
            hideTask?.cancel()
        } else {
            showControls = true
            lastShowAt = Date()
            showRateSelector = false
            showVolumeSlider = false
            if model.isPlaying {
                scheduleHide()
            } else {
                hideTask?.cancel()    // 暂停态保持常显
            }
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
            let up = translation.height < 0
            let worth = abs(translation.height) >= 60
            let name: String?
            if up { name = episodeName(at: model.currentLine + 1) } else { name = episodeName(at: model.currentLine - 1) }
            if !worth {
                seekToast = up ? "↑ 上滑下一集" : "↓ 下滑上一集"
            } else if up, model.hasNextEpisode {
                seekToast = "↑ 下一集 " + (name ?? "")
            } else if !up, model.currentLine > 0 {
                seekToast = "↓ 上一集 " + (name ?? "")
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
        let target = model.currentLine + offset
        guard target >= 0, target < model.allLines.count else {
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
        isLandscape = on
        let mask: UIInterfaceOrientationMask = on ? .landscapeRight : .portrait
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
    }

    /// 2026-10-01 根修：把 `isLandscape` 拉回**容器真实宽高**。
    /// 旋转请求可能被宿主（LiveContainer）/ 系统竖屏锁定挡掉 —— 那时状态若仍是"横屏"，
    /// 横屏排版就会被塞进竖屏窗口，出现「顶栏分享被挤出屏、锁屏键在左边缘被裁、
    /// 进度条压成 0 宽只剩一颗白球」这些溢出。以真实宽高为准即可两头都对。
    private func syncLandscape(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let land = size.width > size.height
        if land != isLandscape { isLandscape = land }
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
    private var lastRecorded = 0.0
    private var lastProgressSeconds = 0.0
    private var lastProgressAt = Date()
    private var autoSwitchCount = 0
    private var reconnectTries = 0        // 46包：同线路原地重连计数（网络抖动不直接判死）
    private var userPaused = false        // 46包：用户主动暂停时看门狗不生效（暂停≠卡死）
    private var startedAt = Date()        // 46包：起播 10s 宽限（起播慢≠失败）
    private let initialLine: Int          // 详情页选集进入时的起始集（playCandidates 下标）
    private let extraLines: [URL]         // 详情页聚合的外部源线路（同名片跨 CMS 源）
    /// 是否剧集（选集面板传入）——决定自动连播与「下一集」按钮的可用性
    let hasEpisodeList: Bool
    private var notifObservers: [NSObjectProtocol] = []

    public init(item: FeedItem, initialLine: Int = 0, extraLines: [URL] = [],
                hasEpisodeList: Bool = false) {
        self.item = item
        self.initialLine = max(0, initialLine)
        self.extraLines = extraLines
        self.hasEpisodeList = hasEpisodeList
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

    // MARK: - 生命周期

    public func start(resume: Bool) {
        UIApplication.shared.isIdleTimerDisabled = true     // 播放中屏幕常亮
        if let entry = UserLibrary.shared.historyEntry(for: item), resume {
            resumeSeconds = entry.progressSeconds
        }
        // 起始集：详情页选集进入时直落该集；越界兜底回第1候选
        play(line: initialLine < allLines.count ? initialLine : 0)
    }

    public func stop() {
        UIApplication.shared.isIdleTimerDisabled = false    // 退出自动恢复系统默认
        recordProgress()
        detachObservers()
        player?.pause()
        player = nil
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

    public func switchToNextLine() {
        switchToLine((currentLine + 1) % max(allLines.count, 1))
    }

    public func switchToLine(_ line: Int) {
        let count = allLines.count
        guard count > 1, line != currentLine, line >= 0, line < count else { return }
        resumeSeconds = player.flatMap { $0.currentTime().seconds.isFinite ? $0.currentTime().seconds : 0 } ?? resumeSeconds
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
    public var hasNextEpisode: Bool {
        hasEpisodeList && currentLine + 1 < allLines.count
    }

    /// 播放结束 → 自动连播下一集（剧集模式；电影播完停在结尾，与大牌一致）。
    private func handlePlaybackDidFinish() {
        isBuffering = false
        // 设置页落地（2026-09-25）：「自动播下一集」开关接管剧集连播（关 = 播完停在结尾）
        // 注意：本函数在 PlayerViewModel（非 View）里，@AppStorage 不可见，须直读 UserDefaults
        let autoNext = UserDefaults.standard.object(forKey: "settings.autoNextEpisode") as? Bool ?? true
        guard autoNext else { return }
        guard hasNextEpisode else { return }
        playEpisode(currentLine + 1)
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
        userPaused = false           // 主动起播/重连 = 用户意图是播放
        failed = false               // 46包：每次起播/重连先清失败态（误报失败面板的保险丝）
        switchingLine = false
        player?.pause()
        detachObservers()            // 旧会话观察者必须先拆，避免悬挂
        let p = AVPlayer(url: url)
        p.allowsExternalPlayback = true
        if rate != 1.0 { p.rate = Float(rate) }
        if resumeSeconds > 0 {
            // 2026-09-30 续播修复：不再在这里立刻 seek（此时 item 未 ready，会被丢），
            // 只记下待定点，由 item readyToPlay 回调执行（见 registerObservers）。
            pendingResume = resumeSeconds
        }
        player = p
        registerObservers()          // 每个新 AVPlayer 都要重挂（重试/切线路后失败态才可感知）
        isBuffering = true
        p.play()
        if reconnectTries == 0 { startedAt = Date() }   // 只有真起播算宽限，重连不算
    }

    private func detachObservers() {
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
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
            observers.append(currentItem.observe(\.status, options: [.new]) { [weak self] it, _ in
                Task { @MainActor in
                    guard let self else { return }
                    // 2026-09-30 用户报「详情里显示上次播放时间，进去却从头播」：
                    // 根因＝`AVPlayer(url:)` 之后**立刻** seek，此刻 item 尚未 readyToPlay，
                    // 这一刀会被丢弃（或被随后起播的 0 覆盖）→ 看到的就是"从头开始"。
                    // 正解＝把续播点位记在 `pendingResume`，等 **item 真正 readyToPlay** 再定点。
                    if it.status == .readyToPlay, self.pendingResume > 0 {
                        let t = self.pendingResume
                        self.pendingResume = 0
                        it.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                        self.currentTime = t
                        filmLog.info("player: 续播定点完成 -> \(Int(t))s")
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
                if p.timeControlStatus == .playing { self?.switchingLine = false }
            }
        })
        // 0.5s 高频观察：驱动控制层时间轴；历史落盘仍按 15s 节流；兼做卡死看门狗
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                let sec = t.seconds
                if sec.isFinite { self.currentTime = sec }
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
            }
        }
    }

    /// 播放失败自愈（46包重做）：先原地重连同一线路×2（网络抖动不判死），
    /// 再自动换下一线路；全部试过才亮失败面板。
    private func handlePlaybackFailure() {
        if reconnectTries < 2 {
            reconnectTries += 1
            filmLog.info("player: stall → 原地重连 x\(self.reconnectTries) line=\(self.currentLine)")
            resumeSeconds = max(currentTime, 0)
            play(line: currentLine)   // 同一线路重拉（reconnectTries>0 → 不重置 startedAt 宽限）
            return
        }
        reconnectTries = 0
        autoSwitchCount += 1
        guard autoSwitchCount <= allLines.count, allLines.count > 1 else {
            failed = true
            return
        }
        switchToNextLine()
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
        return content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color.black.opacity(max(tint, 0.30)))
                }
            }
            .overlay {
                shape.stroke(Color.white.opacity(0.30), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
    }
}

extension View {
    /// 深色播放器专用毛玻璃（原理见 `PlayerGlassBackground`）。
    func playerGlass(cornerRadius: CGFloat = 16, tint: Double = 0.16) -> some View {
        modifier(PlayerGlassBackground(cornerRadius: cornerRadius, tint: tint))
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
    func glassSheet(tint: Double = 0.10, weight: FilmGlassWeight = .regular) -> some View {
        // 2026-09-30 用户钦定：菜单底 = 主页详情页同款透明玻璃（FilmGlassBackground），
        // 透出背后内容跟着变色 —— 不再是深色模式材质的偏黑实底。
        presentationBackground {
            FilmGlassBackground(cornerRadius: 0, tint: tint, strokeOpacity: 0, weight: weight)
                .ignoresSafeArea()
        }
    }
}
