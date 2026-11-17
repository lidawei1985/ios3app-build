import Foundation

/// 远端点播源表（2026-11-17 建）——**根治「源表写死在包里，源站一死 App 就废」**。
///
/// 为什么要有这东西（伟哥原话：「补充好这些源量，不能因为死了就直接掉了源的数量，
/// 还要保障质量，起码要大部分都是秒播，找到解决关键性的问题和方法彻底解决」）：
///  - 旧做法：31 条点播源硬编码在 DefaultSites.swift 里。源站换域名/关站 → App 变成
///    「不出海报 / 点了放不了」的死应用；要修就得改代码 → 云构建 → 重新签名 → 重装，
///    一轮 40 分钟 + 一次验证码，而且 7 天后证书一过期又得再来一遍。
///  - 新做法：**源表放云端**（阿里云 `/ota/ios_vod_sources.json`），App 启动时静默拉一次，
///    落盘缓存（6 小时 TTL）。源死了改云端 JSON 即可，**手机上自动生效，不重签、不发版**。
///    包里那份硬编码清单退化为**兜底**（拉不到远端时照旧能用）。
///
/// 三个区（与 App 现有三套池子一一对应）：
///  - `mixed` → `DefaultSites.builtinMixedVodSources`（星幕/通用影视池，成人分类由 NavPolicy 浏览层拦）
///  - `child` → `DefaultSites.builtinChildVodSources`（心屋儿童池，分类正名单 + 禁全库流）
///  - `drama` → `DefaultSites.tvDramaSources`（电视剧独立通道，串行容灾切换）
///
/// 线程安全：NSLock；读取是**纯内存**（首帧装配时同步读缓存，绝不发网络请求阻塞 UI）。
public final class RemoteVodSites: @unchecked Sendable {

    public static let shared = RemoteVodSites()

    /// 源表地址：阿里云主源（国内实测 0.2~0.9s，与 UpdateChecker/直播源表同机同通道）。
    static let urls: [String] = [
        "http://120.26.233.93/ota/ios_vod_sources.json",
    ]

    static let bodyKey = "fc.remote.vodSites.v2"
    static let stampKey = "fc.remote.vodSites.v2.at"
    static let versionKey = "fc.remote.vodSites.v2.ver"

    /// 刷新间隔：6 小时。源站寿命以天计，6 小时足够快；同时避免每次冷启动都发请求。
    static let ttl: TimeInterval = 6 * 3600

    private struct Payload: Codable {
        struct Item: Codable {
            let key: String
            let name: String
            let api: String
            let type: Int?
        }
        let version: String?
        let zones: [String: [Item]]
    }

    private let lock = NSLock()
    private var zones: [String: [TVBoxSite]] = [:]
    private var version: String = ""
    private var refreshing = false

    private init() {
        loadCache()
    }

    // MARK: - 读取（同步、纯内存）

    /// 某个区的远端源表；远端还没拉到过 → 返回 nil（调用方回落到包里硬编码清单）。
    public func sites(_ zone: String) -> [TVBoxSite]? {
        lock.lock(); defer { lock.unlock() }
        guard let arr = zones[zone], !arr.isEmpty else { return nil }
        return arr
    }

    /// 当前生效的源表版本（设置页/日志可显示，便于确认「远端到底生效了没」）。
    public var currentVersion: String {
        lock.lock(); defer { lock.unlock() }
        return version
    }

    /// 源表是否已从远端生效（false = 还在用包里兜底清单）。
    public var isRemoteActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !zones.isEmpty
    }

    // MARK: - 缓存

    private func loadCache() {
        let d = UserDefaults.standard
        guard let data = d.data(forKey: Self.bodyKey) else { return }
        apply(data, saveToDisk: false)
    }

    private func apply(_ data: Data, saveToDisk: Bool) {
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        var built: [String: [TVBoxSite]] = [:]
        for (zone, items) in p.zones {
            let list = items.compactMap { it -> TVBoxSite? in
                let key = it.key.trimmingCharacters(in: .whitespacesAndNewlines)
                let api = it.api.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, api.lowercased().hasPrefix("http") else { return nil }
                return TVBoxSite(key: key, name: it.name, api: api, type: it.type ?? 1)
            }
            if !list.isEmpty { built[zone] = list }
        }
        guard !built.isEmpty else { return }
        lock.lock()
        zones = built
        version = p.version ?? ""
        lock.unlock()
        if saveToDisk {
            UserDefaults.standard.set(data, forKey: Self.bodyKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.stampKey)
            UserDefaults.standard.set(version, forKey: Self.versionKey)
        }
    }

    // MARK: - 刷新（后台、静默、失败沿用缓存）

    /// App 启动时调一次：不阻塞、不弹窗、失败静默（有缓存就用缓存）。
    public func bootstrap() {
        Task.detached(priority: .utility) { [weak self] in
            await self?.refreshIfStale()
        }
    }

    public func refreshIfStale() async {
        let last = UserDefaults.standard.double(forKey: Self.stampKey)
        if last > 0, Date().timeIntervalSince1970 - last < Self.ttl { return }   // 未过期
        await refresh()
    }

    /// 强制刷新（设置页「立即更新源表」可用）。
    public func refresh() async {
        lock.lock()
        if refreshing { lock.unlock(); return }
        refreshing = true
        lock.unlock()
        defer { lock.lock(); refreshing = false; lock.unlock() }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8        // 源表是**启动期**请求：宁可用缓存，不许拖慢首屏
        cfg.timeoutIntervalForResource = 12
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        for u in Self.urls {
            guard let url = URL(string: u) else { continue }
            var req = URLRequest(url: url)
            req.setValue("xingmu-ios", forHTTPHeaderField: "X-Client")
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { continue }
                apply(data, saveToDisk: true)
                return
            } catch {
                continue          // 换下一个地址；全失败就继续用缓存
            }
        }
    }
}
