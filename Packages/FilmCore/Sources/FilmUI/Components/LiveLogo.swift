import SwiftUI
import UIKit
import FilmCore

/// 直播频道台标（2026-10-01，与 TV 端星幕同一套）。
///
/// 数据源：直播表 `#EXTINF` 的 `tvg-logo`（星幕云端表 619/619 条均带），
/// 形如 `https://cdn.jsdelivr.net/gh/lidawei1985/filmcollector-logos@main/0001.png`
/// （0001 = roster chno 四位补零，与 TV 端共用同一份名册）。
///
/// 显示优先级：**包内台标 -> 远程 URL -> 序号兜底**。
/// 星幕包内随带 332 张（`LiveLogo/NNNN.png`，取自 TV 端同源台标库），
/// 所以 jsDelivr 不通 / 弱网 / 离线时照样有台标，远程仅作包内缺失时的补充。
struct LiveLogo: View {
    let channel: LiveChannel
    let index: Int
    var width: CGFloat = 34
    var height: CGFloat = 24

    @State private var bundled: UIImage?
    @State private var probed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.06))
            artwork
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onAppear(perform: probeBundled)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artwork: some View {
        if let img = bundled {
            Image(uiImage: img).resizable().scaledToFit().padding(2)
        } else if let url = channel.logo {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit().padding(2)
                case .failure:          fallback
                default:                Color.clear
                }
            }
        } else {
            fallback
        }
    }

    /// 序号兜底：没有台标也不留空白，保持原有「01 / 02」的视觉线索。
    private var fallback: some View {
        Text(String(format: "%02d", index))
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func probeBundled() {
        guard !probed else { return }
        probed = true
        guard let key = LiveLogos.key(for: channel.logo) else { return }
        bundled = Self.loadBundled(key)
    }

    /// 包内台标查找：XcodeGen 对 App 资源有「保留 LiveLogo 子目录」与「拍平到根」两种落地布局，两条都试。
    private static func loadBundled(_ key: String) -> UIImage? {
        for dir in ["LiveLogo", nil] as [String?] {
            if let p = Bundle.main.path(forResource: key, ofType: "png", inDirectory: dir),
               let img = UIImage(contentsOfFile: p) { return img }
        }
        return nil
    }
}
