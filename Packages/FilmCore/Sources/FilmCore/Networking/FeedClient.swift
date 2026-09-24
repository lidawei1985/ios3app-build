import Foundation

/// 生产 feed 客户端（iOS 版）：
///  - 基址链逐个尝试（CDN → raw → LAN 调试），单基址短超时快速失败；
///  - manifest / home / 分片三类端点；
///  - 分片并发下载（信号量限流），失败分片重试，单分片失败不整体失败；
///  - 全程写 DataLedger 台账（§七 防缩水）。
public actor FeedClient {

    private let bases: FeedBases
    private let session: URLSession
    private let maxConcurrency = 6

    public init(bases: FeedBases) {
        self.bases = bases
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20      // 短超时：慢基址快速失败，切下一个
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    // MARK: - 基础请求

    private func getJSON(_ paths: [String]) async throws -> Data {
        var errors: [String] = []
        for path in paths {
            for url in bases.url(for: path) {
                do {
                    // 私有 feed 仓（夜航）：raw.githubusercontent 需带 token，否则 404
                    let data: Data
                    if let tok = bases.authToken {
                        var req = URLRequest(url: url)
                        req.setValue("token \(tok)", forHTTPHeaderField: "Authorization")
                        let (d, resp) = try await session.data(for: req)
                        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                            errors.append("\(url.host!):badStatus")
                            continue
                        }
                        data = d
                    } else {
                        let (d, resp) = try await session.data(from: url)
                        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                            errors.append("\(url.host!):badStatus")
                            continue
                        }
                        data = d
                    }
                    // FC 发布层 2026-09-20 起全仓 FCVB1 加密 → 先解密再交付（明文原样通过）
                    let raw = FeedBases.unwrapContents(data)
                    if let pt = FCVault.decryptIfEncrypted(raw) { return pt }
                    guard raw.starts(with: FCVault.magic) == false else {
                        // 密文但解不开（key 未注入/换钥）：按失败走下一 base，别把密文喂给 JSON 解码
                        errors.append("\(url.host!):FCVB1-undecryptable")
                        continue
                    }
                    return raw
                } catch {
                    errors.append("\(url.host!):\(error.localizedDescription)")
                }
            }
        }
        throw FilmError.allBasesFailed(errors)
    }

    /// manifest.json：唯一数量事实来源（count = SOURCE 级台账基准）。
    public func fetchManifest(mode: String) async throws -> FeedManifest {
        let data = try await getJSON(["/v1/feed/\(mode)/manifest.json"])
        do {
            let m = try FilmJSON.decoder().decode(FeedManifest.self, from: data)
            guard m.ok else { throw FilmError.decode("manifest.ok=false") }
            return m
        } catch let e as FilmError { throw e }
        catch { throw FilmError.decode("manifest: \(error.localizedDescription)") }
    }

    /// home.json 轻量首屏包（分类统计 + posters≤40 + pool≤500）。
    public func fetchHome(mode: String) async throws -> FeedHome {
        let data = try await getJSON(["/v1/feed/\(mode)/home.json"])
        do {
            let h = try FilmJSON.decoder().decode(FeedHome.self, from: data)
            guard h.ok else { throw FilmError.decode("home.ok=false") }
            return h
        } catch let e as FilmError { throw e }
        catch { throw FilmError.decode("home: \(error.localizedDescription)") }
    }

    /// 单分片（CDN 失败自动换下一基址；单分片失败上抛由调用方记账）。
    public func fetchPart(mode: String, name: String) async throws -> FeedPart {
        let data = try await getJSON(["/v1/feed/\(mode)/\(name)"])
        do {
            let p = try FilmJSON.decoder().decode(FeedPart.self, from: data)
            guard p.ok else { throw FilmError.decode("part.ok=false") }
            return p
        } catch let e as FilmError { throw e }
        catch { throw FilmError.decode("part \(name): \(error.localizedDescription)") }
    }

    /// persons.json 演员头像映射（演员名 → TMDB 头像 URL）。
    /// 2026-09-25 演员小头像（台账 247/258/288 行）：中台 TMDB credits 匹配产出；
    /// 文件未上线/为空前由调用方吞错（404/解码失败 = 空表，端上回退首字圆标）。
    public func fetchPersons(mode: String) async throws -> [String: String] {
        let data = try await getJSON(["/v1/feed/\(mode)/persons.json"])
        do {
            return try FilmJSON.decoder().decode([String: String].self, from: data)
        } catch {
            throw FilmError.decode("persons: \(error.localizedDescription)")
        }
    }

    // MARK: - 全量分片同步

    /// 并发拉取全部分片，逐片回调（含失败计数），返回合并 items。
    /// 语义：源返回多少就收多少，无 pages 上限假完成；MAX 护栏仅防内存溢出。
    public func fetchAllParts(mode: String,
                              manifest: FeedManifest,
                              progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [FeedItem] {
        let total = manifest.parts.count
        let semaphore = AsyncSemaphore(limit: maxConcurrency)
        let box = ResultBox()
        await withTaskGroup(of: Void.self) { group in
            var index = 0
            for part in manifest.parts {
                index += 1
                group.addTask { [weak self] in
                    guard let self else { return }
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    // 单分片 2 次重试；仍失败只记账（写入失败计数），不中断整体
                    var lastError: Error?
                    for _ in 0..<2 {
                        do {
                            let p = try await self.fetchPart(mode: mode, name: part)
                            await box.append(p.items)
                            lastError = nil
                            break
                        } catch { lastError = error }
                    }
                    if lastError != nil { await box.recordFailure() }
                    await box.tickProgress()
                    if let cb = progress {
                        let done = await box.doneCount
                        cb(done, total)
                    }
                }
            }
            await group.waitForAll()
        }
        let got = await box.items.count
        let failedParts = await box.failures
        FilmLog.i("FEED parts done: got=\(got) failedParts=\(failedParts)/\(total)")
        return await box.items
    }
}

/// 轻量异步信号量（限并发）。
final actor AsyncSemaphore {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit: Int
    private var current = 0
    init(limit: Int) { self.limit = max(1, limit) }

    func wait() async {
        if current < limit { current += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else if current > 0 {
            current -= 1
        }
    }
}

/// 分片合并结果箱（actor 内可变状态）。
final actor ResultBox {
    private(set) var items: [FeedItem] = []
    private(set) var failures = 0
    private(set) var doneCount = 0

    func append(_ new: [FeedItem]) { items.append(contentsOf: new) }
    func recordFailure() { failures += 1 }
    func tickProgress() { doneCount += 1 }
}
