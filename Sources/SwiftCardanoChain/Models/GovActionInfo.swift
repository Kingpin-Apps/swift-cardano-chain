import SwiftCardanoCore

public enum GovActionStatus: Codable, Sendable {
    case enacted
    case ratified
    case dropped
    case expired
}

public struct GovActionInfo: Codable, CustomStringConvertible, Equatable, Sendable {
    public var govActionId: GovActionID
    /// The action the proposal makes, or `nil` when its body is no longer
    /// available — a backend that reads proposals from the ledger's current
    /// governance state (cardano-cli) no longer has a proposal once it has
    /// been enacted, expired or dropped, though it can still report that.
    /// Never a stand-in action.
    public var govAction: GovAction?
    public var proposedIn: UInt64?
    public var expiresAfter: UInt64?
    public var ratifiedEpoch: UInt64?
    public var enactedEpoch: UInt64?
    public var droppedEpoch: UInt64?
    public var expiredEpoch: UInt64?
    
    public var status: GovActionStatus? {
        if enactedEpoch != nil {
            return .enacted
        } else if ratifiedEpoch != nil {
            return .ratified
        } else if droppedEpoch != nil {
            return .dropped
        } else if expiredEpoch != nil {
            return .expired
        } else {
            return nil
        }
    }
    
    public var description: String {
        return try! govActionId.id()
    }
}
