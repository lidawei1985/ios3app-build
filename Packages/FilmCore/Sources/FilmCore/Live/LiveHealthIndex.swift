import Foundation
import os

private let healthLog = Logger(subsystem: "filmthree", category: "live.health")

/// 直播线「地表」（v24 · 用户：直播还是不好用）：
/// 出包前用三级真出流探针（playlist + 首个分片字节 L3）实测每条线路，
/// 把**真能出流**的线路 URL 固化进 `Resources/live_health.json`，随包分发。
///
/// 为什么需要它（今晚实测的硬数据）：
/// 619 台线路里只有 318 条（51.4%）真能出流；**几乎每个热门台正好 1 条活线，
/// 且基本不在第 1 位**（CCTV-1 / 湖南卫视都是「x x O x x x」第 3 条才活；
/// 东方卫视第 1 条活、浙江卫视第 2/5 条活；广东卫视 6 条全死）。
/// App 默认从第 1 条起播 → 直接撞死线 → 永久缓冲，靠看门狗 8~40 秒才换线。
///
/// 本类只做**只读查询**：不写表、不改源序、不做网络请求（探活在离线出包期完成）。
/// 「表里没有」= 未知（不判死），端上仍按原序 + 运行期真探活兜底。
public final class LiveHealthIndex {
    public static let shared = LiveHealthIndex()

    /// 真活线 URL 集合（绝对串，含百分号编码原样 + 解码后两种写法）。
    private let alive: Set<String>
    /// 地表是否可用（资源缺失 / 解析失败 → false，端上一律退回原逻辑）。
    public let hasData: Bool
    public let generatedAt: String
    public let total: Int
    public let ok: Int

    private struct Repo: Decodable {
        let generatedAt: String?
        let total: Int?
        let ok: Int?
        let alive: [String]?
    }

    private init() {
        var set = Set<String>()
        var gen = ""
        var tot = 0
        var okc = 0
        var loaded = false
        if let u = Bundle.module.url(forResource: "live_health", withExtension: "json",
                                     subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "live_health", withExtension: "json"),
           let data = try? Data(contentsOf: u),
           let repo = try? JSONDecoder().decode(Repo.self, from: data),
           let list = repo.alive {
            for s in list {
                set.insert(s)
                if let d = s.removingPercentEncoding, d != s { set.insert(d) }
            }
            gen = repo.generatedAt ?? ""
            tot = repo.total ?? list.count
            okc = repo.ok ?? list.count
            loaded = true
        }
        alive = set
        hasData = loaded && !set.isEmpty
        generatedAt = gen
        total = tot
        ok = okc
        if loaded {
            healthLog.info("live-health: 载入 \(okc)/\(tot) 条真活线（\(gen)）")
        } else {
            healthLog.error("live-health: 地表缺失/解析失败 → 退回原序 + 运行期探活")
        }
    }

    /// 这条线路是否在「真能出流」的地表里。未知（不在表内）返回 false——
    /// 调用方只在「明确知道某条活」时才改起播线，未知一律不动。
    public func isAlive(_ url: URL) -> Bool {
        guard hasData else { return false }
        let s = url.absoluteString
        if alive.contains(s) { return true }
        if let d = s.removingPercentEncoding, alive.contains(d) { return true }
        return false
    }
}
