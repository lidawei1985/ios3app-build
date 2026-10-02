import Foundation

/// 源健康监控（2026-09-25 用户钦点「内置源坏了崩了能不能自动补救替换掉」第一层：单源熔断降级）。
///
/// 状态机（经典熔断器三态）：
///  - **闭合**（正常）：失败连续计数；连挂 `failThreshold`(3) 次 → 转**开路**；
///  - **开路**（熔断）：冷却 `cooldown`(10 分钟) 内聚合搜索直接跳过该源、浏览页沉底；
///  - **半开**（冷却到期）：放行一次探测；成功 → 复活归零；失败 → 直接重新开路（不再数 3 次）。
///
/// 纯 Foundation、无 UI 依赖、内存态（重启清零合理——重启后网络环境可能已恢复）。
/// 线程安全：NSLock 保护（TVBoxSiteClient 是 actor，从其内部同步调用本类安全）。
public final class SourceHealth: @unchecked Sendable {

    public static let shared = SourceHealth()
    private let lock = NSLock()
    private var fails: [String: Int] = [:]       // siteKey -> 连续失败次数
    private var downUntil: [String: Date] = [:]  // siteKey -> 熔断到期时间（到期即半开）

    /// 连挂多少次判定源失效。
    static let failThreshold = 3
    /// 熔断冷却秒数（到期放一次探测）。
    static let cooldown: TimeInterval = 600

    private init() {}

    /// 记录一次请求结果。ok=true 复活归零；false 按状态机推进。
    public func record(_ key: String, ok: Bool) {
        lock.lock(); defer { lock.unlock() }
        if ok {
            fails[key] = 0
            downUntil[key] = nil
            return
        }
        let now = Date()
        if let until = downUntil[key] {
            if now < until {
                // 开路中又被调到（理论上跳过层拦了，保险起见续期）
                downUntil[key] = now.addingTimeInterval(Self.cooldown)
            } else {
                // 半开探测失败 → 直接重新开路（不再数 3 次）
                downUntil[key] = now.addingTimeInterval(Self.cooldown)
                fails[key] = 0
            }
            return
        }
        let n = (fails[key] ?? 0) + 1
        fails[key] = n
        if n >= Self.failThreshold {
            downUntil[key] = now.addingTimeInterval(Self.cooldown)
            fails[key] = 0
        }
    }

    /// 聚合搜索等批量场景：该源是否应跳过（开路中=跳过；半开=放行探测）。
    public func isSkipped(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = downUntil[key] else { return false }
        return Date() < until
    }

    /// 浏览/分类排序键：失效源沉底（不隐藏——保留入口便于半开探测与自愈）。
    public func sortKey(_ key: String) -> Int {
        isSkipped(key) ? 1 : 0
    }

    /// 给定站点里当前失效源个数（整线路健康提示用）。
    public func downCount(among keys: [String]) -> Int {
        keys.filter { isSkipped($0) }.count
    }

    /// 换线路/刷新配置后清零（新线路是另一批源）。
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        fails = [:]
        downUntil = [:]
    }

    // MARK: - 测试支持

    #if DEBUG
    /// 仅供状态机测试：把某源直接置到指定状态。
    func _testInject(key: String, failCount: Int, downRemaining: TimeInterval?) {
        lock.lock(); defer { lock.unlock() }
        fails[key] = failCount
        downUntil[key] = downRemaining.map { Date().addingTimeInterval($0) }
    }
    /// 仅供状态机测试：读取内部状态。
    func _testState(_ key: String) -> (fails: Int, down: Bool) {
        lock.lock(); defer { lock.unlock() }
        let d = downUntil[key].map { Date() < $0 } ?? false
        return (fails[key] ?? 0, d)
    }
    #endif
}
