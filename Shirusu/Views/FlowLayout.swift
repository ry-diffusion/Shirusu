import SwiftUI

/// Lays subviews out left to right, wrapping like text.
///
/// The transcript needs each word to be its own view so it can animate
/// independently, which rules out a single `Text`. This is what puts those views
/// back into something that reads as a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 10

    struct Cache {
        var width: CGFloat = -1
        var rows: [Row] = []
        var height: CGFloat = 0
    }

    struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
        var y: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.width = -1  // force a re-measure when the contents change
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? .infinity
        layout(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: proposal.width ?? contentWidth(subviews), height: cache.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) {
        layout(width: bounds.width, subviews: subviews, cache: &cache)

        for row in cache.rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
        }
    }

    private func layout(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width else { return }
        cache.width = width
        cache.rows = []

        var row = Row()
        var x: CGFloat = 0
        var y: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, x + size.width > width {
                row.y = y
                cache.rows.append(row)
                y += row.height + lineSpacing
                row = Row()
                x = 0
            }
            row.indices.append(index)
            row.height = max(row.height, size.height)
            x += size.width + spacing
        }

        if !row.indices.isEmpty {
            row.y = y
            cache.rows.append(row)
            y += row.height
        }

        cache.height = y
    }

    private func contentWidth(_ subviews: Subviews) -> CGFloat {
        subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
    }
}
