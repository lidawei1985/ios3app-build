import SwiftUI
import UIKit

/// 产品主题：深色底（海报展示）+ 产品强调色。三 App 共用结构、各自注入身份色。
///
/// 2026-09-22：外观不再锁死深色（原 MainTabView 写死 `.preferredColorScheme(.dark)`）。
/// 三色改为**动态色**（跟随系统亮暗），配合设置里「外观：跟随系统 / 深色 / 浅色」三档；
/// 播放页 / 直播页仍在调用处强制深色（视频层大牌惯例）。
public struct FilmTheme {
    public let accent: Color
    public let background: Color
    public let card: Color
    public let textPrimary: Color
    public let textSecondary: Color

    public init(accentHex: String) {
        accent = Color(hex: accentHex) ?? .red
        background = Self.adaptive(dark: "#0B0E14", light: "#FFFFFF")
        // 2026-09-25 玻璃化：card 从实底深灰改为半透明（深=白5.5% / 浅=黑4%）——
        // 同一份 card 被 40+ 处胶囊/卡片/骨架共用，此处一处改 = 全 APP 黑卡变玻璃，
        // 底色由 background 透出来，跟「变色」accent 系统无缝融入。
        card = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.055)
                : UIColor.black.withAlphaComponent(0.04)
        })
        textPrimary = Self.adaptive(dark: "#F2F4F8", light: "#15181E")
        textSecondary = Self.adaptive(dark: "#9AA3B2", light: "#69707D")
    }

    /// 跟随系统亮暗的动态色（同一 Color 在深/浅模式下解析为不同值）。
    private static func adaptive(dark: String, light: String) -> Color {
        Color(UIColor { trait in
            UIColor(rgbHex: trait.userInterfaceStyle == .dark ? dark : light) ?? .label
        })
    }
}

public extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

extension UIColor {
    /// "#RRGGBB" → UIColor（动态色构造用；不透明）。
    convenience init?(rgbHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}

/// 全局环境注入。
public struct FilmThemeKey: EnvironmentKey {
    public static let defaultValue = FilmTheme(accentHex: "#E8443A")
}
public extension EnvironmentValues {
    var filmTheme: FilmTheme {
        get { self[FilmThemeKey.self] }
        set { self[FilmThemeKey.self] = newValue }
    }
}

/// 外观档位（设置页「外观」三档，@AppStorage 持久化）。
public enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, dark, light
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .dark:   return "深色"
        case .light:  return "浅色"
        }
    }
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark:   return .dark
        case .light:  return .light
        }
    }
    public static let storageKey = "filmui.appearance"
}
