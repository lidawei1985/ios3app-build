import Foundation

/// 源质量账本（v69，主人 2026-10-04 钦定）：
///   「尽力不要让人换源 这就涉及到第一个源的质量问题了 如果第一个源质量很好每次都能很快响应
///     直接秒播那不就后面的都不用操作了吗？一定要把优先级搞好」
///
/// **换源是兜底，第一顺位源的质量才是根本** —— 本类负责把「每次都能快速起播」的大源顶到第一位。
///
/// 记录口径（只记**大源品牌**，与 `DefaultSites.brandKey` 归一后的键对齐，跨镜像/跨启动累积）：
///  - 成功样本：从 `play(line:)` 发起 → `timeControlStatus` 首次变 `.playing` 的秒数（起播耗时）
///  - 失败样本：同线路原地重连仍救不回来、被迫放弃该线路时记 1 次
///
/// 排名分（越小越好）= `(1 - 成功率) * 10 + 平均起播秒数`：
///   · 成功率是主键（差 10% 成功率 ≈ 惩罚 1 秒起播），平均耗时是次键 → 「快且稳」者第一。
///   · 样本不足（< `minSamples`）的源**不参与重排**，按 `assumedScore` 参与排序（稳定保序），
///     即「新装/没记录时行为与旧版完全一致」，绝不因一次偶然把默认片源踢下去。
///
/// 纯 Foundation、无 UI 依赖；持久化到 `UserDefaults`（键 `filmui.sourceQuality.v1`，
/// 探针脚本可直接拉出来核验）。NSLock 保护（PlayerViewModel 在 MainActor 上同步调用安全）。
public final class SourceQualityRank: @unchecked Sendable {

    public static let shared = SourceQualityRank()

    /// 参与重排所需的最少样本数（成功+失败）。低于此值视为「未知质量」。
    static let minSamples = 3

    /// 「未知质量」的假定分（稳定排序的锚点）：
    /// 相当于「约 85% 成功率 + 1 秒起播」，比它更好的源才有资格被提到未测源之前。
    static let assumedScore = 2.5

    /// 全失败时的惩罚分（沉底）。
    static let deadScore = 1_000_000.0

    private struct Stat: Codable {
        var success: Int = 0
        var fail: Int = 0
        var totalStartMs: Double = 0     // 成功样本起播耗时累计（毫秒）
        var lastUpdate: Double = 0
    }

    private let lock = NSLock()
    private var stats: [String: Stat] = [:]
    private let storeKey = "filmui.sourceQuality.v1"

    private init() { load() }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: Stat].self, from: data) else { return }
        stats = decoded
    }

    private func saveLocked() {
        if let data = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func norm(_ brand: String) -> String {
        DefaultSites.brandKey(brand).lowercased()
    }

    // MARK: - 采样

    /// 记一次**成功起播**（`startSeconds` = 从发起播放到画面真正动起来的秒数）。
    public func recordSuccess(_ brand: String, startSeconds: Double) {
        let key = norm(brand)
        guard !key.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var s = stats[key] ?? Stat()
        s.success += 1
        // 单次采样封顶 120s，避免把「卡了很久才起播」的极端值拉爆均值
        s.totalStartMs += max(0, min(startSeconds, 120)) * 1000
        s.lastUpdate = Date().timeIntervalSince1970
        stats[key] = s
        saveLocked()
    }

    /// 记一次**失败**（该线路被放弃/换源）。
    public func recordFailure(_ brand: String) {
        let key = norm(brand)
        guard !key.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var s = stats[key] ?? Stat()
        s.fail += 1
        s.lastUpdate = Date().timeIntervalSince1970
        stats[key] = s
        saveLocked()
    }

    // MARK: - 排名

    /// 质量分（越小越好）。返回 nil = 样本不足（调用方保持默认顺位）。
    public func rankScore(_ brand: String) -> Double? {
        let key = norm(brand)
        guard !key.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let s = stats[key], s.success + s.fail >= Self.minSamples else { return nil }
        if s.success == 0 { return Self.deadScore }             // 从没成功过 → 沉底
        let n = Double(s.success + s.fail)
        let successRate = Double(s.success) / n
        let avgStart = (s.totalStartMs / Double(s.success)) / 1000.0
        return (1.0 - successRate) * 10.0 + avgStart
    }

    /// 给排序用的分值：未知质量 → `assumedScore`（保持稳定原序）。
    private func sortScore(_ brand: String) -> Double {
        rankScore(brand) ?? Self.assumedScore
    }

    /// 按质量重排一组「大源名」：越快越稳的排前面；未知质量的按假定分参与（稳定保序）。
    /// 显式稳定排序（同分回退原下标），避免 Swift `sorted` 的非稳定比较破坏默认顺位。
    public func orderedBrands(_ brands: [String]) -> [String] {
        guard brands.count > 1 else { return brands }
        // 一次性把每个品牌的分值取出来（排序闭包里不再反复加锁）
        let scored: [(brand: String, idx: Int, score: Double)] = brands.enumerated().map { i, b in
            (b, i, sortScore(b))
        }
        // 任一大源都没有样本 → 直接原序返回（新装行为与旧版 100% 一致）
        guard scored.contains(where: { rankScore($0.brand) != nil }) else { return brands }
        return scored
            .sorted { a, b in
                if a.score != b.score { return a.score < b.score }
                return a.idx < b.idx
            }
            .map { $0.brand }
    }

    /// 首个大源名（= 会上门面/起播的那个）。无样本时返回入参首个（默认顺位）。
    public func bestBrand(_ brands: [String]) -> String? {
        orderedBrands(brands).first
    }

    /// 复验用：导出全部样本（写 UserDefaults 明文键 `filmui.sourceQuality.dump`，探针脚本可拉取）。
    /// 注意：**持锁期间不得再调用 `rankScore`**（非递归 NSLock 会自锁），分值在这里就地算。
    public func dumpForProbe() {
        lock.lock()
        var out: [String: [String: Double]] = [:]
        for (k, s) in stats {
            let n = max(1, s.success + s.fail)
            let avg = s.success > 0 ? (s.totalStartMs / Double(s.success)) / 1000.0 : -1
            let sr = Double(s.success) / Double(n)
            var score = -1.0
            if s.success + s.fail >= Self.minSamples {
                score = s.success == 0 ? Self.deadScore : (1.0 - sr) * 10.0 + max(0, avg)
            }
            out[k] = ["success": Double(s.success), "fail": Double(s.fail),
                      "avgStartSec": avg, "successRate": sr, "score": score]
        }
        lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: "filmui.sourceQuality.dump")
        }
    }
}
