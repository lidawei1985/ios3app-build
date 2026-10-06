import Foundation

/// 插播广告段识别器（v61 · 2026-10-04）
///
/// ## 背景
/// 部分 CMS 片源（实测 `p.bvvvvvvvvv1f.com` / `v.baofeng9.com` 系）会在**正片 m3u8 里**
/// 用 `#EXT-X-DISCONTINUITY` 拼接一整段**广告视频**：实测为「澳门新葡京娱乐场 063063.COM」
/// 的 26 秒赌博广告（9 个分片），固定插在约 5min / 40min / 2h 三处，跨电影跨 CDN 同源同广告。
///
/// ## 为什么能精确识别
/// 广告分片的 URL 路径带**确定性特征** `adjump`：
///   正片＝`0000000.ts`（连续编号）
///   广告＝`/video/adjump/time/17873198659330000000.ts`（第三方广告仓）
/// 因此按路径判定即可，**不需要猜时间**。
///
/// ## 安全底线（用户钦定：宁可漏，绝不可误伤）
/// 1. 首选只认 `adjump` 类确定性特征；结构兜底（短段夹在长段之间）仅在无任何特征命中时才启用，
///    且要求至少 2 段、前后邻组都够长；
/// 2. 识别出的广告总时长 > `maxTotalSkipSeconds` → **整体放弃**（防"把正片认成广告"）；
/// 3. 播放列表总时长 < `minPlaylistSeconds` → 不启用；
/// 4. 识别结果为空 → 返回空区间，播放器**一秒都不跳**。
public enum AdBreakDetector {

    /// 需要跳过的广告区间（单位＝**播放列表时间轴**上的秒数，含正片前的累计时长）
    public struct Range: Equatable {
        public let start: Double
        public let end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
        public var duration: Double { max(0, end - start) }
    }

    public struct Outcome {
        public let ranges: [Range]
        public let reason: String
        public init(ranges: [Range], reason: String) {
            self.ranges = ranges
            self.reason = reason
        }
    }

    // MARK: 判据常量

    /// 确定性广告路径特征（全小写比对）
    private static let pathMarkers = ["adjump", "/video/ad/", "/ads/", "ad_jump"]

    /// 安全闸：识别出的广告总时长上限（超过即整体放弃）
    private static let maxTotalSkipSeconds: Double = 180
    /// 片长下限：太短不启用
    private static let minPlaylistSeconds: Double = 600
    /// 结构兜底：短段时长上限
    private static let structuralMaxGroupSeconds: Double = 60
    /// 结构兜底：前后邻组时长下限
    private static let structuralMinNeighborSeconds: Double = 180
    private static let requestTimeout: TimeInterval = 12

    // MARK: 入口

    /// 异步拉取并解析播放列表。自动处理**主播放列表 → 变体**（下钻一层）。
    public static func detect(playlistURL: URL, completion: @escaping (Outcome) -> Void) {
        fetch(playlistURL) { text in
            guard let text else {
                completion(Outcome(ranges: [], reason: "拉取失败"))
                return
            }
            // 主播放列表（#EXT-X-STREAM-INF）：先下钻到第一个变体再解析（一层足够，防递归打转）
            if let variant = firstVariantURL(in: text, base: playlistURL) {
                fetch(variant) { sub in
                    guard let sub else {
                        completion(Outcome(ranges: [], reason: "变体拉取失败"))
                        return
                    }
                    completion(parse(sub))
                }
            } else {
                completion(parse(text))
            }
        }
    }

    /// 拉取文本（带手机 UA；12s 超时；禁缓存，保证看到最新播放列表）
    private static func fetch(_ url: URL, completion: @escaping (String?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = requestTimeout
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  !text.isEmpty else {
                completion(nil)
                return
            }
            completion(text)
        }.resume()
    }

    /// 从主播放列表里取第一个变体 URI 并解析为绝对地址（无 STREAM-INF 则返回 nil）
    private static func firstVariantURL(in text: String, base: URL) -> URL? {
        guard text.contains("#EXT-X-STREAM-INF") else { return nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return URL(string: line, relativeTo: base)?.absoluteURL
        }
        return nil
    }

    /// 纯解析（便于单测）。
    public static func parse(_ text: String) -> Outcome {
        struct Seg {
            let uri: String
            let dur: Double
        }

        // 1) 按 #EXT-X-DISCONTINUITY 切段
        var groups: [[Seg]] = []
        var cur: [Seg] = []
        var pending: Double = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXT-X-DISCONTINUITY") {
                if !cur.isEmpty { groups.append(cur); cur = [] }
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                let v = line.dropFirst("#EXTINF:".count)
                    .split(separator: ",").first.map(String.init) ?? ""
                pending = Double(v.trimmingCharacters(in: .whitespaces)) ?? 0
                continue
            }
            if line.hasPrefix("#") { continue }
            cur.append(Seg(uri: line, dur: pending))
            pending = 0
        }
        if !cur.isEmpty { groups.append(cur) }

        guard groups.count >= 2 else {
            return Outcome(ranges: [], reason: "无分段(\(groups.count))")
        }

        // 2) 累计时间轴
        var timeline: [(start: Double, end: Double, segs: [Seg])] = []
        var t = 0.0
        for g in groups {
            let s = t
            for x in g { t += x.dur }
            timeline.append((s, t, g))
        }
        let total = t
        guard total >= minPlaylistSeconds else {
            return Outcome(ranges: [], reason: "片长过短(\(Int(total))s)，不启用")
        }

        // 3) 确定性特征：整组分片路径全部命中广告标记
        var flagged: [Range] = []
        var byMarker = false
        for g in timeline where !g.segs.isEmpty {
            let allAd = g.segs.allSatisfy { seg in
                let low = seg.uri.lowercased()
                return pathMarkers.contains { low.contains($0) }
            }
            if allAd {
                flagged.append(Range(start: g.start, end: g.end))
                byMarker = true
            }
        }

        // 4) 结构兜底（仅在无任何特征命中时启用，条件从严）
        if !byMarker {
            var cand: [Range] = []
            for (i, g) in timeline.enumerated() where !g.segs.isEmpty {
                let dur = g.end - g.start
                guard dur > 0, dur <= structuralMaxGroupSeconds else { continue }
                let prevLong = i - 1 >= 0
                    ? (timeline[i - 1].end - timeline[i - 1].start) >= structuralMinNeighborSeconds
                    : true
                let nextLong = i + 1 < timeline.count
                    ? (timeline[i + 1].end - timeline[i + 1].start) >= structuralMinNeighborSeconds
                    : true
                if prevLong && nextLong { cand.append(Range(start: g.start, end: g.end)) }
            }
            if cand.count >= 2 { flagged = cand }
        }

        guard !flagged.isEmpty else {
            return Outcome(ranges: [], reason: "未识别到广告段")
        }

        // 5) 安全闸：总时长上限
        let totalSkip = flagged.reduce(0) { $0 + $1.duration }
        guard totalSkip <= maxTotalSkipSeconds else {
            return Outcome(ranges: [],
                           reason: "广告总时长 \(Int(totalSkip))s 超安全上限，整体放弃")
        }

        flagged.sort { $0.start < $1.start }
        return Outcome(ranges: flagged,
                       reason: "\(byMarker ? "路径特征" : "结构兜底") 命中 \(flagged.count) 段 / 共 \(Int(totalSkip))s")
    }
}
