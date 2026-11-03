import Foundation

/// Names one Jump. A newer Jump makes older tickets stale.
public struct JumpTicket: Equatable, Sendable {
    public let generation: Int
    public init(generation: Int) { self.generation = generation }

    public func isCurrent(jumpGenerationNow now: Int) -> Bool { generation == now }
}
