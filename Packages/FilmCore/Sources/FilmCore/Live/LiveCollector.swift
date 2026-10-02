import Foundation
import AVFoundation
import os

/// 端上直播采集器（2026-10-03 主人钦定：「不要别人整理好的表，我们自己采集」）。
///
/// 为什么必须端上采集：
///   直播线路能不能播，**取决于用户自己这条网络**（运营商/宽带/地区）。
///   在别处（PC / 云端跑一次）整理好的「活线表」搬到手机上经常播不出——
///   用户看到的就是「表里全是台，点开全在缓冲」。所以：**谁播谁知道**，
///   候选线路一律在**本机**真出流体检过，才允许上屏。
///
/// 判活三级（与 PC 端同一口径，缺一不可）：
///   ① 拉到播放列表（m3u8 200 且含 `#EXTM3U`）
///   ② 不是 `#EXT-X-ENDLIST`（有它 = 点播冒充直播 / 循环垫片）
///   ③ **首分片真拿到字节**（只回列表不给片 = 死链）
///   顺带量「列表耗时 + 首片耗时」，快的排前面 → 秒播。
public actor LiveCollector {
    public static let shared = LiveCollector()

    public struct Result: Codable, Sendable {
        public var ok: Bool
        public var listMs: Int      // 播放列表耗时
        public var segMs: Int       // 首分片耗时
        public var at: Date         // 体检时间
        public var score: Int { ok ? max(1, 1000 - min(listMs + segMs, 900)) : 0 }
    }

    private var results: [String: Result] = [:]
    private var loaded = false
    private let store: URL
    private let queue = DispatchQueue(label: "live.collector")

    private init() {
        let fm = FileManager.default
        let dir = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                   ?? fm.temporaryDirectory).appendingPathComponent("LiveProbe", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        store = dir.appendingPathComponent("probe.json")
    }

    // MARK: - 持久化

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let d = try? Data(contentsOf: store),
              let o = try? JSONDecoder().decode([String: Result].self, from: d) else { return }
        results = o
    }

    private func save() {
        if let d = try? JSONEncoder().encode(results) { try? d.write(to: store, options: .atomic) }
    }

    public func result(for url: URL) -> Result? { results[url.absoluteString] }

    /// 该 URL 是否在有效期内体检通过（默认 6 小时新鲜度；越新越可信）。
    public func isAlive(_ url: URL, maxAge: TimeInterval = 6 * 3600) -> Bool {
        guard let r = results[url.absoluteString], r.ok else { return false }
        return Date().timeIntervalSince(r.at) <= maxAge
    }

    public func checkedCount() -> Int { results.count }
    public func aliveCount() -> Int { results.values.filter { $0.ok }.count }

    /// 未体检 / 体检过期的 URL（拿去排队体检）。
    public func needProbe(_ urls: [URL], maxAge: TimeInterval = 6 * 3600) -> [URL] {
        urls.filter { u in
            guard let r = results[u.absoluteString] else { return true }
            return Date().timeIntervalSince(r.at) > maxAge
        }
    }

    // MARK: - 体检（并发）

    private static let ua = "AppleCoreMedia/1.0.0.21A360 (iPhone; U; CPU OS 17_0 like Mac OS X)"

    private func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 9
        c.httpMaximumConnectionsPerHost = 4
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }

    /// 单条线路体检：三级判活 + 计时。
    private func probeOne(_ url: URL, session: URLSession) async -> Result {
        let t0 = Date()
        var req = URLRequest(url: url)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200, let text = String(data: data, encoding: .utf8),
                  text.contains("#EXTM3U") else {
                return Result(ok: false, listMs: 0, segMs: 0, at: Date())
            }
            let listMs = Int(Date().timeIntervalSince(t0) * 1000)
            guard !text.contains("#EXT-X-ENDLIST") else {          // ② 点播冒充直播
                return Result(ok: false, listMs: listMs, segMs: 0, at: Date())
            }
            let segs = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            guard let first = segs.first,                                    // ③ 必须真有分片
                  let segURL = URL(string: first, relativeTo: url)?.absoluteURL else {
                return Result(ok: false, listMs: listMs, segMs: 0, at: Date())
            }
            let ts0 = Date()
            var sreq = URLRequest(url: segURL)
            sreq.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            sreq.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
            let (sdata, sresp) = try await session.data(for: sreq)
            let scode = (sresp as? HTTPURLResponse)?.statusCode ?? -1
            let segMs = Int(Date().timeIntervalSince(ts0) * 1000)
            let ok = (scode == 200 || scode == 206) && !sdata.isEmpty
            return Result(ok: ok, listMs: listMs, segMs: segMs, at: Date())
        } catch {
            return Result(ok: false, listMs: 0, segMs: 0, at: Date())
        }
    }

    /// 批量体检（并发上限 20；每完成一条即回调进度，便于 UI 实时显示）。
    @discardableResult
    public func probe(_ urls: [URL],
                      progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [String: Result] {
        loadIfNeeded()
        var seen = Set<String>()
        let list = urls.filter { seen.insert($0.absoluteString).inserted }   // 去重（同一 URL 别体检两遍）
        guard !list.isEmpty else { return results }
        let s = session()
        var done = 0
        await withTaskGroup(of: (String, Result).self) { grp in
            var it = list.makeIterator()
            let width = min(20, list.count)
            for _ in 0..<width {
                guard let u = it.next() else { break }
                grp.addTask { [weak self] in
                    let r = await self?.probeOne(u, session: s) ?? Result(ok: false, listMs: 0, segMs: 0, at: Date())
                    return (u.absoluteString, r)
                }
            }
            for await (k, r) in grp {
                results[k] = r
                done += 1
                progress?(done, list.count)
                if let u = it.next() {
                    grp.addTask { [weak self] in
                        let rr = await self?.probeOne(u, session: s) ?? Result(ok: false, listMs: 0, segMs: 0, at: Date())
                        return (u.absoluteString, rr)
                    }
                }
            }
        }
        save()
        return results
    }
}
