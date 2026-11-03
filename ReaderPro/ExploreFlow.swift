import SwiftUI

struct ExploreStyleKey: LayoutValueKey { static let defaultValue = ExploreStyle() }

// Separate measurement from row allocation so percent widths, grow, shrink and
// explicit row breaks can be verified without depending on a device's font.
enum ExploreFlowGeometry {
    static func widths(container: CGFloat, sizes: [CGSize], styles: [ExploreStyle], spacing: CGFloat = 6) -> [[(Int, CGFloat)]] {
        let width = max(1, container)
        var rows: [[(Int, CGFloat)]] = [], row: [(Int, CGFloat)] = []
        var used: CGFloat = 0
        func finish() {
            guard !row.isEmpty else { return }
            let remaining = width - used
            let grow = row.reduce(0.0) { $0 + styles[$1.0].grow }
            let shrink = row.reduce(0.0) { $0 + styles[$1.0].shrink * $1.1 }
            rows.append(row.map { index, size in
                if remaining >= 0 { return (index, size + (grow > 0 ? remaining * styles[index].grow / grow : 0)) }
                return (index, max(1, size + (shrink > 0 ? remaining * styles[index].shrink * size / shrink : 0)))
            })
            row = []; used = 0
        }
        for index in sizes.indices {
            let style = styles[index]
            var size = style.basisPercent >= 0 ? width * style.basisPercent : sizes[index].width
            size = max(1, size)
            if !row.isEmpty && (style.wrapBefore || used + spacing + size > width + 0.01) { finish() }
            // Android's children have a 3 dp margin on all sides. Percent
            // basis is measured before margins; growth/shrink includes them.
            used += spacing + size
            row.append((index, size))
        }
        finish()
        return rows
    }
}

struct CategoryFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(width: proposal.width ?? 320, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            let frame = layout.frames[index]
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                 proposal: ProposedViewSize(frame.size))
        }
    }
    private func positions(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let styles = subviews.map { $0[ExploreStyleKey.self] }
        let rows = ExploreFlowGeometry.widths(container: width, sizes: subviews.map { $0.sizeThatFits(.unspecified) }, styles: styles, spacing: spacing)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = spacing / 2
        for row in rows {
            let dimensions = row.map { subviews[$0.0].dimensions(in: ProposedViewSize(width: $0.1, height: nil)) }
            let baseline = dimensions.enumerated().filter { styles[row[$0.offset].0].alignSelf == "baseline" }.map { $0.element[.firstTextBaseline] }.max() ?? 0
            let height = dimensions.enumerated().map { offset, size in
                size.height + (styles[row[offset].0].alignSelf == "baseline" ? baseline - size[.firstTextBaseline] : 0)
            }.max() ?? 0
            var x: CGFloat = spacing / 2
            for (offset, item) in row.enumerated() {
                let size = dimensions[offset], alignment = styles[item.0].alignSelf
                let dy: CGFloat
                switch alignment {
                case "flex_end": dy = height - size.height
                case "center": dy = (height - size.height) / 2
                case "baseline": dy = baseline - size[.firstTextBaseline]
                default: dy = 0
                }
                frames[item.0] = CGRect(x: x, y: y + dy, width: item.1,
                                        height: alignment == "stretch" || alignment == "auto" ? height : size.height)
                x += item.1 + spacing
            }
            y += height + spacing
        }
        return (CGSize(width: width, height: subviews.isEmpty ? 0 : max(0, y - spacing / 2)), frames)
    }
}
