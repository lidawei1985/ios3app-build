import Foundation

// MARK: - TVBox Spider (type 3) 执行引擎 —— 原版功能移植路线（OwnTVClient）
// TVBoxOSC 原版爬虫实为三类，移植策略各不同：
//   ① 内置规则爬虫（原版 Java 实现，源里只写声明式规则）：
//        csp_XPath / csp_XPathMac / csp_JsonPath / csp_AppYs(V2) 等 —— 覆盖面最大，
//        Swift 重写规则解释器即可，不需要跑别人的代码。
//   ② JS 爬虫（drpy / catvod js 模式）：纯 JavaScript —— iOS 用系统 JavaScriptCore 宿主。
//   ③ 自定义 dex 爬虫（spider jar 里的 Java 类）：Android 专属，iOS 无法执行 —— 明示不支持。
// 里程碑：
//   M1（本文件）：类型识别 + 路由契约。
//   M2：XPath / JsonPath 规则引擎（对齐 ac= 分类/列表/详情/搜索/播放五端点）。
//   M3：JS 源宿主（JavaScriptCore + req/嗅探桥）。
//   M4：AppYs 系与兼容面扩展。
public enum SpiderRouter {

    public enum Kind: String {
        case xpath            // csp_XPath / csp_XPathMac / csp_XPathFilter…
        case jsonPath         // csp_JsonPath
        case appYs            // csp_AppYs / csp_AppYsV2
        case js               // api 以 .js 结尾或 js:// 前缀
        case unsupportedDex   // 其余 csp_ 自定义类（dex）
        case unknown
    }

    /// 按源 api 识别 Spider 子类型（原版按类名分派到内置爬虫的同款思路）。
    public static func classify(api: String) -> Kind {
        let a = api.trimmingCharacters(in: .whitespaces)
        if a.hasPrefix("js://") || a.hasSuffix(".js") { return .js }
        let low = a.lowercased()
        if low.contains("xpath") { return .xpath }
        if low.contains("jsonpath") { return .jsonPath }
        if low.contains("appys") { return .appYs }
        if low.hasPrefix("csp_") { return .unsupportedDex }
        return .unknown
    }

    /// 用户可读的能力说明（UI 明示用）。
    public static func capabilityText(for kind: Kind) -> String {
        switch kind {
        case .xpath, .jsonPath:
            return "规则型 Spider，引擎移植排期中（M2）"
        case .appYs:
            return "AppYs 系 Spider，引擎移植排期中（M4）"
        case .js:
            return "JS 爬虫源，M3 引擎已内置（drpy 宿主）"
        case .unsupportedDex:
            return "Android dex 自定义爬虫，iOS 无法执行（原版能力边界）"
        case .unknown:
            return "未知 Spider 类型"
        }
    }
}
