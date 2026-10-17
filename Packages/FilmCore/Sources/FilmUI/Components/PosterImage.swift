import SwiftUI
import ImageIO      // 10-01：CGImageSource 降采样（ImageIO 不由 SwiftUI/UIKit 透传，必须显式导入）
import FilmCore     // v76.1：LiveDiag / MainThreadMark 取证

/// 海报图片加载器：内存缓存（NSCache）→ 磁盘缓存 → 网络下载（一次重试）→ 占位图。
/// 铁律（§十）：失败 = 占位图，绝不因图片失败让内容消失。
public final class PosterLoader {

    public static let shared = PosterLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let diskDir: URL
    private let session: URLSession
    private let inflight = NSLock()
    private var inflightTasks: [String: Task<Data?, Never>] = [:]
    /// 35包：主视觉 15 张打进 APK（hbn_manifest.json：海报URL→包内文件名），打开就有，不依靠网络
    /// 做成 **static let**（懒加载 + `swift_once`，天然线程安全）而不是纯实例属性：
    /// 主视觉选片跑在后台 `Task.detached`（见 `HomeView.computeShelves`），要判「这张图有没有
    /// 包内高清素材」，不该为了读一份不可变清单去实例化 `shared`。
    static let bundledManifest: [String: String] = loadBundledManifest()
    private let bundled: [String: String] = PosterLoader.bundledManifest

    /// 显示档位（10-01 P0「海报越来越糊」根修 + 主人钦定「主视觉=门面必须高清」）：
    /// 之前**所有图一律压到 600px** —— 海报格（120×180pt）够用，但主视觉/详情页头图是
    /// **满屏大图**（屏宽 430pt × 3x ≈ 1290px，详情页还 scale 1.26），压到 600 必糊。
    /// 现在按用途分档：
    ///   • `gridMaxSide = 600`：海报格/小图，够用即可（省内存、省解码时间）
    ///   • `heroMaxSide  = 0`：主视觉与详情页头图 —— **0 = 原图不降采样**（门面恒高清），
    ///     只做后台解码（ShouldCacheImmediately），不损失一个像素。
    public static let gridMaxSide: CGFloat = 600
    public static let heroMaxSide: CGFloat = 0

    init() {
        // 10-01 卡顿根修：原来只限「张数 600」——600 张**原尺寸**海报（常见 800×1200，解码后
        // 每张约 3.8MB）常驻内存 ≈ 2GB，内存压力下系统反复回收/重解码，滑动与点击都被拖住。
        // 改成「张数 + 总字节」双重上限，并按**显示所需尺寸**降采样入库（见 `thumb`）。
        memory.countLimit = 400
        memory.totalCostLimit = 96 << 20          // 96MB：够铺满十几屏，超了自动淘汰最久未用
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // 10-01 P0：旧目录 `posters` 里存的已经是「压到 600px + JPEG 0.82」的糊图
        //（旧 saveDisk 把降采样后的 UIImage 再压一遍存盘）→ 换 v2 目录存**原图**，
        // 旧目录后台清掉，否则用户磁盘里那批糊图会被一直命中，看着像"越用越糊"。
        let dir = base.appendingPathComponent("posters_v2", isDirectory: true)
        let legacy = base.appendingPathComponent("posters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        diskDir = dir
        Task.detached(priority: .background) { try? FileManager.default.removeItem(at: legacy) }
        let cfg = URLSessionConfiguration.default
        // 34包提速：超时 15→8s（慢图快速失败落占位，不堵整面墙）；每 host 并发 6→12（60 张墙排队减半）
        cfg.timeoutIntervalForRequest = 8
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20, directory: dir)
        session = URLSession(configuration: cfg)
        primeBundledToDisk()
    }

    /// 35包双通道资源查找：XcodeGen 对 `sources: - Apps/Xingmu` 目录的资源落地位置
    /// 有两种可能（bundle 根 或 保留 HeroBundled 子目录），此处**两条都试**，
    /// 不赌 CI 的目录布局（实测哪个命中都行）。
    static func bundledResourcePath(name: String, ext: String) -> String? {
        if let p = Bundle.main.path(forResource: name, ofType: ext) { return p }
        if let p = Bundle.main.path(forResource: name, ofType: ext, inDirectory: "HeroBundled") { return p }
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "HeroBundled"),
           FileManager.default.fileExists(atPath: u.path) { return u.path }
        return nil
    }

    private static func loadBundledManifest() -> [String: String] {
        var data: Data?
        if let u = Bundle.main.url(forResource: "hbn_manifest", withExtension: "json"),
           let d = try? Data(contentsOf: u) {
            data = d
        } else if let p = bundledResourcePath(name: "hbn_manifest", ext: "json"),
                  let d = try? Data(contentsOf: URL(fileURLWithPath: p)) {
            data = d
        }
        guard let d = data, let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }

    private func bundledImage(_ key: String) -> UIImage? {
        guard let fn = bundled[key] else { return nil }
        let name = (fn as NSString).deletingPathExtension
        let ext = (fn as NSString).pathExtension
        guard let p = PosterLoader.bundledResourcePath(name: name, ext: ext) else { return nil }
        return UIImage(contentsOfFile: p)
    }

    // MARK: - 主视觉高清判据（2026-10-03 主人钦定「高清 / 不使用低质量」的机器可查化）

    /// 这张海报是否已有**包内高清素材**（`hbn_*.jpg`）。**静态**：只读不可变清单，可从任意线程调用
    /// （主视觉选片跑在后台 `Task.detached` 里，不该为一次判据去碰 `shared` 实例）。
    ///
    /// 为什么这是「不使用低质量」的第一信号：
    ///  主视觉要的是 ≥1280px 门面图，而 feed 里大量海报来自 CMS 源站图床
    ///  （`img.bfzypic.com` / `img.picbf.com` / `suboimage.com` …），实测**仅 270px**
    ///  （既有台账原文：「feed 自带图床 img.bfzypic.com 仅 270px，用户红线 hero≥1280 高清」）。
    ///  靠域名判质量是错的——采集器正是把这些图床的图**升级成了 ≥1280 的包内素材**，
    ///  所以唯一可靠的第一信号是「这张 URL 在包内清单里有没有」。
    ///  有 = 天生高清 + 离线可显示（打开就有，不等网络）。
    public static func hasBundledHD(_ url: URL?) -> Bool {
        guard let s = url?.absoluteString, !s.isEmpty else { return false }
        return bundledManifest[s] != nil
    }

    /// 已知高清**网络**图源（包内素材没覆盖到的那些，仍要能判高清）。
    ///
    /// 口径（窄而硬，宁可判不出高清也不误判）：
    ///  · TMDB：`/t/p/original/` 原图，或 `/w<数字>/` 且宽 ≥ 780（w780 / w1280 / w1920）；
    ///  · Amazon：`_UX<数字>_` 且宽 ≥ 1000（如 `_UX1200_`）。
    /// 其余一律返回 false —— 未知图床不冒充高清，交由调用方落到次级排序，
    /// 而不是在这里猜（猜错就等于把 270px 的糊图摆上主视觉，正是用户要杜绝的）。
    public static func isKnownHDNetwork(_ url: URL?) -> Bool {
        guard let s = url?.absoluteString.lowercased(), !s.isEmpty else { return false }
        if s.contains("image.tmdb.org") {
            if s.contains("/original/") { return true }
            guard let r = s.range(of: "/w") else { return false }
            let digits = s[r.upperBound...].prefix(4).prefix(while: { $0.isNumber })
            return (Int(digits) ?? 0) >= 780
        }
        if s.contains("media-amazon.com") {
            guard let r = s.range(of: "_ux") else { return false }
            let digits = s[r.upperBound...].prefix(5).prefix(while: { $0.isNumber })
            return (Int(digits) ?? 0) >= 1000
        }
        return false
    }

    /// 合成判据：包内高清 **或** 已知高清网络图源（主视觉门面用）。
    public static func isHighRes(_ url: URL?) -> Bool {
        hasBundledHD(url) || isKnownHDNetwork(url)
    }

    /// 落磁盘缓存（35包原则：包内 hero 直接写进磁盘缓存，网络只做后台静默更新）
    private func primeBundledToDisk() {
        let map = bundled
        guard !map.isEmpty else { return }
        let dir = diskDir
        Task.detached(priority: .background) {
            for (url, fn) in map {
                let name = (fn as NSString).deletingPathExtension
                let ext = (fn as NSString).pathExtension
                guard let src = PosterLoader.bundledResourcePath(name: name, ext: ext) else { continue }
                let dst = dir.appendingPathComponent(PosterLoader.stableDigest(url))
                if !FileManager.default.fileExists(atPath: dst.path) {
                    try? FileManager.default.copyItem(atPath: src, toPath: dst.path)
                }
            }
        }
    }

    /// 跨启动稳定的摘要（35包根修：Swift hashValue 每次启动随机化 → 旧磁盘缓存键全废，
    /// 每次冷启动全部重新下载 = 「海报每次打开都慢」的隐藏根因；改 FNV-1a 持久键）
    static func stableDigest(_ s: String) -> String {
        var h: UInt64 = 14695981039346656037
        for b in s.utf8 { h ^= UInt64(b); h = h &* 1099511628211 }
        return String(h, radix: 16)
    }

    /// 取图（按显示档位解码：海报格 600px / 主视觉原图）。
    /// - Parameter maxSide: 目标最长边像素；**<=0 表示原图不降采样**（主视觉门面专用）。
    public func image(for urlString: String?, thumbPriority: Bool = false,
                      maxSide: CGFloat = PosterLoader.gridMaxSide) async -> UIImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        let key = urlString
        // 内存键带档位：同一张图小格/大图各存一份解码结果（磁盘只存一份原图，不重复下载）
        let memKey = PosterLoader.memKey(key, maxSide)
        if let hit = memory.object(forKey: memKey as NSString) { return hit }
        // ★ v76.1 取证：下面三段（包内解码 / 磁盘读+解码 / 降采样）都是**同步阻塞**。
        //   async 函数不保证离开了调用方所在线程 —— 若调用点在 @MainActor（如 HeroTintStore /
        //   SwiftUI 视图 .task），这几段就可能整段压在主线程上，而主视觉走的是 **原图档 maxSide=0**。
        //   黑匣子里出现「取图·主线程=true 段=Nms maxSide=0」即为主线程卡顿的实锤。
        let t0 = Date()
        // 只记**主线程**动作（环的语义 = 主线程动作链；后台预热的标注会把窗口信息搅浑）
        if Thread.isMainThread {
            MainThreadMark.set("取图 maxSide=\(Int(maxSide)) url=…\(key.suffix(20))")
        }
        func mark(_ seg: String) {
            let ms = Int(-t0.timeIntervalSinceNow * 1000)
            guard ms >= 15 else { return }      // <15ms 不值得记（避免刷掉黑匣子里真正重要的行）
            LiveDiag.write("取图·主线程=\(Thread.isMainThread) 段=\(ms)ms maxSide=\(Int(maxSide)) hit=\(seg) url=…\(key.suffix(26))")
        }
        // 35包：包内 hero 清单命中即秒出（先于磁盘/网络）—— 包内是原图，门面天然高清
        if let b = bundledImage(key) {
            remember(b, memKey)
            mark("bundle")
            return b
        }
        // 磁盘存的是**原图数据**，这里按本次档位解码（不再"盘里就是糊的"）
        if let data = diskData(key), let img = PosterLoader.thumb(from: data, maxSide: maxSide) {
            remember(img, memKey)
            mark("disk")
            return img
        }
        // 走到网络 → 只记「同步段」耗时（不含网络等待，避免淹没有用信息）
        let syncMs = Int(-t0.timeIntervalSinceNow * 1000)
        if syncMs >= 30 {
            LiveDiag.write("取图·同步段 主线程=\(Thread.isMainThread) 段=\(syncMs)ms maxSide=\(Int(maxSide)) hit=miss→net url=…\(key.suffix(26))")
        }
        // 去重并发请求（同一 URL 只下一次，各档位共用同一份原始数据）
        inflight.lock()
        if let existing = inflightTasks[key] {
            inflight.unlock()
            guard let data = await existing.value else { return nil }
            let img = PosterLoader.thumb(from: data, maxSide: maxSide)
            if let img { remember(img, memKey) }
            return img
        }
        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            defer {
                self.inflight.lock(); self.inflightTasks[key] = nil; self.inflight.unlock()
            }
            var data = await self.downloadData(urlString)
            // 重试退避（2026-09-21 增强：弱网/拥塞场景 1→3 轮；被墙 IP 重试仍失败则落占位）
            for backoff in [400_000_000.0, 2_000_000_000.0] where data == nil {
                try? await Task.sleep(nanoseconds: UInt64(backoff))
                data = await self.downloadData(urlString)
            }
            // 10-01 P0：磁盘**存原始数据**（旧实现把降采样后的 UIImage 再压 JPEG 0.82 存盘，
            // 等于"永久降质"——这就是越用越糊的第二根因）。
            if let data { self.saveDisk(key, data) }
            return data
        }
        inflightTasks[key] = task
        inflight.unlock()
        guard let data = await task.value else { return nil }
        guard let img = PosterLoader.thumb(from: data, maxSide: maxSide) else { return nil }
        remember(img, memKey)
        return img
    }

    /// 内存键（档位区分，避免"大图被小图的缓存顶掉"或反过来）
    static func memKey(_ url: String, _ maxSide: CGFloat) -> String {
        maxSide <= 0 ? url + "#full" : url + "#" + String(Int(maxSide))
    }

    private func downloadData(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        for _ in 0..<2 {
            if let (data, resp) = try? await session.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                return data
            }
        }
        return nil
    }

    /// 入库（带字节成本，交给 NSCache 按内存量淘汰）。
    private func remember(_ img: UIImage, _ key: String) {
        let cost = Int(img.size.width * img.size.height * 4)
        memory.setObject(img, forKey: key as NSString, cost: max(1, cost))
    }

    /// 降采样成显示所需尺寸（10-01 卡顿根修）。
    ///
    /// 原实现直接 `UIImage(data:)`：拿到的**原图**往往是 800~1200px 宽，而海报格实际只画
    /// 120×180pt（2x 也才 240×360）。多出来的像素有两个坏处：
    ///  ① 内存成倍膨胀（见 `init` 的 `totalCostLimit` 注释）；
    ///  ② `UIImage` 是**懒解码**——真正解码发生在 SwiftUI 渲染它的那一刻，也就是**主线程**，
    ///     一张大图解几十毫秒，海报墙一屏几十张就是几百毫秒的卡顿（用户报「海报点完半天才出现」）。
    /// 这里用 ImageIO 直接出缩略图并 `ShouldCacheImmediately`，解码在**后台线程**一次做完，
    /// 落到 SwiftUI 手里时已是「可直接画的小图」。
    static func thumb(from data: Data, maxSide: CGFloat = 600) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        // 门面档（maxSide <= 0）：**不降采样**，只强制后台立即解码 —— 主视觉一个像素都不许丢。
        if maxSide <= 0 {
            let opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            if let cg = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) {
                return UIImage(cgImage: cg)
            }
            return UIImage(data: data)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }

    /// 首屏预热（34包）：catalog 就绪后后台把主视觉/首屏货架海报先拉进缓存，
    /// 用户滑到时直接命中内存/磁盘，不再「转圈等图」。后台低优先级、串行慢拉，不抢前台带宽。
    public func prefetch(_ urlStrings: [String], limit: Int = 24) {
        let urls = Array(urlStrings.prefix(limit))
        guard !urls.isEmpty else { return }
        Task.detached(priority: .background) { [weak self] in
            for u in urls {
                guard let self else { return }
                _ = await self.image(for: u)
            }
        }
    }

    private func diskURL(_ key: String) -> URL {
        // 35包：跨启动稳定键（原 hashValue 随机化导致磁盘缓存跨启动全废）
        return diskDir.appendingPathComponent(PosterLoader.stableDigest(key))
    }
    private func diskData(_ key: String) -> Data? {
        // 磁盘里是原图数据，解码按调用方档位进行（见 `image(for:maxSide:)`）
        return try? Data(contentsOf: diskURL(key))
    }
    private func saveDisk(_ key: String, _ data: Data) {
        // 原样落盘，不重编码（JPEG 重压 = 永久降质，10-01 P0）
        try? data.write(to: diskURL(key), options: .atomic)
    }
}

/// 海报视图：加载中占位（轻微呼吸动画）→ 成图渐显；失败显示占位图标与片名首字，不空白。
public struct PosterImage: View {
    let urlString: String?
    var cornerRadius: CGFloat = 8
    var contentMode: SwiftUI.ContentMode = .fill
    /// 显示档位：**0 = 原图不降采样**（主视觉 / 详情页头图，门面恒高清）；默认 600（海报格）
    var maxSide: CGFloat = PosterLoader.gridMaxSide

    @State private var image: UIImage?
    @State private var failed = false

    public init(urlString: String?, cornerRadius: CGFloat = 8,
                contentMode: SwiftUI.ContentMode = .fill,
                maxSide: CGFloat = PosterLoader.gridMaxSide) {
        self.urlString = urlString
        self.cornerRadius = cornerRadius
        self.contentMode = contentMode
        self.maxSide = maxSide
    }

    public var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .clipped()
        .cornerRadius(cornerRadius)
        .task(id: urlString) {
            failed = false
            image = await PosterLoader.shared.image(for: urlString, thumbPriority: true, maxSide: maxSide)
            if image == nil { failed = true }
        }
    }

    private var placeholder: some View {
        Rectangle()
            // 2026-09-23 用户：「货架背景颜色能不能透明化」——旧值 #1C2230 是实色，
            //  会挡住整页取色背景、在货架上糊出一块块深色砖。改半透明玻璃，透出海报取色底。
            .fill(Color.white.opacity(0.07))
            .overlay(
                Group {
                    if failed {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.28))
                    } else {
                        ProgressView().tint(.white.opacity(0.3))
                    }
                }
            )
    }
}
