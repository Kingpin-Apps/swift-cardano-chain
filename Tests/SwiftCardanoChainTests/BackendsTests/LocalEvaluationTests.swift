import Foundation
import OpenAPIRuntime
import SwiftBlockfrostAPI
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoChain

@Suite("Local evaluation inputs")
struct LocalEvaluationTests {
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

    @Test("The slot timeline comes from the chain's genesis")
    func slotTimelineFromGenesis() async throws {
        let context = try await blockfrost()
        #expect(try await context.slotTimeline() == .mainnet)
    }

    @Test("Map-form redeemers keep their tag and index")
    func mapRedeemersKeepTheirKeys() throws {
        let transaction = try Transaction.fromCBORHex(try ChainFixtures.mapRedeemerTransactionHex())
        let redeemers = BlockFrostChainContext.extractRedeemers(from: transaction)
        #expect(!redeemers.isEmpty)
        #expect(redeemers.allSatisfy { $0.tag != nil })
        let keys = Set(redeemers.map { "\($0.tag!):\($0.index)" })
        #expect(keys.count == redeemers.count)
    }
}
