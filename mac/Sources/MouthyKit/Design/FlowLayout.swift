import SwiftUI

/// Wraps chips onto as many lines as they need, left aligned.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    /// Greedy line breaking: a subview starts a new row when it would overflow `width`.
    func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        arrange(width: width, sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func arrange(width: CGFloat, sizes: [CGSize]) -> [Row] {
        var rows: [Row] = [], current = Row()
        for (index, size) in sizes.enumerated() {
            let extra = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if extra > width, !current.indices.isEmpty {
                rows.append(current); current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
