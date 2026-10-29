import Foundation
import SwiftCardanoCore

/// A governance action that can still be voted on, as listed by
/// ``ChainContext/openGovActions()``.
///
/// Lighter than ``GovActionVotes`` and ``GovActionInfo``: it carries what a
/// voter needs to pick an action — its id, kind, deposit, anchor and expiry —
/// and none of the votes or proposal bodies, so backends can list it without
/// a request per vote list or per parameter change.
public struct OpenGovAction: Codable, CustomStringConvertible, Equatable, Sendable {
    public var govActionId: GovActionID
    public var type: GovActionCode
    public var deposit: Coin?
    public var anchor: Anchor?
    /// The epoch the action was proposed in, when the backend reports it.
    public var proposedIn: UInt64?
    /// The last epoch the action can be voted on, when the backend reports it.
    public var expiresAfter: UInt64?

    public init(
        govActionId: GovActionID,
        type: GovActionCode,
        deposit: Coin? = nil,
        anchor: Anchor? = nil,
        proposedIn: UInt64? = nil,
        expiresAfter: UInt64? = nil
    ) {
        self.govActionId = govActionId
        self.type = type
        self.deposit = deposit
        self.anchor = anchor
        self.proposedIn = proposedIn
        self.expiresAfter = expiresAfter
    }

    public var description: String {
        (try? govActionId.id()) ?? "\(govActionId.transactionID.payload.toHex)#\(govActionId.govActionIndex)"
    }

    /// Whether an action expiring after `expiresAfter` can still be voted on
    /// in `epoch`. An unknown expiry is taken as open.
    static func isOpen(expiresAfter: UInt64?, in epoch: UInt64) -> Bool {
        guard let expiresAfter else { return true }
        return expiresAfter >= epoch
    }

    static func code(of action: GovAction) -> GovActionCode {
        switch action {
        case .parameterChangeAction: .parameterChangeAction
        case .hardForkInitiationAction: .hardForkInitiationAction
        case .treasuryWithdrawalsAction: .treasuryWithdrawalsAction
        case .noConfidence: .noConfidence
        case .updateCommittee: .updateCommittee
        case .newConstitution: .newConstitution
        case .infoAction: .infoAction
        }
    }
}

// A plain Int-backed enum, so safe to send; swift-cardano-core does not mark it yet.
extension GovActionCode: @retroactive @unchecked Sendable {}
