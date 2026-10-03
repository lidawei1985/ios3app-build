import SwiftUI
import UIKit
import FilmCore
import FilmUI

/// 方向锁应答口（2026-10-01 四修 · 主人「锁屏横竖屏锁不住」）。
/// 系统每次要转屏都会问这里 —— 这是 iOS 上唯一被保证生效的方向控制点。
/// 播放器锁屏键写 `OrientationLock.shared.mask`，这里照实回答。
final class XingmuAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask ?? .allButUpsideDown
    }
}

/// 星幕 iOS（普通影视）— 独立产品入口。
/// Bundle ID / Scheme / 内容池独立：normal feed + Normal 隔离安全网。
@main
struct XingmuApp: App {
    @UIApplicationDelegateAdaptor(XingmuAppDelegate.self) private var appDelegate
    @StateObject private var store = CatalogStore(profile: .xingmu)
    @StateObject private var library = UserLibrary.shared
    @StateObject private var tvbox = TVBoxConfigStore.shared
    private let theme = FilmTheme(accentHex: ProductProfile.xingmu.accentColorHex)

    init() {
        // 产品隔离：星幕=normal → 内置线路仅影视组（无成人组）
        TVBoxConfigStore.shared.configure(productMode: ProductProfile.xingmu.mode)
    }

    var body: some Scene {
        WindowGroup {
            // 2026-10-03 启动动画：过场包在**最外层**（TabView 外面）→ TabView 只布局一次。
            // 过场期间 boot/更新检查照常跑（互不等待），过场到点自动淡出揭幕。
            LaunchSplashGate(profile: .xingmu) {
                MainTabView(profile: .xingmu)
                    .environmentObject(store)
                    .environmentObject(library)
                    .environmentObject(tvbox)
                    .environment(\.filmTheme, theme)
                    .task { await store.boot() }
                    .task {
                        // 2026-10-01 主人钦定「自动更新」：启动静默查一次，有新版弹窗
                        UpdateChecker.shared.assetName = "XingmuISO.ipa"
                        await UpdateChecker.shared.check(silent: true)
                    }
                    .alert("发现新版本", isPresented: $updateChecker.showUpdate) {
                        // 2026-10-03 主人钦定：弹窗只待 3 秒自关（见 UpdateChecker.presentThenAutoClose）。
                        Button("立即更新") { updateChecker.dismissUpdate(); updateChecker.installLatest() }
                        Button("稍后", role: .cancel) { updateChecker.dismissUpdate() }
                    } message: {
                        Text(updateChecker.releaseNote)
                    }
            }
        }
    }

    @ObservedObject private var updateChecker = UpdateChecker.shared
}
