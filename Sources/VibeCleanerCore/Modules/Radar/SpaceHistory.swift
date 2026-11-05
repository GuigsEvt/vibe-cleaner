import Foundation

/// Back / forward navigation between Radar levels, stored as paths so removed folders are skipped.
public struct SpaceHistory: Sendable, Equatable {
    public private(set) var back: [String] = []
    public private(set) var forward: [String] = []

    public init() {}

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Records a move from `current` to another level; a new move clears the forward stack.
    public mutating func visit(from current: SpaceNode, to next: SpaceNode) {
        guard current !== next else { return }
        back.append(current.path)
        forward = []
    }

    public mutating func goBack(from current: SpaceNode, in root: SpaceNode) -> SpaceNode? {
        step(from: current, in: root, pop: &back, push: &forward)
    }

    public mutating func goForward(from current: SpaceNode, in root: SpaceNode) -> SpaceNode? {
        step(from: current, in: root, pop: &forward, push: &back)
    }

    public mutating func reset() { self = SpaceHistory() }

    private func step(from current: SpaceNode, in root: SpaceNode, pop: inout [String], push: inout [String]) -> SpaceNode? {
        while let path = pop.popLast() {
            guard let node = root.node(at: path), node !== current else { continue }
            push.append(current.path)
            return node
        }
        return nil
    }
}
