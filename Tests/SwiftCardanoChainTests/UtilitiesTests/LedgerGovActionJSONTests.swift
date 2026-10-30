import Foundation
import SwiftCardanoCore
import SwiftYaciAPI
import Testing

@testable import SwiftCardanoChain

@Suite("Ledger-JSON governance actions are read strictly")
struct LedgerGovActionJSONTests {

    static let id = GovActionID(
        transactionID: TransactionId(payload: Data(repeating: 0x2d, count: 32)), govActionIndex: 0)
    static let keyHash = String(repeating: "ab", count: 28)
    static let anchorHash = String(repeating: "cd", count: 32)

    private func parse(_ json: String) throws -> GovAction {
        let any = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
        return try LedgerGovActionJSON.govAction(any, "test") {
            try LedgerGovActionJSON.protocolParamUpdate($0, "test")
        }
    }

    static let corruptActions: [String] = [
        // Not an object, no tag, an unknown tag.
        "null",
        #"{"contents": []}"#,
        #"{"tag": "SomethingNew", "contents": []}"#,
        // Contents of the wrong shape.
        #"{"tag": "HardForkInitiation", "contents": [null]}"#,
        #"{"tag": "HardForkInitiation", "contents": [null, {"major": 10}]}"#,
        #"{"tag": "ParameterChange", "contents": [null, {}]}"#,
        #"{"tag": "ParameterChange", "contents": [null, [], null]}"#,
        #"{"tag": "TreasuryWithdrawals", "contents": {"a": 1}}"#,
        // A withdrawal account with no network, which is not guessed.
        #"{"tag": "TreasuryWithdrawals", "contents": [[[{"keyHash": "\#(keyHash)"}, 1]], null]}"#,
        #"{"tag": "UpdateCommittee", "contents": [null, [], {}]}"#,
        #"{"tag": "UpdateCommittee", "contents": [null, [], {"keyHash-\#(keyHash)": "soon"}, 0.5]}"#,
        #"{"tag": "NewConstitution", "contents": [null, {"script": null}]}"#,
        #"{"tag": "NewConstitution", "contents": [null]}"#,
    ]

    @Test("A missing tag, unknown tag or wrong shape throws instead of reading as an info action",
          arguments: corruptActions)
    func corruptThrows(_ json: String) {
        #expect(throws: CardanoChainError.self) { try parse(json) }
    }

    @Test("A real InfoAction is still an info action")
    func infoAction() throws {
        guard case .infoAction = try parse(#"{"tag": "InfoAction"}"#) else {
            Issue.record("Expected an info action")
            return
        }
    }

    @Test("Each variant reads its contents")
    func variants() throws {
        guard case .hardForkInitiationAction(let fork) = try parse(
            #"{"tag": "HardForkInitiation", "contents": [null, {"major": 10, "minor": 2}]}"#)
        else { Issue.record("Expected a hard fork"); return }
        #expect(fork.protocolVersion.major == 10 && fork.protocolVersion.minor == 2)

        guard case .treasuryWithdrawalsAction(let treasury) = try parse(
            #"{"tag": "TreasuryWithdrawals", "contents": [[[{"network": "Testnet", "credential": {"scriptHash": "\#(Self.keyHash)"}}, 7]], "\#(Self.keyHash)"]}"#)
        else { Issue.record("Expected a treasury withdrawal"); return }
        let account = try #require(treasury.withdrawals.keys.first)
        #expect(account.first == 0xF0)
        #expect(treasury.withdrawals[account] == 7)
        #expect(treasury.policyHash?.payload.toHex == Self.keyHash)

        guard case .updateCommittee(let committee) = try parse(
            #"{"tag": "UpdateCommittee", "contents": [null, [{"keyHash": "\#(Self.keyHash)"}], {"scriptHash-\#(Self.keyHash)": 500}, {"numerator": 2, "denominator": 3}]}"#)
        else { Issue.record("Expected a committee update"); return }
        // The member to remove and the member to add are kept apart.
        #expect(committee.coldCredentials == [
            CommitteeColdCredential(credential: .verificationKeyHash(VerificationKeyHash(payload: Data(hex: Self.keyHash))))])
        #expect(committee.credentialEpochs == [
            CommitteeColdCredential(credential: .scriptHash(ScriptHash(payload: Data(hex: Self.keyHash)))): 500])
        #expect(committee.interval.numerator == 2 && committee.interval.denominator == 3)

        guard case .newConstitution(let constitution) = try parse(
            #"{"tag": "NewConstitution", "contents": [null, {"anchor": {"url": "ipfs://c", "dataHash": "\#(Self.anchorHash)"}}]}"#)
        else { Issue.record("Expected a new constitution"); return }
        #expect(constitution.constitution.anchor.anchorUrl.text == "ipfs://c")
        #expect(constitution.constitution.scriptHash == nil)

        guard case .parameterChangeAction(let change) = try parse(
            #"{"tag": "ParameterChange", "contents": [null, {"maxTxSize": 16384}, null]}"#)
        else { Issue.record("Expected a parameter change"); return }
        #expect(change.protocolParamUpdate.maxTransactionSize == 16384)
    }

    // MARK: Yaci

    static let corruptYaciProposals: [String] = [
        // No type at all.
        #"{"details": {}}"#,
        // An unknown type (the generated client refuses one in `type`, so it comes via details).
        #"{"details": {"type": "SOMETHING_NEW"}}"#,
        #"{"type": "NEW_CONSTITUTION", "details": {}}"#,
        #"{"type": "TREASURY_WITHDRAWALS_ACTION", "details": {}}"#,
        #"{"type": "TREASURY_WITHDRAWALS_ACTION", "details": {"withdrawals": {"stake_test1x": "lots"}}}"#,
        #"{"type": "UPDATE_COMMITTEE", "details": {"newMembersAndTerms": {}, "threshold": 0.5}}"#,
    ]

    @Test("A Yaci proposal with no type, an unknown type or missing contents throws",
          arguments: corruptYaciProposals)
    func corruptYaci(_ fields: String) throws {
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(fields.utf8)) as? [String: Any])
        object["tx_hash"] = String(repeating: "2d", count: 32)
        object["index"] = 0
        let proposal = try JSONDecoder().decode(
            Components.Schemas.GovActionProposal.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: CardanoChainError.self) { try YaciDevkitChainContext.govAction(from: proposal, id: Self.id) }
    }
}
