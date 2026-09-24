import SwiftUI

/// 加载 / 空态 / 网络错误 + 重试（§十二：任何失败不得白屏）。
public struct LoadingView: View {
    let text: String
    public init(text: String = "正在加载…") { self.text = text }
    public var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.accentColor).controlSize(.large)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 首页骨架屏（大牌做法：首屏灰块占位 + 呼吸动画，比转圈更有"内容在路上"的确定感）。
public struct HomeSkeletonView: View {
    @Environment(\.filmTheme) private var theme
    @State private var pulse = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.card)
                    .aspectRatio(16/9, contentMode: .fit)
                    .padding(.horizontal, 16)
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.card)
                            .frame(width: 96, height: 16)
                            .padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(0..<5, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(theme.card)
                                        .frame(width: 104, height: 156)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .disabled(true)
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .opacity(pulse ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

public struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String?
    public init(icon: String = "film.stack", title: String, subtitle: String? = nil) {
        self.icon = icon; self.title = title; self.subtitle = subtitle
    }
    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

public struct ErrorStateView: View {
    let message: String
    let retry: () -> Void
    public init(message: String, retry: @escaping () -> Void) {
        self.message = message; self.retry = retry
    }
    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 44)).foregroundStyle(.orange)
            Text("网络不给力").font(.headline)
            Text(message).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(3)
            Button {
                retry()
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 28).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// 后台全量同步进度胶囊（首页顶部；同步中显示，结束自动消失）。
public struct SyncBadge: View {
    let progress: Int?
    let total: Int?
    public init(progress: Int?, total: Int?) {
        self.progress = progress; self.total = total
    }
    public var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(progressText).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }
    private var progressText: String {
        if let p = progress, let t = total { return "片库同步 \(p)/\(t)" }
        return "片库同步中…"
    }
}
