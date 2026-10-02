import SwiftUI
import FilmCore
import FilmUI

/// 心屋 iOS（儿童影视）— 独立产品入口。
/// Bundle ID / Scheme / 内容池独立：child feed + Child 隔离安全网。
/// 按用户指令（2026-09-19）：家长锁/时长守卫等门禁模块本期不迁移，仅保留内容边界。
@main
struct XinwuApp: App {
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
                    Button("立即更新") { updateChecker.installLatest() }
                    Button("稍后", role: .cancel) {}
                } message: {
                    Text(updateChecker.releaseNote)
                }
        }
    }

    @ObservedObject private var updateChecker = UpdateChecker.shared
}
