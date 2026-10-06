import SwiftUI
import FilmCore

/// 启动动画（2026-10-03 主人钦定「启动动画这个还算个有用的东西」，气质：品牌字标 + 光晕）。
///
/// 它解决的是三件具体的丑事，不是"开机放张图"：
///  ① **冷启动白闪**：系统启动屏（`UILaunchScreen.UIColorName = LaunchBackground`）与本视图首帧
///     是同一个色（#0B0E14）→ 从点图标到过场结束，屏幕不会白一下、黑一下、再闪一下；
///  ② **首页硬切**：原来数据一到，首页整屏"啪"地蹦出来。现在由过场淡出揭开，
///     观感是"揭幕"，不是"跳变"；
///  ③ **揭幕了还在转圈**：过场期间 `store.boot()` 照常在后台跑（互不等待），
///     所以过场结束露出来的首页通常已经填好内容 —— 是"揭幕即就位"，不是"揭幕再等图"。
///
/// 不卡的三条纪律（动这里之前先读）：
///  • 全程只动 `opacity` / `scale` / 这一根线的 `frame(width:)` —— 都是**不触发父视图重排**的量。
///    绝不碰会引发整树重新布局的属性：`LazyVGrid`/`LazyHStack` 一旦被惊动就是掉帧；
///  • 主色光晕是**静态**的（不参与动画）——动画元素越少越稳；
///  • 这层遮罩挂在 TabView **外面**（见 `LaunchSplashGate`），TabView 只建一次、只布局一次，
///    揭幕时没有二次布局。
public struct LaunchSplash: View {
    let profile: ProductProfile

    @State private var markIn = false     // 字标 + 主色横线
    @State private var textIn = false     // 副标 + slogan

    public init(profile: ProductProfile) { self.profile = profile }

    private var accent: Color { Color(hex: profile.accentColorHex) ?? .red }
    /// 必须与 `Apps/{Xingmu,Xinwu}/Assets.xcassets/LaunchBackground.colorset` **同色**
    /// （那是系统启动屏用的）。改色要两处一起改，少改一处就是一次白闪。
    private static let stage = Color(hex: "#0B0E14") ?? .black

    public var body: some View {
        ZStack {
            Self.stage
            // 主色光晕：静态，不参与任何动画
            RadialGradient(
                colors: [accent.opacity(0.34), accent.opacity(0.06), .clear],
                center: UnitPoint(x: 0.5, y: 0.44),
                startRadius: 0,
                endRadius: 360
            )
            VStack(spacing: 0) {
                Text(profile.logoName)
                    .font(.system(size: 26, weight: .black))
                    .kerning(7)
                    .foregroundStyle(.white)
                    .opacity(markIn ? 1 : 0)
                    .scaleEffect(markIn ? 1 : 0.96)
                // 主色横线：随字标一起「拉开」（宽度只影响这根线自己，不影响别的布局）
                Rectangle()
                    .fill(accent)
                    .frame(width: markIn ? 58 : 10, height: 2)
                    .padding(.top, 16)
                    .opacity(markIn ? 1 : 0)
                Text(profile.appName)
                    .font(.system(size: 16, weight: .semibold))
                    .kerning(5)
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.top, 18)
                    .opacity(textIn ? 1 : 0)
                Text(profile.tagline)
                    .font(.system(size: 11))
                    .kerning(1.4)
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.top, 8)
                    .opacity(textIn ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 0.52)) { markIn = true }
            withAnimation(.easeOut(duration: 0.52).delay(0.18)) { textIn = true }
        }
        .accessibilityHidden(true)     // 纯装饰，别让读屏念它
    }
}

/// 启动过场闸门：把 App 内容包一层，过场到点自动揭幕。
/// 三端入口一致：`LaunchSplashGate(profile: .xingmu) { MainTabView(profile: .xingmu)… }`
///
/// 时序铁律：**固定 ~1.0s 就揭幕，绝不等数据。**
/// 反过来（等 `store.boot()` 完成才揭幕）在弱网下会变成"过场卡 8 秒"，那是灾难。
/// 正确心智：过场是**盖住加载**，不是**等加载** —— 它占用的是本来就在转圈的那段时间。
public struct LaunchSplashGate<Content: View>: View {
    let profile: ProductProfile
    let content: Content

    /// 过场停留时长（秒）。改大会"显得启动慢"，改小可能盖不住首屏加载 → 建议 0.9~1.2。
    private let hold: Double = 1.0
    private let fade: Double = 0.46

    @State private var show = true

    public init(profile: ProductProfile, @ViewBuilder content: () -> Content) {
        self.profile = profile
        self.content = content()
    }

    public var body: some View {
        ZStack {
            content
            if show {
                LaunchSplash(profile: profile)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            withAnimation(.easeInOut(duration: fade)) { show = false }
        }
    }
}
