import SwiftUI
import FilmCore
import FilmUI

/// 星幕 iOS（普通影视）— 独立产品入口。
/// Bundle ID / Scheme / 内容池独立：normal feed + Normal 隔离安全网。
@main
struct XingmuApp: App {
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
                    Button("立即更新") { updateChecker.installLatest() }
                    Button("稍后", role: .cancel) {}
                } message: {
                    Text(updateChecker.releaseNote)
                }
        }
    }

    @ObservedObject private var updateChecker = UpdateChecker.shared
}
