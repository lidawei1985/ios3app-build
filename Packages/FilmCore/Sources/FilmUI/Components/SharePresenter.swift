import SwiftUI
import UIKit
import FilmCore

/// 系统分享面板统一入口（大牌标配：长按海报 / 播放页分享）。
/// 之前各页面自行拼 UIActivityViewController，弹窗定位与顶层容器处理重复且易错，统一到此。
public enum SharePresenter {

    /// 弹出系统分享面板（自动定位到最顶层控制器，iPad 走 popover 锚点）。
    @MainActor
    public static func present(_ items: [Any]) {
        guard !items.isEmpty else { return }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = (scene.keyWindow ?? scene.windows.first)?.rootViewController else { return }
        if let pop = av.popoverPresentationController {
            pop.sourceView = root.view
            pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
        }
        var top = root
        while let p = top.presentedViewController { top = p }
        top.present(av, animated: true)
    }

    /// 分享一部影片：片名（含年份）+ 一句推荐语 + 播放地址（有则带）。
    @MainActor
    public static func share(item: FeedItem, appName: String = "", playURL: String? = nil) {
        var text = "《\(item.title)》"
        if let y = item.year, !y.isEmpty { text += "（\(y)）" }
        if !appName.isEmpty { text += " —— 我正在 \(appName) 看" }
        var items: [Any] = [text]
        if let u = playURL ?? item.bestPosterURL?.absoluteString, !u.isEmpty { items.append(u) }
        present(items)
    }
}
