import SwiftUI
import UIKit
import FilmCore
import FilmUI

/// 方向锁应答口（2026-10-01 四修 · 主人「锁屏横竖屏锁不住」）。
/// 系统每次要转屏都会问这里 —— 这是 iOS 上唯一被保证生效的方向控制点。
final class XinwuAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask ?? .allButUpsideDown
    }
}

/// 心屋 iOS（儿童影视）— 独立产品入口。
/// Bundle ID / Scheme / 内容池独立：child feed + Child 隔离安全网。
/// 按用户指令（2026-09-19）：家长锁/时长守卫等门禁模块本期不迁移，仅保留内容边界。
@main
struct XinwuApp: App {
    @UIApplicationDelegateAdaptor(XinwuAppDelegate.self) private var appDelegate
    @StateObject private var store = CatalogStore(profile: .xinwu)
    @StateObject private var library = UserLibrary.shared
    @StateObject private var tvbox = TVBoxConfigStore.shared
    private let theme = FilmTheme(accentHex: ProductProfile.xinwu.accentColorHex)

    init() {
        // 产品隔离：心屋=child → 内置线路 = 空集（用户钦定：心屋不要 TVBox 线路）
        TVBoxConfigStore.shared.configure(productMode: ProductProfile.xinwu.mode)
    }

    var body: some Scene {
        WindowGroup {
            MainTabView(profile: .xinwu)
                .environmentObject(store)
                .environmentObject(library)
                .environmentObject(tvbox)
                .environment(\.filmTheme, theme)
                .task { await store.boot() }
                .task {
                    // 2026-10-01 主人钦定「自动更新」：启动静默查一次，有新版弹窗
                    UpdateChecker.shared.assetName = "XinwuISO.ipa"
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

    @ObservedObject private var updateChecker = UpdateChecker.shared
}
