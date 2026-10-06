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
        MainThreadWatchdog.start()   // v76：最早时点开主线程看门狗（App init 里的卡也抓得到）
        MainThreadMark.set("App init")   // v76.1：截图窗口内的责任动作链起点
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
                        // 2026-10-01 主人钦定「自动更新」：启动静默查一次。
                        // 2026-10-06 主人钦定「更新的那个提示彻底取消」→ 这里**不再挂任何 alert**，
                        // 查到新版只记 state，设置页那行变「新构建 xxx · 点此更新」，全流程无感。
                        UpdateChecker.shared.assetName = "XingmuISO.ipa"
                        UpdateChecker.shared.lcScheme = "livecontainer"   // 星幕 = 第 1 容器实例
                        await UpdateChecker.shared.check(silent: true)
                    }
            }
        }
    }
}
