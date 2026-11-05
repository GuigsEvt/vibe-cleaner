import Foundation

/// One bubble of a Radar level: a real child, or the aggregate of the smaller ones.
public struct SpaceBubble: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let size: Int64
    public let fileCount: Int
    /// The child shown, nil for the aggregate bubble.
    public let node: SpaceNode?
    /// Children folded into the aggregate bubble (largest first), empty otherwise.
    public let others: [SpaceNode]
    public var isAggregate: Bool { node == nil }
}

/// Fraction of the parent below which a child is folded into « Éléments plus petits ».
public let spaceBubbleMinFraction = 0.01

/// Rule: keep at most `maxCount` children, each weighing ≥ 1 % of the parent (and > 0 bytes);
/// the rest becomes one aggregate bubble. If only one child would be folded, it is shown as itself.
/// Space macOS can reclaim by itself (local snapshots, caches), shown at the root of a volume scan.
public func purgeableBubble(_ bytes: Int64) -> SpaceBubble {
    SpaceBubble(id: "\u{0}purgeable", name: "Espace purgeable", size: bytes, fileCount: 0, node: nil, others: [])
}

public func bubbles(for node: SpaceNode, maxCount: Int = 30) -> [SpaceBubble] {
    let threshold = Int64(Double(node.size) * spaceBubbleMinFraction)
    var keep = node.children.prefix(maxCount).prefix { $0.size > 0 && $0.size >= threshold }.count
    if node.children.count == keep + 1 { keep += 1 }
    var result = node.children.prefix(keep).map {
        SpaceBubble(id: $0.path, name: $0.name, size: $0.size, fileCount: $0.fileCount, node: $0, others: [])
    }
    let rest = Array(node.children.dropFirst(keep))
    if !rest.isEmpty {
        result.append(SpaceBubble(id: node.path + "/\u{0}smaller", name: "Éléments plus petits",
                                  size: rest.reduce(0) { $0 + $1.size }, fileCount: rest.reduce(0) { $0 + $1.fileCount },
                                  node: nil, others: rest))
    }
    return result
}
