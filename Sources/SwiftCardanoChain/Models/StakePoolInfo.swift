import Foundation
import SwiftCardanoCore

public enum PoolStatus: Codable, Sendable {
    case registered
    case retired
    case retiring(epoch: UInt)
}

/// A stake pool's registration and, where the backend reports them, its live figures.
///
/// Every optional figure is `nil` only when the backend genuinely does not
/// have it: the endpoint or query is not served (or not supported by the
/// node), or the backend does not list this pool. A backend that answers but
/// sends something that does not decode, or a value out of range, throws
/// instead of leaving the figure out.
public struct StakePoolInfo: Codable, Sendable {
    /// The pool's registered parameters.
    public var poolParams: PoolParams
    /// The stake its owners hold now (lovelace); `nil` when the backend does not report it.
    public var livePledge: UInt?
    /// The stake delegated to it now (lovelace); `nil` when the backend does not report it
    /// or does not list this pool in its stake distribution.
    public var liveStake: UInt?
    /// `liveStake` as a share of all live stake; `nil` when that is not reported, or the
    /// total is zero.
    public var liveSize: Decimal?
    /// The stake in this epoch's snapshot (lovelace); `nil` when the backend does not report it.
    public var activeStake: UInt?
    /// `activeStake` as a share of all active stake; `nil` when the backend does not report it.
    public var activeSize: Decimal?
    /// The counter of the pool's latest operational certificate; `nil` when the backend does
    /// not report certificates, or the pool has not issued one.
    public var opcertCounter: UInt?
    /// Registered, retiring or retired; `nil` when the backend does not report it.
    public var status: PoolStatus?

    public init(
        poolParams: PoolParams,
        livePledge: UInt? = nil,
        liveStake: UInt? = nil,
        liveSize: Decimal? = nil,
        activeStake: UInt? = nil,
        activeSize: Decimal? = nil,
        opcertCounter: UInt? = nil,
        status: PoolStatus? = nil
    ) {
        self.poolParams = poolParams
        self.livePledge = livePledge
        self.liveStake = liveStake
        self.liveSize = liveSize
        self.activeStake = activeStake
        self.activeSize = activeSize
        self.opcertCounter = opcertCounter
        self.status = status
    }
}
