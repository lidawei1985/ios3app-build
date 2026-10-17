import Foundation

/// 搜索闸门：记住「源站把关键词搜索接口封了」的 host，之后不再为它白烧预算。
///
/// 为什么需要（2026-10-17 真机 + PC 双向实测）：
/// 主人报「换了索倪源，以前能搜到 LLZ 的影片比如蜜桃成熟时，现在搜不到，而且内置源结果也不显示」。
/// 逐条实测定位到**两件互相独立的事**：
///
/// ① 索倪源站封了 `wd=` 搜索接口（不是我们请求写错）：
///    `ac=detail&wd=蜜桃` → **HTTP 403 + Cloudflare 拦截页**，换 6 种 UA 全 403
///    （okhttp/4.10、okhttp/3.12、Chrome 桌面、iPhone Safari、Android Chrome、Android TV Dalvik）；
///    同一台机器、同一分钟，`ac=list&pg=1`（浏览）→ HTTP 200 正常。
///    对照组：`wd=蜜桃` 在非凡 6 条 / 猫眼 11 条 / 红牛3 17 条，全都 200 ——
///    证明只有索倪一家把搜索打了，跟参数写法、UA、协议都无关。
///
/// ② 纯拼音查询（llz / mtscs）在任何 MacCMS 源上都恒返回 0 条（`wd=` 只认中文），
///    以前能搜到是因为本地快照里存过那些片名、走了本地拼音索引，不是源站给的。
///
/// 本闸门只处理 ①：**运行时探测到 403 才标记**，不写死任何 host ——
/// 万一只是某条线路封、换网就能用，标记后 7 天自动过期重试，不会永久废掉一个源。
/// ② 由 `SearchView` 的拼音桥接处理（先把拼音翻成中文再搜）。
public enum SearchGate {

    private static let key = "TVBoxSearchBlockedHosts"
    private static let ttl: TimeInterval = 7 * 24 * 3600

    private static func load() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
    }

    private static func save(_ m: [String: Double]) {
        UserDefaults.standard.set(m, forKey: key)
    }

    public static func host(of api: String) -> String {
        (URLComponents(string: api)?.host ?? api).lowercased()
    }

    /// 该 host 的搜索是否已被判定为封禁（且未过期）。
    public static func isSearchBlocked(_ host: String) -> Bool {
        guard let at = load()[host.lowercased()] else { return false }
        return Date().timeIntervalSince1970 - at < ttl
    }

    /// 便捷：直接传源 api。
    public static func isSearchBlocked(api: String) -> Bool {
        isSearchBlocked(host(of: api))
    }

    /// 打上封禁标记（带时间戳，到期自动失效重试）。
    public static func markSearchBlocked(_ host: String) {
        var m = load()
        m[host.lowercased()] = Date().timeIntervalSince1970
        // 顺手清掉已过期的，避免字典无限长
        let now = Date().timeIntervalSince1970
        m = m.filter { now - $0.value < ttl }
        save(m)
        LiveDiag.writeSite("搜索闸门·\(host) 源站拦截 wd= 搜索（403）→ 7 天内跳过该源搜索")
    }

    /// 手动清除（设置页「恢复被跳过的源搜索」用；也便于排查时立刻重试）。
    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    public static var blockedHosts: [String] { Array(load().keys).sorted() }
}
