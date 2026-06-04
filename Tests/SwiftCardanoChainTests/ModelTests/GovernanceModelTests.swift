import Foundation
import SwiftCardanoCore
import SwiftCardanoNetwork
import Testing

@testable import SwiftCardanoChain

@Suite("CommitteeMemberInfo Model Tests")
struct CommitteeMemberInfoModelTests {

    @Test("description mirrors cold credential description")
    func descriptionUsesColdCredential() throws {
        let coldCredential = CommitteeColdCredential(
            credential: .scriptHash(
                try ScriptHash(
                    from: .string("1980dbf1ad624b0cb5410359b5ab14d008561994a6c2b6c53fabec00")
                )
            )
        )
        let hotCredential = CommitteeHotCredential(
            credential: .scriptHash(
                try ScriptHash(
                    from: .string("646d1b3ac94568a422b687db6c47acdf849f1674982ae4f9a494be43")
                )
            )
        )
        let info = CommitteeMemberInfo(
            coldCredential: coldCredential,
            hotCredential: hotCredential,
            expiration: EpochNumber(726),
            status: .active
        )

        #expect(info.coldCredential == coldCredential)
        #expect(info.hotCredential == hotCredential)
        #expect(info.expiration == EpochNumber(726))
        if case .active? = info.status {
        } else {
            Issue.record("Expected active status")
        }
        #expect(info.description == coldCredential.description)
    }
}

@Suite("DRepInfo Model Tests")
struct DRepInfoModelTests {

    @Test("init stores governance metadata and description uses drep")
    func initStoresGovernanceMetadata() throws {
        let drep = try DRep.fromBech32("drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0")
        let anchor = Anchor(
            anchorUrl: try Url("https://anchor.test"),
            anchorDataHash: AnchorDataHash(
                payload: Data(
                    hex: "35aeb21ba4be07cf9fda041b635f107ef978238b3fccae9be1b571518ce9d1b7")
            )
        )
        let info = DRepInfo(
            active: true,
            drep: drep,
            anchor: anchor,
            deposit: Coin(500_000_000),
            stake: Coin(305_554_989_074),
            expiry: 639,
            status: .registered
        )

        #expect(info.active == true)
        #expect(info.drep == drep)
        #expect(info.anchor == anchor)
        #expect(info.deposit == Coin(500_000_000))
        #expect(info.stake == Coin(305_554_989_074))
        #expect(info.expiry == 639)
        if case .registered? = info.status {
        } else {
            Issue.record("Expected registered status")
        }
        #expect(info.description == drep.description)
    }

    @Test("minimal init leaves optional metadata empty")
    func minimalInitLeavesOptionalsNil() {
        let drep = DRep(credential: .alwaysAbstain)
        let info = DRepInfo(active: true, drep: drep, stake: Coin(42))

        #expect(info.anchor == nil)
        #expect(info.deposit == nil)
        #expect(info.expiry == nil)
        #expect(info.status == nil)
    }
}

@Suite("GovActionInfo Model Tests")
struct GovActionInfoModelTests {

    @Test("status prefers enacted over all other epochs")
    func statusPrefersEnacted() {
        let info = GovActionInfo(
            govActionId: ModelTestFixtures.makeGovActionID(),
            govAction: GovAction.infoAction(InfoAction()),
            proposedIn: 100,
            expiresAfter: 120,
            ratifiedEpoch: 130,
            enactedEpoch: 140,
            droppedEpoch: 150,
            expiredEpoch: 160
        )

        if case .enacted? = info.status {
        } else {
            Issue.record("Expected enacted status")
        }
    }

    @Test("status falls back through ratified dropped expired")
    func statusFallbackOrder() {
        let ratified = GovActionInfo(
            govActionId: ModelTestFixtures.makeGovActionID(byte: 0x01),
            govAction: GovAction.infoAction(InfoAction()),
            ratifiedEpoch: 130
        )
        let dropped = GovActionInfo(
            govActionId: ModelTestFixtures.makeGovActionID(byte: 0x02),
            govAction: GovAction.infoAction(InfoAction()),
            droppedEpoch: 140
        )
        let expired = GovActionInfo(
            govActionId: ModelTestFixtures.makeGovActionID(byte: 0x03),
            govAction: GovAction.infoAction(InfoAction()),
            expiredEpoch: 150
        )
        let pending = GovActionInfo(
            govActionId: ModelTestFixtures.makeGovActionID(byte: 0x04),
            govAction: GovAction.infoAction(InfoAction())
        )

        if case .ratified? = ratified.status {
        } else {
            Issue.record("Expected ratified status")
        }
        if case .dropped? = dropped.status {
        } else {
            Issue.record("Expected dropped status")
        }
        if case .expired? = expired.status {
        } else {
            Issue.record("Expected expired status")
        }
        #expect(pending.status == nil)
    }

    @Test("description returns governance action identifier")
    func descriptionReturnsActionIdentifier() throws {
        let govActionId = ModelTestFixtures.makeGovActionID(byte: 0x55, index: 2)
        let info = GovActionInfo(
            govActionId: govActionId,
            govAction: GovAction.infoAction(InfoAction())
        )
        let identifier = try govActionId.id()

        #expect(info.description == identifier)
    }
}

@Suite("GovActionVotes Model Tests")
struct GovActionVotesModelTests {

    private static func makeBase(
        committeeVotes: [SwiftCardanoNetwork.CommitteeVote] = [],
        dRepVotes: [SwiftCardanoNetwork.DRepVote] = [],
        stakePoolVotes: [SwiftCardanoNetwork.StakePoolVote] = [],
        anchor: Anchor? = nil,
        proposedIn: UInt64? = nil,
        expiresAfter: UInt64? = nil,
        ratifiedEpoch: UInt64? = nil,
        enactedEpoch: UInt64? = nil,
        droppedEpoch: UInt64? = nil,
        expiredEpoch: UInt64? = nil
    ) -> GovActionVotes {
        GovActionVotes(
            govActionId: ModelTestFixtures.makeGovActionID(),
            govAction: GovAction.infoAction(InfoAction()),
            committeeVotes: committeeVotes,
            dRepVotes: dRepVotes,
            stakePoolVotes: stakePoolVotes,
            deposit: Coin(100_000_000_000),
            depositReturnAddr: RewardAccount(Data(repeating: 0xE0, count: 29)),
            anchor: anchor,
            proposedIn: proposedIn,
            expiresAfter: expiresAfter,
            ratifiedEpoch: ratifiedEpoch,
            enactedEpoch: enactedEpoch,
            droppedEpoch: droppedEpoch,
            expiredEpoch: expiredEpoch
        )
    }

    @Test("status prefers enacted over all other epochs")
    func statusPrefersEnacted() {
        let votes = Self.makeBase(
            ratifiedEpoch: 130,
            enactedEpoch: 140,
            droppedEpoch: 150,
            expiredEpoch: 160
        )

        if case .enacted? = votes.status {
        } else {
            Issue.record("Expected enacted status")
        }
    }

    @Test("status falls back through ratified, dropped, expired, nil")
    func statusFallbackOrder() {
        let ratified = Self.makeBase(ratifiedEpoch: 130)
        let dropped = Self.makeBase(droppedEpoch: 140)
        let expired = Self.makeBase(expiredEpoch: 150)
        let pending = Self.makeBase()

        if case .ratified? = ratified.status {
        } else {
            Issue.record("Expected ratified status")
        }
        if case .dropped? = dropped.status {
        } else {
            Issue.record("Expected dropped status")
        }
        if case .expired? = expired.status {
        } else {
            Issue.record("Expected expired status")
        }
        #expect(pending.status == nil)
    }

    @Test("description returns governance action identifier")
    func descriptionReturnsActionIdentifier() throws {
        let govActionId = ModelTestFixtures.makeGovActionID(byte: 0x55, index: 2)
        let votes = GovActionVotes(
            govActionId: govActionId,
            govAction: GovAction.infoAction(InfoAction()),
            deposit: Coin(0),
            depositReturnAddr: RewardAccount(Data())
        )

        #expect(votes.description == (try govActionId.id()))
    }

    @Test("init defaults leave votes empty and optional fields nil")
    func initDefaults() {
        let votes = GovActionVotes(
            govActionId: ModelTestFixtures.makeGovActionID(),
            govAction: GovAction.infoAction(InfoAction()),
            deposit: Coin(0),
            depositReturnAddr: RewardAccount(Data())
        )

        #expect(votes.committeeVotes.isEmpty)
        #expect(votes.dRepVotes.isEmpty)
        #expect(votes.stakePoolVotes.isEmpty)
        #expect(votes.anchor == nil)
        #expect(votes.proposedIn == nil)
        #expect(votes.expiresAfter == nil)
        #expect(votes.ratifiedEpoch == nil)
        #expect(votes.enactedEpoch == nil)
        #expect(votes.droppedEpoch == nil)
        #expect(votes.expiredEpoch == nil)
        #expect(votes.status == nil)
    }

    @Test("asGovActionInfo projects epochs and identifiers")
    func asGovActionInfoProjects() {
        let votes = Self.makeBase(
            proposedIn: 100,
            expiresAfter: 120,
            ratifiedEpoch: 130,
            enactedEpoch: 140,
            droppedEpoch: 150,
            expiredEpoch: 160
        )
        let info = votes.asGovActionInfo

        #expect(info.govActionId == votes.govActionId)
        #expect(info.govAction == votes.govAction)
        #expect(info.proposedIn == 100)
        #expect(info.expiresAfter == 120)
        #expect(info.ratifiedEpoch == 130)
        #expect(info.enactedEpoch == 140)
        #expect(info.droppedEpoch == 150)
        #expect(info.expiredEpoch == 160)
    }

    @Test("Codable round-trip preserves vote arrays, anchor, and epoch fields")
    func codableRoundTrip() throws {
        let committeeCred = CommitteeHotCredential(
            credential: .verificationKeyHash(
                VerificationKeyHash(payload: Data(repeating: 0x11, count: 28))
            )
        )
        let drepCred = DRepCredential(
            credential: .scriptHash(ScriptHash(payload: Data(repeating: 0x22, count: 28)))
        )
        let poolOp = PoolOperator(
            poolKeyHash: PoolKeyHash(payload: Data(repeating: 0x33, count: 28))
        )
        let anchor = Anchor(
            anchorUrl: try Url("https://anchor.test"),
            anchorDataHash: AnchorDataHash(
                payload: Data(repeating: 0x44, count: 32)
            )
        )

        let original = GovActionVotes(
            govActionId: ModelTestFixtures.makeGovActionID(byte: 0xab, index: 1),
            govAction: GovAction.infoAction(InfoAction()),
            committeeVotes: [.init(credential: committeeCred, vote: .yes)],
            dRepVotes: [.init(credential: drepCred, vote: .abstain)],
            stakePoolVotes: [.init(poolOperator: poolOp, vote: .no)],
            deposit: Coin(500_000_000_000),
            depositReturnAddr: RewardAccount(Data(repeating: 0xE0, count: 29)),
            anchor: anchor,
            proposedIn: 10,
            expiresAfter: 20,
            ratifiedEpoch: 30,
            enactedEpoch: 40
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GovActionVotes.self, from: encoded)

        #expect(decoded == original)
    }
}

@Suite("CommitteeStateInfo Model Tests")
struct CommitteeStateInfoModelTests {

    @Test("Member init stores credentials, expiration, status")
    func memberInitStoresFields() {
        let cold = CommitteeColdCredential(
            credential: .verificationKeyHash(
                VerificationKeyHash(payload: Data(repeating: 0xaa, count: 28))
            )
        )
        let hot = CommitteeHotCredential(
            credential: .verificationKeyHash(
                VerificationKeyHash(payload: Data(repeating: 0xbb, count: 28))
            )
        )

        let member = CommitteeStateInfo.Member(
            coldCredential: cold,
            hotCredential: hot,
            expiration: EpochNumber(500),
            status: .active
        )

        #expect(member.coldCredential == cold)
        #expect(member.hotCredential == hot)
        #expect(member.expiration == EpochNumber(500))
        if case .active? = member.status {
        } else {
            Issue.record("Expected active status")
        }
    }

    @Test("init preserves member order and threshold")
    func initPreservesMembersAndThreshold() {
        let memberA = CommitteeStateInfo.Member(
            coldCredential: CommitteeColdCredential(
                credential: .verificationKeyHash(
                    VerificationKeyHash(payload: Data(repeating: 0x01, count: 28))
                )
            )
        )
        let memberB = CommitteeStateInfo.Member(
            coldCredential: CommitteeColdCredential(
                credential: .verificationKeyHash(
                    VerificationKeyHash(payload: Data(repeating: 0x02, count: 28))
                )
            ),
            status: .expired
        )

        let state = CommitteeStateInfo(members: [memberA, memberB], threshold: 0.67)

        #expect(state.members.count == 2)
        #expect(state.members[0] == memberA)
        #expect(state.members[1] == memberB)
        #expect(state.threshold == 0.67)
    }

    @Test("Codable round-trip preserves keyHash and scriptHash members")
    func codableRoundTrip() throws {
        let keyHashMember = CommitteeStateInfo.Member(
            coldCredential: CommitteeColdCredential(
                credential: .verificationKeyHash(
                    VerificationKeyHash(payload: Data(repeating: 0x10, count: 28))
                )
            ),
            hotCredential: CommitteeHotCredential(
                credential: .verificationKeyHash(
                    VerificationKeyHash(payload: Data(repeating: 0x11, count: 28))
                )
            ),
            expiration: EpochNumber(800),
            status: .active
        )
        let scriptHashMember = CommitteeStateInfo.Member(
            coldCredential: CommitteeColdCredential(
                credential: .scriptHash(ScriptHash(payload: Data(repeating: 0x20, count: 28)))
            ),
            hotCredential: nil,
            expiration: EpochNumber(900),
            status: .expired
        )
        let original = CommitteeStateInfo(
            members: [keyHashMember, scriptHashMember],
            threshold: 0.51
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CommitteeStateInfo.self, from: encoded)

        #expect(decoded == original)
    }
}
