import Foundation
import SwiftCardanoCore

public struct StakePoolInfo: Codable {
    public var poolParams: PoolParams
    public var livePledge: UInt?
    public var liveStake: UInt?
    public var liveSize: Decimal?
    public var activeStake: UInt?
    public var activeSize: Decimal?
    public var opcertCounter: UInt?

    public init(
        poolParams: PoolParams,
        livePledge: UInt? = nil,
        liveStake: UInt? = nil,
        liveSize: Decimal? = nil,
        activeStake: UInt? = nil,
        activeSize: Decimal? = nil,
        opcertCounter: UInt? = nil
    ) {
        self.poolParams = poolParams
        self.livePledge = livePledge
        self.liveStake = liveStake
        self.liveSize = liveSize
        self.activeStake = activeStake
        self.activeSize = activeSize
        self.opcertCounter = opcertCounter
    }
}
