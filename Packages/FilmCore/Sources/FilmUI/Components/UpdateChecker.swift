import Foundation
import SwiftUI
import UIKit
import FilmCore

/// App 内自动更新（2026-10-01 主人钦定：「自动更新 + 随时下载使用 · 谁都可以下载有下载地址 能安装」）。
///
/// 数据链路：
/// - CI 每次 push 自动发**滚动 Release**（固定 tag `latest`，明文 IPA）+ 部署 gh-pages；
/// - App 启动/设置页拉 `https://<pages-host>/update.json`（静态文件，无 API 限流）；
/// - JSON 里的 `stamp` 与本机构建指纹（`FeedSecret.buildStamp`）不同 → 只**记状态**（2026-10-06 起零弹窗）；
/// - **启动即自动升级（2026-10-10 主人钦定）**：启动静默检查 → 检测到新版本即
///   **自动**走 LiveContainer 官方 URL scheme `livecontainer://install?url=<IPA直链>`
///   → LC 自动下载导入签名，新版替换旧版、数据不丢；用户在本 App 内**零点击**。
///   （iOS 硬约束：LC 会显下载/安装进度，这一步系统不允许隐藏——这是能做到的"最接近无感"。）
/// - 设置页「检查更新」行仍保留手动入口；本机没装 LC → 回退打开 Pages 安装指南页。
///
/// 静默原则（2026-10-06 强化到「彻底无感」）：**任何时候都不弹窗**；
/// 本地是未注入 stamp 的调试包（`__BUILD_STAMP__`）或网络失败 → 也永不打扰。
@MainActor
public final class UpdateChecker: ObservableObject {
    public static let shared = UpdateChecker()

    public static let repo = "lidawei1985/ios3app-build"
    /// gh-pages 域名（Pages 部署根）——2026-10-07 起降为**备用**版本信号源
    public static let pagesBase = "https://lidawei1985.github.io/ios3app-build"
    /// 阿里云基础设施（2026-10-07 上线）：**版本信号主源 + 字节中转兜底**。
    /// 为什么能当主源：Pages 域名在国内时通时不通（本机实测 3.7s，页面偶发 000 超时），
    /// 而 `/ver.json` 实测 0.17~0.94s 稳定。
    /// ⛔ 铁律：阿里云**只搬管道不搬内容** —— 服务端纯流式转发、零落盘、无访问日志；
    ///    分发包 / 点播源表 / OTA 安装页继续留 GitHub Pages，不上这台国内实名机器。
    public static let infraBase = "http://120.26.233.93"
    /// 滚动 Release tag
    public static let releaseTag = "latest"

    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(remoteStamp: String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var releaseNote = ""
    /// 启动即自动升级开关（默认 **开**，2026-10-10 主人钦定）。
    /// 关掉后回到旧行为：启动只静默检查，用户自己去设置页点「检查更新」。
    @Published public var autoUpdateEnabled: Bool {
        didSet { UserDefaults.standard.set(autoUpdateEnabled, forKey: Self.autoUpdateKey) }
    }
    private static let autoUpdateKey = "filmcore.autoUpdateOnLaunch"
    /// 每次进程内只自动触发一次（冷启动跳一次 LC 即可，避免同一会话反复跳）。
    private var autoInstallTriggered = false
    // 2026-10-06 主人钦定「更新的那个提示彻底取消」→ 全流程零弹窗：
    // 启动静默检查只记 state（设置页那行仍会变成「新构建 xxx · 点此更新」），不再打扰任何人。

    private var remoteStamp: String?
    /// 本端 IPA 的 Release 资产名（App 入口处设置：星幕 XingmuISO.ipa / 心屋 XinwuISO.ipa）
    public var assetName: String = ""
    /// 本端跑在哪个 LiveContainer 容器实例（App 入口处设置）：
    /// 星幕 = `livecontainer`，心屋 = `livecontainer2`（第二容器实例，与网页端 scripts/pages/index.html
    /// 同口径 —— 两个容器抢同一个 scheme 会把片源装错容器）。
    public var lcScheme: String = "livecontainer"

    private init() {
        // 默认开；若用户曾手动关过，则沿用其选择。
        autoUpdateEnabled = (UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool) ?? true
    }

    public var localStamp: String { FeedSecret.buildStamp }

    /// 查更新。`silent=true`（启动自动）任何失败都不打扰；`silent=false`（设置页手动）失败给提示。
    public func check(silent: Bool) async {
        guard !localStamp.hasPrefix("__") else {           // 本地调试包：无有效构建指纹
            state = .idle
            if !silent { releaseNote = "当前是本地调试包（无构建指纹），跳过更新检查。" }
            return
        }
        state = .checking
        defer { if case .checking = state { state = .idle } }
        do {
            // 版本信号：阿里云主源 → GitHub Pages 备用（2026-10-07）。两个都挂才算检查失败。
            guard let data = await Self.fetchVersionJSON() else {
                throw URLError(.cannotConnectToHost)
            }
            let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let stamp = j?["stamp"] as? String, !stamp.isEmpty else {
                throw URLError(.cannotParseResponse)
            }
            let note = (j?["note"] as? String) ?? ""
            remoteStamp = stamp
            if stamp == localStamp {
                state = .upToDate
                if !silent { releaseNote = "已是最新版本（构建 \(localStamp)）。" }
            } else {
                state = .available(remoteStamp: stamp)
                releaseNote = note.isEmpty
                    ? "新版本构建 \(stamp) 已发布，更新由 LiveContainer 自动完成，数据保留。"
                    : note
                // 2026-10-06 起：这里**不再弹任何东西**（主人钦定「更新提示彻底取消」）。
                // state 已是 .available → 设置页「检查更新」那行显示「新构建 xxx · 点此更新」，
                // 用户想看/想更时才进来点，属于用户主动，不是被弹窗打断。
            }
        } catch {
            state = .idle
            if !silent { releaseNote = "检查失败：\(error.localizedDescription)" }
        }
    }

    /// 启动即自动升级（2026-10-10 主人钦定「能不能实现静默无感更新」→ 采用"启动即自动升级"）。
    ///
    /// 流程：静默检查 → 检测到新版本 + 开关开启 + 本机装了 LiveContainer →
    /// **自动唤起安装，用户在本 App 内零操作**（LC 会显下载/安装进度，这是 iOS 允许的极限）。
    /// 检查失败 / 已是最新 / 开关关闭 / 没装 LC → 一律静默什么都不做，绝不打扰。
    public func autoUpdateOnLaunch() async {
        await check(silent: true)
        guard case .available = state else { return }        // 已最新 or 检查失败 → 不动作
        guard autoUpdateEnabled, !autoInstallTriggered else { return }
        autoInstallTriggered = true                          // 同一会话只跳一次
        guard canOpenInstaller() else {
            // 没装 LC：自动跳只会把用户甩到网页，帮不上忙 → 静默不动（等用户自己处理）
            return
        }
        installLatest()
    }

    /// 本机是否装了可用安装器（LiveContainer 容器 scheme 能被打开）。
    /// 依赖 Info.plist 的 LSApplicationQueriesSchemes 已声明 livecontainer / livecontainer2。
    private func canOpenInstaller() -> Bool {
        guard let u = URL(string: "\(lcScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(u)
    }

    /// 一键更新（2026-10-04 重修「LC不可用」，三处病根一次治）：
    /// ① Info.plist 未声明 LSApplicationQueriesSchemes → canOpenURL 恒 false，
    ///    永远掉进 GitHub 网页兜底（国内手机网络打不开）＝ 用户看到的「LC不可用」；
    /// ② 心屋必须走 `livecontainer2`（第二容器实例），旧代码两个 App 都硬编码 `livecontainer`；
    /// ③ 裸 GitHub 直链在国内手机网络经常超时（网页端 2026-10-01 实测并做了镜像竞速），
    ///    App 内也照做：先竞速选最快可达通道，再交给 LC 下载。
    /// LC 没装时兜底开 **Pages 安装指南页**（pages 域名手机可达；
    /// GitHub.com 的 Release 页在国内基本打不开，旧兜底等于没兜底）。
    public func installLatest() {
        guard remoteStamp != nil else { return }
        let asset = assetName.isEmpty ? "XingmuISO.ipa" : assetName
        Task { @MainActor in
            let direct = await Self.fastestDirectURL(asset: asset)
            let encoded = direct.absoluteString
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? direct.absoluteString
            let lc = URL(string: "\(lcScheme)://install?url=\(encoded)")
            if let lc, UIApplication.shared.canOpenURL(lc) {
                _ = await UIApplication.shared.open(lc)
            } else {
                // 没装 LC（或容器 scheme 未声明）：开安装指南页，页面自带镜像竞速与一键导入
                if let web = URL(string: Self.pagesBase + "/") {
                    _ = await UIApplication.shared.open(web)
                }
            }
        }
    }

    /// 镜像竞速：与网页端 `scripts/pages/index.html` 同一套通道。
    /// 判据见下方 2026-10-10 说明（现为 **Range 512KB 真实吞吐**，取最快者）。
    /// 全挂时走**兜底阶梯**：阿里云字节中转 → 官方直链（永不返回 nil）。
    ///
    /// ⚠️ 2026-10-07 修 P0「赢了竞速然后卡死」：**官方直链已从竞速候选里剔除**，只作兜底。
    ///
    /// 病根：旧代码把「官方直链」也放进竞速，判据是 **Range 1KB 的响应时间**。
    /// 可官方直链是 `github.com → 302 → release-assets.githubusercontent.com(Azure blob)`，
    /// **起手快、之后掐速**——本机实测 1KB 首字节 1.26~3.96s（完全能在竞速里胜出），
    /// 真实吞吐却只有 **213~466 B/s**：45 秒只吐 131KB，34MB 得跑 3 个多小时 ⇒ 必然失败。
    /// 同一个 URL 经三个镜像站，实测吞吐 63~470 KB/s（34MB 约 1.2~9 分钟），差三个数量级。
    ///
    /// 修法（与网页端 `pickMirror()` 同口径：官方直链垫底、不参与选优）：
    /// 竞速只在**三个镜像**之间进行；全挂时按**兜底阶梯**降级（阿里云中转 → 官方直链），
    /// 保证永不返回 nil。
    ///
    /// ⚠️ 2026-10-10 再修判据（主人问"镜像加速"）：旧判据是 **Range 1KB 首字节耗时**——
    /// 会被"首字节快、之后掐速"的通道骗（官方直链就是这么混进来的）。改为
    /// **Range 512KB 真实吞吐**计时，选出来的才是真快的那条。
    /// 本机实测（512KB）：gh-proxy.com 298KB/s ≫ ghproxy.net 57 ≫ ghfast.top 35
    /// ≫ 阿里云 /dl 21 ≫ 官方直链≈0。其余候选镜像（ghproxy.cc / llkk / moeyy / ghp.ci 等）本次全挂，不入池。
    static func fastestDirectURL(asset: String) async -> URL {
        let rel = URL(string: "https://github.com/\(repo)/releases/download/\(releaseTag)/\(asset)")!
        // ⛔ 这里**绝不能**再放 ""（官方直链）：首字节快、吞吐极慢，会把竞速带沟里。
        let mirrors: [String] = [
            "https://gh-proxy.com/",
            "https://ghproxy.net/",
            "https://ghfast.top/",
        ]
        // 竞速判据 = 真实吞吐（KB/s），取最大者。
        let fastest = await withTaskGroup(of: (URL?, Double).self) { group in
            for p in mirrors {
                group.addTask {
                    guard let u = URL(string: p + rel.absoluteString) else { return (nil, 0) }
                    guard let kbps = await Self.probeThroughput(u) else { return (nil, 0) }
                    return (u, kbps)
                }
            }
            var best: (URL, Double)? = nil
            for await r in group {
                if let u = r.0, best == nil || r.1 > best!.1 { best = (u, r.1) }
            }
            return best?.0
        }
        if let fastest { return fastest }
        // ② 三镜像全挂 → 阿里云字节中转兜底。实测 54 KB/s：比镜像慢 16 倍，所以**不进竞速**
        //    （进去只会拖后腿），但它比官方直链快约 130 倍 —— 走投无路时值这一跳。
        if let infra = URL(string: "\(Self.infraBase)/dl/\(asset)"), await Self.probe(infra) != nil {
            return infra
        }
        // ③ 最后才回官方直链：慢到基本等于失败，但**永不返回 nil**（调用方不必处理空值）。
        return rel
    }

    /// 取版本信号：**阿里云 `/ver.json` 主源 → GitHub Pages `update.json` 备用**（2026-10-07）。
    /// 两级都失败才返回 nil（silent 模式下调用方依旧静默，不打扰任何人）。
    static func fetchVersionJSON() async -> Data? {
        let sources: [(String, Double)] = [
            (infraBase + "/ver.json", 6),        // 国内稳定，给短超时（挂了就快速让位）
            (pagesBase + "/update.json", 10),    // 备用：境外、时通时不通，给宽一点
        ]
        for (url, timeout) in sources {
            guard let u = URL(string: url) else { continue }
            var req = URLRequest(url: u)
            req.timeoutInterval = timeout
            req.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { continue }
                return data
            } catch {
                continue
            }
        }
        return nil
    }

    /// Range 1KB 探活：可达返回耗时（秒），不可达/非 2xx 返回 nil。
    /// 竞速与兜底阶梯共用同一套判据（2026-10-07 抽出，避免两处判据各自漂移）。
    /// `nonisolated`：本类带 `@MainActor`，而竞速用的是 `@Sendable` 的 task group 闭包
    /// （非隔离上下文）——不标的话这里过不了隔离检查。纯网络 IO，不碰任何隔离状态。
    nonisolated static func probe(_ url: URL) async -> Double? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let t0 = Date()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  http.statusCode == 206 || (200...299).contains(http.statusCode) else { return nil }
            return Date().timeIntervalSince(t0)
        } catch {
            return nil
        }
    }

    /// Range 512KB **真实吞吐**探测（2026-10-10 新增，替代"首字节耗时"判据）。
    /// 返回 KB/s；不可达 / 非 2xx / 空体 → nil。
    /// 为什么不用更小的探测：太小会被"首字节快"主导；512KB 已足够暴露"之后掐速"的通道，
    /// 又不会让启动更新多等太久（与三镜像并行，最坏 ~8s 出结果）。
    nonisolated static func probeThroughput(_ url: URL) async -> Double? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("bytes=0-524287", forHTTPHeaderField: "Range")   // 512KB
        let t0 = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  http.statusCode == 206 || (200...299).contains(http.statusCode),
                  !data.isEmpty else { return nil }
            let dt = Date().timeIntervalSince(t0)
            guard dt > 0 else { return nil }
            return Double(data.count) / dt / 1024.0                   // KB/s
        } catch {
            return nil
        }
    }
}
