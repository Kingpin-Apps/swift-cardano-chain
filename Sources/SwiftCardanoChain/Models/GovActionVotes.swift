import Foundation
import SwiftCardanoCore
import SwiftCardanoNetwork

/// Helpers used by `GovActionVotes` and `OfflineTransfer` to encode/decode
/// `Serializable` types whose default `JSONSerializable` bridging is broken
/// (the Mirror-based `toDict()` emits an object but `init(from primitive:)`
/// expects a list — so the JSON round-trip throws). CBOR round-trips
/// consistently for these types, so we wrap them as CBOR-hex strings in
/// the on-disk JSON.
extension KeyedEncodingContainer {
    mutating func encodeCBORHex<T: CBORSerializable>(_ values: [T], forKey key: Key) throws {
        let hexes = try values.map { try $0.toCBORHex() }
        try encode(hexes, forKey: key)
    }

    mutating func encodeCBORHexIfPresent<T: CBORSerializable>(_ value: T?, forKey key: Key) throws {
        guard let value else { return }
        try encode(try value.toCBORHex(), forKey: key)
    }
}

extension KeyedDecodingContainer {
    func decodeCBORHexArray<T: CBORSerializable>(_ type: [T].Type, forKey key: Key) throws -> [T] {
        let hexes = try decodeIfPresent([String].self, forKey: key) ?? []
        return try hexes.map { try T.fromCBORHex($0) }
    }

    func decodeCBORHexIfPresent<T: CBORSerializable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard let hex = try decodeIfPresent(String.self, forKey: key) else { return nil }
        return try T.fromCBORHex(hex)
    }
}

/// Full vote tally for a governance action, including the proposal procedure
/// (deposit / return address / anchor) needed for display.
///
/// Returned by `ChainContext.govActionVotes(govActionID:)` and
/// `ChainContext.govActionsAll()`. Vote arrays are empty when no votes have
/// been recorded for that voter class yet.
public struct GovActionVotes: Codable, CustomStringConvertible, Equatable, Sendable {
    public var govActionId: GovActionID
    public var govAction: GovAction
    public var committeeVotes: [CommitteeVote]
    public var dRepVotes: [DRepVote]
    public var stakePoolVotes: [StakePoolVote]
    public var deposit: Coin
    public var depositReturnAddr: RewardAccount
    public var anchor: Anchor?
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

    public init(
        govActionId: GovActionID,
        govAction: GovAction,
        committeeVotes: [CommitteeVote] = [],
        dRepVotes: [DRepVote] = [],
        stakePoolVotes: [StakePoolVote] = [],
        deposit: Coin,
        depositReturnAddr: RewardAccount,
        anchor: Anchor? = nil,
        proposedIn: UInt64? = nil,
        expiresAfter: UInt64? = nil,
        ratifiedEpoch: UInt64? = nil,
        enactedEpoch: UInt64? = nil,
        droppedEpoch: UInt64? = nil,
        expiredEpoch: UInt64? = nil
    ) {
        self.govActionId = govActionId
        self.govAction = govAction
        self.committeeVotes = committeeVotes
        self.dRepVotes = dRepVotes
        self.stakePoolVotes = stakePoolVotes
        self.deposit = deposit
        self.depositReturnAddr = depositReturnAddr
        self.anchor = anchor
        self.proposedIn = proposedIn
        self.expiresAfter = expiresAfter
        self.ratifiedEpoch = ratifiedEpoch
        self.enactedEpoch = enactedEpoch
        self.droppedEpoch = droppedEpoch
        self.expiredEpoch = expiredEpoch
    }

    public var description: String {
        return (try? govActionId.id()) ?? "GovActionVotes(unprintable id)"
    }

    // MARK: - Codable
    //
    // `committeeVotes` / `dRepVotes` / `stakePoolVotes` / `anchor` are
    // Serializable types whose default JSON Codable round-trip is broken
    // (toDict emits an object but init(from primitive:) expects a list).
    // We persist them as CBOR-hex strings instead — CBOR uses
    // toPrimitive/init(from primitive:) directly and round-trips cleanly.

    private enum CodingKeys: String, CodingKey {
        case govActionId, govAction, committeeVotes, dRepVotes, stakePoolVotes
        case deposit, depositReturnAddr, anchor
        case proposedIn, expiresAfter, ratifiedEpoch, enactedEpoch, droppedEpoch, expiredEpoch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.govActionId = try c.decode(GovActionID.self, forKey: .govActionId)
        self.govAction = try c.decode(GovAction.self, forKey: .govAction)
        self.committeeVotes = try c.decodeCBORHexArray([CommitteeVote].self, forKey: .committeeVotes)
        self.dRepVotes = try c.decodeCBORHexArray([DRepVote].self, forKey: .dRepVotes)
        self.stakePoolVotes = try c.decodeCBORHexArray([StakePoolVote].self, forKey: .stakePoolVotes)
        self.deposit = try c.decode(Coin.self, forKey: .deposit)
        self.depositReturnAddr = try c.decode(RewardAccount.self, forKey: .depositReturnAddr)
        self.anchor = try c.decodeCBORHexIfPresent(Anchor.self, forKey: .anchor)
        self.proposedIn = try c.decodeIfPresent(UInt64.self, forKey: .proposedIn)
        self.expiresAfter = try c.decodeIfPresent(UInt64.self, forKey: .expiresAfter)
        self.ratifiedEpoch = try c.decodeIfPresent(UInt64.self, forKey: .ratifiedEpoch)
        self.enactedEpoch = try c.decodeIfPresent(UInt64.self, forKey: .enactedEpoch)
        self.droppedEpoch = try c.decodeIfPresent(UInt64.self, forKey: .droppedEpoch)
        self.expiredEpoch = try c.decodeIfPresent(UInt64.self, forKey: .expiredEpoch)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(govActionId, forKey: .govActionId)
        try c.encode(govAction, forKey: .govAction)
        try c.encodeCBORHex(committeeVotes, forKey: .committeeVotes)
        try c.encodeCBORHex(dRepVotes, forKey: .dRepVotes)
        try c.encodeCBORHex(stakePoolVotes, forKey: .stakePoolVotes)
        try c.encode(deposit, forKey: .deposit)
        try c.encode(depositReturnAddr, forKey: .depositReturnAddr)
        try c.encodeCBORHexIfPresent(anchor, forKey: .anchor)
        try c.encodeIfPresent(proposedIn, forKey: .proposedIn)
        try c.encodeIfPresent(expiresAfter, forKey: .expiresAfter)
        try c.encodeIfPresent(ratifiedEpoch, forKey: .ratifiedEpoch)
        try c.encodeIfPresent(enactedEpoch, forKey: .enactedEpoch)
        try c.encodeIfPresent(droppedEpoch, forKey: .droppedEpoch)
        try c.encodeIfPresent(expiredEpoch, forKey: .expiredEpoch)
    }

    /// Project this aggregate down to a `GovActionInfo` for reuse with the existing
    /// `govActionInfoSummary` printer in `swift-cardano-multitool`.
    public var asGovActionInfo: GovActionInfo {
        GovActionInfo(
            govActionId: govActionId,
            govAction: govAction,
            proposedIn: proposedIn,
            expiresAfter: expiresAfter,
            ratifiedEpoch: ratifiedEpoch,
            enactedEpoch: enactedEpoch,
            droppedEpoch: droppedEpoch,
            expiredEpoch: expiredEpoch
        )
    }
}

/// State of the constitutional committee surfaced for vote-tallying:
/// cold→hot authorizations, term expirations, and the active quorum threshold.
///
/// Returned by `ChainContext.committeeState()`. Distinct from
/// `SwiftCardanoNetwork.GovernanceCommitteeState`, which is the raw ledger-state
/// shape (cold credential → expiry only) — this aggregate also carries the
/// hot credential and status needed by the multitool's vote-tally display.
public struct CommitteeStateInfo: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Sendable {
        public var coldCredential: CommitteeColdCredential
        public var hotCredential: CommitteeHotCredential?
        public var expiration: EpochNumber?
        public var status: CommitteeMemberStatus?

        public init(
            coldCredential: CommitteeColdCredential,
            hotCredential: CommitteeHotCredential? = nil,
            expiration: EpochNumber? = nil,
            status: CommitteeMemberStatus? = nil
        ) {
            self.coldCredential = coldCredential
            self.hotCredential = hotCredential
            self.expiration = expiration
            self.status = status
        }
    }

    public var members: [Member]
    /// Quorum threshold as a decimal in [0.0, 1.0].
    public var threshold: Double

    public init(members: [Member], threshold: Double) {
        self.members = members
        self.threshold = threshold
    }
}
