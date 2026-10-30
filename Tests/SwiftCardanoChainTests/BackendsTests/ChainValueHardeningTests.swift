import Foundation
import HTTPTypes
import OpenAPIRuntime
import SwiftBlockfrostAPI
import SwiftCardanoCore
import SwiftKoios
import SwiftYaciAPI
import Testing

@testable import SwiftCardanoChain

/// Answers the listed Blockfrost operations with the given JSON and everything
/// else from `ParameterChangeMockTransport`.
private struct BlockfrostOverrideTransport: ClientTransport {
    let overrides: [String: Data]
    private let fallback = ParameterChangeMockTransport()

    func send(
        _ request: HTTPTypes.HTTPRequest, body: OpenAPIRuntime.HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
        if let data = overrides[operationID] {
            return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), .init(data))
        }
        return try await fallback.send(request, body: body, baseURL: baseURL, operationID: operationID)
    }
}

private let proposalTxHash = "2dd15e0ef6e6a17841cb9541c27724072ce4d4b79b91e58432fbaa32d9572531"

private func blockfrost(_ overrides: [String: Data]) async throws -> BlockFrostChainContext {
    try await BlockFrostChainContext(
        projectId: "fake-project-id",
        network: .preview,
        client: Client(
            serverURL: URL(string: "https://cardano-preview.blockfrost.io/api/v0")!,
            transport: BlockfrostOverrideTransport(overrides: overrides)
        )
    )
}

private func proposal(deposit: String = "12000", expiration: Int = 120) throws -> Data {
    try JSONEncoder().encode(
        Components.Schemas.Proposal(
            id: "gov_action1qkm52uwlnw0gtcyh9259sjuwsyrnjdfd3hg7tjzrl463xtv4wfxysqqqqqfd6vw0",
            txHash: proposalTxHash,
            certIndex: 1,
            governanceType: .infoAction,
            governanceDescription: Components.Schemas.Proposal.GovernanceDescriptionPayload(),
            deposit: deposit,
            returnAddress: "stake_test1urd3hs7rlxwwdzthe6hj026dmyt3y0heuulctscyydh2kgck6nkmz",
            ratifiedEpoch: nil,
            enactedEpoch: nil,
            droppedEpoch: nil,
            expiredEpoch: nil,
            expiration: expiration
        )
    )
}

private let govActionID = GovActionID(
    transactionID: TransactionId(payload: Data(hex: proposalTxHash)),
    govActionIndex: 1
)

private func ogmiosResult(_ method: String, _ result: String) -> Data {
    Data(#"{"jsonrpc": "2.0", "method": "\#(method)", "result": \#(result), "id": null}"#.utf8)
}

@Suite("Values from the network throw instead of trapping or defaulting")
struct ChainValueHardeningTests {

    // MARK: Ogmios

    @Test("A negative Ogmios treasury throws")
    func ogmiosNegativeTreasury() async throws {
        let context = try await createMockOgmiosChainContext(overrides: [
            "queryLedgerState/treasuryAndReserves": ogmiosResult(
                "queryLedgerState/treasuryAndReserves",
                #"{"treasury": {"ada": {"lovelace": -1}}, "reserves": {"ada": {"lovelace": 1}}}"#)
        ])
        await #expect(throws: CardanoChainError.self) { _ = try await context.treasury() }
    }

    /// DRep summaries whose stake is negative, one per DRep kind.
    static let negativeStakeDReps: [String] = [
        #"[{"type": "registered", "from": "verificationKey", "id": "b02f7b335aebf284bbdc20bdc3b59e4e183ae2cfc47ad2d8bc19a241", "mandate": {"epoch": 639}, "deposit": {"ada": {"lovelace": 500000000}}, "stake": {"ada": {"lovelace": -5}}, "delegators": []}]"#,
        #"[{"type": "abstain", "stake": {"ada": {"lovelace": -5}}}]"#,
        #"[{"type": "noConfidence", "stake": {"ada": {"lovelace": -5}}}]"#,
    ]

    static let dreps: [String] = [
        "drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0",
        "drep_always_abstain",
        "drep_always_no_confidence",
    ]

    @Test("A negative Ogmios DRep stake throws", arguments: zip(negativeStakeDReps, dreps))
    func ogmiosNegativeStake(_ summaries: String, _ drep: String) async throws {
        let context = try await createMockOgmiosChainContext(overrides: [
            "queryLedgerState/delegateRepresentatives": ogmiosResult(
                "queryLedgerState/delegateRepresentatives", summaries)
        ])
        let target: DRep
        switch drep {
        case "drep_always_abstain": target = DRep(credential: .alwaysAbstain)
        case "drep_always_no_confidence": target = DRep(credential: .alwaysNoConfidence)
        default: target = try DRep.fromBech32(drep)
        }
        await #expect(throws: CardanoChainError.self) { _ = try await context.drepInfo(drep: target) }
    }

    @Test("Ogmios's predefined DReps are told apart by their type, not SwiftOgmios's case")
    func ogmiosPredefinedDRepStake() async throws {
        // SwiftOgmios decodes an "abstain" summary as `.noConfidence`.
        let context = try await createMockOgmiosChainContext()
        let abstain = try await context.drepInfo(drep: DRep(credential: .alwaysAbstain))
        let noConfidence = try await context.drepInfo(drep: DRep(credential: .alwaysNoConfidence))
        #expect(abstain.stake == 8_803_265_544_870_414)
        #expect(noConfidence.stake == 194_527_627_240_783)
    }

    @Test("A predefined DRep missing from Ogmios's summaries throws instead of reading as 0")
    func ogmiosMissingPredefinedDRep() async throws {
        let context = try await createMockOgmiosChainContext(overrides: [
            "queryLedgerState/delegateRepresentatives": ogmiosResult(
                "queryLedgerState/delegateRepresentatives",
                #"[{"type": "noConfidence", "stake": {"ada": {"lovelace": 5}}}]"#)
        ])
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.drepInfo(drep: DRep(credential: .alwaysAbstain))
        }
    }

    static let badStartTimes: [String] = ["not a date", "", "2022-13-45T00:00:00Z"]

    @Test("An Ogmios genesis start time that does not parse throws", arguments: badStartTimes)
    func ogmiosBadSystemStart(_ text: String) {
        #expect(throws: CardanoChainError.self) { try OgmiosChainContext.systemStart(text) }
    }

    @Test("An Ogmios genesis start time parses, with or without fractional seconds")
    func ogmiosSystemStart() throws {
        #expect(try OgmiosChainContext.systemStart("2022-10-25T00:00:00Z") == Date(timeIntervalSince1970: 1_666_656_000))
        #expect(try OgmiosChainContext.systemStart("2022-10-25T00:00:00.5Z") == Date(timeIntervalSince1970: 1_666_656_000.5))
    }

    @Test("genesisParameters throws on an Ogmios start time that does not parse")
    func ogmiosGenesisBadSystemStart() async throws {
        let original = String(decoding: OgmiosMockData.genesisConfigurationShelley, as: UTF8.self)
        let broken = original.replacingOccurrences(of: #""startTime":"2022-10-25T00:00:00Z""#, with: #""startTime":"yesterday""#)
        #expect(broken != original)
        let context = try await createMockOgmiosChainContext(overrides: [
            "queryNetwork/genesisConfiguration": Data(broken.utf8)
        ])
        await #expect(throws: CardanoChainError.self) { _ = try await context.genesisParameters() }
    }

    static let badQuorums: [String] = ["3/2", "1/0", "-1/2", "two thirds"]

    @Test("A malformed Ogmios committee quorum throws", arguments: badQuorums)
    func ogmiosBadQuorum(_ raw: String) {
        #expect(throws: CardanoChainError.self) { try OgmiosChainContext.quorumThreshold(raw) }
    }

    @Test("An Ogmios committee quorum is read exactly, and none is nil")
    func ogmiosQuorum() throws {
        #expect(try OgmiosChainContext.quorumThreshold("2/3") == unit(2, 3))
        #expect(try OgmiosChainContext.quorumThreshold("6/10") == unit(3, 5))
        #expect(try OgmiosChainContext.quorumThreshold(nil) == nil)
    }

    @Test("committeeState with no Ogmios committee has no threshold, and does not throw")
    func ogmiosNoCommittee() async throws {
        let context = try await createMockOgmiosChainContext(overrides: [
            "queryLedgerState/constitutionalCommittee": ogmiosResult(
                "queryLedgerState/constitutionalCommittee", #"{"members": []}"#)
        ])
        let state = try await context.committeeState()
        #expect(state.threshold == nil)
        #expect(state.members.isEmpty)
    }

    // MARK: Koios

    private func koiosCommittee(_ quorum: String) async throws -> CommitteeStateInfo {
        let context = try await KoiosChainContext(
            network: .preview,
            client: SwiftKoios.Client(
                serverURL: try SwiftKoios.Network.preview.url(),
                transport: KoiosMockTransport(overrides: [
                    "committee_info": #"{"proposal_id": null, \#(quorum) "members": []}"#
                ])
            )
        )
        return try await context.committeeState()
    }

    @Test("No Koios committee quorum is a nil threshold, not an error")
    func koiosNoQuorum() async throws {
        let state = try await koiosCommittee("")
        #expect(state.threshold == nil)
    }

    static let badKoiosQuorums: [String] = [
        #""quorum_numerator": 2,"#,
        #""quorum_numerator": 3, "quorum_denominator": 2,"#,
        #""quorum_numerator": -1, "quorum_denominator": 2,"#,
        #""quorum_numerator": 1.5, "quorum_denominator": 2,"#,
    ]

    @Test("A malformed Koios committee quorum throws", arguments: badKoiosQuorums)
    func koiosBadQuorum(_ quorum: String) async throws {
        await #expect(throws: CardanoChainError.self) { _ = try await self.koiosCommittee(quorum) }
    }

    // MARK: Blockfrost

    static let badDeposits: [String] = ["abc", "-1", "1.5", ""]

    @Test("A Blockfrost proposal deposit that does not parse throws, not 0", arguments: badDeposits)
    func blockfrostBadDeposit(_ deposit: String) async throws {
        let context = try await blockfrost([
            "get/governance/proposals/{tx_hash}/{cert_index}": try proposal(deposit: deposit)
        ])
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.govActionVotes(govActionID: govActionID)
        }
    }

    @Test("A negative Blockfrost proposal expiration throws, not 0")
    func blockfrostNegativeExpiration() async throws {
        let context = try await blockfrost([
            "get/governance/proposals/{tx_hash}/{cert_index}": try proposal(expiration: -1)
        ])
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.govActionInfo(govActionID: govActionID)
        }
    }

    static let badCertIndices: [Int] = [Int(UInt16.max) + 1, -1]

    @Test("A Blockfrost cert_index outside UInt16 throws", arguments: badCertIndices)
    func blockfrostCertIndex(_ certIndex: Int) async throws {
        let list = try JSONEncoder().encode([
            Components.Schemas.ProposalsPayload(
                id: "gov_action1qkm52uwlnw0gtcyh9259sjuwsyrnjdfd3hg7tjzrl463xtv4wfxysqqqqqfd6vw0",
                txHash: proposalTxHash,
                certIndex: certIndex,
                governanceType: .infoAction
            )
        ])
        let context = try await blockfrost(["get/governance/proposals": list])
        await #expect(throws: CardanoChainError.self) { _ = try await context.govActionsAll() }
    }

    private func parameters(extraEntropy: String?) throws -> Data {
        try JSONEncoder().encode(
            Components.Schemas.ProposalParameters(
                id: "gov_action1qkm52uwlnw0gtcyh9259sjuwsyrnjdfd3hg7tjzrl463xtv4wfxysqqqqqfd6vw0",
                txHash: proposalTxHash,
                certIndex: 1,
                parameters: Components.Schemas.ProposalParameters.ParametersPayload(
                    a0: 0.3, rho: 0.003, tau: 0.2, decentralisationParam: 0.5,
                    extraEntropy: extraEntropy, protocolMajorVer: 10, protocolMinorVer: 0
                )
            )
        )
    }

    private func parameterUpdate(extraEntropy: String?) async throws -> ProtocolParamUpdate {
        let context = try await blockfrost([
            "get/governance/proposals/{tx_hash}/{cert_index}/parameters": try parameters(extraEntropy: extraEntropy)
        ])
        let info = try await context.govActionInfo(govActionID: govActionID)
        guard case let .parameterChangeAction(action) = info.govAction else {
            Issue.record("Expected a parameter change, got \(info.govAction)")
            throw CardanoChainError.valueError("not a parameter change")
        }
        return action.protocolParamUpdate
    }

    @Test("A null Blockfrost extra_entropy leaves the nonce unchanged")
    func blockfrostNullExtraEntropy() async throws {
        #expect(try await parameterUpdate(extraEntropy: nil).extraEntropy == nil)
    }

    @Test("A hex Blockfrost extra_entropy is the nonce's hash")
    func blockfrostHexExtraEntropy() async throws {
        let hex = "d982e06fd33e7440b43cefad529b7ecafbaa255e38178ad4189a37e4ce9bf1fa"
        let nonce = try #require(try await parameterUpdate(extraEntropy: hex).extraEntropy)
        #expect(nonce.hash == Data(hex: hex))
    }

    static let badEntropy: [String] = ["not hex", "abcd"]

    @Test("A Blockfrost extra_entropy that is not a 32-byte hex hash throws", arguments: badEntropy)
    func blockfrostBadExtraEntropy(_ value: String) async throws {
        await #expect(throws: (any Error).self) { _ = try await self.parameterUpdate(extraEntropy: value) }
    }

    // MARK: Yaci

    static let thresholdFields: [String] = [
        #""pvt_committee_no_confidence": 0.51, "#,
        #""dvt_treasury_withdrawal": 0.67, "#,
    ]

    @Test("A missing Yaci voting threshold throws instead of reading as 0", arguments: thresholdFields)
    func yaciMissingThreshold(_ field: String) async throws {
        var params = YaciMockResponses.protocolParams
        let before = params
        params = params.replacingOccurrences(of: field, with: "")
        #expect(params != before)
        let context = try YaciDevkitChainContext(
            apiURL: "http://localhost:8080",
            network: .custom(42),
            client: Client(
                serverURL: URL(string: "http://localhost:8080")!,
                transport: MockYaciTransport(overrides: ["getLatestProtocolParams": params])
            ),
            admin: MockYaciDevkitAdmin()
        )
        await #expect(throws: CardanoChainError.self) { _ = try await context.protocolParameters() }
    }

    static let committeeUpdates: [String] = [
        // No quorum at all.
        #"{"membersForRemoval": [], "newMembersAndTerms": {}}"#,
        // A quorum above one.
        #"{"membersForRemoval": [], "newMembersAndTerms": {}, "threshold": {"numerator": 3, "denominator": 2}}"#,
        // A member term that is not an epoch.
        #"{"membersForRemoval": [], "newMembersAndTerms": {"keyHash-00000000000000000000000000000000000000000000000000000000": -1}, "threshold": 0.5}"#,
    ]

    @Test("A Yaci committee update with a missing or invalid value throws", arguments: committeeUpdates)
    func yaciCommitteeUpdate(_ details: String) throws {
        let json = """
            {"tx_hash": "\(YaciMockData.proposalTxHash)", "index": 0,
             "type": "UPDATE_COMMITTEE", "details": \(details)}
            """
        let proposal = try JSONDecoder().decode(Components.Schemas.GovActionProposal.self, from: Data(json.utf8))
        let id = GovActionID(
            transactionID: TransactionId(payload: Data(hex: YaciMockData.proposalTxHash)), govActionIndex: 0)
        #expect(throws: CardanoChainError.self) { try YaciDevkitChainContext.govAction(from: proposal, id: id) }
    }

    // MARK: Anchors and relays

    /// A URL one byte over the ledger's 128-byte limit.
    static let longURL = "https://example.com/" + String(repeating: "a", count: 109)
    /// A DNS name one byte over the ledger's 128-byte limit.
    static let longDNSName = String(repeating: "a", count: 121) + ".example"
    static let anchorHash = "35aeb21ba4be07cf9fda041b635f107ef978238b3fccae9be1b571518ce9d1b7"

    @Test("The over-long fixtures are just over the ledger's limits")
    func overLongFixtures() {
        #expect(Self.longURL.utf8.count == 129)
        #expect(Self.longDNSName.utf8.count == 129)
    }

    static let longNameRelays: [SwiftYaciAPI.Components.Schemas.Relay] = [
        // A single-host name (it has a port).
        .init(port: 6000, dnsName: longDNSName),
        // A multi-host SRV name (no port).
        .init(dnsName: longDNSName),
    ]

    @Test("A Yaci relay whose DNS name is over the ledger's limit throws instead of being dropped",
          arguments: longNameRelays)
    func yaciLongRelayName(_ relay: SwiftYaciAPI.Components.Schemas.Relay) {
        #expect(throws: CardanoChainError.self) { try YaciDevkitChainContext.relay(from: relay) }
    }

    static let badAddressRelays: [SwiftYaciAPI.Components.Schemas.Relay] = [
        .init(port: 3001, ipv4: "300.1.2.3"),
        .init(port: 3001, ipv6: "not an address"),
    ]

    @Test("A Yaci relay whose address does not parse throws instead of being dropped",
          arguments: badAddressRelays)
    func yaciBadRelayAddress(_ relay: SwiftYaciAPI.Components.Schemas.Relay) {
        #expect(throws: CardanoChainError.self) { try YaciDevkitChainContext.relay(from: relay) }
    }

    static let anchorURLs: [String] = [longURL]

    @Test("An anchor URL over 128 bytes throws", arguments: anchorURLs)
    func anchorURLOverLimit(_ url: String) {
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.anchor(url: url, hash: Self.anchorHash, "anchor")
        }
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.anchor(json: ["url": url, "dataHash": Self.anchorHash], "anchor")
        }
        #expect(throws: CardanoChainError.self) {
            try YaciDevkitChainContext.anchor(url: url, hash: Self.anchorHash)
        }
    }

    @Test("A URL of exactly 128 bytes is kept as written")
    func anchorURLAtLimit() throws {
        let url = "https://example.com/" + String(repeating: "a", count: 108)
        #expect(try LedgerValues.anchor(url: url, hash: Self.anchorHash, "anchor").anchorUrl.text == url)
    }

    private func drepMetadata(url: String) throws -> Data {
        try JSONEncoder().encode(
            SwiftBlockfrostAPI.Components.Schemas.DrepMetadata(
                drepId: "drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0",
                hex: "b02f7b335aebf284bbdc20bdc3b59e4e183ae2cfc47ad2d8bc19a241",
                url: url,
                hash: Self.anchorHash,
                jsonMetadata: SwiftBlockfrostAPI.Components.Schemas.DrepMetadata.JsonMetadataPayload(),
                bytes: ""
            )
        )
    }

    @Test("A Blockfrost DRep anchor URL over 128 bytes throws instead of reading as no anchor")
    func blockfrostDRepLongAnchorURL() async throws {
        let context = try await blockfrost([
            "get/governance/dreps/{drep_id}/metadata": try drepMetadata(url: Self.longURL)
        ])
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.drepInfo(
                drep: DRep.fromBech32("drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0"))
        }
    }

    @Test("A Blockfrost proposal anchor URL over 128 bytes throws instead of being dropped")
    func blockfrostProposalLongAnchorURL() async throws {
        let metadata = try JSONEncoder().encode(
            SwiftBlockfrostAPI.Components.Schemas.ProposalMetadata(
                id: "gov_action1qkm52uwlnw0gtcyh9259sjuwsyrnjdfd3hg7tjzrl463xtv4wfxysqqqqqfd6vw0",
                txHash: proposalTxHash,
                certIndex: 1,
                url: Self.longURL,
                hash: Self.anchorHash,
                bytes: ""
            )
        )
        let context = try await blockfrost([
            "get/governance/proposals/{tx_hash}/{cert_index}": try proposal(),
            "get/governance/proposals/{tx_hash}/{cert_index}/metadata": metadata,
        ])
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.govActionVotes(govActionID: govActionID)
        }
    }

    private func constitutionProposal(_ description: String) -> Data {
        describedProposal("new_constitution", description)
    }

    private func describedProposal(_ type: String, _ description: String) -> Data {
        Data("""
            {"id": "gov_action1qkm52uwlnw0gtcyh9259sjuwsyrnjdfd3hg7tjzrl463xtv4wfxysqqqqqfd6vw0",
             "tx_hash": "\(proposalTxHash)", "cert_index": 1,
             "governance_type": "\(type)",
             "governance_description": \(description),
             "deposit": "12000",
             "return_address": "stake_test1urd3hs7rlxwwdzthe6hj026dmyt3y0heuulctscyydh2kgck6nkmz",
             "ratified_epoch": null, "enacted_epoch": null, "dropped_epoch": null,
             "expired_epoch": null, "expiration": 120}
            """.utf8)
    }

    @Test("A Blockfrost new constitution carries its own anchor, not a placeholder or the proposal's")
    func blockfrostConstitutionAnchor() async throws {
        let constitutionURL = "ipfs://bafkreiconstitution"
        let scriptHash = "fa24fb305126805cf2164c161d852a0e7330cf988f1fe558cf7d4a64"
        let context = try await blockfrost([
            "get/governance/proposals/{tx_hash}/{cert_index}": constitutionProposal("""
                {"tag": "NewConstitution", "contents": [null,
                  {"anchor": {"url": "\(constitutionURL)", "dataHash": "\(Self.anchorHash)"},
                   "script": "\(scriptHash)"}]}
                """)
        ])
        let info = try await context.govActionInfo(govActionID: govActionID)
        guard case .newConstitution(let action) = info.govAction else {
            Issue.record("Expected a new constitution, got \(info.govAction)")
            return
        }
        #expect(action.constitution.anchor.anchorUrl.text == constitutionURL)
        #expect(action.constitution.anchor.anchorDataHash.payload.toHex == Self.anchorHash)
        #expect(action.constitution.scriptHash?.payload.toHex == scriptHash)
    }

    static let brokenConstitutionDescriptions: [String] = [
        // No description at all.
        "null",
        // A constitution with no anchor.
        #"{"tag": "NewConstitution", "contents": [null, {"script": null}]}"#,
        // An anchor whose URL is over the ledger's limit.
        #"{"tag": "NewConstitution", "contents": [null, {"anchor": {"url": ""# + longURL
            + #"", "dataHash": ""# + anchorHash + #""}}]}"#,
        // An anchor whose hash is not a 32-byte hash.
        #"{"tag": "NewConstitution", "contents": [null, {"anchor": {"url": "ipfs://x", "dataHash": "abcd"}}]}"#,
    ]

    @Test("A Blockfrost new constitution with no valid anchor throws instead of using a placeholder",
          arguments: brokenConstitutionDescriptions)
    func blockfrostConstitutionNoAnchor(_ description: String) async throws {
        let context = try await blockfrost([
            "get/governance/proposals/{tx_hash}/{cert_index}": constitutionProposal(description)
        ])
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.govActionInfo(govActionID: govActionID)
        }
    }

    // MARK: Strict hex

    static let badHotKeys: [String] = [
        // 29 bytes, which the lenient reader used to take as a key hash.
        String(repeating: "00", count: 29),
        "not hex",
    ]

    @Test("A Blockfrost committee hot key that is not a 28-byte hash throws", arguments: badHotKeys)
    func blockfrostBadHotKey(_ hotHex: String) async throws {
        let committee = try JSONEncoder().encode(
            SwiftBlockfrostAPI.Components.Schemas.Committee(
                govActionId: nil, proposalTxHash: nil, proposalIndex: nil, isDissolved: false,
                quorum: .init(numerator: 2, denominator: 3),
                members: [
                    .init(
                        ccColdId: "cc_cold1zgqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqz3la7s",
                        ccColdHex: "13493790d9b03483a1e1e684ea4faf1ee48a58f402574e7f2246f4d4",
                        ccColdHasScript: false,
                        ccHotId: nil, ccHotHex: hotHex, ccHotHasScript: false,
                        status: .authorized, expirationEpoch: 800)
                ]))
        let context = try await blockfrost(["get/governance/committee": committee])
        await #expect(throws: CardanoChainError.self) { _ = try await context.committeeState() }
    }

    // MARK: Blockfrost committee update

    @Test("A Blockfrost committee update reads its members and quorum, not an empty 0/1 stand-in")
    func blockfrostCommitteeUpdate() async throws {
        let removed = String(repeating: "ab", count: 28)
        let added = String(repeating: "cd", count: 28)
        let context = try await blockfrost([
            "get/governance/proposals/{tx_hash}/{cert_index}": describedProposal("new_committee", """
                {"tag": "UpdateCommittee", "contents": [null,
                  [{"keyHash": "\(removed)"}],
                  {"scriptHash-\(added)": 580},
                  0.67]}
                """)
        ])
        let info = try await context.govActionInfo(govActionID: govActionID)
        guard case .updateCommittee(let update) = info.govAction else {
            Issue.record("Expected a committee update, got \(info.govAction)")
            return
        }
        let addedCredential = CommitteeColdCredential(
            credential: .scriptHash(ScriptHash(payload: Data(hex: added))))
        let removedCredential = CommitteeColdCredential(
            credential: .verificationKeyHash(VerificationKeyHash(payload: Data(hex: removed))))
        #expect(update.coldCredentials == [addedCredential, removedCredential])
        #expect(update.credentialEpochs == [addedCredential: 580])
        #expect(update.interval.numerator == 67 && update.interval.denominator == 100)
    }

    static let brokenCommitteeDescriptions: [String] = [
        // No description: Blockfrost has nowhere else to read the update from.
        "null",
        // A description of a different action.
        #"{"tag": "InfoAction"}"#,
        // No quorum.
        #"{"tag": "UpdateCommittee", "contents": [null, [], {}]}"#,
        // A member whose hash is not 28 bytes.
        #"{"tag": "UpdateCommittee", "contents": [null, [{"keyHash": "abcd"}], {}, 0.5]}"#,
    ]

    @Test("A Blockfrost committee update with no readable description throws",
          arguments: brokenCommitteeDescriptions)
    func blockfrostBrokenCommitteeUpdate(_ description: String) async throws {
        let context = try await blockfrost([
            "get/governance/proposals/{tx_hash}/{cert_index}": describedProposal("new_committee", description)
        ])
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.govActionInfo(govActionID: govActionID)
        }
    }
}
