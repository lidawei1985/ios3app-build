import Foundation
import os

private let liveLog = Logger(subsystem: "filmthree", category: "live")

/// M3U 直播列表解析（星幕 xingmu.m3u；心屋无直播）。
/// 只做协议翻译：extinf 名称 + 频道 URL。心屋侧调用方根本不会拉取。
public struct LiveChannel: Identifiable, Hashable {
    public let id: String       // 行唯一键（名+URL；同台多线路各自独立，同 URL 不同台不再互吞）
    public let name: String
    public let url: URL
    public let group: String    // group-title 分组（央视/卫视/地方频道…），抽屉换台按此分组
    public let logo: URL?       // tvg-logo 台标（云端表 619/619 条均带；原实现直接丢弃 → 全端无台标）
    public let chno: Int?       // tvg-chno 固定频道号（roster 恒定，供稳定排序/对位）

    public init(id: String, name: String, url: URL, group: String = "",
                logo: URL? = nil, chno: Int? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.group = group
        self.logo = logo
        self.chno = chno
    }
}

public enum M3UParser {
    /// 统一解析：M3U（#EXTINF）与 TVBox txt（"组名,#genre#" / "频道名,url1#url2"）双格式自动识别。
    /// txt 多 URL 用 # 分隔：首个为主线路，后续生成「频道名·备N」（与自动换源归一规则配套）。
    public static func parse(_ text: String) -> [LiveChannel] {
        var out: [LiveChannel] = []
        var pendingName: String?
        var pendingGroup = ""
        var pendingLogo: URL?
        var pendingChno: Int?
        var txtGroup = ""   // TVBox txt 当前分组（组名,#genre# 之后生效）
        var seen = Set<String>()
        // v75：行尾归一化（★本次「远端保鲜从未成功」的真根因）。
        // Swift 里 "\r\n" 是**单个字素簇**（UAX#29 GB3：CR×LF 不拆开），CRLF 文本中
        // 根本不存在独立 "\n" 字符 → split(separator: "\n") 把整个 1469 行文件当**一行**返回
        // → 该行以 #EXTM3U 开头、hasPrefix("#") 为真被整体跳过 → 恒 0 条。
        // 铁证（v74 黑匣子 01:59）：三基址 200+解密成功、明文 141996B 头 #EXTM3U、解析 0 条；
        // 同一解析器吃包内 **LF** 快照却 734 条正常；PC Python 复刻（split('\n') 按标量切）
        // 同一份明文得 688 条。trimmingCharacters 写得再对也轮不到它出手——split 压根没切。
        // 归一化后 LF/CRLF/裸 CR 三种行尾通吃。
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n") {
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
                pendingGroup = extractAttr(line, "group-title") ?? ""
                // 台标 / 固定频道号：与 TV 端共用同一张表，属性一直都在，只是 iOS 侧原先没解析。
                pendingLogo = extractAttr(line, "tvg-logo").flatMap { URL(string: $0) }
                pendingChno = extractAttr(line, "tvg-chno").flatMap { Int($0) }
            } else if !line.hasPrefix("#") {
                // TVBox txt 频道行：名称,url1#url2（URL 段必须含 "://"，防止误吞普通 M3U URL 行）
                if let urls = txtChannelURLs(line) {
                    let name = line.split(separator: ",", maxSplits: 1).first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    appendTXTChannel(name, urls, group: txtGroup, to: &out, seen: &seen)
                } else if let url = flexibleURL(line) {
                    let nm = pendingName ?? url.host ?? "频道"
                    // 去重键 = 名 + URL（不是只按 URL）：云端表实测 24 条「同一路流被两个台名引用」
                    // （涉及 20 个台：亳州农村频道/绍兴公共频道/萧山综合…），只按 URL 去重会把整台吞掉；
                    // 同一张表的多个镜像因 (名,URL) 全同，仍会被正确合并。
                    let dedupKey = nm + "\u{1}" + line
                    if seen.insert(dedupKey).inserted {
                        out.append(LiveChannel(id: dedupKey,
                                               name: nm,
                                               url: url,
                                               group: pendingGroup,
                                               logo: pendingLogo,
                                               chno: pendingChno))
                    }
                    pendingName = nil
                    pendingGroup = ""
                    pendingLogo = nil
                    pendingChno = nil
                }
            }
        }
        return out
    }

    /// v75：URL 宽容解析。云端表有 ~45 条 URL 带中文 query（如 …/live.php?id=东南卫视），
    /// iOS 17+ 严格版 URL(string:) 对非 ASCII/空格直接返回 nil → 这些台静默丢失。
    /// 先按原样试；失败再把非法字符百分号编码重试（% 保留原样防二次编码破坏已编码段）。
    private static func flexibleURL(_ s: String) -> URL? {
        if let u = URL(string: s), u.scheme != nil { return u }
        let allowed = CharacterSet(charactersIn:
            "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._~:/?#[]@!$&'()*+,;=%")
        guard let enc = s.addingPercentEncoding(withAllowedCharacters: allowed),
              let u = URL(string: enc), u.scheme != nil else { return nil }
        return u
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
            guard let url = flexibleURL(u) else { continue }
            let cname = i == 0 ? base : "\(base)·备\(i)"
            out.append(LiveChannel(id: u, name: cname, url: url, group: group))
        }
    }

    /// 抓取任意 `key="xxx"` 属性（group-title / tvg-logo / tvg-chno …；
    /// 用户自定义 M3U 与 live 云端产物均带这些属性）。
    private static func extractAttr(_ extinf: String, _ key: String) -> String? {
        guard let range = extinf.range(of: "\(key)=\"") else { return nil }
        let tail = extinf[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
    }
}

/// 台标工具：把 tvg-logo 的 URL 映射成「包内台标文件名键」。
/// 约定：云端表台标形如 `…/filmcollector-logos@main/0001.png`（0001 = roster chno 四位补零）；
/// 端侧包内同放 `0001.png`（随包，离线/取网失败也能显），故键 = 文件名主干。
public enum LiveLogos {
    public static func key(for logo: URL?) -> String? {
        guard let logo else { return nil }
        let fn = logo.lastPathComponent          // 0001.png
        guard fn.hasSuffix(".png") else { return nil }
        let stem = String(fn.dropLast(4))        // 0001
        return (!stem.isEmpty && stem.allSatisfy { $0.isNumber }) ? stem : nil
    }
}

/// 直播列表加载器（复用 feed 基址链；失败返回空列表由 UI 展示错误/重试）。
public actor LiveLoader {
    private let bases: FeedBases
    private let session: URLSession

    public init(bases: FeedBases) {
        self.bases = bases
        let cfg = URLSessionConfiguration.default
        // v74：URLCache 会把坏响应（401/旧密文）落盘缓存，App 重启仍在 → 每次
        // 静默失败一模一样（真机 01:49 全灭且零逐基址日志）。直播表要的是新鲜，
        // 内存缓存足矣，磁盘缓存一律绕开。
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // ③直播慢修复 2026-09-22：失败基址 8s 快速失败切下一个。
        // 原 15s × 多基址串行兜底 = 用户口中「慢到过年」的主因之一。
        // 60包（2026-09-23 用户：「直播依然需要等很久一直在缓存」）：8s → 5s。
        //
        // v71（2026-10-05 主人「解决啊」）5s → 20s，对齐 FeedClient（20s/120s）。
        // 铁证：同一时刻同一手机——点播 catalog 同步成功落盘（saved_at 00:58），
        // 直播表却从未成功（LiveCache 目录始终不存在）。唯一差异就是超时：
        // 5s 是 PC 本机实测（2.9s 拉完），手机到 api.github.com 的 TLS+响应经常 >5s 被掐，
        // 三基址竞速全灭。本刷新是**后台任务**（refreshFromRemote），超时放宽不阻塞进页起播。
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        session = URLSession(configuration: cfg)
    }

    // MARK: - 磁盘缓存（③直播慢修复 2026-09-22）
    // 上次成功抓到的明文列表落 Application Support/LiveCache：
    // 启动秒开（先出缓存再后台刷新）+ 断网兜底（不降级测试源）。
    // 列表缓存为明文（本地文件系统，非传输层），可接受。

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
                        guard code == 200 else {
                            // v72：os.Logger 在 LC guest 里抓不到（1.29M 行零 filmthree），
                            // 保鲜拉排死因必须走黑匣子，否则永远只能靠猜。
                            LiveDiag.write("保鲜·\(url.host ?? "?") HTTP \(code) \(ms)ms")
                            return nil
                        }
                        let raw = FeedBases.unwrapContents(d)
                        // FCVB1 密文直播源（发布层全仓加密）：解密后解析；解不开按失败换下一 base
                        let text: String?
                        if let pt = FCVault.decryptIfEncrypted(raw) {
                            text = String(data: pt, encoding: .utf8)
                        } else if raw.starts(with: FCVault.magic) {
                            liveLog.error("live FCVB1-undecryptable: \(url.absoluteString, privacy: .public)")
                            LiveDiag.write("保鲜·\(url.host ?? "?") FCVB1解不开 \(d.count)B")
                            text = nil
                        } else {
                            text = String(data: raw, encoding: .utf8)
                        }
                        guard let text else {
                            LiveDiag.write("保鲜·\(url.host ?? "?") utf8失败 \(d.count)B raw头=\(String(raw.prefix(4).map { String(format: "%02x", $0) }.joined()))")
                            return nil
                        }
                        let chs = M3UParser.parse(text)
                        if chs.isEmpty {
                            LiveDiag.write("保鲜·\(url.host ?? "?") 解析0条 \(d.count)B 头=\(text.prefix(40))")
                        }
                        liveLog.info("live parsed: \(chs.count) channels")
                        return chs.isEmpty ? nil : (text, chs)
                    } catch {
                        let ms = Int(Date().timeIntervalSince(t0) * 1000)
                        liveLog.error("live ERR: \(error.localizedDescription, privacy: .public) \(ms)ms \(url.absoluteString, privacy: .public)")
                        LiveDiag.write("保鲜·\(url.host ?? "?") ERR \(error.localizedDescription) \(ms)ms")
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
            if first == nil {
                LiveDiag.write("远端保鲜全灭 path=\(path)（三基址无一成功，见上方逐基址死因）")
            }
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

    /// 离线兜底按产品分流：星幕 = 包内真直播快照；心屋 = 空。
    /// **不再自动回落到 embedded（北邮测试源）**：那批源在播循环测试画面，会让人误以为在看真台。
    /// embedded 仅在「先看离线备用频道」这个显式入口保留。
    public static func embeddedChannels(forMode mode: String) -> [LiveChannel] {
        switch mode {
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
