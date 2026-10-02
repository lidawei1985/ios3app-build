import Foundation
import CryptoKit

/// FilmCollector 发布层 FCVB1 信封解密（2026-09-21 补齐接线）。
///
/// 背景：发布层 2026-09-20 起全仓加密（fc_reencrypt_repo.py，方案B·B-3b）——
/// feed JSON（home.json/p*.json/manifest.json）与 live M3U 均为 FCVB1 密文。
/// 此前 iOS 端从未实现解密 → feed 同步与直播全靠本地快照硬撑（真机复现）。
///
/// 信封格式（与 E:/FilmCollector/adult_vault.py 对齐）：
///   "FCVB1"(5B) + 保留(1B) + nonce(12B) + AES-256-GCM 密文(含 16B tag)
/// 密钥：32B 原始字节的 base64，CI 以 secret 注入（同 FeedSecret token 模式）。
public enum FCVault {

    static let magic = Data("FCVB1".utf8)

    static var key: SymmetricKey? = {
        let b64 = FeedSecret.fcVaultKeyB64
        guard !b64.isEmpty, b64 != "__FC_VAULT_KEY_B64__",
              let raw = Data(base64Encoded: b64), raw.count == 32 else { return nil }
        return SymmetricKey(data: raw)
    }()

    /// FCVB1 密文 → 明文。非密文/未注入密钥/解密失败 → nil（调用方按明文处理）。
    public static func decryptIfEncrypted(_ data: Data) -> Data? {
        guard data.starts(with: magic), data.count > 6 + 12 + 16, let key else { return nil }
        // combined = nonce(12) + ciphertext + tag(16)，恰好从 offset 6 起
        guard let box = try? AES.GCM.SealedBox(combined: data.subdata(in: 6..<data.count)) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
