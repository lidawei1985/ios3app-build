import SwiftUI
import FilmCore

/// 详情卡片全局路由：所有海报入口统一走「底部圆角卡片弹层」。
/// 2026-09-25 用户钦定（原型 `home_v2.html` 详情浮层）：
/// 详情不再整页推入（NavigationLink push），改为底部滑上卡片——
/// 88% 高 / 顶部 30px 圆角 / 拖拽把手 / 背后压暗。
public final class DetailRouter: ObservableObject {
    @Published public var item: FeedItem?
    public init() {}
    public func open(_ item: FeedItem) { self.item = item }
}

/// 详情卡弹层内容（主框架 `.sheet(item:)` 直接调用）。
/// 2026-09-25 02:10 教训固化：不要给 `.sheet(item:)` 喂手搓 `Binding(get:set:)` ——
/// modifier 结构体只含同一引用时 SwiftUI diff 判「无变化」不重算 body，sheet 永不呈现
/// （真机表现为「点海报毫无反应、无崩溃」）。必须用 @StateObject 的投影绑定 `$router.item`。
public func detailCardContent(item: FeedItem, router: DetailRouter) -> some View {
    NavigationStack {
        DetailView(item: item)
            .id(item.dedupId)
            .toolbar(.hidden, for: .navigationBar)   // 详情卡本体无导航栏（原型同款）
    }
    .environmentObject(router)   // sheet 不保证继承外层 environmentObject，显式注入
    .presentationDetents([.fraction(0.88)])
    .presentationCornerRadius(30)
    .presentationDragIndicator(.visible)
    .presentationBackground(.clear)
}
