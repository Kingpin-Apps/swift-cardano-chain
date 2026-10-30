import Foundation
import HTTPTypes
import OpenAPIRuntime
import SwiftBlockfrostAPI
import SwiftCardanoCore
import SwiftKoios
import SwiftYaciAPI
import Testing

@testable import SwiftCardanoChain

/// A governance action's `id` is its previous action of the same purpose (the
/// ledger's `prev_gov_action_id`) or `nil`, never the proposal's own id; and a
/// committee update's `coldCredentials` is only the members to remove.
@Suite("Governance actions carry their previous action and keep committee changes apart")
struct GovActionPreviousIDTests {

    static let proposalTx = "2dd15e0ef6e6a17841cb9541c27724072ce4d4b79b91e58432fbaa32d9572531"
    static let previousTx = "0b19476e40bbbb5e1e8ce153523762e2b6859e7ecacbaf06eae0ee6a447e79b9"
    static let removedHash = String(repeating: "ab", count: 28)
    static let addedHash = String(repeating: "cd", count: 28)
    static let proposalID = GovActionID(
        transactionID: TransactionId(payload: Data(hex: proposalTx)), govActionIndex: 0)
    static let previousID = GovActionID(
        transactionID: TransactionId(payload: Data(hex: previousTx)), govActionIndex: 2)

    static let removed = CommitteeColdCredential(
        credential: .verificationKeyHash(VerificationKeyHash(payload: Data(hex: removedHash))))
    static let added = CommitteeColdCredential(credential: .scriptHash(ScriptHash(payload: Data(hex: addedHash))))

    /// The ledger's `{tag, contents}` form of a hard fork, with or without a previous action.
    static func ledgerHardFork(_ previous: Bool) -> String {
        let prev = previous ? #"{"txId": "\#(previousTx)", "govActionIx": 2}"# : "null"
        return #"{"tag": "HardForkInitiation", "contents": [\#(prev), {"major": 11, "minor": 0}]}"#
    }

    static let ledgerCommittee = """
        {"tag": "UpdateCommittee", "contents": [{"txId": "\(previousTx)", "govActionIx": 2},
          [{"keyHash": "\(removedHash)"}], {"scriptHash-\(addedHash)": 500}, {"numerator": 2, "denominator": 3}]}
        """

    /// `id` and the committee members of `action`, checked against the expectations.
    static func check(_ action: GovAction, previous: Bool) {
        let expected = previous ? previousID : nil
        switch action {
        case .hardForkInitiationAction(let a):
            #expect(a.id == expected)
            #expect(a.id != proposalID)
        case .noConfidence(let a):
            #expect(a.id == expected)
        case .updateCommittee(let a):
            #expect(a.id == expected)
            #expect(a.coldCredentials == [removed])
            #expect(a.credentialEpochs == [added: 500])
        default:
            Issue.record("Unexpected action \(action)")
        }
    }

    static let withAndWithout: [Bool] = [true, false]

    // MARK: Koios

    private func koios(_ type: String, _ description: String) async throws -> GovAction {
        let row = """
            {"proposal_id": null, "proposal_tx_hash": "\(Self.proposalTx)", "proposal_index": 0,
             "proposal_type": "\(type)", "proposal_description": \(description),
             "deposit": "500000000",
             "return_address": "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",
             "proposed_epoch": 100, "ratified_epoch": null, "enacted_epoch": null, "dropped_epoch": null,
             "expired_epoch": null, "expiration": 120}
            """
        let context = try await KoiosChainContext(
            network: .preview,
            client: SwiftKoios.Client(
                serverURL: try SwiftKoios.Network.preview.url(),
                transport: KoiosMockTransport(overrides: ["proposal_list": "[\(row)]"])))
        return try #require(try await context.govActionInfo(govActionID: Self.proposalID).govAction)
    }

    @Test("Koios reads a hard fork's previous action, or none", arguments: withAndWithout)
    func koiosHardFork(_ previous: Bool) async throws {
        Self.check(try await koios("HardForkInitiation", Self.ledgerHardFork(previous)), previous: previous)
    }

    @Test("Koios keeps a committee update's removals and additions apart")
    func koiosCommittee() async throws {
        Self.check(try await koios("NewCommittee", Self.ledgerCommittee), previous: true)
    }

    // MARK: Blockfrost

    private struct Transport: ClientTransport {
        let proposal: Data
        func send(
            _ request: HTTPTypes.HTTPRequest, body: OpenAPIRuntime.HTTPBody?, baseURL: URL, operationID: String
        ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
            if operationID == "get/governance/proposals/{tx_hash}/{cert_index}" {
                return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), .init(proposal))
            }
            return try await MockTransport().send(request, body: body, baseURL: baseURL, operationID: operationID)
        }
    }

    private func blockfrost(_ type: String, _ description: String) async throws -> GovAction {
        let proposal = Data("""
            {"id": "gov_action1qkm52uwlnw0gtcyh9259sjuwsyrnjdfd3hg7tjzrl463xtv4wfxysqqqqqfd6vw0",
             "tx_hash": "\(Self.proposalTx)", "cert_index": 0, "governance_type": "\(type)",
             "governance_description": \(description), "deposit": "12000",
             "return_address": "stake_test1urd3hs7rlxwwdzthe6hj026dmyt3y0heuulctscyydh2kgck6nkmz",
             "ratified_epoch": null, "enacted_epoch": null, "dropped_epoch": null,
             "expired_epoch": null, "expiration": 120}
            """.utf8)
        let context = try await BlockFrostChainContext(
            projectId: "fake-project-id", network: .preview,
            client: SwiftBlockfrostAPI.Client(
                serverURL: URL(string: "https://cardano-preview.blockfrost.io/api/v0")!,
                transport: Transport(proposal: proposal)))
        return try #require(try await context.govActionInfo(govActionID: Self.proposalID).govAction)
    }

    @Test("Blockfrost reads a hard fork's previous action, or none", arguments: withAndWithout)
    func blockfrostHardFork(_ previous: Bool) async throws {
        Self.check(
            try await blockfrost("hard_fork_initiation", Self.ledgerHardFork(previous)), previous: previous)
    }

    @Test("Blockfrost reads a no-confidence motion's previous action, or none", arguments: withAndWithout)
    func blockfrostNoConfidence(_ previous: Bool) async throws {
        let contents = previous ? #"{"txId": "\#(Self.previousTx)", "govActionIx": 2}"# : "null"
        Self.check(
            try await blockfrost("no_confidence", #"{"tag": "NoConfidence", "contents": \#(contents)}"#),
            previous: previous)
    }

    @Test("Blockfrost keeps a committee update's removals and additions apart")
    func blockfrostCommittee() async throws {
        Self.check(try await blockfrost("new_committee", Self.ledgerCommittee), previous: true)
    }

    @Test("Blockfrost reads a parameter change's previous action and policy hash from its description")
    func blockfrostParameterChange() async throws {
        let context = try await BlockFrostChainContext(
            projectId: "fake-project-id", network: .preview,
            client: SwiftBlockfrostAPI.Client(
                serverURL: URL(string: "https://cardano-preview.blockfrost.io/api/v0")!,
                transport: ParameterChangeMockTransport()))
        let info = try await context.govActionInfo(govActionID: Self.proposalID)
        guard case .parameterChangeAction(let change) = info.govAction else {
            Issue.record("Expected a parameter change")
            return
        }
        #expect(change.id?.transactionID.payload.toHex == ParameterChangeMockTransport.previousTxHash)
        #expect(change.id?.govActionIndex == 3)
        #expect(change.policyHash?.payload.toHex == ParameterChangeMockTransport.policyHash)
    }

    @Test("Blockfrost reads a treasury withdrawal's policy hash from its description")
    func blockfrostTreasuryPolicyHash() async throws {
        let context = try await BlockFrostChainContext(
            projectId: "fake-project-id", network: .preview,
            client: SwiftBlockfrostAPI.Client(
                serverURL: URL(string: "https://cardano-preview.blockfrost.io/api/v0")!,
                transport: MockTransport()))
        let info = try await context.govActionInfo(govActionID: Self.proposalID)
        guard case .treasuryWithdrawalsAction(let treasury) = info.govAction else {
            Issue.record("Expected a treasury withdrawal")
            return
        }
        #expect(treasury.policyHash?.payload.toHex == MockTransport.treasuryPolicyHash)
    }

    static let treasuryDescriptionsWithoutPolicy: [String] = [
        // No description: the policy hash cannot be read, and is not taken as none.
        "null",
        #"{"tag": "InfoAction"}"#,
        #"{"tag": "TreasuryWithdrawals", "contents": [[]]}"#,
    ]

    @Test("A Blockfrost treasury withdrawal whose description is missing or malformed throws",
          arguments: treasuryDescriptionsWithoutPolicy)
    func blockfrostTreasuryNoDescription(_ description: String) async throws {
        await #expect(throws: CardanoChainError.self) {
            _ = try await self.blockfrost("treasury_withdrawals", description)
        }
    }

    // MARK: Ogmios

    private func ogmios(_ action: String) async throws -> GovAction {
        let result = """
            {"jsonrpc": "2.0", "method": "queryLedgerState/governanceProposals", "id": null, "result": [{
              "proposal": {"transaction": {"id": "\(Self.proposalTx)"}, "index": 0},
              "deposit": {"ada": {"lovelace": 100000000000}},
              "returnAccount": "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",
              "metadata": {"url": "https://example.com",
                           "hash": "34f05fe67c8f4172ac5e955c20c8204d37a3f5b2561038d199f4f626a32db6cf"},
              "since": {"epoch": 100}, "until": {"epoch": 130},
              "action": \(action), "votes": []}]}
            """
        let context = try await createMockOgmiosChainContext(
            overrides: ["queryLedgerState/governanceProposals": Data(result.utf8)])
        return try #require(try await context.govActionInfo(govActionID: Self.proposalID).govAction)
    }

    static func ogmiosAncestor(_ previous: Bool) -> String {
        previous ? #""ancestor": {"transaction": {"id": "\#(previousTx)"}, "index": 2},"# : ""
    }

    @Test("Ogmios reads a hard fork's ancestor, or none", arguments: withAndWithout)
    func ogmiosHardFork(_ previous: Bool) async throws {
        Self.check(
            try await ogmios(#"{"type": "hardForkInitiation", \#(Self.ogmiosAncestor(previous)) "version": {"major": 11, "minor": 0}}"#),
            previous: previous)
    }

    @Test("Ogmios reads a no-confidence motion's ancestor, or none", arguments: withAndWithout)
    func ogmiosNoConfidence(_ previous: Bool) async throws {
        let ancestor = Self.ogmiosAncestor(previous).dropLast()
        let action = previous ? #"{"type": "noConfidence", \#(ancestor)}"# : #"{"type": "noConfidence"}"#
        Self.check(try await ogmios(action), previous: previous)
    }

    @Test("Ogmios puts added members in the add map, not in the members to remove")
    func ogmiosCommitteeAdded() async throws {
        let action = """
            {"type": "constitutionalCommittee", \(Self.ogmiosAncestor(true))
             "members": {"added": [{"id": "\(Self.addedHash)", "from": "script", "mandate": {"epoch": 500}}],
                         "removed": []},
             "quorum": "2/3"}
            """
        guard case .updateCommittee(let update) = try await ogmios(action) else {
            Issue.record("Expected a committee update")
            return
        }
        #expect(update.id == Self.previousID)
        #expect(update.coldCredentials.isEmpty)
        #expect(update.credentialEpochs == [Self.added: 500])
    }

    @Test("An Ogmios committee update that removes members throws, since SwiftOgmios cannot decode who")
    func ogmiosCommitteeRemoved() async throws {
        let action = """
            {"type": "constitutionalCommittee",
             "members": {"removed": [{"id": "\(Self.removedHash)", "from": "verificationKey"}]},
             "quorum": "2/3"}
            """
        await #expect(throws: CardanoChainError.self) { _ = try await self.ogmios(action) }
    }

    static let guardrails = "fa24fb305126805cf2164c161d852a0e7330cf988f1fe558cf7d4a64"

    @Test("Ogmios reads a constitution's and a treasury withdrawal's guardrails script")
    func ogmiosGuardrails() async throws {
        guard case .newConstitution(let constitution) = try await ogmios("""
            {"type": "constitution", "metadata": {"url": "ipfs://c", "hash": "\(String(repeating: "cd", count: 32))"},
             "guardrails": {"hash": "\(Self.guardrails)"}}
            """)
        else { Issue.record("Expected a new constitution"); return }
        #expect(constitution.constitution.scriptHash?.payload.toHex == Self.guardrails)
        #expect(constitution.id == nil)

        guard case .treasuryWithdrawalsAction(let treasury) = try await ogmios("""
            {"type": "treasuryWithdrawals",
             "withdrawals": {"stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n": {"ada": {"lovelace": 7}}},
             "guardrails": {"hash": "\(Self.guardrails)"}}
            """)
        else { Issue.record("Expected a treasury withdrawal"); return }
        #expect(treasury.policyHash?.payload.toHex == Self.guardrails)
        #expect(treasury.withdrawals.values.first == 7)
    }

    @Test("An Ogmios treasury transfer throws instead of reading as an info action")
    func ogmiosTreasuryTransfer() async throws {
        await #expect(throws: CardanoChainError.self) {
            _ = try await self.ogmios(
                #"{"type": "treasuryTransfer", "source": "reserves", "target": "treasury", "value": {"ada": {"lovelace": 1}}}"#)
        }
    }

    @Test("Ogmios reads a proposed parameter update instead of an empty one")
    func ogmiosParameterUpdate() async throws {
        let action = try await ogmios("""
            {"type": "protocolParametersUpdate", \(Self.ogmiosAncestor(true))
             "parameters": {"minFeeCoefficient": 44, "maxTransactionSize": {"bytes": 16384},
               "plutusCostModels": {"plutus:v2": [1, 2, 3]},
               "scriptExecutionPrices": {"memory": "577/10000", "cpu": "721/10000000"},
               "maxExecutionUnitsPerTransaction": {"memory": 14000000, "cpu": 10000000000},
               "governanceActionDeposit": {"ada": {"lovelace": 100000000000}},
               "treasuryExpansion": "1/5"},
             "guardrails": {"hash": "\(Self.guardrails)"}}
            """)
        guard case .parameterChangeAction(let change) = action else {
            Issue.record("Expected a parameter change, got \(action)")
            return
        }
        let u = change.protocolParamUpdate
        #expect(change.id == Self.previousID)
        #expect(change.policyHash?.payload.toHex == Self.guardrails)
        #expect(u.minFeeA == 44 && u.maxTransactionSize == 16384)
        #expect(u.costModels?.plutusV2.map { Array($0.values.prefix(3)) } == [1, 2, 3])
        #expect(u.executionCosts?.stepPrice.denominator == 10_000_000)
        #expect(u.maxTxExUnits?.steps == 10_000_000_000)
        #expect(u.governanceActionDeposit == 100_000_000_000)
        #expect(u.treasuryGrowthRate?.numerator == 1 && u.treasuryGrowthRate?.denominator == 5)
        #expect(u.maxBlockBodySize == nil && u.drepVotingThresholds == nil)
    }

    static let unsupportedOgmiosUpdates: [String] = [
        #"{"extraEntropy": "neutral"}"#,
        #"{"minUtxoDepositConstant": {"ada": {"lovelace": 1}}}"#,
        #"{"plutusCostModels": {"plutus:v9": [1]}}"#,
    ]

    @Test("An Ogmios update carrying a non-Conway or unknown field throws", arguments: unsupportedOgmiosUpdates)
    func ogmiosUnsupportedUpdate(_ parameters: String) async throws {
        await #expect(throws: (any Error).self) {
            _ = try await self.ogmios(#"{"type": "protocolParametersUpdate", "parameters": \#(parameters)}"#)
        }
    }

    // MARK: Yaci

    private func yaci(_ type: String, _ details: String) throws -> GovAction {
        let json = """
            {"tx_hash": "\(Self.proposalTx)", "index": 0, "type": "\(type)", "details": \(details)}
            """
        let proposal = try JSONDecoder().decode(Components.Schemas.GovActionProposal.self, from: Data(json.utf8))
        return try YaciDevkitChainContext.govAction(from: proposal, id: Self.proposalID)
    }

    static func yaciPrevious(_ previous: Bool) -> String {
        previous ? #""govActionId": {"transactionId": "\#(previousTx)", "gov_action_index": 2},"# : ""
    }

    @Test("Yaci reads a hard fork's govActionId, or none", arguments: withAndWithout)
    func yaciHardFork(_ previous: Bool) throws {
        Self.check(
            try yaci("HARD_FORK_INITIATION_ACTION",
                     #"{\#(Self.yaciPrevious(previous)) "protocolVersion": {"_1": 11, "_2": 0}}"#),
            previous: previous)
    }

    @Test("Yaci keeps a committee update's removals and additions apart")
    func yaciCommittee() throws {
        Self.check(
            try yaci("UPDATE_COMMITTEE", """
                {\(Self.yaciPrevious(true))
                 "membersForRemoval": [{"type": "ADDR_KEYHASH", "hash": "\(Self.removedHash)"}],
                 "newMembersAndTerms": {"scriptHash-\(Self.addedHash)": 500},
                 "threshold": {"numerator": 2, "denominator": 3}}
                """),
            previous: true)
    }
}
