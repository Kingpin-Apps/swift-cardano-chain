import Foundation
import HTTPTypes
import OpenAPIRuntime
import SwiftBlockfrostAPI
import SwiftCardanoCore
import SwiftOgmios
import SwiftYaciAPI
import Testing

#if NODESOCKET
import SwiftCardanoNetwork
#endif

@testable import SwiftCardanoChain

/// Answers the listed Blockfrost operations with the given status and body, and
/// everything else from `MockTransport`.
private struct StatusOverrideTransport: ClientTransport {
    let overrides: [String: (HTTPResponse.Status, String)]
    private let fallback = MockTransport()

    init(_ overrides: [String: (HTTPResponse.Status, String)]) {
        self.overrides = overrides
    }

    func send(
        _ request: HTTPTypes.HTTPRequest, body: OpenAPIRuntime.HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
        if let (status, json) = overrides[operationID] {
            return (HTTPResponse(status: status, headerFields: [.contentType: "application/json"]), .init(json))
        }
        return try await fallback.send(request, body: body, baseURL: baseURL, operationID: operationID)
    }
}

private struct Unexpected: Error {}

@Suite("Optional enrichment is nil only when the data is unavailable")
struct OptionalEnrichmentTests {

    // MARK: Ogmios

    static let poolId = "pool1qqa8tkycj4zck4sy7n8mqr22x5g7tvm8hnp9st95wmuvvtw28th"

    private func ogmios(_ method: String, _ body: String) -> Data {
        Data(#"{"jsonrpc": "2.0", "method": "\#(method)", \#(body), "id": null}"#.utf8)
    }

    @Test("A query the Ogmios server does not answer leaves its figures out")
    func ogmiosUnsupported() async throws {
        let error = #""error": {"code": -32601, "message": "Unknown method"}"#
        let context = try await createMockOgmiosChainContext(overrides: [
            "queryLedgerState/operationalCertificates": ogmios("queryLedgerState/operationalCertificates", error),
            "queryLedgerState/stakePoolsPerformances": ogmios("queryLedgerState/stakePoolsPerformances", error),
        ])
        let info = try await context.stakePoolInfo(poolId: Self.poolId)
        #expect(info.opcertCounter == nil)
        #expect(info.liveStake == nil && info.liveSize == nil && info.livePledge == nil)
        #expect(info.poolParams.cost == 340_000_000)
    }

    @Test("An Ogmios answer that does not decode throws instead of being left out",
          arguments: ["queryLedgerState/operationalCertificates", "queryLedgerState/stakePoolsPerformances"])
    func ogmiosMalformed(_ method: String) async throws {
        let context = try await createMockOgmiosChainContext(overrides: [
            method: ogmios(method, #""result": "not the shape""#)
        ])
        await #expect(throws: (any Error).self) {
            _ = try await context.stakePoolInfo(poolId: Self.poolId)
        }
    }

    @Test("An operational certificate counter out of range throws")
    func ogmiosNegativeCounter() async throws {
        let method = "queryLedgerState/operationalCertificates"
        let context = try await createMockOgmiosChainContext(overrides: [
            method: ogmios(method, #""result": {"\#(Self.poolId)": -1}"#)
        ])
        await #expect(throws: (any Error).self) {
            _ = try await context.stakePoolInfo(poolId: Self.poolId)
        }
    }

    @Test("Only an unanswered Ogmios query is nil; other failures throw")
    func ogmiosHelper() async throws {
        let unsupported: Int? = try await OgmiosChainContext.optionalLedgerQuery {
            throw OgmiosError.responseError("Ogmios returned an unknown error code: -32601")
        }
        #expect(unsupported == nil)
        let notFound: Int? = try await OgmiosChainContext.optionalLedgerQuery {
            throw OgmiosError.connectionError("HTTP Error: 404, Response Body: ")
        }
        #expect(notFound == nil)
        #expect(try await OgmiosChainContext.optionalLedgerQuery { 7 } == 7)
        await #expect(throws: OgmiosError.self) {
            _ = try await OgmiosChainContext.optionalLedgerQuery { () throws -> Int in
                throw OgmiosError.connectionError("HTTP Error: 500, Response Body: ")
            }
        }
        await #expect(throws: OgmiosError.self) {
            _ = try await OgmiosChainContext.optionalLedgerQuery { () throws -> Int in
                throw OgmiosError.connectionError("Connection refused")
            }
        }
        await #expect(throws: Unexpected.self) {
            _ = try await OgmiosChainContext.optionalLedgerQuery { () throws -> Int in throw Unexpected() }
        }
    }

    // MARK: Blockfrost

    static let drep = "drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0"

    private func blockfrost(_ overrides: [String: (HTTPResponse.Status, String)]) async throws -> BlockFrostChainContext {
        try await BlockFrostChainContext(
            projectId: "fake-project-id",
            network: .preview,
            client: Client(
                serverURL: URL(string: "https://cardano-preview.blockfrost.io/api/v0")!,
                transport: StatusOverrideTransport(overrides)))
    }

    @Test("A DRep whose metadata endpoint answers 404 has no anchor")
    func blockfrostNotFound() async throws {
        let context = try await blockfrost([
            "get/governance/dreps/{drep_id}/metadata": (.notFound, #"{"status_code": 404, "error": "Not Found", "message": "none"}"#)
        ])
        let info = try await context.drepInfo(drep: DRep.fromBech32(Self.drep))
        #expect(info.anchor == nil)
    }

    @Test("A DRep metadata answer that does not decode throws instead of dropping the anchor")
    func blockfrostMalformed() async throws {
        let context = try await blockfrost([
            "get/governance/dreps/{drep_id}/metadata": (.ok, #"["not", "metadata"]"#)
        ])
        await #expect(throws: (any Error).self) {
            _ = try await context.drepInfo(drep: DRep.fromBech32(Self.drep))
        }
    }

    // MARK: Yaci

    private func yaci(_ transport: MockYaciTransport) throws -> YaciDevkitChainContext {
        try YaciDevkitChainContext(
            apiURL: "http://localhost:8080",
            network: .custom(42),
            client: SwiftYaciAPI.Client(serverURL: URL(string: "http://localhost:8080")!, transport: transport),
            admin: MockYaciDevkitAdmin())
    }

    @Test("A Yaci that does not serve the indexed committee falls back to the live view")
    func yaciNotServed() async throws {
        let state = try await yaci(MockYaciTransport(failing: ["getCommitteeMembers": 404])).committeeState()
        #expect(state.threshold?.numerator == 3 && state.threshold?.denominator == 5)
    }

    @Test("An indexed committee answer that does not decode throws instead of falling back")
    func yaciMalformed() async throws {
        let context = try yaci(MockYaciTransport(overrides: ["getCommitteeMembers": #"["not", "a committee"]"#]))
        await #expect(throws: (any Error).self) { _ = try await context.committeeState() }
    }

    // MARK: NodeSocket

    #if NODESOCKET
    @Test("Only a query the node does not support is nil; other failures throw")
    func nodeSocketHelper() async throws {
        let unsupported: Int? = try await NodeSocketChainContext.optionalQuery {
            throw LocalStateQueryError.queryNotSupported(name: "poolState", negotiatedVersion: 15, requiredVersion: 16)
        }
        #expect(unsupported == nil)
        #expect(try await NodeSocketChainContext.optionalQuery { 3 } == 3)
        await #expect(throws: LocalStateQueryError.self) {
            _ = try await NodeSocketChainContext.optionalQuery { () throws -> Int in
                throw LocalStateQueryError.unexpectedArrayLength(9)
            }
        }
        await #expect(throws: Unexpected.self) {
            _ = try await NodeSocketChainContext.optionalQuery { () throws -> Int in throw Unexpected() }
        }
    }
    #endif
}
