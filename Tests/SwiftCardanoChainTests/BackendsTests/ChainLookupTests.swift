import Foundation
import OpenAPIRuntime
import SwiftCardanoCore
import SwiftBlockfrostAPI
import SwiftCardanoUPLC
import SwiftKoios
import Testing

@testable import SwiftCardanoChain

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ChainFixtures {
    /// The on-chain id of the fixture transaction, which uses map-form redeemers.
    static let mapRedeemerTransactionId = "f5cd70603aedb09e99c454f56f7afa59ad67c1def54d9022b70b8550a7b60700"

    static func mapRedeemerTransactionHex() throws -> String {
        let url = try #require(
            Bundle.module.resourceURL?.appendingPathComponent("data/tx/\(mapRedeemerTransactionId).hex")
        )
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Suite("Transactions by hash")
struct ChainLookupTests {
    let id = try! TransactionId(from: .string(ChainFixtures.mapRedeemerTransactionId))
    let otherId = TransactionId(payload: Data(repeating: 0xAB, count: 32))

    func blockfrost() async throws -> BlockFrostChainContext {
        try await BlockFrostChainContext(
            projectId: "fake-project-id",
            network: .mainnet,
            client: SwiftBlockfrostAPI.Client(
                serverURL: URL(string: "https://cardano-mainnet.blockfrost.io/api/v0")!,
                transport: MockTransport()
            )
        )
    }

    @Test("Blockfrost returns a transaction's bytes, and they hash to its id")
    func blockfrostTransaction() async throws {
        let context = try await blockfrost()
        let cbor = try await context.transactionCBOR(hash: id)
        #expect(cbor.toHex == (try ChainFixtures.mapRedeemerTransactionHex()))
        let transaction = try await context.transaction(hash: id)
        #expect(transaction.id == id)
    }

    @Test("A transaction whose bytes hash to another id is refused")
    func mismatchedTransactionIsRefused() async throws {
        let context = try await blockfrost()
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.transaction(hash: otherId)
        }
    }

    @Test("Koios returns a transaction's bytes")
    func koiosTransaction() async throws {
        let hex = try ChainFixtures.mapRedeemerTransactionHex()
        let context = try await KoiosChainContext(
            network: .mainnet,
            client: SwiftKoios.Client(serverURL: URL(string: "https://api.koios.rest/api/v1")!, transport: KoiosMockTransport(overrides: [
                "tx_cbor": #"[{"tx_hash": "\#(ChainFixtures.mapRedeemerTransactionId)", "cbor": "\#(hex)"}]"#
            ]))
        )
        let transaction = try await context.transaction(hash: id)
        #expect(transaction.id == id)
    }

    @Test("Koios reports a transaction it does not have")
    func koiosMissingTransaction() async throws {
        let context = try await KoiosChainContext(
            network: .mainnet,
            client: SwiftKoios.Client(serverURL: URL(string: "https://api.koios.rest/api/v1")!, transport: KoiosMockTransport(overrides: ["tx_cbor": "[]"]))
        )
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.transactionCBOR(hash: id)
        }
    }
}
