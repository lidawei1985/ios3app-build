import UIKit

/// 全局屏幕方向锁（2026-10-01 四修 · 主人「锁屏横竖屏锁不住啊」）。
///
/// 为什么前三修都没根治：`UIWindowScene.requestGeometryUpdate` 只是**请求**——
/// 系统竖屏锁定开着、或宿主（LiveContainer）自己管方向时，这条请求会被**静默忽略**。
/// iOS 上**唯一被保证生效**的方向口子是 AppDelegate 的
/// `application(_:supportedInterfaceOrientationsFor:)` —— 系统每次要转屏都会问它。
///
/// 所以本类持有唯一真源：AppDelegate 读它、播放器锁屏键写它。
/// 写入时同时做两件事：
///   ① `requestGeometryUpdate` 让系统**主动**转到现在允许的方向（不然锁横屏后
///      得等下一次物理转动才生效）；
///   ② 沿 key window 的控制器链调 `setNeedsUpdateOfSupportedInterfaceOrientations()`
///      —— 否则系统会沿用**缓存的**支持方向，AppDelegate 的新答案不生效。
///
/// `mask == nil` = 不限制（跟随系统）；`.portrait` / `.landscape` = 钉死。
public final class OrientationLock {
    public static let shared = OrientationLock()
    private init() {}

    /// 当前锁；nil = 不限制。
    public private(set) var mask: UIInterfaceOrientationMask?

    /// 设定方向锁。传 nil 解锁。
    public func set(_ m: UIInterfaceOrientationMask?) {
        mask = m
        let target: UIInterfaceOrientationMask = m ?? .allButUpsideDown
        DispatchQueue.main.async {
            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                ws.requestGeometryUpdate(.iOS(interfaceOrientations: target))
                for w in ws.windows { Self.reroll(w.rootViewController) }
            }
        }
    }

    /// 沿控制器链让系统重新询问「支持哪些方向」（否则 AppDelegate 的新答案不生效）。
    private static func reroll(_ vc: UIViewController?) {
        guard let vc else { return }
        vc.setNeedsUpdateOfSupportedInterfaceOrientations()
        vc.children.forEach { reroll($0) }
        reroll(vc.presentedViewController)
    }
}
