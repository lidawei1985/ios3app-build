import Foundation

// MARK: - TVBox 点播源客户端（原版 TVBox 思路：sites 驱动点播浏览）
// CMS JSON 协议（type 0/1 通用 ac= 端点）：
//   {api}?ac=list                 → 分类 + 第一页
//   {api}?ac=detail&t=<id>&pg=<n> → 分类分页（含 vod_play_url）
//   {api}?ac=detail&ids=<id>      → 详情
//   {api}?ac=detail&wd=<关键词>   → 搜索
// 解析结果统一映射为 FeedItem，复用现有详情页/播放器/搜索 UI。
// 注意：FilmJSON.decoder 带 convertFromSnakeCase，结构体属性必须驼峰。

/// CMS 端 type_id / vod_id 混用 int/string，柔性解码。
public struct FlexibleID: Codable, Hashable {
    public let value: String
    public init?(_ raw: Any?) {
        if let s = raw as? String { value = s } else if let i = raw as? Int { value = String(i) } else { return nil }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // 容错优先（35包加固）：原实现对未知类型直接 throw → 整个响应解码失败 →
        // 整个点播源列表变空（用户看到「这个源没东西」）。改为落空串，
        // 由上层 map() 的 `!vodId.isEmpty` 守卫把这**一个条目**丢掉，而不是丢整页。
        if let i = try? c.decode(Int.self) { value = String(i) }
        else if let s = try? c.decode(String.self) { value = s }
        else if let d = try? c.decode(Double.self) { value = String(Int(d)) }
        else { value = "" }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let i = Int(value) { try c.encode(i) } else { try c.encode(value) }
    }
}

public struct SiteCategory: Codable, Hashable, Identifiable {
    public let id: String        // type_id
    public let name: String      // type_name
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum TVBoxPlayParser {
    /// vod_play_url: 线路间 "$$$"（MacCMS 标准，实测量子/天涯/非凡等均如此），集间 "#"，名$链接；
    /// 本工程内部合成（XML dd 块）用 "###" 作线路分隔 —— **两种都要认**。
    /// 52包修（用户：「电视剧播放时不能选集得退出去选」「电视剧下一集按钮怎么没有」）：
    /// 此前只按 "###" 分块 → 真实源的 "$$$" 不被识别 → 第二条线路整体并进第一块，
    /// 两套集数连成一串（集名从"第01集"重复到"第40集"再重来），选集分组/线路标签全乱、
    /// 换源失效。实测「量子资源」一部 40 集剧 = 2 线路 × 40 集，旧解析只剩 1 组。
    /// vod_play_from: 线路名，同样支持 "$$$" / "###"。
    public static func parse(playURL: String, playFrom: String?) -> (defaultURL: String?, lines: [FeedPlay.Line]) {
        let normalized = playURL.replacingOccurrences(of: "$$$", with: "###")
        let lineBlocks = normalized.components(separatedBy: "###").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let fromNames = (playFrom ?? "").replacingOccurrences(of: "$$$", with: "###")
            .components(separatedBy: "###").map { $0.trimmingCharacters(in: .whitespaces) }
        var urls: [String] = []
        var lines: [FeedPlay.Line] = []
        for (idx, block) in lineBlocks.enumerated() {
            let lineName = idx < fromNames.count && !fromNames[idx].isEmpty ? fromNames[idx] : "线路\(idx + 1)"
            for ep in block.components(separatedBy: "#") {
                let parts = ep.components(separatedBy: "$")
                guard parts.count >= 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let url = parts[1].trimmingCharacters(in: .whitespaces)
                guard url.hasPrefix("http") else { continue }
                if !urls.contains(url) { urls.append(url) }
                lines.append(FeedPlay.Line(name: name.isEmpty ? nil : name, url: url, quality: lineName))
            }
        }
        // 直链优先（2026-09-21 金鹰实测：第一条线路常是网页播放页 /play/<id>（HTML），
        // 播放器拿到必失败 → 按 m3u8 > mp4 等媒体后缀 > 其他 排序，defaultURL 取排头）。
        if lines.count > 1 {
            lines.sort { Self.mediaRank($0.url) < Self.mediaRank($1.url) }
        }
        urls = lines.map(\.url)
        return (urls.first, lines)
    }

    /// 媒体直链等级：m3u8=0，mp4/mkv/flv 等后缀=1，其余（网页播放页等）=2。
    static func mediaRank(_ url: String) -> Int {
        let lower = url.lowercased()
        if lower.contains(".m3u8") { return 0 }
        for ext in [".mp4", ".mkv", ".flv", ".ts", ".avi", ".webm", ".mov"] where lower.contains(ext) { return 1 }
        // 无后缀但路径带 hls/ 或以 index.m3u8 变体结尾的兜底交给 m3u8 规则；其余视为网页
        return 2
    }
}

public actor TVBoxSiteClient {

    public let site: TVBoxSite
    private let session: URLSession
    /// 搜索专用短会话（见 init 注释：78 源实测，慢源能把整批拖死 → 搜索必须短超时）
    private let searchSession: URLSession
    /// ★ 2026-10-17：已证实**只有 https 能通**的 host（明文连接被拒）。
    /// 持久化到 UserDefaults —— 实例内的 Set 靠不住（日志里同一 host 被"记住"三次仍每次重撞），
    /// 而 UserDefaults 跨实例、跨进页面、跨冷启动都有效。
    private static let httpsOnlyKey = "TVBoxHTTPSOnlyHosts"

    private var httpsOnlyHosts: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.httpsOnlyKey) ?? [])
    }

    private func markHTTPSOnly(_ host: String) {
        guard !host.isEmpty else { return }
        var a = UserDefaults.standard.stringArray(forKey: Self.httpsOnlyKey) ?? []
        guard !a.contains(host) else { return }
        a.append(host)
        UserDefaults.standard.set(a, forKey: Self.httpsOnlyKey)
    }

    public init(site: TVBoxSite) {
        self.site = site
        let cfg = URLSessionConfiguration.default
        // 52包：放宽到 30s/60s，是为了不让几个慢源被误杀。
        // ★ 2026-10-17 主人报「换源后一直转圈出不来」实测改口：
        //   同一批源站 **HTTP 明文 4.3s 就回、HTTPS 并发握手 25s 直接超时**
        //   （_probe_sites.py 十路并发对照，见台账）。30s 的超时在这里不是"耐心"，
        //   而是**把一次握手失败拖成半分钟白屏**。收到 15s/25s：够慢源回，又不至于长转。
        // ★ 2026-10-17：HTTPS 握手被掐时是**直接卡住**（实测 25s 才报 timeout），
        //   所以这里的超时值 = 用户白等多久。正常源 1~4s 就回，6s 足够；
        //   超时后立刻降级 http（4s 回），首屏最坏 ≈ 10s，且第二个请求起命中 host 记忆直接 4s。
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 20
        // 同 host 连接池 6 条：与 enrichPosters 的并发上限对齐（并发握手正是被源站掐的那个点）
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg)
        // 2026-10-02「搜索好慢」实测 78 源同一关键词：中位 2.1s，但**最慢 38.6s**，
        // 且 6 个源超过 22s。搜索是**交互操作**，等 30s 的源毫无意义——
        // 搜的关键词在任何源都能搜到，慢源的结果对用户没有增量价值，只会拖住整屏。
        // 故搜索单独走 8s/12s 的短会话；分类/详情仍用上面的长会话（那里慢一点可以忍）。
        let s = URLSessionConfiguration.default
        s.timeoutIntervalForRequest = 8
        s.timeoutIntervalForResource = 12
        searchSession = URLSession(configuration: s)
    }

    // MARK: - 客户端复用（2026-10-03「搜索加速 / 内置源加载加速」根修）

    /// 进程内按 `site.key` 复用客户端。**别再 new 了，走这里。**
    ///
    /// 为什么这是「搜索慢 / 进源慢」里肉眼可见的那一截（实机口径）：
    ///  ① 每个 `TVBoxSiteClient` 的 `init` 会新建**两个** `URLSession`（长会话 + 搜索短会话）；
    ///  ② 搜索是**每个源一个客户端**：60~78 源 → 每次搜索新建 120~156 个 URLSession；
    ///     `SiteBrowseView` / `TVSeriesView` 更狠，把客户端写成**计算属性**
    ///     `{ TVBoxSiteClient(site: site) }` —— 每读一次就再建两个，一次页面加载能建十几个；
    ///  ③ URLSession 一丢，它内部的 **HTTP keep-alive 连接池随之作废** → 每次搜索/翻页都要
    ///     重做 DNS + TCP + TLS 握手。慢的从来不只是源站，还有这一整套"重新认识服务器"。
    ///
    /// 复用后：同一源跨搜索、跨翻页、跨进详情页都共用同一条连接池 → 第二次开始明显更快。
    ///
    /// 不变式（为什么复用不会串数据）：客户端里唯一的可变业务状态是 `picCache`（海报补图缓存），
    /// 复用恰好是我们想要的（少拉一次图）；其余全是只读的 `site` 与会话。
    ///
    /// 池子放在**文件作用域** 的 `private enum` 里（而不是 actor 内部）：
    /// 与 `SpiderDrpyHost` / `LiveDiag` 同款写法，避开「actor 的静态存储属性」在不同
    /// Swift 版本下的语义歧义——本仓 `swift-tools-version: 5.9`，不赌编译器。
    public static func shared(for site: TVBoxSite) -> TVBoxSiteClient {
        TVBoxClientPool.shared(for: site)
    }

    private func api(_ query: [String: String], via sess: URLSession? = nil) async -> Data? {
        // ★ 2026-10-17（主人「看下日志源加载超级慢」）——
        //   此前请求层**一个耗时都不落盘**：日志里全是「取图」，源请求记录被 600 行环形缓冲整个刷掉，
        //   于是「慢」只能靠猜。现在每条请求都记：源名 / ac / pg / 实际毫秒 / 成败 / 走的 http 还是 https。
        let t0 = Date()
        var hit = false
        var usedScheme = "-"
        var lastErr = ""
        defer {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            LiveDiag.writeSite("源·请求 \(site.name) ac=\(query["ac"] ?? "-") pg=\(query["pg"] ?? "-") 用时=\(ms)ms 结果=\(hit ? "ok" : "失败") \(usedScheme)\(lastErr)")
        }
        guard var comps = URLComponents(string: site.api), comps.scheme != nil else {
            lastErr = " api非法"
            return nil
        }
        var items = comps.queryItems ?? []
        for (k, v) in query { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        let s = sess ?? session
        let host = comps.host ?? ""
        let isHTTPS = (comps.scheme ?? "").lowercased() == "https"
        usedScheme = comps.scheme ?? "-"
        guard let origin = comps.url else { lastErr = " url非法"; return nil }

        // ★★ 2026-10-17（主人：「10秒出内容以前几秒就出来了 现在40秒都有！你自己看日志吧」）
        //
        // 实盘日志（livediag.txt）三次连打，**同一个 host 记住三次**：
        //   18:38:41 源请求降级 http 并记住 host=suoniapi.com
        //   18:38:59 源请求降级 http 并记住 host=suoniapi.com
        //   18:39:06 源请求降级 http 并记住 host=suoniapi.com
        // 结论：① 「记住」没有跨请求生效（实例内 Set 靠不住）；② 每条请求都先白等一次握手超时。
        // 进一个分类页要发 2~4 条请求（分类 / 第一页 / 详情 / 补图），一条 6s+4s = 10s，
        // 串起来正好 30~40s —— 与用户体感完全对得上。
        //
        // 处置：不再"HTTPS 优先、失败再降级"，改成 **http 优先**（安全兜底仍在）。
        // 依据是同一秒十路并发实测（ios_ctrl/_probe_sites.py）：
        //   https://www.hongniuzy4.com/…/?ac=list&pg=1 → 25.4s 握手超时，0 字节
        //   http ://www.hongniuzy4.com/…/?ac=list&pg=1 →  4.3s，200 / 6465 字节
        //   https://suoniapi.com/…/?ac=list&pg=1        → 25.4s 超时
        //   http ://suoniapi.com（同参数）              →  4.3s 有数据
        // 首次就把 10s 的等待砍成 4s；且走过的结果**持久化**（UserDefaults），冷启动后依然有效。
        if isHTTPS, var pc = URLComponents(url: origin, resolvingAgainstBaseURL: false) {
            if httpsOnlyHosts.contains(host) {
                // 这条源已证实只有 https 能通 → 别再浪费时间试明文
                usedScheme = "https(记忆)"
                if let data = await Self.fetchURL(origin, session: s) { hit = true; return data }
                usedScheme = "http(重试)"
            } else {
                pc.scheme = "http"
                usedScheme = "http(优先)"
                if let pu = pc.url, let data = await Self.fetchURL(pu, session: s) { hit = true; return data }
                usedScheme = "https(回退)"
            }
            // 明文不通 → 回 https（只支持 https 的源照常可用），成功则记住它是 https-only
            if let data = await Self.fetchURL(origin, session: s) {
                hit = true
                markHTTPSOnly(host)
                return data
            }
            lastErr = " 双协议均失败"
            return nil
        }
        // 源本身就配成 http：单发即可
        if let data = await Self.fetchURL(origin, session: s) { hit = true; return data }
        lastErr = " http失败"
        return nil
    }

    /// 实测「HTTPS 与 HTTP 并发竞速」不采用：这批 CMS 站对同 host 并发握手极不友好
    /// （十路并发里 TLS 全挂），多开一条连接反而拖慢首包。故只做单发 + 协议优先级记忆。

    /// 单次 GET（200 且非空才算成功）；GBK 源在此归一化为 UTF-8。
    private static func fetchURL(_ url: URL, session: URLSession) async -> Data? {
        var req = URLRequest(url: url)
        // TVBox 原版以 okhttp UA 出请求；部分 CMS 对空/默认 UA 返回空体
        req.setValue("okhttp/4.10.0", forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return normalizeUTF8(data) ?? data
    }

    /// 非 UTF-8 响应（常见 GBK）→ 转 UTF-8；已是 UTF-8 原样返回。
    static func normalizeUTF8(_ data: Data) -> Data? {
        if String(data: data, encoding: .utf8) != nil { return data }
        guard let s = TVBoxFetcher.decodeAuto(data) else { return nil }
        return s.data(using: .utf8)
    }

    // MARK: - CMS JSON 骨架（属性驼峰：decoder 会把蛇形键转驼峰再匹配）

    private struct CMSClass: Codable {
        let typeId: FlexibleID?
        let typePid: FlexibleID?      // 父分类 id；0=顶级。实测：顶级分类 ac=list&t=<顶级> 恒返回 0 条，必须落到叶子
        let typeName: String?
    }
    private struct CMSItem: Codable {
        let vodId: FlexibleID?
        let vodName: String?
        let vodPic: String?
        let vodYear: String?
        let vodRemarks: String?
        let vodContent: String?
        let vodDirector: String?
        let vodActor: String?
        let vodClass: String?
        let vodPlayUrl: String?
        let vodPlayFrom: String?
        let vodArea: String?          // 源站地区字段（2026-09-23：源浏览也有了地区筛选数据）
        let typeName: String?
    }
    /// 分页数字（容错）：Int / Double / String / null 都能吃，取不到就是 nil，
    /// **绝不因为一个元信息字段让整页解码失败**（35包加固）。
    private struct LMetric: Codable {
        let value: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { value = i }
            else if let d = try? c.decode(Double.self) { value = Int(d) }
            else if let s = try? c.decode(String.self) { value = Int(s) }
            else { value = nil }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(value ?? 0)
        }
    }

    private struct CMSResponse: Codable {
        let `class`: [CMSClass]?
        let list: [CMSItem]?
        // 分页元信息（35包·翻页功能）：实测 360资源 叶子分类 pagecount=193/total=3860/limit=20，
        // 不再靠「返回条数 < 10 猜到底」——直接拿权威页码总数给用户翻页。
        let pagecount: LMetric?
        let total: LMetric?
        let limit: LMetric?
    }

    /// 一页结果 + 分页元信息（翻页 UI 用）。
    public struct CMSListPage {
        public let items: [FeedItem]
        public let page: Int
        public let pageCount: Int      // 总页数（0=上游没给）
        public let total: Int          // 总条数（0=上游没给）
        public let perPage: Int        // 上游单页条数
        /// 上游响应是否成功解码（区分「请求失败」与「该分类确实为空」）。
        /// 上层据此才敢把空分类判死并摘掉——网络抖动不会被误判成死分类。
        public let ok: Bool
    }

    // MARK: - 接口

    /// JSON 优先、XML 兜底（type0 站点返回 rss XML，28号包补齐）。
    private func decodeCMS(_ data: Data) -> CMSResponse? {
        if let rsp = try? FilmJSON.decoder().decode(CMSResponse.self, from: data) { return rsp }
        guard CMSXML.looksXML(data), let xml = CMSXML.parse(data) else { return nil }
        return CMSResponse(
            `class`: xml.classes.isEmpty ? nil : xml.classes.map {
                CMSClass(typeId: FlexibleID($0.id), typePid: nil, typeName: $0.name)
            },
            list: xml.videos.isEmpty ? nil : xml.videos.map {
                CMSItem(vodId: $0.id.flatMap(FlexibleID.init), vodName: $0.name, vodPic: $0.pic,
                        vodYear: $0.year, vodRemarks: $0.remarks, vodContent: $0.content,
                        vodDirector: $0.director, vodActor: $0.actor, vodClass: nil,
                        vodPlayUrl: $0.playURL, vodPlayFrom: $0.playFrom,
                        vodArea: nil,   // XML 通道暂不解析 area 标签，地区由分类名派生
                        typeName: $0.typeName)
            },
            pagecount: nil, total: nil, limit: nil)
    }

    /// 分类列表（ac=list）。
    /// 35包修正：**只给叶子分类**——实测 360资源/无尽资源 等 CMS，顶级分类（type_pid=0，如「电影」）
    /// 用 ac=list&t=<顶级> 恒返回 0 条，只有叶子分类（动作片/喜剧片…）才有内容。
    /// 原实现把顶级分类也做成入口 → 用户点「电影」拿到 0 条 → 回退全量只剩 20~40 部
    /// （用户报「点开一个分类最多三四十部」的根因之一）。
    /// 规则：若响应里存在 type_pid != 0 的条目（说明是分类树），就只保留「有子分类的父级之外」的条目；
    ///       平铺站点（全 type_pid=0）则原样返回，不做删减。
    public func categories() async -> [SiteCategory] {
        guard let data = await api(["ac": "list"]),
              let rsp = decodeCMS(data) else { return [] }
        let raw = (rsp.class ?? []).compactMap { c -> (id: String, pid: String, name: String)? in
            guard let name = c.typeName, !name.isEmpty, let id = c.typeId?.value, !id.isEmpty else { return nil }
            return (id, c.typePid?.value ?? "0", name)
        }
        guard !raw.isEmpty else { return [] }
        let hasTree = raw.contains { $0.pid != "0" && $0.pid != "" }
        let kept: [(id: String, pid: String, name: String)]
        if hasTree {
            let parentIds = Set(raw.map(\.pid).filter { $0 != "0" && $0 != "" })
            // 叶子 = 非顶级；另外保留「顶级但没有任何子分类」的条目（个别源顶级就是叶子）
            kept = raw.filter { ($0.pid != "0" && $0.pid != "") || !parentIds.contains($0.id) }
        } else {
            kept = raw
        }
        var seen = Set<String>()
        return kept.filter { seen.insert($0.id).inserted }
                   .map { SiteCategory(id: $0.id, name: $0.name) }
    }

    /// 分类分页 + 元信息（35包·翻页）。主路 ac=list。
    /// 兜底：page=1 且 list 空 → 退回 detail（个别源 list 端点坏）。
    public func listPage(categoryId: String?, page: Int) async -> CMSListPage {
        let pg = max(1, page)
        var q = ["ac": "list", "pg": String(pg)]
        if let categoryId, !categoryId.isEmpty { q["t"] = categoryId }
        var items: [FeedItem] = []
        var pageCount = 0, total = 0, perPage = 0
        var ok = false
        var responded = false   // 上游**应答成功**（哪怕是空列表）
        if let data = await api(q), let rsp = decodeCMS(data) {
            ok = true
            responded = true
            items = (rsp.list ?? []).compactMap { map($0) }
            pageCount = rsp.pagecount?.value ?? 0
            total = rsp.total?.value ?? 0
            perPage = rsp.limit?.value ?? 0
        }
        // ★ 2026-10-17：detail 兜底只治「list 端点坏（应答了但恒空）」，不治网络。
        //   旧写法只要 `items.isEmpty` 就再发一条 detail —— 而红牛资源 2 的 detail 实测 **50s**
        //   （比 list 慢一个数量级）→ 换源时白等一分钟，主人看到的就是「一直转圈」。
        //   现在网络失败（responded=false）直接收工，交给上层报错/换源，不再二次受罪。
        if items.isEmpty, pg <= 1, responded {
            var dq = ["ac": "detail", "pg": "1"]
            if let categoryId, !categoryId.isEmpty { dq["t"] = categoryId }
            if let data = await api(dq), let rsp = decodeCMS(data) {
                ok = true
                let dItems = (rsp.list ?? []).compactMap { map($0) }
                if !dItems.isEmpty {
                    items = dItems
                    pageCount = rsp.pagecount?.value ?? pageCount
                    total = rsp.total?.value ?? total
                    perPage = rsp.limit?.value ?? perPage
                }
            }
        }
        // 熔断记账（2026-09-25 用户钦点「源坏了自动补救」）：超时/非200/解码失败 = ok=false
        SourceHealth.shared.record(site.key, ok: ok)
        return CMSListPage(items: items, page: pg, pageCount: pageCount,
                           total: total, perPage: perPage == 0 ? items.count : perPage,
                           ok: ok)
    }

    /// 旧接口（保持兼容，内部走 listPage）。
    public func videos(categoryId: String?, page: Int) async -> [FeedItem] {
        await listPage(categoryId: categoryId, page: page).items
    }

    /// 详情（ac=detail&ids=）。
    public func detail(vodId: String) async -> FeedItem? {
        guard let data = await api(["ac": "detail", "ids": vodId]),
              let rsp = decodeCMS(data),
              let first = rsp.list?.first else {
            SourceHealth.shared.record(site.key, ok: false)
            return nil
        }
        SourceHealth.shared.record(site.key, ok: true)
        return map(first)
    }

    /// 搜索（ac=detail&wd=）。空结果≠源坏（可能真没这片），只有网络层失败才记熔断。
    public func search(_ keyword: String) async -> [FeedItem] {
        // 走短会话（8s）：慢源不再拖住整屏搜索，见 init 注释里的实测数据
        guard let data = await api(["ac": "detail", "wd": keyword], via: searchSession),
              let rsp = decodeCMS(data) else {
            // 空结果≠源坏（可能真没这片），只有网络层失败才记熔断。
            // 但**被预算取消**不算失败（见 GlobalSiteSearch 的 budget：到点就 cancelAll），
            // 否则每轮搜完都会把"还没轮到"的源误判成坏源、沉底后再也浮不上来。
            if !Task.isCancelled { SourceHealth.shared.record(site.key, ok: false) }
            return []
        }
        SourceHealth.shared.record(site.key, ok: true)
        return (rsp.list ?? []).compactMap { map($0) }
    }

    // MARK: - 列表补图（34包根修「内置源海报不显示」）

    /// ac=list 的 vod_pic 全空（8 内置源 2026-09-22 并发实测全空；图只在 ac=detail 返回）。
    /// 对无 poster 的条目并发补 detail 仅取图；picCache 防翻页/重进重复拉。
    private var picCache: [String: String] = [:]

    /// ★ 2026-10-17：并发 6→3、单轮上限 24→12。
    ///   实测（图 3「索倪首行三张海报一直转圈」）：同 host 6 条 detail 并发会**互相掐握手**，
    ///   而 ac=detail 是这条源最慢的端点（红牛 50s / 索倪 29s）→ 越并发越全挂。
    ///   补图是"锦上添花"，宁可慢一点也不能把首屏拖成转圈墙：3 条并发 + 只补首屏这一屏。
    public func enrichPosters(_ items: [FeedItem], limit: Int = 12) async -> [FeedItem] {
        var out = items
        func noPic(_ it: FeedItem) -> Bool { (it.poster?.url ?? "").isEmpty }
        // 先吃缓存
        for i in out.indices where noPic(out[i]) {
            if let pic = picCache[vodIdOf(out[i])], !pic.isEmpty {
                out[i] = out[i].withPoster(pic)
            }
        }
        let targets = out.indices.filter { noPic(out[$0]) }.prefix(limit)
        guard !targets.isEmpty else { return out }
        await withTaskGroup(of: (Int, String?).self) { group in
            // 限流 3 并发；回收的结果必须当场落盘应用，直接丢弃会白拉（34包修正）
            func apply(_ idx: Int, _ pic: String?) {
                guard let pic, !pic.isEmpty else { return }
                picCache[vodIdOf(out[idx])] = pic
                out[idx] = out[idx].withPoster(pic)
            }
            var inFlight = 0
            for idx in targets {
                if inFlight >= 3 {
                    if let (doneIdx, pic) = await group.next() { apply(doneIdx, pic) }
                    inFlight -= 1
                }
                let vodId = vodIdOf(out[idx])
                group.addTask { [weak self] in
                    guard let self else { return (idx, nil) }
                    let d = await self.detail(vodId: vodId)
                    return (idx, d?.poster?.url)
                }
                inFlight += 1
            }
            for await (idx, pic) in group { apply(idx, pic) }
        }
        return out
    }

    /// dedupId = tvbox:<siteId>:<vodId>，siteId 可含冒号（builtin:xxx）——去两段前缀取 vodId。
    private func vodIdOf(_ it: FeedItem) -> String {
        let rest = it.dedupId.hasPrefix("tvbox:") ? String(it.dedupId.dropFirst(6)) : it.dedupId
        let prefix = site.id + ":"
        return rest.hasPrefix(prefix) ? String(rest.dropFirst(prefix.count)) : rest
    }

    /// vod_pic 归一化：空 → nil；相对路径 → 拼源站 host；绝对 → 原样。
    private func normalizedPic(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http") { return raw }
        if let comps = URLComponents(string: site.api), let host = comps.host {
            let scheme = comps.scheme ?? "https"
            return "\(scheme)://\(host)\(raw.hasPrefix("/") ? "" : "/")\(raw)"
        }
        return nil
    }

    // MARK: - CMS → FeedItem 映射（复用现有 UI 全链路）

    private func map(_ raw: CMSItem) -> FeedItem? {
        guard let vodId = raw.vodId?.value, !vodId.isEmpty,
              let name = raw.vodName, !name.isEmpty else { return nil }
        let (defaultURL, lines) = TVBoxPlayParser.parse(playURL: raw.vodPlayUrl ?? "",
                                                        playFrom: raw.vodPlayFrom)
        let typeName = raw.typeName ?? raw.vodClass
        let cats = (raw.vodClass ?? "").split(separator: ",").map(String.init)
        return FeedItem(
            dedupId: "tvbox:\(site.id):\(vodId)",
            title: name,
            // 年份清洗（与 feed 通道同规）：钳制 1900~当前年，杜绝 2027/2030 穿越
            year: Self.sanitizeYear(raw.vodYear),
            directors: raw.vodDirector.map { $0.split(separator: ",").map(String.init) },
            actors: raw.vodActor.map { $0.split(separator: ",").map(String.init) },
            summary: raw.vodContent,
            contentType: guessContentType(typeName: typeName, cats: cats),
            // 源站 vod_area 归一化为中台同口径地区名；取不到再从分类名派生（如「香港剧」）
            area: NavPolicy.regionLabel(raw.vodArea ?? "") ?? NavPolicy.regionLabel(typeName ?? ""),
            isAdult: nil,
            playable: defaultURL != nil,
            categories: FeedCategories(normal: cats.isEmpty ? nil : cats, canonical: nil, tags: nil),
            aggregateCategoryId: nil,
            aggregateCategoryName: typeName,
            originalCategoryName: typeName,   // 内置源：源分类即站点栏目名（隔离闸门依赖此字段）
            poster: normalizedPic(raw.vodPic).map { PosterRef(url: $0, thumb: nil) },
            backdrop: nil,
            qualityScore: nil,
            // 内置源不给评分/热度：源站 vod_score 无真值，留 nil 让端侧货架自然跳过（不进高分/热门榜）
            rating: nil,
            votes: nil,
            hits: nil,
            origin: FeedOrigin(sourceId: site.id, sourceName: site.name, category: typeName),
            play: FeedPlay(lines: lines.isEmpty ? nil : lines,
                           defaultLine: lines.first?.quality,
                           defaultURL: defaultURL)
        )
    }

    private func guessContentType(typeName: String?, cats: [String]) -> String? {
        let bag = (typeName ?? "") + cats.joined()
        if bag.contains("剧") || bag.contains("综艺") || bag.contains("动漫") || bag.contains("短剧") { return "tv" }
        if bag.contains("电影") { return "movie" }
        return nil
    }

    /// 年份清洗（与 feed 通道同规）：取前4位数字，钳制 1900~当前年。
    /// 源站有 2027/2030 等未来穿越年份（用户 2026-09-20 报障），一律压回当前年。
    static func sanitizeYear(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let digits = raw.prefix(4).filter(\.isNumber)
        guard let y = Int(digits), y >= 1900 else { return nil }
        let current = Calendar.current.component(.year, from: Date())
        return String(min(y, current))
    }
}

// MARK: - CMS XML 协议（type 0 站点）解析
// TVBox 原版 type0=XML(苹果CMS rss) / type1=JSON；App 此前只认 JSON，
// 电视/PC 能用的 XML 站在手机上全部「暂无内容」（2026-09-21 28号包补齐）。
// XML 解析器产出顶层中间模型（actor 内 private 类型不可达），由 TVBoxSiteClient.decodeCMS 转换。
struct CMSXMLModel {
    struct RawClass { let id: String; let name: String }
    struct RawVideo {
        let id: String?; let name: String?; let pic: String?; let year: String?
        let remarks: String?; let content: String?; let director: String?; let actor: String?
        let playURL: String?; let playFrom: String?; let typeName: String?
    }
    var classes: [RawClass] = []
    var videos: [RawVideo] = []
}

enum CMSXML {
    static func looksXML(_ data: Data) -> Bool {
        let head = String(data: data.prefix(64), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return head.hasPrefix("<")
    }

    static func parse(_ data: Data) -> CMSXMLModel? {
        let delegate = CMSXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        guard !(delegate.model.videos.isEmpty && delegate.model.classes.isEmpty) else { return nil }
        return delegate.model
    }
}

final class CMSXMLDelegate: NSObject, XMLParserDelegate {
    var model = CMSXMLModel()

    private var text = ""
    private var inClass = false
    private var inVideo = false
    private var curClassID = ""
    private var curClassTyID = ""
    private var video: [String: String] = [:]
    private var dds: [(flags: String, body: String)] = []
    private var curDDFlags = ""

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String] = [:]) {
        text = ""
        switch el {
        case "class": inClass = true
        case "video": inVideo = true; video = [:]; dds = []
        case "ty" where inClass: curClassTyID = attrs["id"] ?? ""
        case "dd": curDDFlags = attrs["flag"] ?? attrs["flags"] ?? ""
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCharacters str: String) { text += str }

    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        switch el {
        case "class":
            inClass = false
        case "ty":
            if !curClassTyID.isEmpty, !v.isEmpty { model.classes.append(.init(id: curClassTyID, name: v)) }
            curClassTyID = ""
        case "id" where inClass: curClassID = v            // <class><id>..</id><t_name>..</t_name>
        case "t_name":
            if !curClassID.isEmpty, !v.isEmpty { model.classes.append(.init(id: curClassID, name: v)) }
            curClassID = ""
        case "video":
            inVideo = false
            let playURL = dds.map { $0.body }.joined(separator: "###")
            let playFrom = dds.map { $0.flags }.joined(separator: "###")
            model.videos.append(.init(id: video["id"], name: video["name"], pic: video["pic"],
                                      year: video["year"], remarks: video["note"],
                                      content: video["dt"] ?? video["content"] ?? video["des"],
                                      director: video["director"], actor: video["actor"],
                                      playURL: playURL.isEmpty ? nil : playURL,
                                      playFrom: playFrom.isEmpty ? nil : playFrom,
                                      typeName: video["type"]))
            video = [:]
        case "dd":
            dds.append((curDDFlags, v))
            curDDFlags = ""
        default:
            if inVideo { video[el] = v }
        }
    }
}

// MARK: - 点播源客户端池（2026-10-03「内置源加载加速 / 搜索加速」）

/// 进程内按 `site.key` 复用 `TVBoxSiteClient`，目的是**别把 URLSession 的连接池丢掉**。
///
/// 放在文件作用域的 `private enum` 里（本仓既有写法，见 `SpiderDrpyHost` / `LiveDiag`）：
/// 静态存储属性写在这里语义最稳，不受 actor / 泛型等上下文差异影响。
///
/// 线程安全：全部访问走 `lock`；`shared(for:)` 本身只做一次字典查表 + 必要时构造，
/// 临界区极短，不会成为热点。返回的 `TVBoxSiteClient` 是 actor，自身并发安全。
private enum TVBoxClientPool {
    private static var pool: [String: TVBoxSiteClient] = [:]
    private static let lock = NSLock()

    static func shared(for site: TVBoxSite) -> TVBoxSiteClient {
        lock.lock()
        defer { lock.unlock() }
        if let c = pool[site.key] { return c }
        let c = TVBoxSiteClient(site: site)
        pool[site.key] = c
        return c
    }
}
