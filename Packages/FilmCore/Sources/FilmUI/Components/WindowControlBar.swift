import UIKit

/// 窗口级播放控制条（2026-09-21 28号包 / 2026-09-22 视觉重做）：
/// 点播居中控钮（快退10s / 播放·暂停 / 快进10s）下沉为 keyWindow 上的 UIKit 按钮，
/// 物理免疫 LiveContainer 吞 SwiftUI hit-testing —— 与 WindowBackButton 同根因同解法
/// （27号包 SwiftUI 居中按钮在 LC 里"看得见点不着"的真机实测结论）。
/// 显隐随 SwiftUI 控制层（showControls）同步：PlayerScreen 调 show()/hide()。
///
/// 2026-09-22 用户反馈：「为啥非得弄个黑框」「按钮那么小」→ 按主流视频 App 观感重做：
///   无底板、无圆角框；白色实心/线性图标 + 黑色投影（亮画面同样清晰）；
///   主按钮（播放·暂停）78pt、图标 66pt；两侧 ±10s 58pt、图标 38pt；按钮间距 56pt。
final class WindowControlBar {

    // MARK: - 视觉参数（集中在这里，方便后续微调）
    private enum Metric {
        static let playSize: CGFloat = 78      // 主按钮点击区
        static let sideSize: CGFloat = 58      // 两侧按钮点击区
        static let playIcon: CGFloat = 66      // 主图标字号
        static let sideIcon: CGFloat = 38      // 侧图标字号
        static let gap: CGFloat = 56           // 按钮间距
        static let shadowRadius: CGFloat = 10
        static let shadowOpacity: Float = 0.8
    }

    private var stack: UIStackView?
    private var playBtn: UIButton?
    private var onSkip: (Double) -> Void = { _ in }
    private var onToggle: () -> Void = {}

    static func install(onSkip: @escaping (Double) -> Void,
                        onToggle: @escaping () -> Void) -> WindowControlBar {
        let bar = WindowControlBar()
        bar.onSkip = onSkip
        bar.onToggle = onToggle
        bar.attachWithRetry(attempts: 8)
        return bar
    }

    private func attachWithRetry(attempts: Int) {
        guard attempts > 0 else {
            filmLog.error("ctrl-bar: no window to attach")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.attach() { return }
            self.attachWithRetry(attempts: attempts - 1)
        }
    }

    private func attach() -> Bool {
        guard stack == nil else { return true }
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.keyWindow ?? scene.windows.first else { return false }

        /// 无底框按钮：白色符号图标 + 黑色投影（大牌做法，不用黑底也能在任何画面上看清）
        func mk(_ symbol: String, _ point: CGFloat, _ weight: UIImage.SymbolWeight,
                _ label: String, _ handler: @escaping () -> Void) -> UIButton {
            let cfg = UIImage.SymbolConfiguration(pointSize: point, weight: weight)
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
            b.tintColor = .white
            b.accessibilityLabel = label
            b.imageView?.contentMode = .scaleAspectFit
            // 投影跟随图标形状（UIImageView 的 layer shadow 按 alpha 通道绘制）
            b.imageView?.layer.shadowColor = UIColor.black.cgColor
            b.imageView?.layer.shadowOpacity = Metric.shadowOpacity
            b.imageView?.layer.shadowRadius = Metric.shadowRadius
            b.imageView?.layer.shadowOffset = CGSize(width: 0, height: 2)
            b.addAction(UIAction { _ in handler() }, for: .touchUpInside)
            return b
        }

        let back = mk("gobackward.10", Metric.sideIcon, .semibold, "快退10秒") { [weak self] in self?.onSkip(-10) }
        let play = mk("pause.fill", Metric.playIcon, .regular, "播放/暂停") { [weak self] in self?.onToggle() }
        let fwd  = mk("goforward.10", Metric.sideIcon, .semibold, "快进10秒") { [weak self] in self?.onSkip(10) }
        playBtn = play

        let s = UIStackView(arrangedSubviews: [back, play, fwd])
        s.axis = .horizontal
        s.spacing = Metric.gap
        s.alignment = .center
        s.backgroundColor = .clear          // ← 去掉黑框
        s.isLayoutMarginsRelativeArrangement = false
        s.translatesAutoresizingMaskIntoConstraints = false
        s.isHidden = true
        window.addSubview(s)
        NSLayoutConstraint.activate([
            s.centerXAnchor.constraint(equalTo: window.safeAreaLayoutGuide.centerXAnchor),
            // 略高于几何中心，符合主流播放器视觉重心
            s.centerYAnchor.constraint(equalTo: window.safeAreaLayoutGuide.centerYAnchor, constant: -8),
            play.widthAnchor.constraint(equalToConstant: Metric.playSize),
            play.heightAnchor.constraint(equalToConstant: Metric.playSize),
            back.widthAnchor.constraint(equalToConstant: Metric.sideSize),
            back.heightAnchor.constraint(equalToConstant: Metric.sideSize),
            fwd.widthAnchor.constraint(equalToConstant: Metric.sideSize),
            fwd.heightAnchor.constraint(equalToConstant: Metric.sideSize),
        ])
        stack = s
        filmLog.info("ctrl-bar: installed on window (no-frame, play=\(Metric.playSize), side=\(Metric.sideSize))")
        return true
    }

    /// 播放态变化时刷新中间图标（暂停⇄播放，两个不同图标）
    func update(playing: Bool) {
        let cfg = UIImage.SymbolConfiguration(pointSize: Metric.playIcon, weight: .regular)
        playBtn?.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: cfg),
                          for: .normal)
    }

    func show() { stack?.isHidden = false }
    func hide() { stack?.isHidden = true }

    func remove() {
        stack?.removeFromSuperview()
        stack = nil
        playBtn = nil
    }

    deinit {
        let s = stack
        DispatchQueue.main.async { s?.removeFromSuperview() }
    }
}
