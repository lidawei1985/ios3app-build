import Foundation

/// 直播源健康度（v17 · 用户钦定「好源在第一位、补充在后、降级策略」）：
/// 每个 URL 记一个分数——播起来 +1，判死/幻灯片降级 -2（坏源快速沉底）。
/// 同台多条线路时按分数降序选备线：历史上播得顺的源当第一候选，
/// 从没出过问题的源（0 分）按表内原顺序兜底。分档上限防极端值堆积。
public final class LiveSourceHealth {
    public static let shared = LiveSourceHealth()

    private let storeKey = "live.srcHealth.v1"
    private var scores: [String: Int]
    private let queue = DispatchQueue(label: "live.srcHealth")

    private init() {
        if let d = UserDefaults.standard.data(forKey: storeKey),
           let o = try? JSONDecoder().decode([String: Int].self, from: d) {
            scores = o
        } else {
            scores = [:]
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(scores) {
            UserDefaults.standard.set(d, forKey: storeKey)
        }
    }

    public func record(_ url: URL, ok: Bool) {
        let k = url.absoluteString
        queue.sync {
            let s = (scores[k] ?? 0) + (ok ? 1 : -2)
            scores[k] = min(max(s, -30), 30)
            save()
        }
    }

    public func score(_ url: URL) -> Int {
        queue.sync { scores[url.absoluteString] ?? 0 }
    }

    /// 同台候选线路排序：健康度降序（稳定），同分保持原顺序（表内优先级不动）。
    /// 返回的是**原始下标序列**（调用方拿去挑下一条）。
    public static func ranked(_ urls: [URL]) -> [Int] {
        let s = shared
        return Array(urls.indices).sorted { a, b in
            let sa = s.score(urls[a]), sb = s.score(urls[b])
            return sa != sb ? sa > sb : a < b
        }
    }
}
