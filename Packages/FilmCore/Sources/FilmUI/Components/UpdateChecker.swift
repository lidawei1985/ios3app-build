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
/// - 用户想看/想更时进设置页「检查更新」行 → 点一下走 LiveContainer 官方 URL scheme：
///   `livecontainer://install?url=<IPA直链>` → LC 自动下载导入签名，新版替换旧版、数据不丢；
/// - 本机没装 LC → fallback 打开 Pages 安装指南页（下载 IPA 自签 / TrollStore）。
///
/// 静默原则（2026-10-06 强化到「彻底无感」）：**任何时候都不弹窗**；
/// 本地是未注入 stamp 的调试包（`__BUILD_STAMP__`）或网络失败 → 也永不打扰。
@MainActor
public final class UpdateChecker: ObservableObject {
    public static let shared = UpdateChecker()

    public static let repo = "lidawei1985/ios3app-build"
    /// gh-pages 域名（Pages 部署根）
    public static let pagesBase = "https://lidawei1985.github.io/ios3app-build"
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
    // 2026-10-06 主人钦定「更新的那个提示彻底取消」→ 全流程零弹窗：
    // 启动静默检查只记 state（设置页那行仍会变成「新构建 xxx · 点此更新」），不再打扰任何人。

    private var remoteStamp: String?
    /// 本端 IPA 的 Release 资产名（App 入口处设置：星幕 XingmuISO.ipa / 心屋 XinwuISO.ipa）
    public var assetName: String = ""
    /// 本端跑在哪个 LiveContainer 容器实例（App 入口处设置）：
    /// 星幕 = `livecontainer`，心屋 = `livecontainer2`（第二容器实例，与网页端 scripts/pages/index.html
    /// 同口径 —— 两个容器抢同一个 scheme 会把片源装错容器）。
    public var lcScheme: String = "livecontainer"

    private init() {}

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
            var req = URLRequest(url: URL(string: Self.pagesBase + "/update.json")!)
            req.timeoutInterval = 10
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
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
    /// Range 1KB 探测、6 秒超时；取最快可达者，全挂则回官方直链（永不返回 nil）。
    ///
    /// ⚠️ 2026-10-07 修 P0「赢了竞速然后卡死」：**官方直链已从竞速候选里剔除**，只作兜底。
    ///
    /// 病根：旧代码把「官方直链」也放进竞速，判据是 **Range 1KB 的响应时间**。
    /// 可官方直链是 `github.com → 302 → release-assets.githubusercontent.com(Azure blob)`，
    /// **起手快、之后掐速**——本机实测 1KB 首字节 1.26~3.96s（完全能在竞速里胜出），
    /// 真实吞吐却只有 **213~466 B/s**：45 秒只吐 131KB，34MB 得跑 3 个多小时 ⇒ 必然失败。
    /// 同一个 URL 经三个镜像站，实测吞吐 63~470 KB/s（34MB 约 1.2~9 分钟），差三个数量级。
    ///
    /// 修法（最小改动，与网页端 `pickMirror()` 同口径：官方直链垫底、不参与选优）：
    /// 竞速只在**三个镜像**之间进行；官方直链仅当镜像全挂时兜底返回（永不返回 nil）。
    static func fastestDirectURL(asset: String) async -> URL {
        let rel = URL(string: "https://github.com/\(repo)/releases/download/\(releaseTag)/\(asset)")!
        // ⛔ 这里**绝不能**再放 ""（官方直链）：首字节快、吞吐极慢，会把竞速带沟里。
        let mirrors: [String] = [
            "https://gh-proxy.com/",
            "https://ghproxy.net/",
            "https://ghfast.top/",
        ]
        let fastest = await withTaskGroup(of: (Int, URL?, Double).self) { group in
            for (i, p) in mirrors.enumerated() {
                group.addTask {
                    guard let u = URL(string: p + rel.absoluteString) else { return (i, nil, 0) }
                    var req = URLRequest(url: u)
                    req.timeoutInterval = 6
                    req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
                    let t0 = Date()
                    do {
                        let (_, resp) = try await URLSession.shared.data(for: req)
                        guard let http = resp as? HTTPURLResponse,
                              http.statusCode == 206 || (200...299).contains(http.statusCode) else {
                            return (i, nil, 0)
                        }
                        return (i, u, Date().timeIntervalSince(t0))
                    } catch {
                        return (i, nil, 0)
                    }
                }
            }
            var best: (Int, URL, Double)? = nil
            for await r in group {
                if let u = r.1, best == nil || r.2 < best!.2 { best = (r.0, u, r.2) }
            }
            return best?.1
        }
        return fastest ?? rel
    }
}
