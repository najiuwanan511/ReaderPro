import SwiftUI

struct ExploreStyleKey: LayoutValueKey { static let defaultValue = ExploreStyle() }

// Separate measurement from row allocation so percent widths, grow, shrink and
// explicit row breaks can be verified without depending on a device's font.
enum ExploreFlowGeometry {
    // item_find_book.xml: Flexbox padding 3 dp, child margin 3 dp and an
    // 8 dp middle divider in both directions (shape_space_divider.xml).
    static let padding: CGFloat = 3
    static let margin: CGFloat = 3
    static let divider: CGFloat = 8

    static func widths(container: CGFloat, sizes: [CGSize], styles: [ExploreStyle]) -> [[(Int, CGFloat)]] {
        let width = max(1, container)
        var rows: [[(Int, CGFloat)]] = [], row: [(Int, CGFloat)] = []
        var used: CGFloat = 2 * padding
        func finish() {
            guard !row.isEmpty else { return }
            let remaining = width - used
            let grow = row.reduce(0.0) { $0 + styles[$1.0].grow }
            let shrink = row.reduce(0.0) { $0 + styles[$1.0].shrink }
            rows.append(row.map { index, size in
                if remaining >= 0 { return (index, size + (grow > 0 ? remaining * styles[index].grow / grow : 0)) }
                // Android Flexbox 3.0 distributes by the shrink factor,
                // without the CSS browser's additional basis-width weighting.
                return (index, max(0, size + (shrink > 0 ? remaining * styles[index].shrink / shrink : 0)))
            })
            row = []; used = 2 * padding
        }
        for index in sizes.indices {
            let style = styles[index]
            let naturalWidth = min(sizes[index].width, max(0, width - 2 * (padding + margin)))
            let size = max(0, style.basisPercent >= 0 ? width * style.basisPercent : naturalWidth)
            if !row.isEmpty && (style.wrapBefore || used + divider + 2 * margin + size > width + 0.01) { finish() }
            used += (row.isEmpty ? 0 : divider) + 2 * margin + size
            row.append((index, size))
        }
        finish()
        return rows
    }
}

struct CategoryFlow: Layout {

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
        let rows = ExploreFlowGeometry.widths(container: width, sizes: subviews.map { $0.sizeThatFits(.unspecified) }, styles: styles)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        let padding = ExploreFlowGeometry.padding, margin = ExploreFlowGeometry.margin, divider = ExploreFlowGeometry.divider
        var y = padding + margin
        for row in rows {
            let dimensions = row.map { subviews[$0.0].dimensions(in: ProposedViewSize(width: $0.1, height: nil)) }
            let baseline = dimensions.enumerated().filter { styles[row[$0.offset].0].alignSelf == "baseline" }.map { $0.element[.firstTextBaseline] }.max() ?? 0
            let height = dimensions.enumerated().map { offset, size in
                size.height + (styles[row[offset].0].alignSelf == "baseline" ? baseline - size[.firstTextBaseline] : 0)
            }.max() ?? 0
            var x = padding + margin
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
                x += item.1 + 2 * margin + divider
            }
            y += height + 2 * margin + divider
        }
        return (CGSize(width: width, height: subviews.isEmpty ? 0 : max(0, y - divider - margin + padding)), frames)
    }
}
