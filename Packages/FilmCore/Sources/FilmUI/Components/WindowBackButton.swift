import UIKit
import os

/// 全局构建标记：随每次发包手动递增。
/// 播放器打开时闪现 + 设置页常驻，用于一眼确认手机上实际运行的包版本。
///
/// 序号对照（2026-09-22）：
///   35 = 自定义源/成人源合并
///   36 = 播放器层（去黑框·按钮放大·单击暂停·长按2x·画面比例·AirPlay·分享）
///   37 = 检索与体验批次1（拼音首字母检索·搜索联想·长按菜单·迷你播放条·外观跟随）
///   38 = 体验批次2（首屏骨架屏·榜单页·演员作品墙·分类排序·热度口径）
///   39 = 检索升级（拼音：演员/导演可搜·热度排序·ü 的 v/lu 双通道·结果标注命中人物）
///   40 = 索倪源三端分派（NavPolicy：三端导航大类合并 + 端隔离闸门 + 4K 同片升画质）
///        + 返回键对齐大牌（小白箭头无黑框·随控件层自动显隐·点返回不再卡住/丢失）
///   41 = 内置源可见性修复（墓碑按「线路/点播源」拆两套·恢复入口置顶常显·内置行加标签
///        ·心屋空线路说明化·线路行删除键移出激活按钮）+ 全局构建标记
///   42 = 分类归并落地（用户：「打开我的分类看到三个分类，应该都是属于伦理下面的，
///        像日本伦理、西方伦理」/「情色就是三级片，应该和港台三级、三级合并」
///        /「两性课堂不就是成人动漫吗」/「真动画片还在还占个分类」/「而且还不能翻页」）
///        —— 新增 NavCatalog 归并层（分类总览/首页导航/分类浏览三处统一走）；
///        三级组吃进情色·成人动漫组吃进两性课堂·夜航挡掉普通动画分类；
///        分类浏览页新增真页码翻页（上/下一页 + 页码 + 首页/末页）。
///   43 = 搜索穿透到源（用户：「别不三级蜜桃成熟时我搜索是不是得能看到找到」）
///        —— 原「电视剧网络源搜索」仅星幕可用 → 扩到三端：夜航搜索倪+成人源、
///        心屋搜共通源、星幕搜剧集源+共通源；结果过 NavPolicy 端隔离，多源合并去重。
///   44 = 直播「一直缓冲中」根修（用户：「直播一直卡着不动，一直缓冲中…我们的采集器不干活吗」）
///        —— 采集器只管片库元数据、不参与播放，卡顿是播放器侧三处硬伤：
///        ① 缓冲只给 2 秒（抖一下就停且不回头）→ 改 8 秒 + 出画后开「自动等待以最小化卡顿」；
///        ② 卡住只会找「同名备用线路」，单线路频道（索倪/星秀）直接 return → 永远缓冲
///           → 新增 `reconnectSameURL()` 原地重连；
///        ③ 恢复链改为「原地重连×2 → 同名备线×2 → 跳台」，计数只在真出画时归零（有上限、不无限重连）。
///   45 = 播放器「黑框」治理（用户：「暂停以后超大个黑框基本满屏了能不能不要呢」
///        +「那个框的闪动不正常一闪一闪的」）
///        —— 根因：① 顶栏/底栏的渐变挂在满屏 VStack（内含 Spacer）上 → 两条渐变各铺满整屏，
///        叠加后画面从上到下全暗；② 切线路提示 = LoadingView 撑满 + 满屏黑 0.6 → 每次切线路整屏黑一下。
///        修法：渐变各限高（顶 160 / 底 220）；切线路改小卡片（保留居中控钮「无底框」观感）。
///   61 = 直播「卡一会儿才播 / 换台卡」根治（用户：「还是会卡很久才会播 换台也是卡住在屏幕能看见内容
///        但是卡一会才能正常播放」「要先把返回键还给我」「返回键点不动」）
///        —— ① **源侧**：重算主源，按「分片时长→首包耗时→时间新鲜」排序（原表中位分片 7s、最大 20s，
///           必须下满一整片才出画 → 这是"卡一会儿"的直接原因）；同台备线隐藏、点 ⇄N 展开；
///        ② **播放器**：换台先彻底断旧流（pause + replaceCurrentItem(nil)，否则旧流抢带宽/抢解码器）；
///           起播低延迟三连（低码率变体 + 零缓冲目标 + 不等待）；出画后**不再**抬高缓冲门槛（旧逻辑 8s 是卡顿源）；
///        ③ **提速**：呼出列表/开播时预热邻近台 playlist（命中缓存省 DNS/TLS 一跳）；
///           起播 3s 无进展即换源（原 5s）；
///        ④ **返回键**：恢复**窗口级 UIKit 返回键**（物理免疫被全屏手势层吞掉 tap），
///           列表打开时关掉全屏点屏手势层（它正是吃掉返回键点击的元凶）。
public enum AppBuildInfo {
    public static let mark = "20260923-67"
}

let filmLog = Logger(subsystem: "filmthree", category: "player")

/// 窗口级返回按钮（2026-09-20 核弹级返回修复）：
/// 直接挂在 keyWindow 上的 UIKit UIButton，凌驾于全部 SwiftUI 图层之上，
/// 不会被视频层/手势层/容器环境（LiveContainer）吞掉 hit-testing。
/// 此前 SwiftUI 返回按钮在 LC 里点不到（六轮未闭上的根因），本组件物理免疫该问题。
final class WindowBackButton {

    private var button: UIButton?
    private let action: () -> Void
    /// 期望可见性（安装是异步的：调用方可能在按钮进窗口前就调 setVisible，
    /// 先记下意图，`attach` 成功后立即对齐，否则会「明明设了可见却一直不出现」）。
    private var desiredVisible: Bool = true

    /// 以尾闭包创建并安装（等价 install(anchor:action:)）。
    init(action: @escaping () -> Void) {
        self.action = action
        self.attachWithRetry(anchor: nil, attempts: 24)
    }

    /// 安装到 keyWindow（锚点视图所在窗口优先）。自动重试等待进窗口层级。
    @discardableResult
    static func install(anchor: UIView? = nil, action: @escaping () -> Void) -> WindowBackButton {
        let helper = WindowBackButton(action: action)
        helper.attachWithRetry(anchor: anchor, attempts: 24)
        return helper
    }

    /// 重试安装：24 × 50ms（≈1.2s 窗口就绪窗口期）。
    /// 用户反馈「有的时候不在」—— 初版 8 次全是同一 runloop 内连发，Play 转场未完成时
    /// 连续失败就永久放弃；加 50ms 间隔后覆盖转场全过程。
    private func attachWithRetry(anchor: UIView?, attempts: Int) {
        guard attempts > 0 else {
            filmLog.error("back-button: no window to attach")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if self.attach(anchor: anchor) { return }
            self.attachWithRetry(anchor: anchor, attempts: attempts - 1)
        }
    }

    private func attach(anchor: UIView?) -> Bool {
        guard button == nil else { return true }
        let window: UIWindow?
        if let w = anchor?.window {
            window = w
        } else {
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            window = scene?.keyWindow ?? scene?.windows.first
        }
        guard let window else { return false }

        let b = UIButton(type: .system)
        // 2026-09-22 用户反馈「黑框、白色，大牌不这样」——真身是**箭头过大（30pt）+ 投影过重**
        // （opacity 0.8 / radius 10），在浅色画面上糊成一圈黑影，看着就是个「黑框白箭头」。
        // 大牌（爱奇艺/腾讯/Netflix/YouTube）播放器返回键＝**干净的白色小箭头、无底无框、投影极轻**。
        let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        b.setImage(UIImage(systemName: "chevron.left", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.backgroundColor = .clear
        b.imageView?.contentMode = .scaleAspectFit
        b.imageView?.layer.shadowColor = UIColor.black.cgColor
        b.imageView?.layer.shadowOpacity = 0.35     // 只保证浅色画面可见，不做「黑框」
        b.imageView?.layer.shadowRadius = 3
        b.imageView?.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.accessibilityLabel = "返回"
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addAction(UIAction { [weak self] _ in
            filmLog.info("back-button: WINDOW TAP FIRED")
            self?.action()
        }, for: .touchUpInside)
        window.addSubview(b)
        NSLayoutConstraint.activate([
            b.leadingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            b.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 6),
            b.widthAnchor.constraint(equalToConstant: 44),
            b.heightAnchor.constraint(equalToConstant: 44),
        ])
        button = b
        applyVisibility(animated: false)   // 安装即对齐调用方先前设定的显隐意图
        filmLog.info("back-button: installed on window \(String(describing: window))")
        return true
    }

    /// 显隐控制（2026-09-22 用户反馈「播放时该隐藏的没隐藏」「想返回时它又不见了」）：
    /// 对齐大牌行为 —— 返回键**属于播放器控件层**，跟底部进度条/标题一起
    /// 播放 3.4s 后淡出、点画面一起淡入；暂停时保持可见；锁定态隐藏。
    func setVisible(_ visible: Bool, animated: Bool = true) {
        desiredVisible = visible
        applyVisibility(animated: animated)
    }

    private func applyVisibility(animated: Bool) {
        guard let b = button else { return }     // 还没进窗口 → 意图已记录，attach 后对齐
        let visible = desiredVisible
        let target: CGFloat = visible ? 1 : 0
        guard b.alpha != target else { return }
        let apply = {
            b.alpha = target
            b.isUserInteractionEnabled = visible
        }
        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
    }

    func remove() {
        button?.removeFromSuperview()
        button = nil
    }

    deinit {
        let b = button
        DispatchQueue.main.async {
            b?.removeFromSuperview()
        }
    }
}
