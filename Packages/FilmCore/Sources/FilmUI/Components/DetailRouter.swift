import SwiftUI
import FilmCore

/// 详情卡片全局路由：所有海报入口统一走「底部圆角卡片弹层」。
/// 2026-09-25 用户钦定（原型 `home_v2.html` 详情浮层）：
/// 详情不再整页推入（NavigationLink push），改为底部滑上卡片——
/// 88% 高 / 顶部 30px 圆角 / 拖拽把手 / 背后压暗。
///
/// 2026-10-02 点击痕迹（主人：「点的是 1 却错位点到 2 上」，海报/内置源/继续观看三处都犯）：
/// 这一刀能把"到底是哪一步错了"分清楚 —— 痕迹里落的是**传给弹层的那一条**：
///   · 痕迹 = 片 2 而用户点的是片 1 → **命中测试送错了**（视图几何/层级问题）；
///   · 痕迹 = 片 1 却弹出片 2 → **弹层内容没跟着换**（`.sheet(item:)` 侧问题）。
/// 两种病的修法完全不同，不许靠猜。痕迹写进 UserDefaults（随容器落盘，探针可拉取）。
public final class DetailRouter: ObservableObject {
    @Published public var item: FeedItem?
    /// 2026-10-02（主人：「点继续播放 —— ①海报直接打开 ②详情页」）：
    /// 2026-10-02 曾按「点海报=直接开播」接通（继续观看/历史传 autoplay:true）；
    /// ★ 2026-10-04 主人改口（「只要是继续观看里的海报点一下就直接播放了」）→ 两处调用已撤销，
    ///   现全站入口都不传 autoplay，本通道**保留但休眠**（想恢复直接续播，调用处补回 true 即可）。
    @Published public var autoplay = false
    public init() {}
    public func open(_ item: FeedItem, from: String = "", autoplay: Bool = false) {
        TapTrace.record(dedupId: item.dedupId, title: item.title, from: from)
        self.autoplay = autoplay
        // 2026-10-02「点 1 得 2」根修：.sheet(item:) 在 sheet 已展开时换片，
        // SwiftUI 会复用同一 sheet 视图实例，导致 DetailView 的 @State 仍停在旧条目。
        // 这里先关再开，强制 sheet 重新创建，DetailView 的 @State 必重新初始化。
        if self.item == nil {
            self.item = item
        } else {
            self.item = nil
            DispatchQueue.main.async { [weak self] in
                self?.item = item
            }
        }
    }
}

/// 点击痕迹（写 UserDefaults → 随 App 容器落盘 → `ios_ctrl` 探针可从手机拉回核验）。
///
/// 两套痕迹对照才能一次定案：
///   · `tap`     = **送进路由的那一条**（点下去那一刻）
///   · `present` = **弹层真正渲染出来的那一条**（页面出现那一刻）
///   tap=片1 & present=片2 → 弹层内容没跟着换；tap=片2 & present=片2 → 命中测试送错了。
enum TapTrace {
    private static func push(_ key: String, _ line: String) {
        UserDefaults.standard.set(line, forKey: key + ".last")
        var log = UserDefaults.standard.stringArray(forKey: key + ".log") ?? []
        log.append(line)
        if log.count > 60 { log.removeFirst(log.count - 60) }
        UserDefaults.standard.set(log, forKey: key + ".log")
    }
    /// 点下去那一刻（路由收到的是哪一条）
    static func record(dedupId: String, title: String, from: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        push("taptrace", "\(stamp) [\(from.isEmpty ? "-" : from)] \(title) <\(dedupId)>")
    }
    /// 弹层真正渲染出来的那一刻（展示的是哪一条）
    static func present(dedupId: String, title: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        push("taptrace.present", "\(stamp) [shown] \(title) <\(dedupId)>")
    }
    /// 2026-10-02：从「继续观看 / 历史」进来后**真的自动起播**了的那一刻。
    /// 用来区分「点了没续播」的两种病：没走到起播（autoplay 没触发）还是
    /// 走到了但起播被拦（player 层问题）—— 与 taptrace 对照即可定案。
    static func autoplay(dedupId: String, title: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        push("taptrace.autoplay", "\(stamp) [autoplay] \(title) <\(dedupId)>")
    }
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
    // ★ 2026-10-02「点 1 得 2」结构性加固：`.id()` 提到**最外层**。
    //   之前只加在 DetailView 上，SwiftUI 仍可能复用外层 NavigationStack 的壳子、
    //   拿旧内容顶上来（真机表现：点的是 A、弹出来的是 B）。绑在最外层 = 换片必重建整棵树。
    .id(item.dedupId)
    .environmentObject(router)   // sheet 不保证继承外层 environmentObject，显式注入
    .presentationDetents([.fraction(0.88)])
    .presentationCornerRadius(30)
    .presentationDragIndicator(.visible)
    .presentationBackground(.clear)
    // ★ 展示痕迹：记下"弹层真正渲染出来的是哪一条"，与 taptrace 对照即可一次定案
    .onAppear { TapTrace.present(dedupId: item.dedupId, title: item.title) }
}
