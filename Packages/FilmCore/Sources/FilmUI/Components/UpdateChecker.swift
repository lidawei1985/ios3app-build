import Foundation
import SwiftUI
import UIKit
import FilmCore

/// App 内自动更新（2026-10-01 主人钦定：「自动更新 + 随时下载使用 · 谁都可以下载有下载地址 能安装」）。
///
/// 数据链路：
/// - CI 每次 push 自动发**滚动 Release**（固定 tag `latest`，明文 IPA）+ 部署 gh-pages；
/// - App 启动/设置页拉 `https://<pages-host>/update.json`（静态文件，无 API 限流）；
/// - JSON 里的 `stamp` 与本机构建指纹（`FeedSecret.buildStamp`）不同 → 弹「发现新版本」；
/// - 点「立即更新」→ 跳 LiveContainer 官方 URL scheme：
///   `livecontainer://install?url=<IPA直链>` → LC 自动下载导入签名，新版替换旧版、数据不丢；
/// - 本机没装 LC → fallback 打开 Release 网页（下载 IPA 自签 / TrollStore）。
///
/// 静默原则：本地是未注入 stamp 的调试包（`__BUILD_STAMP__`）或网络失败 → 永不打扰。
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
    @Published public var showUpdate = false
    @Published public private(set) var releaseNote = ""

    /// 弹窗自动关的定时任务（2026-10-03 主人钦定：「那个更新弹窗不能弹完 3 秒就关吗？一直在那烦死人了」）
    private var autoCloseTask: Task<Void, Never>?
    /// 弹窗自动关闭延时（秒）
    public static let autoCloseSeconds: Double = 3

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
                if silent { presentThenAutoClose() }        // 启动静默检查 → 有新版才弹（3 秒自关）
            }
        } catch {
            state = .idle
            if !silent { releaseNote = "检查失败：\(error.localizedDescription)" }
        }
    }

    /// 弹「发现新版本」并 **3 秒后自动关**（主人 2026-10-03 钦定：「弹完 3 秒就关，别一直在那烦」）。
    /// 只在**启动静默检查**（`silent: true`）时弹 —— 那是"用户没主动要、被挡一次"的场景，最该少待；
    /// 设置页手动检查（`silent: false`）**不弹窗**，只把那行文字改成「新构建 xxx · 点此更新」
    /// （用户是主动来的，别再用弹窗打断他）。
    /// 关掉后 `state` 仍是 `.available`，设置页那行仍显示「点此更新」，功能不减。
    private func presentThenAutoClose() {
        showUpdate = true
        autoCloseTask?.cancel()
        autoCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoCloseSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.showUpdate { self.showUpdate = false }
        }
    }

    /// 用户手点「稍后 / 立即更新」时收掉定时任务，避免重复触发。
    public func dismissUpdate() {
        autoCloseTask?.cancel()
        autoCloseTask = nil
        showUpdate = false
    }

    /// 一键更新（2026-10-04 重修「LC不可用」，三处病根一次治）：
    /// ① Info.plist 未声明 LSApplicationQueriesSchemes → canOpenURL 恒 false，
    ///    永远掉进 GitHub 网页兜底（国内手机网络打不开）＝ 用户看到的「LC不可用」；
    /// ② 心屋必须走 `livecontainer2`（第二容器实例），旧代码两个 App 都硬编码 `livecontainer`；
    /// ③ 裸 GitHub 直链在国内手机网络经常超时（网页端 2026-10-01 实测并做了镜像竞速），
    ///    App 内也照做：先竞速选最快可达通道，再交给 LC 下载。
    /// LC 没装时兜底开 **gh-pages 安装指南页**（pages 域名手机可达 —— 能弹「发现新版本」
    /// 就证明它通；GitHub.com 的 Release 页在国内基本打不开，旧兜底等于没兜底）。
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

    /// 镜像竞速：与网页端 `scripts/pages/index.html` 同一套通道（2026-10-01 手机网络实测可达）。
    /// Range 1KB 探测、6 秒超时；取最快可达者，全挂则回官方直链（永不返回 nil）。
    static func fastestDirectURL(asset: String) async -> URL {
        let rel = URL(string: "https://github.com/\(repo)/releases/download/\(releaseTag)/\(asset)")!
        let mirrors: [String] = [
            "",                              // 官方直链
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
