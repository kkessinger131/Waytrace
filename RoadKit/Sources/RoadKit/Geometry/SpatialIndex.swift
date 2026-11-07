import Foundation

public struct BBox: Hashable, Sendable {
    public var minX, minY, maxX, maxY: Double

    public init(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    public init(points: [XY]) {
        var b = BBox(.infinity, .infinity, -.infinity, -.infinity)
        for p in points {
            b.minX = min(b.minX, p.x); b.minY = min(b.minY, p.y)
            b.maxX = max(b.maxX, p.x); b.maxY = max(b.maxY, p.y)
        }
        self = b
    }

    public func intersects(_ o: BBox) -> Bool {
        minX <= o.maxX && o.minX <= maxX && minY <= o.maxY && o.minY <= maxY
    }

    public func union(_ o: BBox) -> BBox {
        BBox(min(minX, o.minX), min(minY, o.minY), max(maxX, o.maxX), max(maxY, o.maxY))
    }

    public func expanded(by d: Double) -> BBox { BBox(minX - d, minY - d, maxX + d, maxY + d) }

    var center: XY { XY((minX + maxX) / 2, (minY + maxY) / 2) }
}

/// A packed (sort-tile-recursive) R-tree over bounding boxes, the same structure
/// Shapely's STRtree uses. query() returns the indexes of every box that intersects
/// the given box, in ascending order.
public final class STRTree {
    private struct Node {
        var box: BBox
        var children: [Int]      // node indexes, or item indexes at the leaf level
    }

    private let capacity = 10
    private var levels: [[Node]] = []   // levels[0] = leaves
    private let items: [BBox]

    public init(_ boxes: [BBox]) {
        items = boxes
        guard !boxes.isEmpty else { return }
        var entries = boxes.indices.map { ($0, boxes[$0]) }
        levels.append(STRTree.pack(&entries, capacity: capacity))
        while levels[levels.count - 1].count > 1 {
            var upper = levels[levels.count - 1].indices.map { ($0, levels[levels.count - 1][$0].box) }
            levels.append(STRTree.pack(&upper, capacity: capacity))
        }
    }

    public convenience init(_ geoms: [Geometry]) {
        self.init(geoms.map { $0.bounds ?? BBox(.nan, .nan, .nan, .nan) })
    }

    private static func pack(_ entries: inout [(Int, BBox)], capacity: Int) -> [Node] {
        let n = entries.count
        let leafCount = Int((Double(n) / Double(capacity)).rounded(.up))
        let slices = max(1, Int(Double(leafCount).squareRoot().rounded(.up)))
        entries.sort { $0.1.center.x < $1.1.center.x }
        let perSlice = slices * capacity
        var nodes: [Node] = []
        var start = 0
        while start < n {
            var slice = Array(entries[start..<min(n, start + perSlice)])
            slice.sort { $0.1.center.y < $1.1.center.y }
            var i = 0
            while i < slice.count {
                let group = slice[i..<min(slice.count, i + capacity)]
                var box = group.first!.1
                for g in group.dropFirst() { box = box.union(g.1) }
                nodes.append(Node(box: box, children: group.map { $0.0 }))
                i += capacity
            }
            start += perSlice
        }
        return nodes
    }

    public func query(_ box: BBox) -> [Int] {
        guard let top = levels.last else { return [] }
        var out: [Int] = []
        var stack: [(level: Int, node: Int)] = top.indices.map { (levels.count - 1, $0) }
        while let (level, idx) = stack.popLast() {
            let node = levels[level][idx]
            guard node.box.intersects(box) else { continue }
            if level == 0 {
                for i in node.children where items[i].intersects(box) { out.append(i) }
            } else {
                for c in node.children { stack.append((level - 1, c)) }
            }
        }
        return out.sorted()
    }

    public func query(_ g: Geometry) -> [Int] {
        guard let b = g.bounds else { return [] }
        return query(b)
    }
}
