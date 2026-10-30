import Foundation
import HTTPTypes
import OpenAPIRuntime
import SwiftBlockfrostAPI
import SwiftCardanoCore
import SwiftKoios
import Testing
@testable import SwiftCardanoChain

@Suite("Open governance actions")
struct OpenGovActionsTests {
    /// Transaction ids for proposals, newest (index 0) first.
    static func txHash(_ n: Int) -> String { String(format: "%064x", n + 1) }

    @Test("Blockfrost lists newest first and stops at the first expired proposal")
    func blockfrost() async throws {
        // The mock's epoch is 500. Newest first: open, ratified, open, expired by
        // epoch, then one that must never be fetched.
        let transport = BlockfrostProposalsTransport(proposals: [
            .init(expiration: 505),
            .init(expiration: 504, ratified: 499),
            .init(expiration: 500),
            .init(expiration: 499),
            .init(expiration: 498),
        ])
        let chainContext = try await BlockFrostChainContext(
            projectId: "fake-project-id",
            network: .preview,
            client: SwiftBlockfrostAPI.Client(
                serverURL: URL(string: "https://cardano-preview.blockfrost.io/api/v0")!,
                transport: transport
            )
        )

        let open = try await chainContext.openGovActions()

        #expect(open.map(\.govActionId.transactionID.payload.toHex) == [Self.txHash(0), Self.txHash(2)])
        #expect(open.map(\.expiresAfter) == [505, 500])
        #expect(open.first?.type == .treasuryWithdrawalsAction)
        #expect(open.first?.deposit == Coin(100_000_000_000))
        // One list request, and details only up to the batch holding the
        // first expired proposal: none of the votes.
        #expect(transport.counter.count("get/governance/proposals") == 1)
        #expect(transport.counter.count("get/governance/proposals/{tx_hash}/{cert_index}") == 5)
        #expect(transport.counter.count("get/governance/proposals/{tx_hash}/{cert_index}/votes") == 0)
    }

    @Test("Koios selects only the columns it needs and drops concluded and expired proposals")
    func koios() async throws {
        func row(_ n: Int, expiration: Int, enacted: Int? = nil) -> String {
            """
            {"proposal_tx_hash": "\(Self.txHash(n))", "proposal_index": 0, "proposal_type": "InfoAction",
             "deposit": "100000000000", "proposed_epoch": 494, "ratified_epoch": null,
             "enacted_epoch": \(enacted.map(String.init) ?? "null"), "dropped_epoch": null, "expired_epoch": null,
             "expiration": \(expiration), "meta_url": "https://anchor.test", "meta_hash": "\(String(repeating: "ab", count: 32))"}
            """
        }
        let rows = [row(0, expiration: 506), row(1, expiration: 505, enacted: 499), row(2, expiration: 499)]
        let recorder = QueryRecorder()
        let chainContext = try await KoiosChainContext(
            network: .preview,
            client: SwiftKoios.Client(
                serverURL: try SwiftKoios.Network.preview.url(),
                transport: RecordingTransport(
                    wrapped: KoiosMockTransport(overrides: ["proposal_list": "[\(rows.joined(separator: ","))]"]),
                    recorder: recorder
                )
            )
        )

        let open = try await chainContext.openGovActions()

        #expect(open.count == 1)
        #expect(open.first?.govActionId.transactionID.payload.toHex == Self.txHash(0))
        #expect(open.first?.type == .infoAction)
        #expect(open.first?.proposedIn == 494 && open.first?.expiresAfter == 506)
        #expect(open.first?.anchor?.anchorUrl.absoluteString == "https://anchor.test")
        let query = try #require(recorder.paths["proposal_list"])
        #expect(query.contains("select=") && !query.contains("meta_json") && !query.contains("proposal_description"))
    }

    @Test("A backend reading the ledger filters every action it lists")
    func defaultFilter() async throws {
        let open = try await GovStateContext().openGovActions()
        #expect(open.map(\.govActionId.govActionIndex) == [0])
    }

    @Test("An unknown expiry is open; a past one is not")
    func expiry() {
        #expect(OpenGovAction.isOpen(expiresAfter: nil, in: 10))
        #expect(OpenGovAction.isOpen(expiresAfter: 10, in: 10))
        #expect(!OpenGovAction.isOpen(expiresAfter: 9, in: 10))
    }
}

// MARK: - Blockfrost

final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func add(_ operation: String) {
        lock.withLock { counts[operation, default: 0] += 1 }
    }

    func count(_ operation: String) -> Int {
        lock.withLock { counts[operation] ?? 0 }
    }
}

/// Serves a list of proposals and their details, counting requests;
/// everything else goes to the shared mock.
struct BlockfrostProposalsTransport: ClientTransport {
    struct Proposal {
        var expiration: Int
        var ratified: Int?
    }

    let proposals: [Proposal]
    let counter = RequestCounter()
    private let fallback = MockTransport()

    init(proposals: [Proposal]) {
        self.proposals = proposals
    }

    func send(
        _ request: HTTPTypes.HTTPRequest,
        body: OpenAPIRuntime.HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
        counter.add(operationID)
        let data: Data
        switch operationID {
        case "get/governance/proposals":
            data = try JSONEncoder().encode(proposals.indices.map { n in
                Components.Schemas.ProposalsPayload(
                    id: "gov_action\(n)", txHash: OpenGovActionsTests.txHash(n), certIndex: 0, governanceType: .treasuryWithdrawals
                )
            })
        case "get/governance/proposals/{tx_hash}/{cert_index}":
            let hash = request.path?.split(separator: "/").dropLast().last.map(String.init) ?? ""
            let n = try #require(proposals.indices.first { OpenGovActionsTests.txHash($0) == hash })
            data = try JSONEncoder().encode(Components.Schemas.Proposal(
                id: "gov_action\(n)",
                txHash: hash,
                certIndex: 0,
                governanceType: .treasuryWithdrawals,
                governanceDescription: .object([:]),
                deposit: "100000000000",
                returnAddress: "stake_test1urd3hs7rlxwwdzthe6hj026dmyt3y0heuulctscyydh2kgck6nkmz",
                ratifiedEpoch: proposals[n].ratified,
                enactedEpoch: nil,
                droppedEpoch: nil,
                expiredEpoch: nil,
                expiration: proposals[n].expiration
            ))
        default:
            return try await fallback.send(request, body: body, baseURL: baseURL, operationID: operationID)
        }
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), .init(data))
    }
}

// MARK: - Koios

final class QueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String: String] = [:]

    func record(_ operation: String, _ path: String) {
        lock.withLock { recorded[operation] = path }
    }

    var paths: [String: String] { lock.withLock { recorded } }
}

/// Records each request's path and query, then passes it on.
struct RecordingTransport<Wrapped: ClientTransport>: ClientTransport {
    let wrapped: Wrapped
    let recorder: QueryRecorder

    func send(
        _ request: HTTPTypes.HTTPRequest,
        body: OpenAPIRuntime.HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
        recorder.record(operationID, request.path?.removingPercentEncoding ?? "")
        return try await wrapped.send(request, body: body, baseURL: baseURL, operationID: operationID)
    }
}

// MARK: - Default implementation

/// A context that reads governance state in one query, as a node does.
private struct GovStateContext: ChainContext {
    var name: String { "stub" }
    var type: ContextType { .online }
    var networkId: NetworkId { .testnet }

    func govActionsAll() async throws -> [GovActionVotes] {
        func action(_ index: UInt16, expiresAfter: UInt64, enacted: UInt64? = nil) -> GovActionVotes {
            GovActionVotes(
                govActionId: GovActionID(transactionID: TransactionId(payload: Data(repeating: 1, count: 32)), govActionIndex: index),
                govAction: .infoAction(InfoAction()),
                committeeVotes: [], dRepVotes: [], stakePoolVotes: [],
                deposit: Coin(1), depositReturnAddr: Data(), anchor: nil,
                proposedIn: 1, expiresAfter: expiresAfter, enactedEpoch: enacted
            )
        }
        return [action(0, expiresAfter: 12), action(1, expiresAfter: 12, enacted: 9), action(2, expiresAfter: 9)]
    }

    func protocolParameters() async throws -> ProtocolParameters { throw CardanoChainError.notImplemented(nil) }
    func genesisParameters() async throws -> GenesisParameters { throw CardanoChainError.notImplemented(nil) }
    func epoch() async throws -> Int { 10 }
    func era() async throws -> Era? { nil }
    func lastBlockSlot() async throws -> Int { 0 }
}

@Suite("Koios current epoch")
struct KoiosCurrentEpochTests {
    @Test("The current epoch is the tip's, not the first row of the whole epoch table")
    func epochFromTip() async throws {
        let chainContext = try await KoiosChainContext(
            network: .preview,
            client: SwiftKoios.Client(serverURL: try SwiftKoios.Network.preview.url(), transport: EpochTableTransport())
        )
        #expect(try await chainContext.epoch() == 500)
    }
}

/// Serves the whole epoch table, oldest first, unless one epoch is asked for.
private struct EpochTableTransport: ClientTransport {
    private let fallback = KoiosMockTransport()

    func send(
        _ request: HTTPTypes.HTTPRequest,
        body: OpenAPIRuntime.HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
        guard operationID == "epoch_info" else {
            return try await fallback.send(request, body: body, baseURL: baseURL, operationID: operationID)
        }
        let end = Int(Date().timeIntervalSince1970) + 3600
        let query = request.path ?? ""
        let epochs = query.contains("_epoch_no=500") ? [500] : [1, 2, 500]
        let rows = epochs.map { #"{"epoch_no": \#($0), "end_time": \#(end)}"# }
        return (
            HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
            .init(Data("[\(rows.joined(separator: ","))]".utf8))
        )
    }
}
