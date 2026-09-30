import SwiftUI

/// 流式自动换行布局（chips 云用）。
/// iOS17 Layout 协议；子视图按测量宽度逐个排，排不下换行。
/// 用于：设置首屏「内置线路 / 点播源可视化」、源与线路新版页。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW {   // x>0 守卫：单条比容器宽时不死循环
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        let w = maxW == .infinity ? max(0, x - spacing) : maxW
        return CGSize(width: w, height: max(0, y + rowH - (rowH == 0 ? spacing : 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
