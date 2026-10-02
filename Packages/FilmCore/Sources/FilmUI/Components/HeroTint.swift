import SwiftUI
import UIKit

/// 主视觉「跟着海报变色」取色（2026-09-24 根修版）。
///
/// 用户钦定把主视觉搬真机（原型看过、点头），且这是用户最爱的一口：
/// 「背景跟着海报变色」这种**看得见的动态效果**（交接单 §7）。
///
/// 根因（2026-09-24 取证）：此前 `_shade` 走 HSL 并把 `deep` 压到 `mul=0.17`，
/// 导致暗海报的页面底色直接黑掉；而可点原型真正渲染出来的颜色来自
/// `gen_hero_data.py` / `gen_home_data.py` 的 HSV 衍生算法（`deep=v×0.44`、
/// `glow` 带最低亮度 0.42 / 最低饱和度 0.30）。
///
/// 算法：
///   26×38 缩略采样 → 丢弃「太暗（亮度<26）」或「太灰（饱和度<0.14）」的像素 →
///   其余按 `饱和度 × (1 - |亮度-150|/240)` 加权平均（越鲜艳、越接近中等亮度的像素权重越大）
///   → 得主色 `dom` → 转 HSV 派生 mid/deep/edge/glow（与原型生成器同款）。
public struct HeroPalette: Equatable, Sendable {

    /// 0–255 的 RGB 三元组（与原型同一数值域，便于逐行对照，**不要**改成 0–1）。
    public struct RGB: Equatable, Sendable {
        public var r: Double, g: Double, b: Double
        public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

        public var color: Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
        public func alpha(_ a: Double) -> Color { color.opacity(a) }
        public func scaled(_ k: Double) -> RGB { RGB(r * k, g * k, b * k) }

        /// HSV 三元组（h,s,v 均为 0–1）。
        public var hsv: (h: Double, s: Double, v: Double) {
            let rr = r / 255, gg = g / 255, bb = b / 255
            let mx = max(rr, gg, bb), mn = min(rr, gg, bb), d = mx - mn
            var h = 0.0
            if d != 0 {
                if mx == rr { h = ((gg - bb) / d + (gg < bb ? 6 : 0)) / 6 }
                else if mx == gg { h = ((bb - rr) / d + 2) / 6 }
                else { h = ((rr - gg) / d + 4) / 6 }
            }
            let s = mx == 0 ? 0 : d / mx
            return (h, s, mx)
        }

        /// 按 HSV 生成新 RGB（分量均已 clamp 到 0–1）。
        public static func fromHSV(h: Double, s: Double, v: Double) -> RGB {
            let s = max(0, min(1, s))
            let v = max(0, min(1, v))
            var hh = (h * 6).truncatingRemainder(dividingBy: 6)
            if hh < 0 { hh += 6 }
            let i = Int(hh)
            let c = v * s
            let x = c * (1 - abs(((h * 6).truncatingRemainder(dividingBy: 2)) - 1))
            let m = v - c
            let (r1, g1, b1): (Double, Double, Double)
            switch i {
            case 0: r1 = c;   g1 = x;   b1 = 0
            case 1: r1 = x;   g1 = c;   b1 = 0
            case 2: r1 = 0;   g1 = c;   b1 = x
            case 3: r1 = 0;   g1 = x;   b1 = c
            case 4: r1 = x;   g1 = 0;   b1 = c
            default: r1 = c; g1 = 0;   b1 = x
            }
            return RGB((r1 + m) * 255, (g1 + m) * 255, (b1 + m) * 255)
        }

        /// 亮度 ×mul、饱和度 +ds（旧 HSL 算法，保留以兼容）。
        public func shade(mul: Double, ds: Double) -> RGB {
            let c = [r / 255, g / 255, b / 255]
            let mx = max(c[0], c[1], c[2]), mn = min(c[0], c[1], c[2])
            let l0 = (mx + mn) / 2, d = mx - mn
            var s = d == 0 ? 0 : (l0 > 0.5 ? d / (2 - mx - mn) : d / (mx + mn))
            var h = 0.0
            if d != 0 {
                if mx == c[0] { h = (c[1] - c[2]) / d + (c[1] < c[2] ? 6 : 0) }
                else if mx == c[1] { h = (c[2] - c[0]) / d + 2 }
                else { h = (c[0] - c[1]) / d + 4 }
                h /= 6
            }
            s = min(1, max(0, s + ds))
            let l = min(1, max(0, l0 * mul))
            func h2r(_ p: Double, _ q: Double, _ t0: Double) -> Double {
                var t = t0
                if t < 0 { t += 1 }
                if t > 1 { t -= 1 }
                if t < 1.0 / 6 { return p + (q - p) * 6 * t }
                if t < 1.0 / 2 { return q }
                if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
                return p
            }
            var rr = l, gg = l, bb = l
            if s != 0 {
                let q = l < 0.5 ? l * (1 + s) : l + s - l * s
                let p = 2 * l - q
                rr = h2r(p, q, h + 1.0 / 3)
                gg = h2r(p, q, h)
                bb = h2r(p, q, h - 1.0 / 3)
            }
            return RGB(rr * 255, gg * 255, bb * 255)
        }
    }

    public let dom: RGB
    public let mid: RGB
    public let deep: RGB
    public let edge: RGB
    public let glow: RGB
    /// 按钮渐变第二色（原型 `grad = 135deg, shade(c,.78,.22) → shade(c,.30,.26)`）。
    public let buttonTop: RGB
    public let buttonBottom: RGB

    public init(dom: RGB) {
        self.dom = dom
        let (h, s, v) = dom.hsv
        // HSV 派生与原型生成器 `gen_hero_data.py` / `gen_home_data.py` 逐行对齐：
        //   deep = v×0.44, s+0.24； mid = v×0.62, s+0.16；
        //   glow = 最低亮度 0.42、最低饱和度 0.30、最高亮度 0.68，并做 v×1.25。
        self.mid = RGB.fromHSV(h: h, s: min(1, s + 0.16), v: v * 0.62)
        self.deep = RGB.fromHSV(h: h, s: min(1, s + 0.24), v: v * 0.44)
        self.edge = RGB.fromHSV(h: h, s: min(1, s + 0.18), v: v * 0.28)
        self.glow = RGB.fromHSV(h: h, s: min(0.85, max(s, 0.30)), v: min(0.68, max(v * 1.25, 0.42)))
        self.buttonTop = RGB.fromHSV(h: h, s: min(1, s + 0.22), v: v * 0.78)
        self.buttonBottom = RGB.fromHSV(h: h, s: min(1, s + 0.26), v: v * 0.30)
    }

    /// 取不到色时的兜底（原型同样兜 `#5f6480`，HSV 衍生后也不会黑）。
    public static let fallback = HeroPalette(dom: RGB(95, 100, 128))

    /// 主色提取（原型 `_domOf`）。
    public static func extract(from image: UIImage) -> HeroPalette? {
        guard let cg = image.cgImage else { return nil }
        let w = 26, h = 38
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let R = Double(buf[i]), G = Double(buf[i + 1]), B = Double(buf[i + 2])
            let mx = max(R, G, B), mn = min(R, G, B)
            let sat = mx > 0 ? (mx - mn) / mx : 0
            let lum = R * 0.299 + G * 0.587 + B * 0.114
            if lum < 26 || sat < 0.14 { continue }        // 太暗 / 太灰的像素不参与
            let k = sat * (1 - abs(lum - 150) / 240)
            if k <= 0 { continue }
            r += R * k; g += G * k; b += B * k; weight += k
        }
        guard weight >= 0.6 else { return nil }           // 有效像素不足 → 判定取色失败（走兜底）
        return HeroPalette(dom: RGB(r / weight, g / weight, b / weight))
    }
}

/// 取色缓存：同一张海报只解一次；图片走既有 `PosterLoader`（内存+磁盘缓存），不额外下载。
///
/// 2026-09-23：升级为 `ObservableObject` 并新增 `current` —— 除首页外，
/// **分类页/详情页等整页底色也要跟着主视觉取色**（用户：「整页背景跟着海报变色」、原型 `__catTint`）。
@MainActor
public final class HeroTintStore: ObservableObject {
    public static let shared = HeroTintStore()
    /// 当前主视觉取色（首页轮播换帧时写入；其它页面订阅它做整页取色底）。
    @Published public var current: HeroPalette = .fallback
    private var cache: [String: HeroPalette] = [:]

    public func palette(for urlString: String?) async -> HeroPalette {
        guard let key = urlString, !key.isEmpty else { return .fallback }
        if let hit = cache[key] { return hit }
        // 取色只需很小的一张（10-01 P0 分档后：这里显式要小档，别去跟主视觉抢原图内存）
        guard let img = await PosterLoader.shared.image(for: key, thumbPriority: false, maxSide: 200),
              let p = HeroPalette.extract(from: img) else { return .fallback }
        cache[key] = p
        return p
    }
}


// MARK: - 整页取色渐变底（公共组件）

/// 整页取色底：随主视觉取色（`HeroTintStore.current`）变化，与首页/分类页同源。
///
/// 2026-09-27：此前 **分类页 / 片库 / 搜索 / 内置源 / 电视剧 5 处各自复制了一份完全相同的实现**
/// （归一化后哈希一致 `aa9d3fccd572`），已抽成此组件 —— 改一处全端生效，
/// 避免再出现「改了 3 个页、漏了 2 个」的不一致。
///
/// 历史沿革（各页当初落地时的原话，已从各页迁来此处集中保存）：
/// - 分类页 2026-09-23（方案 A）：跟随主视觉当前海报色，和首页连成一片。
/// - 片库 / 搜索（v14）：跟首页、分类页同源 ——「你看首页什么样，我的和搜索就是什么样子」。
/// - 内置源主页 2026-09-27：「内置源主页要像首页那种玻璃效果」；与首页/分类页共用
///   `HeroTintStore.shared.current`，从首页进来颜色连成一片，不再是纯黑底。
/// - 电视剧 2026-09-24：「电视剧分类里面的颜色不跟着变啊，我看分其他的都跟随了就他自己不变」。
///   旧版死底 `theme.background` 是全 App 唯一不跟色的页面；改用与分类页同一方案后，
///   从首页进来颜色连续不跳色。
struct TintBackgroundView: View {
    @ObservedObject private var tint = HeroTintStore.shared

    var body: some View {
        let p = tint.current
        // 2026-09-30 用户报「设置页子页进去都是透明的看不清」根因：
        // 渐变**顶部第 1 站只给了 0.40 alpha**（`p.mid.alpha(0.40)`），单铺这一层时，
        // 背后的一级页/首页内容会从顶部透上来 → 子页看着"透明、字看不清"。
        // 正解＝在这层渐变**底下先垫一层不透明底色**（观感仍是同一套取色玻璃，但不再透）。
        // 一处修好，6 个用它的页面（设置/分类/片库/搜索/内置源/电视剧）同时生效。
        return ZStack {
            Color(hex: "#0A0A0D") ?? .black
            LinearGradient(stops: [
                .init(color: p.mid.alpha(0.40), location: 0.00),
                .init(color: p.deep.scaled(0.94).color, location: 0.31),
                .init(color: Color(hex: "#0A0A0D") ?? .black, location: 0.76)
            ], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.9), value: tint.current)
    }
}
