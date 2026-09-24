import SwiftUI
import AVKit
import UIKit
import MediaPlayer
import FilmCore

/// 播放器拖动手势模式。
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
    @State private var showRatePanel = false   // 52包废弃（倍速改点一下循环切换），保留声明防误引用
    @State private var showLinePanel = false
    @State private var showEpisodePanel = false
    // 51包：原画面比例面板已删（比例改为底栏点一下循环切换 cycleAspect）
    /// 长按加速结束时刻（用于挡住"松手被当成单击→误暂停"）
    @State private var lastBoostEnd = Date.distantPast
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var seekToast: String?
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
    /// 窗口级返回按钮句柄（UIKit 层，LC 环境免疫 hit-testing 吞噬）
    // 50包：返回键并回控制层（topBar 内普通按钮），窗口级 WindowBackButton 停用——
    // 它靠异步抢窗口时机安装，「有的时候不在」；类文件保留（mark/filmLog 定义在此）。
    // 48包：居中三钮并回控制层（centerTransportRow），窗口级 WindowControlBar 停用——
    // 它与控制层显隐两条路，用户实测"暂停快进没了"即显隐对不上。类文件保留备回切。
    @State private var savedRate: Double = {
        let v = UserDefaults.standard.double(forKey: "filmui.playerRate")
        return v > 0 ? v : 1.0
    }()

    public static let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    @AppStorage("settings.skipIntroSeconds") private var skipIntroSetting = 0

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
                // UIKit 级单击/双击兜底：LC 容器吞 SwiftUI 手势时由此通道响应（与 SwiftUI 手势层互补，
                // 正常 iOS 上层手势命中后事件不到达底层 recognizer，不会双重触发）
                if tapCount == 2 {
                    doubleTapSeek(centerX: loc.x)
                } else {
                    tapScreen()
                }
            }, onLongPress: { began in
                began ? boostBegan() : boostEnded()   // 长按加速（LC 通道）
            })
                .ignoresSafeArea()

            // 手势层（锁定时不吃手势，仅露出解锁钮）
            // 注：不使用长按倍速手势 —— pressing 回调在手指触屏瞬间即触发，
            // 会导致每次点击都进入 3x 并吞掉单击呼出控制层（2026-09-20 修复）。
            if !locked {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { v in doubleTapSeek(centerX: v.location.x) }
                            .exclusively(before: TapGesture().onEnded { tapScreen() })
                    )
                    // 长按 2x 加速（大牌标配）：非 LC 环境走这条，LC 环境走 UIKit 兜底
                    // 注意：绝不在 onPressingChanged(true) 里开始加速 —— 那是手指一碰就触发（09-20 已踩坑）
                    .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 40) {
                        boostBegan()
                    } onPressingChanged: { pressing in
                        if !pressing { boostEnded() }
                    }
                    .gesture(playerDragGesture)
            }

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

            // 跳过片头（大牌标配：片头区间右下角浮现；设置里可自定义秒数，默认 85s）
            // 46包（用户：「啥按钮都加黑框」）：无底框化——白字+投影，与居中控钮同一套视觉
            if showSkipIntro {
                Button { model.seek(to: skipIntroSeconds); showSeekToast("已跳过片头") } label: {
                    Text("跳过片头 ▸").font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                        .contentShape(Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 18).padding(.bottom, 130)
            }

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

            if showControls {
                if locked {
                    lockHint
                } else {
                    topBar
                    bottomBar
                    // 48包（用户：「暂停快进怎么没了 要隐藏也没说不要暂停快进」）：
                    // 爱腾优式——居中三钮是控制层的**一部分**，随控制层同显隐。
                    // 旧实现是挂在系统窗口上的 UIKit 条，与控制层各走各的，显隐对不上=看起来"消失"。
                    // 失败态不显示（失败面板自带重试）。
                    if !model.failed { centerTransportRow }
                }
            }

            if let toast = seekToast {
                Text(toast)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 4, y: 1)
                    .padding(.horizontal, 18).padding(.vertical, 10)
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
            }
        }
        .onAppear {
            model.start(resume: startAtResume)
            if savedRate != 1.0 { model.setRate(savedRate) }
            setLandscape(true)
            scheduleHide()
            // 46包：撤掉「Build 20260922-xx」闪现——小白用户看不懂还截图问「这是啥玩意」；
            // 包版本核验走 LC 内二进制探针，不再打扰播放画面。
        }
        .onDisappear {
            gone = true
            model.stop()
            setLandscape(false)
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

    // MARK: - 居中控制行（爱腾优式：快退10s / 播放·暂停 / 快进10s）

    /// 无底框：白色图标+投影（与 46 包去黑框同一套视觉）；放在 ZStack 最顶层保证可点
    /// （控制层子视图都在手势层之后，命中优先；同层里它排最后=最优先）。
    private var centerTransportRow: some View {
        HStack(spacing: 56) {
            Button { model.skip(-10) } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 8, y: 2)
                    .frame(width: 58, height: 58)
                    .contentShape(Rectangle())
            }
            Button { model.togglePlayPause() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 10, y: 2)
                    .frame(width: 84, height: 84)
                    .contentShape(Rectangle())
            }
            Button { model.skip(10) } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 8, y: 2)
                    .frame(width: 58, height: 58)
                    .contentShape(Rectangle())
            }
        }
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
                Button {
                    locked = true
                    showControls = true
                    scheduleHide()
                } label: {
                    Image(systemName: "lock.open").font(.body)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            Spacer()
        }
        // 54包（用户钦定）：顶/底渐变整条删除 —— 96+120pt 在横屏上叠成
        // "整屏蒙一层黑纱"。文字/按钮可读性由投影（shadow）保证，渐变不再保留。
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Spacer()
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

            HStack(spacing: 14) {
                // 49包（用户钦定爱腾优/腾讯视频式）：左下角 = 播放/暂停 + 下一集，
                // 与居中三钮**联动**——同一 model.isPlaying 状态、同一套动作，
                // SwiftUI 响应式自动同步图标（居中暂停 → 左下角同步变播放键）。
                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                if model.hasNextEpisode {
                    Button { playNext() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("下一集")
                }
                Spacer()
                if episodeCount > 1 {
                    // 大牌式播放中直接切集：不用退回详情页
                    Button { showEpisodePanel = true; hideTask?.cancel() } label: {
                        Text("选集").font(.footnote).foregroundStyle(.white)
                    }
                }
                // 52包（用户：「倍数也是进菜单的！！！！」）→ 与画面比例同款：点一下循环换档，
                // 按钮显示当前档位 + 右下角轻提示，不弹菜单（不挡画面）。
                Button { cycleRate(); hideTask?.cancel() } label: {
                    Text(rateLabel).font(.footnote).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                }
                if model.allLines.count > 1 {
                    // 大牌式一键换源：直接循环切下一条线路（保留进度），不弹列表
                    Button {
                        model.switchToNextLine()
                        // 35包修：原式 currentLine+2（绕回时还错成 1）与按钮标签 currentLine+1 不一致 → 提示线路号错。
                        // switchToLine 已把 currentLine 更新为新线路下标，直接用 +1 与按钮对齐。
                        showSeekToast("已换源 \(model.currentLine + 1)/\(model.allLines.count)")
                        scheduleHide()
                    } label: {
                        Text("换源 \(model.currentLine + 1)/\(model.allLines.count)").font(.footnote).foregroundStyle(.white)
                    }
                }
                // 51包（用户：「画面比例还出来个菜单呢这个也不是合理的啊 正常不就是点一下换
                // 一个模式吗…还弹出个菜单满屏都挡死了」）→ 大牌做法：点一下循环换模式，
                // 按钮自身就是当前模式名，右下角飘一条轻提示，不弹面板、不挡画面。
                Button { cycleAspect() } label: {
                    Text(model.aspect.shortTitle).font(.footnote).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("画面比例：\(model.aspect.shortTitle)")
                // 投屏（AirPlay，系统原生按钮，大牌标配）
                RoutePickerView().frame(width: 26, height: 26)
                // 分享（系统分享面板）
                Button { sharePlayback(); hideTask?.cancel() } label: {
                    Image(systemName: "square.and.arrow.up").font(.body).foregroundStyle(.white)
                        .accessibilityLabel("分享")
                }
                Button {
                    setLandscape(!isLandscape)
                    // 51包：提示文案与按钮一致（旧文案在切换后读值 → 提示正好反着）
                    showSeekToast(isLandscape ? "已切到竖屏" : "已切到横屏")
                } label: {
                    // 51包（用户：「横竖屏那个按钮做成腾讯那种吧 现在这个不好看」）：
                    // 腾讯/爱奇艺用的是**四角箭头**（外扩=进入全屏，内收=退出全屏），不是方框图标
                    Image(systemName: isLandscape ? "arrow.down.right.and.arrow.up.left"
                                                  : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(isLandscape ? "退出全屏" : "全屏")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        // 54包：底渐变同步删除（同顶渐变，黑纱根因之一）。
        .sheet(isPresented: $showLinePanel) { linePanel }
    }

    private var rateLabel: String {
        model.rate == 1.0 ? "倍速" : String(format: "%.1fx", model.rate)
    }

    /// 选集总集数（跨线路取最大组）。
    private var episodeCount: Int {
        episodeGroups.map { $0.eps.count }.max() ?? 0
    }

    /// 跳过片头：设置秒数（0 = 默认 85s）；只对 >10min 的长视频显示，片头区间内浮现。
    private var skipIntroSeconds: Double {
        skipIntroSetting > 0 ? Double(skipIntroSetting) : 85
    }

    private var showSkipIntro: Bool {
        model.duration > 600
            && model.currentTime >= 3
            && model.currentTime < skipIntroSeconds
    }

    /// 片尾 90s 内且还有下一集 → 浮现「下一集」（自动连播的手动兜底）。
    private var showNextEpisode: Bool {
        model.hasEpisodeList
            && model.duration > 0
            && model.currentLine + 1 < model.allLines.count
            && model.duration - model.currentTime < 90
            && model.duration - model.currentTime > 0
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

    /// 按线路下标找集名（选集面板/切集提示共用）。
    private func episodeName(at index: Int) -> String? {
        for g in episodeGroups {
            if let ep = g.eps.first(where: { $0.index == index }) { return ep.name }
        }
        return nil
    }

    /// 选集面板（大牌式：分组 chips + 网格；当前集高亮）。
    private var episodePanel: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(episodeGroups.enumerated()), id: \.offset) { _, g in
                        VStack(alignment: .leading, spacing: 10) {
                            if episodeGroups.count > 1 {
                                Text("线路：\(g.line)").font(.footnote.bold())
                                    .foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                                ForEach(g.eps, id: \.index) { ep in
                                    Button {
                                        showEpisodePanel = false
                                        guard ep.index != model.currentLine else { return }
                                        model.playEpisode(ep.index)
                                        onEpisodeChange?(ep.name)
                                        showSeekToast("正在播放：\(ep.name)")
                                        scheduleHide()
                                    } label: {
                                        Text(ep.name)
                                            .font(.caption.weight(.medium)).lineLimit(1)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 9)
                                            .background(model.currentLine == ep.index
                                                        ? Color.white.opacity(0.22)
                                                        : Color(uiColor: .systemGray6),
                                                        in: RoundedRectangle(cornerRadius: 9))
                                            .foregroundStyle(model.currentLine == ep.index
                                                             ? Color.accentColor : .primary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
                // 2026-09-23 抖音式切集的可发现性：不写提示没人知道右滑能换集
                Text("提示：在播放画面**右侧边缘**竖滑 —— 上滑看下一集 / 下滑看上一集")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 18)
            }
            .navigationTitle("选集（\(episodeCount)）")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
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
        NavigationStack {
            lineList
        }
        .presentationDetents([.medium])
    }

    private var lineList: some View {
        List {
            ForEach(Array(model.allLines.enumerated()), id: \.offset) { pair in
                lineRow(pair.offset, url: pair.element)
            }
        }
        .navigationTitle("切换线路")
        .navigationBarTitleDisplayMode(.inline)
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

    private var lockHint: some View {
        VStack {
            HStack {
                Button {
                    locked = false
                    scheduleHide()
                } label: {
                    Image(systemName: "lock.fill").font(.title3)
                        .foregroundStyle(.white)
                        .padding(10)
                        .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
                }
                .padding(.leading, 16)
                Spacer()
            }
            Spacer()
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
        if showControls {
            showControls = false      // 已显示 → 收起
            hideTask?.cancel()
        } else {
            showControls = true
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
        guard !scrubbing, !showLinePanel, !showEpisodePanel else { return }
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
        // 2026-09-22 用户反馈「播放器内点返回会卡住」：
        // 旧实现把 model.stop() + 转屏 + 摘按钮全塞在这次点击里同步做，主线程被占住 → 点击无反馈像卡死。
        // 大牌式退出＝**先关页面给反馈，重活挪到下一拍**。
        onClose?()                       // 保险 3：宿主 binding 关闭（正常 iOS 路径）
        dismiss()                        // 保险 4：SwiftUI 环境 dismiss
        Task { @MainActor in
            // 保险 5：UIKit 兜底 —— LC 里 SwiftUI 关闭环境可能全废，直接从根 VC 关掉呈现层
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            scene?.keyWindow?.rootViewController?.dismiss(animated: true)
            try? await Task.sleep(nanoseconds: 40_000_000)   // 让关闭动画先起
            model.stop()                 // 保险 2：停播放、灭掉常亮
            setLandscape(false)
        }
        // 用户反馈「想返回却不见了」：旧实现在这里就把 backBtn 摘了 —— 一旦关闭失败，
        // 按钮已没了，用户永远回不去。现在**保留按钮**，1.2s 后仍在呈现就再关一次；
        // 真正消失由 onDisappear 收尾（gone = true + 摘按钮）。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !gone else { return }
            filmLog.error("player close: still presenting after 1.2s → retry dismiss")
            onClose?()
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            scene?.keyWindow?.rootViewController?.dismiss(animated: true)
        }
    }

    private var playerDragGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in handleDragChanged(value) }
            .onEnded { value in handleDragEnded(value) }
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        if dragMode == .idle {
            let dx = abs(value.translation.width)
            let dy = abs(value.translation.height)
            let screenH = UIScreen.main.bounds.height
            let screenW = UIScreen.main.bounds.width
            if value.translation.height > 60, dy > dx, value.startLocation.y < screenH * 0.2 {
                dragMode = .close      // 屏幕上部下滑 = 退出播放
                return
            }
            // 抖音式切集：右边缘（右侧 22% 宽）× 上部 20% 以下，竖向起手即锁定本模式
            if episodeCount > 1, dy > dx, dy > 24,
               value.startLocation.x > screenW * 0.78,
               value.startLocation.y > screenH * 0.2 {
                dragMode = .episode
                return
            }
            hideTask?.cancel()
            if dx >= dy {
                dragMode = .seek
                dragSeekTarget = min(max(model.currentTime, 0), max(model.duration, 0.1))
            } else if value.startLocation.x < screenW / 2 {
                dragMode = .brightness
                startBrightness = UIScreen.main.brightness
            } else {
                dragMode = .volume
                startVolume = PlayerVolumeController.current()
            }
        }
        switch dragMode {
        case .seek:
            let raw = abs(Double(value.translation.width))
            let moved = raw < 60 ? raw : 60 + (raw - 60) * 3   // 前 60pt 1s/pt，之后加速
            let signed = value.translation.width < 0 ? -moved : moved
            let limit = max(model.duration, 0.1)
            dragSeekTarget = min(max(model.currentTime + signed, 0), limit)
            seekToast = (value.translation.width < 0 ? "◀ " : "▶ ") + Self.format(dragSeekTarget)
        case .brightness:
            let target = min(max(startBrightness - value.translation.height / 500, 0), 1)
            UIScreen.main.brightness = target
            seekToast = "亮度 \(Int(target * 100))%"
        case .volume:
            let target = min(max(startVolume - Float(value.translation.height) / 500, 0), 1)
            PlayerVolumeController.set(target)
            seekToast = "音量 \(Int(target * 100))%"
        case .episode:
            // 上滑（translate 负）= 下一集；下滑 = 上一集。实时给方向提示，松手才真正切换。
            let up = value.translation.height < 0
            let worth = abs(value.translation.height) >= 60
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

    private func handleDragEnded(_ value: DragGesture.Value) {
        if dragMode == .seek {
            model.seek(to: dragSeekTarget)
            showSeekToast("跳转 " + Self.format(dragSeekTarget))
        } else if dragMode == .close {
            close()
        } else if dragMode == .episode {
            // 抖动阈值 60pt：够远才切，避免"想点一下"被误判成换集
            if value.translation.height <= -60 {
                switchEpisode(by: 1)
            } else if value.translation.height >= 60 {
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
        if centerX < mid {
            model.skip(-10); showSeekToast("快退 10s")
        } else {
            model.skip(10); showSeekToast("快进 10s")
        }
    }

    private func showSeekToast(_ text: String) {
        seekToast = text
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            seekToast = nil
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

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, onLongPress: onLongPress) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = model.player
        vc.showsPlaybackControls = false
        vc.videoGravity = model.aspect.gravity     // 画面比例随用户选择
        // 恢复交互（此前 false 是为防吞上层手势；SwiftUI 手势层在其上层，正常路径仍优先命中）
        vc.view.isUserInteractionEnabled = true
        let double = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleDouble(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleSingle(_:)))
        single.numberOfTapsRequired = 1
        single.require(toFail: double)
        // 长按=加速（大牌标配）：与单击互斥，避免长按松手被当成单击而暂停
        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.allowableMovement = 40
        single.require(toFail: longPress)
        vc.view.addGestureRecognizer(single)
        vc.view.addGestureRecognizer(double)
        vc.view.addGestureRecognizer(longPress)
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== model.player { vc.player = model.player }
        if vc.videoGravity != model.aspect.gravity {   // 用户在面板改比例 → 立即生效
            vc.videoGravity = model.aspect.gravity
        }
        context.coordinator.onTap = onTap
        context.coordinator.onLongPress = onLongPress
    }

    final class Coordinator: NSObject {
        var onTap: ((CGPoint, Int) -> Void)?
        var onLongPress: ((Bool) -> Void)?
        init(onTap: ((CGPoint, Int) -> Void)?, onLongPress: ((Bool) -> Void)?) {
            self.onTap = onTap
            self.onLongPress = onLongPress
        }
        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began: onLongPress?(true)
            case .ended, .cancelled, .failed: onLongPress?(false)
            default: break
            }
        }
        @objc func handleSingle(_ g: UITapGestureRecognizer) {
            onTap?(g.location(in: g.view), 1)
        }
        @objc func handleDouble(_ g: UITapGestureRecognizer) {
            onTap?(g.location(in: g.view), 2)
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

    /// 画面比例（自适应/铺满/拉伸）—— 外部改动请用 setAspect(_:)（会持久化）
    /// 53包：默认改「铺满」（腾讯同款，宽银幕片自动裁掉上下黑边）；
    /// 用户原话「黑框也没去掉啊」= 上下 letterbox 黑边。
    @Published public private(set) var aspect: AspectMode =
        AspectMode(rawValue: UserDefaults.standard.string(forKey: "filmui.playerAspect") ?? "") ?? .fill

    /// 切换画面比例并持久化（下次打开沿用）
    public func setAspect(_ m: AspectMode) {
        guard aspect != m else { return }
        aspect = m
        UserDefaults.standard.set(m.rawValue, forKey: "filmui.playerAspect")
        filmLog.info("player: aspect -> \(m.rawValue)")
    }

    public private(set) var player: AVPlayer?
    private let item: FeedItem
    private var timeObserver: Any?
    private var observers: [NSKeyValueObservation] = []
    private var resumeSeconds: Double = 0
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
            p.seek(to: CMTime(seconds: resumeSeconds, preferredTimescale: 600))
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
                    guard let self, it.status == .failed else { return }
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
