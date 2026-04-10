import Foundation
import SwiftCardanoCore
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
