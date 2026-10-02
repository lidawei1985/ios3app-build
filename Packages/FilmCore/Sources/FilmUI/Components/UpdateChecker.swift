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

    private var remoteStamp: String?
    /// 本端 IPA 的 Release 资产名（App 入口处设置：星幕 XingmuISO.ipa / 心屋 XinwuISO.ipa）
    public var assetName: String = ""

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
                if silent { showUpdate = true }             // 启动静默检查 → 有新版才弹
            }
        } catch {
            state = .idle
            if !silent { releaseNote = "检查失败：\(error.localizedDescription)" }
        }
    }

    /// 一键更新：优先 LiveContainer scheme（免电脑直装），未装 LC 时打开 Release 网页兜底。
    public func installLatest() {
        guard let stamp = remoteStamp else { return }
        let asset = assetName.isEmpty ? "XingmuISO.ipa" : assetName
        let direct = "https://github.com/\(Self.repo)/releases/download/\(Self.releaseTag)/\(asset)"
        let lc = URL(string:
            "livecontainer://install?url=\(direct.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? direct)")
        if let lc, UIApplication.shared.canOpenURL(lc) {
            UIApplication.shared.open(lc)
        } else {
            // 没装 LC：退回网页（下载 IPA / 查看安装说明）
            if let web = URL(string: "https://github.com/\(Self.repo)/releases/tag/\(Self.releaseTag)") {
                UIApplication.shared.open(web)
            }
        }
        _ = stamp
    }
}
