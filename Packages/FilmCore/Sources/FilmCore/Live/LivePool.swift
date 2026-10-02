import Foundation
import os

private let poolLog = Logger(subsystem: "filmthree", category: "livepool")

/// 表外候选池（随包 `Resources/live_pool.m3u`）：按**台名归一**索引的备用线路。
///
/// 为什么必须有它（主人 2026-10-02 钦定的运行态）：
///   「不是整体替换 —— 比如 CCTV1 8 点能看、8:01 看不了了就得知道马上自找开始补；
///     还有备用的 CCTV1 源 1/2/3/4，只要有一个不能用就给换上，始终保持都是能用的。」
///   ⇒ 表内某台线路全坏时，端上要能**当场从池里找一条补进来**，而不是把这台划掉。
///
/// 池里线路**仍要本机真测**（`LiveCollector`）才允许上屏 —— PC 上通的线 ≠ 手机上通（谁播谁知道）。
public enum LivePool {

    public struct Candidate: Sendable {
        public let name: String
        public let url: URL
    }

    /// 全池按归一后的台名索引（进程内只解析一次；解析失败视为「池不可用」，不影响起播）。
    private static let index: [String: [Candidate]] = {
        guard let u = locate(),
              let text = try? String(contentsOf: u, encoding: .utf8) else {
            poolLog.error("live_pool.m3u 不可读，端上补源不可用")
            return [:]
        }
        var map: [String: [Candidate]] = [:]
        var seen = Set<String>()
        for ch in M3UParser.parse(text) {
            guard playableOnDevice(ch.url) else { continue }
            let key = normalize(ch.name)
            guard !key.isEmpty else { continue }
            let dk = key + "\u{1}" + ch.url.absoluteString
            guard seen.insert(dk).inserted else { continue }
            map[key, default: []].append(Candidate(name: ch.name, url: ch.url))
        }
        let lines = map.values.reduce(0) { $0 + $1.count }
        poolLog.info("live pool loaded: \(map.count) stations / \(lines) lines")
        return map
    }()

    private static func locate() -> URL? {
        Bundle.module.url(forResource: "live_pool", withExtension: "m3u", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "live_pool", withExtension: "m3u")
    }

    /// 本机是否可能播：AVPlayer 只吃 http(s)；rtp/udp/rtsp 组播与 IPv6 字面量（多为内网组播网关）
    /// 在手机上恒不可达，进来只会白占体检时间。
    public static func playableOnDevice(_ u: URL) -> Bool {
        guard let s = u.scheme?.lowercased(), s == "http" || s == "https" else { return false }
        guard let h = u.host, !h.isEmpty else { return false }
        if h.hasPrefix("[") { return false }        // IPv6 字面量（例：[2409:8087:8:21::18]）
        if h.hasPrefix("239.") || h.hasPrefix("224.") { return false }   // 组播网段
        return true
    }

    /// 台名归一：与表侧同口径，且更强 —— 去「·备N/·池N」、去括号补充、去清晰度后缀、
    /// 统一大小写与分隔符。目的：让 `CCTV-1`、`CCTV1`、`CCTV-1 综合`、`CCTV-1高清`
    /// 落到同一个 key 上（表侧写 CCTV-1，池侧写 CCTV-1·池3，必须能对上）。
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for sep in ["·备", "·池", "·源", "·候", "·待"] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        if let r = s.range(of: "備") { s = String(s[..<r.lowerBound]) }
        s = s.uppercased()
        s = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
        // 去中英文括号补充说明（「东方卫视（高清）」→「东方卫视」）
        for (open, close) in [("（", "）"), ("(", ")"), ("【", "】"), ("[", "]")] {
            while let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) {
                s.removeSubrange(a.lowerBound...b.upperBound)
            }
        }
        let suffices = ["高清版", "标清版", "超清版", "高清", "标清", "超清", "蓝光", "1080P", "720P", "FHD", "HD", "SD", "4K"]
        var changed = true
        while changed {
            changed = false
            for x in suffices where s.hasSuffix(x) && s.count > x.count {
                s = String(s.dropLast(x.count))
                changed = true
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 该台在池中的候选（已排除 `excluding` 里的 URL，即表内已有的线）。
    /// `limit` 限流：端上体检是并发有上限的，一次拿太多反而拖慢起播。
    public static func candidates(for tableName: String,
                                  excluding: Set<String>,
                                  limit: Int = 8) -> [URL] {
        let key = normalize(tableName)
        guard !key.isEmpty else { return [] }
        // 精确 key 优先；再退一步按「前缀包含」找（池里偶有「CCTV-1综合」这类写法）
        var list = index[key] ?? []
        if list.isEmpty {
            list = index.first { k, _ in k.hasPrefix(key) || key.hasPrefix(k) }?.value ?? []
        }
        guard !list.isEmpty else { return [] }
        var out: [URL] = []
        for c in list {
            let s = c.url.absoluteString
            guard !excluding.contains(s) else { continue }
            guard !out.contains(where: { $0.absoluteString == s }) else { continue }
            out.append(c.url)
            if out.count >= limit { break }
        }
        return out
    }

    public static func hasCandidates(for tableName: String) -> Bool { !(index[normalize(tableName)] ?? []).isEmpty }

    public static var stationCount: Int { index.count }
    public static var lineCount: Int { index.values.reduce(0) { $0 + $1.count } }
}

/// 「补进来的线」要活过本次会话 —— 否则每次进页都要重新体检一遍池子（慢），
/// 也就不满足主人要的「天天都有、天天都能看」。落 UserDefaults，随包表不动。
public enum LiveRefill {
    private static let key = "live.refilled.v1"

    /// 台名归一 → [url]
    public static func all() -> [String: [String]] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let o = try? JSONDecoder().decode([String: [String]].self, from: d) else { return [:] }
        return o
    }

    public static func add(station tableName: String, url: URL, cap: Int = 6) {
        let k = LivePool.normalize(tableName)
        guard !k.isEmpty else { return }
        var o = all()
        var list = o[k] ?? []
        let s = url.absoluteString
        list.removeAll { $0 == s }
        list.insert(s, at: 0)                      // 新补的放最前（最近实测过）
        if list.count > cap { list = Array(list.prefix(cap)) }
        o[k] = list
        persist(o)
    }

    public static func urls(for tableName: String) -> [URL] {
        (all()[LivePool.normalize(tableName)] ?? []).compactMap { URL(string: $0) }
    }

    public static func forget() { UserDefaults.standard.removeObject(forKey: key) }

    private static func persist(_ o: [String: [String]]) {
        if let d = try? JSONEncoder().encode(o) { UserDefaults.standard.set(d, forKey: key) }
    }
}
