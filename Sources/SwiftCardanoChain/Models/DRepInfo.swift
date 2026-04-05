import SwiftCardanoCore

public enum DRepStatus: Codable, Sendable {
    case registered
    case retired
    case notRegistered
}

public struct DRepInfo: Codable, CustomStringConvertible, Equatable, Sendable {

    public var active: Bool
    public var drep: DRep
    public var anchor: Anchor?
    public var deposit: Coin?
    public var stake: Coin
    public var expiry: UInt64?
    public var status: DRepStatus?
    
    public var description: String {
        return drep.description
    }
}
