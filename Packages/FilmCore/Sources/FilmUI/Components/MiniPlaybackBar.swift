import SwiftUI
import FilmCore

/// 迷你播放条（大牌标配：离开播放页后底部悬浮条，一点回到上次看的位置）。
/// 挂在 MainTabView 底部，数据来自 `UserLibrary.history.first`（最近观看）。
public struct MiniPlaybackBar: View {
    let entry: UserLibrary.WatchEntry
    let onTap: () -> Void
    let onClose: () -> Void

    @Environment(\.filmTheme) private var theme

    public init(entry: UserLibrary.WatchEntry, onTap: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.entry = entry
        self.onTap = onTap
        self.onClose = onClose
    }

    private var progress: Double {
        guard entry.durationSeconds > 0 else { return 0 }
        return min(1, max(0, entry.progressSeconds / entry.durationSeconds))
    }

    public var body: some View {
        HStack(spacing: 10) {
            PosterImage(urlString: entry.item.bestPosterURL?.absoluteString)
                .frame(width: 40, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(progress > 0.01 ? "已看 \(Int(progress * 100))%" : "上次看到这里")
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.textSecondary.opacity(0.25))
                        Capsule().fill(theme.accent).frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 2)
            }

            Button(action: onTap) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("继续播放")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.textSecondary.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("继续播放 \(entry.item.title)")
    }
}
