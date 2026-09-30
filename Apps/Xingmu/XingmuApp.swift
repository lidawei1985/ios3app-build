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
        }
    }
}
