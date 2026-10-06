import Foundation

/// 双产品身份档案。两款 App 各自持有一个静态实例；共享核心，身份/内容池/品牌严格独立。
/// 铁律：不在此处做任何内容分类判断；FeedCollector 是唯一分类事实来源。
public struct ProductProfile: Sendable {
    public let appName: String          // 展示名（保持现有品牌，不擅自改名）
    public let logoName: String         // 顶部英文 LOGO 字标（奈飞式纯英文 wordmark）
    public let mode: String             // normal / child / adult（与 feed 目录一致）
    public let feedRepo: String         // filmcollector-pages-{xingmu|xinwu}
    public let accentColorHex: String
    public let liveM3UPath: String?     // 心屋无直播（生产现状 2026-09-16 已摘直播入口）
    public let tagline: String
    public let requiresAuth: Bool       // true = feed 仓为私有（成人内容仓库级门禁），走 token 鉴权通道

    public init(appName: String, logoName: String, mode: String, feedRepo: String,
                accentColorHex: String, liveM3UPath: String?, tagline: String,
                requiresAuth: Bool = false) {
        self.appName = appName
        self.logoName = logoName
        self.mode = mode
        self.feedRepo = feedRepo
        self.accentColorHex = accentColorHex
        self.liveM3UPath = liveM3UPath
        self.tagline = tagline
        self.requiresAuth = requiresAuth
    }

    public static let xingmu = ProductProfile(
        appName: "星幕", logoName: "STARSCREEN", mode: "normal",
        feedRepo: "filmcollector-pages-xingmu",
        accentColorHex: "#E8443A",
        // ★ 2026-10-02 主人钦定「直播表各用各的，免得弄完别人的不能用」：
        //   星幕读**自己的** `v1/live/xingmu.m3u`（作者 = ios_ctrl/live_refresh_xingmu.py）。
        //   曾经读的是 `v1/live/normal.m3u` —— 那是 **TV/安卓三端**的表
        //   （云端 live-build.yml 按 TV 名册每 6h 重写、只补不换；安卓 LiveCatalog 6 条 URL 全指它）。
        //   共用一张表的后果：TV 一改 iOS 就跟着变、iOS 一改 TV 就挂；
        //   且 TV 口径（只补不换）会把 iOS 端的死线永远留着 → 起播常撞死线。
        liveM3UPath: "/v1/live/xingmu.m3u",
        tagline: "海量影视 · 每日更新")

    public static let xinwu = ProductProfile(
        appName: "心屋", logoName: "KIDNEST", mode: "child",
        feedRepo: "filmcollector-pages-xinwu",
        accentColorHex: "#F5A623",
        liveM3UPath: nil,               // 生产现状：心屋无直播
        tagline: "孩子的专属小影院")

    /// 双产品静态注册表（供测试校验隔离，不用于运行时切换身份）。
    /// 2026-10-05：第三端（成人流 App）已彻底下线删除，只保留星幕 / 心屋。
    public static let all: [ProductProfile] = [.xingmu, .xinwu]
}

/// feed 拉取链路（对应 Android 端 FEED_BASES 顺序，移动端裁剪）：
/// jsDelivr CDN（墙内可达）→ raw.githubusercontent（墙外兜底）→ 局域网加速（可选，调试）。
/// 顺序治理原因与 Android 端一致：LAN 无服务时快速失败不阻塞，raw 墙内常超时只作最后兜底。
public struct FeedBases: Sendable {
    public let bases: [String]
    /// 私有仓鉴权令牌（构建期注入 FeedSecret，见 FeedSecret.swift；nil/空 = 公开仓无需鉴权）
    public let authToken: String?

    public init(profile: ProductProfile, lanBase: String? = nil) {
        var b: [String] = []
        if let lan = lanBase { b.append(lan) }                     // 调试通道（adb/reverse 或同局域网）
        // v73（2026-10-05 真机黑匣子铁证「保鲜·api.github.com HTTP 401」）：
        // CI build-ipa.yml 只注入 FC_VAULT_KEY，星幕/心屋包里 feedToken 仍是
        // 占位符 "__FEED_TOKEN_PLACEHOLDER__"（非空！）→ 被当真 token 发给
        // api.github.com → 401 → 远端直播表三基址全灭 → LiveCache 永远不生成
        // → 手机永远吃不到新表（feed 活着纯靠 fastly 忽略 Auth 头）。
        // 占位符（双下划线包裹）一律视为未注入。
        let rawTok = FeedSecret.feedToken
        let token: String? = (rawTok.isEmpty || rawTok.hasPrefix("__")) ? nil : rawTok
        if profile.requiresAuth {
            // 私有仓：jsDelivr 不服务私有内容。
            // 主通道 = api.github.com contents（国内实测稳定直连；raw 在国内常被墙），
            // 兜底 = raw + token（墙外网络可用）。
            b.append("https://api.github.com/repos/lidawei1985/\(profile.feedRepo)/contents")
            b.append("https://raw.githubusercontent.com/lidawei1985/\(profile.feedRepo)/main")
            authToken = token
        } else {
            // 公开仓：jsDelivr 国内近期不稳 → api.github.com contents 作中继。
            // 同样注入 token：匿名 api.github.com 限额 60 次/时/IP 极易烧光（2026-09-20 真机复现），
            // 带 token 提至 5000/h；LiveLoader 仅对 github.com 域带此头，jsDelivr 不受影响。
            b.append("https://fastly.jsdelivr.net/gh/lidawei1985/\(profile.feedRepo)@main")
            b.append("https://api.github.com/repos/lidawei1985/\(profile.feedRepo)/contents")
            b.append("https://raw.githubusercontent.com/lidawei1985/\(profile.feedRepo)/main")
            authToken = token
        }
        bases = b
    }

    public func url(for path: String) -> [URL] {
        bases.compactMap { URL(string: $0 + path) }
    }

    /// api.github.com contents 通道返回 {"content": <base64>}（raw 直接是字节）——统一解包。
    /// 非 contents 响应（无 content 字段）原样返回。
    public static func unwrapContents(_ data: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["encoding"] as? String == "base64",
              let b64 = obj["content"] as? String,
              let raw = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: ""),
                             options: [.ignoreUnknownCharacters]) else {
            return data
        }
        return raw
    }
}

/// 构建期注入的 feed 访问凭据（CI 用 Actions Secret 覆写本文件，令牌不进源码仓历史之外的任何地方）。
/// 本仓为私有仓；若 IPA 泄露应立即在 GitHub 撤销该 fine-grained/classic token。
public enum FeedSecret {
    public static let feedToken: String = "__FEED_TOKEN_PLACEHOLDER__"
    /// FC 发布层全仓加密密钥（32B 原始字节的 base64）；CI 以 FC_VAULT_KEY secret 注入。
    /// 未注入 = feed/live 密文不可解，App 落快照兜底（2026-09-21 接线 FCVault）。
    public static let fcVaultKeyB64: String = "__FC_VAULT_KEY_B64__"

    /// 构建指纹：CI 把「实际检出的提交短 SHA」写进来，打包后**回读产物二进制断言此串存在**。
    ///
    /// 存在意义（2026-09-23 事故机器判据）：当天出现「代码在仓里、但真机上跑的还是旧界面」，
    /// 光看"构建成功"完全查不出来。有了它，任何缓存复用 / 检错 ref / 旧产物冒充新产物
    /// 都会在打包阶段当场红灯，而不是等用户装到手机上才发现。
    /// 本地直接编译时保持占位串，不影响任何运行逻辑。
    public static let buildStamp: String = "__BUILD_STAMP__"
}
