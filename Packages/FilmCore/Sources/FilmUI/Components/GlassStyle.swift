import SwiftUI

// ★★★ 全局唯一毛玻璃 v2（2026-09-30 · 用户「这？玻璃？」）
//
// 结论先写死（免得下次再试）：系统原生 Liquid Glass（.glassEffect）需要 Xcode 26 / iOS 26 SDK，
// **中转仓 CI 的 runner SDK 没有**（v22 首轮实测：error: value of type 'Color' has no member 'glassEffect'）。
// 等哪天 CI 升了 Xcode 26，再把 GlassEffectBranch 加回来。
//
// v1 问题：ultraThinMaterial + 平的白提亮 —— 背后是纯色深底时模糊出来就是一块平灰，看不出玻璃。
// v2 观感方案（在材质之上做「玻璃的视觉语言」）：
//   ① thinMaterial（比 ultraThin 亮一档，深色模式不再发黑）；
//   ② 顶部→底部白色渐变（上亮下沉，模拟玻璃受光面）；
//   ③ 顶部发丝高光边（上亮下暗双描边，模拟玻璃厚度）。
// 机检：`scripts/check_glass_global.py` —— FilmUI 内裸材质残留必须为 0
//（只允许 PlayerScreen.swift 的 playerGlass/glassSheet 与本文件内部使用）。

/// 玻璃厚度档位（2026-10-01 新增）。
///
/// 根因（用户 2026-10-01 真机提问「那块面板是不是加了层灰的、整体都变灰了」）：
/// v22b 把材质从 `.ultraThinMaterial` 换成 **`.thinMaterial`**（+顶部白渐变），
/// 而 `.thinMaterial` 在深色下**比 ultraThin 更实**——底层取色背景几乎透不上来，
/// 渲染出来就是一块平灰（真机实测面板色 (97,85,79)→(63,62,63)，而页面底是暖棕 (63,26,8)）。
///
/// 2026-10-01 二次实测（v27 装上后用户仍报「灰色框还在」）——**换档不够，材质本身就是元凶**：
///   `Material` 无论厚薄，都会把背景**去色**（把彩色底压向中性）。真机逐点取样：
///     页面底 (28,33,26) 比值 1 : 1.18 : 0.93（绿调）
///     面板内 (48,50,46) 比值 1 : 1.04 : 0.96（绿调被压平 → 看着就是"一块灰"）
///   所以只要还留着材质，白度怎么调都还是灰的。**正解＝不用材质**：只叠一层极淡的
///   白色提亮，底色（连同它的色相）原样透出 → 背景什么色、面板就什么色。
///
/// 材质字面量必须留在本文件内（机检 `scripts/check_glass_global.py`：白名单外不许出现裸材质），
/// 所以对外只暴露语义档位，页面侧传 `.clear` 即可，不接触任何材质字面量。
enum FilmGlassWeight {
    /// 常规：thinMaterial。观感更"实"，适合需要压住底下内容的浮层。
    case regular
    /// 轻薄：ultraThinMaterial。比 regular 透，但仍会被材质去色。
    case light
    /// 纯透明（**推荐用于"跟底变色"**）：**不挂任何材质**，只叠一层极淡均匀白提亮。
    /// 底色（含色相）原样透出 —— 页面底色变，面板跟着变，不产生中性灰块。
    /// 适用：背后是**静态取色底**的页面（设置页点播源面板等）。
    case clear
    /// 压暗（**播放器 / 视频上浮层专用**）：挂 ultraThinMaterial 把画面虚化，再**均匀压一层黑**。
    ///
    /// 为什么播放器**不能**照搬 `.clear`：面板背后是会动的视频、明暗不定 —— 完全不挂材质时，
    /// 浅色画面（雪景/白墙）一上来白字就糊得读不清，这是当初加材质的唯一理由。
    /// 为什么**不能**用 `.regular`：那档是「白提亮 + 顶部更亮渐变」，叠在深色材质上正好洗出一块灰
    /// （用户 2026-09-30、2026-10-01 两次拍桌「倍速还是黑框 / 灰框」的同一个根因）。
    /// 正解＝**中性压暗**（黑在最暗处，不会把画面洗灰）+ 亮发丝边 = 爱优腾浮层观感。
    case dark

    /// nil = 不铺材质（`.clear` 档）。
    var material: Material? {
        switch self {
        case .regular:       return .thinMaterial
        case .light, .dark:  return .ultraThinMaterial
        case .clear:         return nil
        }
    }
}

struct FilmGlassBackground: View {
    var cornerRadius: CGFloat
    var tint: Double
    var strokeOpacity: Double
    var weight: FilmGlassWeight

    init(cornerRadius: CGFloat = 12, tint: Double = 0.12, strokeOpacity: Double = 0.16,
         weight: FilmGlassWeight = .regular) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.strokeOpacity = strokeOpacity
        self.weight = weight
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            switch weight {
            case .regular, .light:
                if let m = weight.material { shape.fill(m) }
                // 受光面：顶部更亮的白渐变（玻璃的明暗语言）——只在「白提亮」两档叠。
                // `.clear` 档不叠：顶部 +0.10 的白会在"纯透明"面板上糊出上半截发白，
                // 那又变成另一种"灰"，与「跟着背景变色」目标相反。
                shape.fill(
                    LinearGradient(stops: [
                        .init(color: .white.opacity(tint + 0.10), location: 0),
                        .init(color: .white.opacity(tint), location: 0.45),
                        .init(color: .white.opacity(max(tint - 0.06, 0)), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                )
            case .clear:
                // 纯透明档：**均匀**一层极淡白，不加渐变、不去色 —— 底色原样透上来。
                shape.fill(Color.white.opacity(tint))
            case .dark:
                if let m = weight.material { shape.fill(m) }
                // 视频上浮层：均匀**压暗**（不是提亮）—— 中性、不洗灰，白字任何画面下都读得清。
                shape.fill(Color.black.opacity(tint))
            }
        }
        .overlay(
            // 玻璃厚度：上亮下暗双发丝边
            shape.stroke(Color.white.opacity(strokeOpacity + 0.10), lineWidth: 0.8)
                .blendMode(.plusLighter)
                .mask(
                    LinearGradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0.25), location: 0.5),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                )
        )
        .overlay(
            shape.stroke(Color.white.opacity(strokeOpacity * 0.5), lineWidth: 0.5)
        )
    }
}

extension View {
    /// 全局通用毛玻璃：thinMaterial + 渐变受光面 + 上亮发丝边（玻璃视觉语言）。
    /// cornerRadius 传 ≥ 短边一半（如 999）时自动退化为胶囊/圆（与 playerGlass 同技巧）。
    /// weight 传 `.light` 走 ultraThinMaterial（更透）；传 `.clear` **完全不挂材质**，
    /// 只有一层极淡均匀白 —— 底色连同色相原样透出，用于「面板跟着背景一起变色」。
    func filmGlass(cornerRadius: CGFloat = 12, tint: Double = 0.12, strokeOpacity: Double = 0.16,
                   weight: FilmGlassWeight = .regular) -> some View {
        background(FilmGlassBackground(cornerRadius: cornerRadius, tint: tint,
                                       strokeOpacity: strokeOpacity, weight: weight))
    }
}
