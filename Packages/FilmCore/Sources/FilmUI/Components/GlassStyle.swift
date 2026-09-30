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
/// 材质字面量必须留在本文件内（机检 `scripts/check_glass_global.py`：白名单外不许出现裸材质），
/// 所以对外只暴露语义档位，页面侧传 `.light` 即可，不接触 `.thinMaterial` 这类字面量。
enum FilmGlassWeight {
    /// 常规：thinMaterial。观感更"实"，适合需要压住底下内容的浮层。
    case regular
    /// 轻薄：ultraThinMaterial。更透，底层取色背景能透上来 —— 「透明跟底」用这档。
    case light

    var material: Material {
        switch self {
        case .regular: return .thinMaterial
        case .light:   return .ultraThinMaterial
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
            shape.fill(weight.material)
            // 受光面：顶部更亮的白渐变（玻璃的明暗语言）
            shape.fill(
                LinearGradient(stops: [
                    .init(color: .white.opacity(tint + 0.10), location: 0),
                    .init(color: .white.opacity(tint), location: 0.45),
                    .init(color: .white.opacity(max(tint - 0.06, 0)), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
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
    /// weight 传 `.light` 走 ultraThinMaterial —— 更透、底层取色背景透得上来（「透明跟底」）。
    func filmGlass(cornerRadius: CGFloat = 12, tint: Double = 0.12, strokeOpacity: Double = 0.16,
                   weight: FilmGlassWeight = .regular) -> some View {
        background(FilmGlassBackground(cornerRadius: cornerRadius, tint: tint,
                                       strokeOpacity: strokeOpacity, weight: weight))
    }
}
