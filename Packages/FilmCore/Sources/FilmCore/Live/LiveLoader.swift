import Foundation
import os

private let liveLog = Logger(subsystem: "filmthree", category: "live")

/// M3U 直播列表解析（星幕 normal.m3u / 夜航 adult.m3u；心屋无直播）。
/// 只做协议翻译：extinf 名称 + 频道 URL。心屋侧调用方根本不会拉取。
public struct LiveChannel: Identifiable, Hashable {
    public let id: String       // url 的稳定哈希
    public let name: String
    public let url: URL
    public let group: String    // group-title 分组（央视/卫视/地方频道…），抽屉换台按此分组

    public init(id: String, name: String, url: URL, group: String = "") {
        self.id = id
        self.name = name
        self.url = url
        self.group = group
    }
}

public enum M3UParser {
    /// 统一解析：M3U（#EXTINF）与 TVBox txt（"组名,#genre#" / "频道名,url1#url2"）双格式自动识别。
    /// txt 多 URL 用 # 分隔：首个为主线路，后续生成「频道名·备N」（与自动换源归一规则配套）。
    public static func parse(_ text: String) -> [LiveChannel] {
        var out: [LiveChannel] = []
        var pendingName: String?
        var pendingGroup = ""
        var txtGroup = ""   // TVBox txt 当前分组（组名,#genre# 之后生效）
        var seen = Set<String>()
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            // TVBox txt：组名,#genre# —— 切换当前分组
            if line.hasSuffix("#genre#") {
                let g = line.split(separator: ",", maxSplits: 1).first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !g.isEmpty { txtGroup = g }
                pendingName = nil
                continue
            }
            if line.hasPrefix("#EXTINF") {
                pendingName = line.split(separator: ",", maxSplits: 1).last.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? "未命名频道"
                pendingGroup = extractGroupTitle(line)
            } else if !line.hasPrefix("#") {
                // TVBox txt 频道行：名称,url1#url2（URL 段必须含 "://"，防止误吞普通 M3U URL 行）
                if let urls = txtChannelURLs(line) {
                    let name = line.split(separator: ",", maxSplits: 1).first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    appendTXTChannel(name, urls, group: txtGroup, to: &out, seen: &seen)
                } else if let url = URL(string: line), url.scheme != nil {
                    if seen.insert(line).inserted {
                        out.append(LiveChannel(id: line,
                                               name: pendingName ?? url.host ?? "频道",
                                               url: url,
                                               group: pendingGroup))
                    }
                    pendingName = nil
                    pendingGroup = ""
                }
            }
        }
        return out
    }

    /// TVBox txt 频道行的 URL 段提取：首个逗号之后按 # 拆分，全部（至少一个）须含 "://"。
    private static func txtChannelURLs(_ line: String) -> [String]? {
        guard line.contains(",") else { return nil }
        let after = line.split(separator: ",", maxSplits: 1).last.map(String.init) ?? ""
        let candidates = after.split(separator: "#")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty, candidates.allSatisfy({ $0.contains("://") }) else { return nil }
        return candidates
    }

    /// txt 频道入库：主线路用原名，备用线路生成「名·备N」供播放器自动换源。
    private static func appendTXTChannel(_ name: String, _ urls: [String], group: String,
                                         to out: inout [LiveChannel], seen: inout Set<String>) {
        let base = name.isEmpty ? "未命名频道" : name
        for (i, u) in urls.enumerated() where seen.insert(u).inserted {
            guard let url = URL(string: u) else { continue }
            let cname = i == 0 ? base : "\(base)·备\(i)"
            out.append(LiveChannel(id: u, name: cname, url: url, group: group))
        }
    }

    /// 抓取 group-title="xxx"（用户自定义 M3U 与 live_engine 产物均带此属性）。
    private static func extractGroupTitle(_ extinf: String) -> String {
        guard let range = extinf.range(of: "group-title=\"") else { return "" }
        let tail = extinf[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return "" }
        return String(tail[..<end])
    }
}

/// 直播列表加载器（复用 feed 基址链；失败返回空列表由 UI 展示错误/重试）。
public actor LiveLoader {
    private let bases: FeedBases
    private let session: URLSession

    public init(bases: FeedBases) {
        self.bases = bases
        let cfg = URLSessionConfiguration.default
        // ③直播慢修复 2026-09-22：失败基址 8s 快速失败切下一个。
        // 原 15s × 多基址串行兜底 = 用户口中「慢到过年」的主因之一。
        // 60包（2026-09-23 用户：「直播依然需要等很久一直在缓存」）：8s → 5s。
        // 竞速后最坏等待 = 单个基址超时，必须短；5s 足够拉到 166KB 表（本机实测 2.9s）。
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 10
        session = URLSession(configuration: cfg)
    }

    // MARK: - 磁盘缓存（③直播慢修复 2026-09-22）
    // 上次成功抓到的明文列表落 Application Support/LiveCache：
    // 启动秒开（先出缓存再后台刷新）+ 断网兜底（不降级测试源）。
    // 夜航缓存为明文，与 bundle 内 adult_live.m3u 快照同级（本地文件系统，非传输层），可接受。

    private static var cacheDir: URL? {
        let fm = FileManager.default
        guard let sup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = sup.appendingPathComponent("LiveCache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFile(for path: String) -> URL? {
        let key = path.replacingOccurrences(of: "/", with: "_")
        return cacheDir?.appendingPathComponent("live\(key).txt")
    }

    /// 读缓存：上次成功拉取并解析过的频道（秒开用；无缓存/解析为空返回 nil）。
    public func cachedChannels(path: String) -> [LiveChannel]? {
        guard let f = Self.cacheFile(for: path),
              let text = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        let chs = M3UParser.parse(text)
        return chs.isEmpty ? nil : chs
    }

    private func storeCache(_ text: String, path: String) {
        guard let f = Self.cacheFile(for: path) else { return }
        try? text.write(to: f, atomically: true, encoding: .utf8)
    }

    /// GitHub 域请求在持有 token 时一律带上：匿名 api.github.com 限额仅 60 次/时/IP，
    /// 蜂窝/共享出口极易烧光 → 403 静默失败 → 落 16 个死保底。带 token 提至 5000/h。
    private func request(for url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if let tok = bases.authToken, !tok.isEmpty,
           url.host?.contains("github.com") == true {
            req.setValue("token \(tok)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// 拉一张直播表（路径 → FeedBases 多基址）。
    ///
    /// 60包（2026-09-23 用户：「直播依然需要等很久一直在缓存」）——本函数是那次投诉的**真根因**：
    /// 原实现是**串行 for**：jsDelivr(5s 超时) → raw.githubusercontent(5s) → LAN(5s)，
    /// 手机上第一个基址不通就是白等 5 秒，前两个都不通 = 10~15 秒，用户看到的就是「一直在缓存」。
    /// 现在改为 **多基址并行竞速：谁先成功用谁**，最坏等待 = 单个基址超时（5s）。
    public func load(path: String) async -> [LiveChannel] {
        let reqs = bases.url(for: path).map { ($0, request(for: $0)) }
        let race: (String, [LiveChannel])? = await withTaskGroup(of: (String, [LiveChannel])?.self) { grp in
            for (url, req) in reqs {
                grp.addTask { [session] in
                    let t0 = Date()
                    do {
                        liveLog.info("live try: \(url.absoluteString, privacy: .public)")
                        let (d, resp) = try await session.data(for: req)
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                        let ms = Int(Date().timeIntervalSince(t0) * 1000)
                        liveLog.info("live got: code=\(code, privacy: .public) \(d.count)B \(ms)ms \(url.absoluteString, privacy: .public)")
                        guard code == 200 else { return nil }
                        let raw = FeedBases.unwrapContents(d)
                        // FCVB1 密文直播源（发布层全仓加密）：解密后解析；解不开按失败换下一 base
                        let text: String?
                        if let pt = FCVault.decryptIfEncrypted(raw) {
                            text = String(data: pt, encoding: .utf8)
                        } else if raw.starts(with: FCVault.magic) {
                            liveLog.error("live FCVB1-undecryptable: \(url.absoluteString, privacy: .public)")
                            text = nil
                        } else {
                            text = String(data: raw, encoding: .utf8)
                        }
                        guard let text else { return nil }
                        let chs = M3UParser.parse(text)
                        liveLog.info("live parsed: \(chs.count) channels")
                        return chs.isEmpty ? nil : (text, chs)
                    } catch {
                        let ms = Int(Date().timeIntervalSince(t0) * 1000)
                        liveLog.error("live ERR: \(error.localizedDescription, privacy: .public) \(ms)ms \(url.absoluteString, privacy: .public)")
                        return nil
                    }
                }
            }
            var first: (String, [LiveChannel])?
            for await r in grp {
                if first == nil, let r { first = r }
                if first != nil { break }   // 竞速：第一个成功即收工，其余取消
            }
            grp.cancelAll()
            return first
        }
        guard let (text, chs) = race else {
            liveLog.error("live load: ALL bases failed for \(path, privacy: .public)")
            return []
        }
        storeCache(text, path: path)   // ③修复：成功列表落盘，下次启动秒开
        return chs
    }
}

/// 内置保底频道（随包离线可用，不依赖任何远端文件）。
/// 用户此前反馈"直播没有内置直播源"：原实现只拉 feed 仓库 M3U（仓库无此文件，恒为空）。
/// 频道源为公开测试 HLS（北邮 iptv 镜像），可搭配「设置 → TVBox 配置订阅」的自有源使用。
public enum LiveDefaults {

    public static let embedded: [LiveChannel] = [
        ch("CCTV-1 综合", "cctv1hd"),
        ch("CCTV-2 财经", "cctv2hd"),
        ch("CCTV-3 综艺", "cctv3hd"),
        ch("CCTV-4 中文国际", "cctv4hd"),
        ch("CCTV-5 体育", "cctv5hd"),
        ch("CCTV-5+ 体育赛事", "cctv5phd"),
        ch("CCTV-6 电影", "cctv6hd"),
        ch("CCTV-13 新闻", "cctv13hd"),
        ch("湖南卫视", "hunanhd"),
        ch("浙江卫视", "zjhd"),
        ch("江苏卫视", "jshd"),
        ch("东方卫视", "dongfanghd"),
        ch("广东卫视", "gdhd"),
        ch("深圳卫视", "szhd"),
        ch("北京卫视", "btvhd"),
        ch("天津卫视", "tjhd"),
    ]

    /// 夜航离线兜底（2026-09-21 28号包）：夜航直播只依赖私有仓 adult.m3u 一个源，
    /// 手机上 api.github.com 间歇不通就 0 频道。快照随包（构建时从仓拉取），远端断了照样播。
    public static let yehangEmbedded: [LiveChannel] = {
        guard let u = Bundle.module.url(forResource: "adult_live", withExtension: "m3u", subdirectory: "Resources")
                  ?? Bundle.module.url(forResource: "adult_live", withExtension: "m3u"),
              let text = try? String(contentsOf: u, encoding: .utf8) else { return [] }
        return M3UParser.parse(text)
    }()

    /// 星幕包内真直播快照（60包 2026-09-23）。
    /// 来源：`F:\IOS3APP\ios_ctrl\live_build_xingmu.py` 体检重建（剔除循环垫片流 / 点播冒充直播 / 死链）。
    /// 为什么必须有：星幕此前只依赖远端 /v1/live/normal.m3u，**手机上拿不到就落 LiveDefaults.embedded
    /// （北邮测试源 ivi.bupt.edu.cn）**——用户实测「浙江卫视一个镜头循环 N 次」，看的其实是垫片测试流。
    /// 这份快照随包 = 零网络即可播真台；远端刷新照旧（拿到更全的表会整体替换，正在播的台已 pinned 不受影响）。
    public static let xingmuEmbedded: [LiveChannel] = {
        guard let u = Bundle.module.url(forResource: "normal_live", withExtension: "m3u", subdirectory: "Resources")
                  ?? Bundle.module.url(forResource: "normal_live", withExtension: "m3u"),
              let text = try? String(contentsOf: u, encoding: .utf8) else { return [] }
        return M3UParser.parse(text)
    }()

    /// 离线兜底按产品分流：星幕 = 包内真直播快照；夜航 = adult_live.m3u；心屋 = 空。
    /// **不再自动回落到 embedded（北邮测试源）**：那批源在播循环测试画面，会让人误以为在看真台。
    /// embedded 仅在「先看离线备用频道」这个显式入口保留。
    public static func embeddedChannels(forMode mode: String) -> [LiveChannel] {
        switch mode {
        case "adult": return yehangEmbedded
        case "child": return []
        default: return xingmuEmbedded
        }
    }

    private static func ch(_ name: String, _ key: String) -> LiveChannel {
        LiveChannel(id: "builtin." + key,
                    name: name,
                    url: URL(string: "http://ivi.bupt.edu.cn/hls/\(key).m3u8")!)
    }
}
