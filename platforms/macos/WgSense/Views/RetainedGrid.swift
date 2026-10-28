import SwiftUI

// A flat collection keeps each item's SwiftUI identity when it moves between rows.
// No snapshots, guessed text heights, width quantization, or delayed reflow.
struct GridItemSpec: Equatable {
    var span: Int
    var fullWidth = false
    var height: CGFloat? = nil
}

struct GridPlacement: Equatable {
    var indices: [Int]
    var spans: [Int]
}

enum GridGeometry {
    static let gap: CGFloat = 8
    static let minimum: CGFloat = 112

    static func columns(_ width: CGFloat) -> Int {
        max(1, Int((max(1, width) + gap) / (minimum + gap)))
    }

    static func pack(_ specs: [GridItemSpec], columns: Int) -> [GridPlacement] {
        var result: [GridPlacement] = []
        var row = GridPlacement(indices: [], spans: [])
        var used = 0
        for (index, spec) in specs.enumerated() {
            let span = spec.fullWidth ? columns : min(columns, max(1, spec.span))
            if used + span > columns, !row.indices.isEmpty {
                result.append(row); row = GridPlacement(indices: [], spans: []); used = 0
            }
            row.indices.append(index); row.spans.append(span); used += span
            if used == columns {
                result.append(row); row = GridPlacement(indices: [], spans: []); used = 0
            }
        }
        if !row.indices.isEmpty { result.append(row) }
        return result
    }

    static func frames(width: CGFloat, rows: [GridPlacement], measure: (Int, CGFloat) -> CGFloat) -> [Int: CGRect] {
        let count = columns(width)
        let cell = (width - CGFloat(count - 1) * gap) / CGFloat(count)
        var frames: [Int: CGRect] = [:]
        var y: CGFloat = 0
        for row in rows {
            var x: CGFloat = 0
            var height: CGFloat = 0
            for (index, span) in zip(row.indices, row.spans) {
                let w = cell * CGFloat(span) + gap * CGFloat(span - 1)
                let h = measure(index, w)
                frames[index] = CGRect(x: x, y: y, width: w, height: h)
                height = max(height, h); x += w + gap
            }
            y += height + gap
        }
        return frames
    }
}

struct RetainedGrid: Layout {
    var specs: [GridItemSpec]

    struct Cache {
        var columns = 0
        var specs: [GridItemSpec] = []
        var rows: [GridPlacement] = []
        var width: CGFloat?
        var frames: [Int: CGRect] = [:]
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Text, font, locale, controls and content changes must invalidate measurements.
        // Retain only row membership, which depends on the item specs and column count.
        cache.width = nil
    }

    private func resolve(_ width: CGFloat, subviews: Subviews, cache: inout Cache) {
        let columns = GridGeometry.columns(width)
        if cache.columns != columns || cache.specs != specs {
            cache.columns = columns; cache.specs = specs
            cache.rows = GridGeometry.pack(specs, columns: columns)
            cache.width = nil
        }
        guard cache.width != width else { return }
        cache.frames = GridGeometry.frames(width: width, rows: cache.rows) { index, itemWidth in
            specs[index].height ?? subviews[index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height
        }
        cache.height = cache.frames.values.map(\.maxY).max() ?? 0
        cache.width = width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = max(1, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 360)
        resolve(width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        // Reuse the exact result of sizeThatFits, including real wrapped-text heights.
        resolve(bounds.width, subviews: subviews, cache: &cache)
        for (index, frame) in cache.frames {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
