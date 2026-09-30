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
        }
    }
}
