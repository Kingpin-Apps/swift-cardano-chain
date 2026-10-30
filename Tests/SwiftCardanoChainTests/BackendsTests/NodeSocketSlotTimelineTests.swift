#if NODESOCKET
import Foundation
import SwiftCardanoCore
import SwiftCardanoNetwork
import SystemPackage
import Testing

@testable import SwiftCardanoChain

private struct GenesisUnreadable: Error {}

@Suite("NodeSocket slot timeline comes from genesis")
struct NodeSocketSlotTimelineTests {

    /// Preview's genesis parameters, from the fixture genesis file.
    private static func previewGenesis() throws -> GenesisParameters {
        let path = try #require(Bundle.module.path(forResource: "shelley-genesis", ofType: "json", inDirectory: "data"))
        return try NodeSocketChainContext.convertShelleyGenesis(ShelleyGenesis.load(from: path), network: .preview)
    }

    @Test("A known network's slot timeline is the built-in one")
    func knownNetwork() async throws {
        let genesis = try Self.previewGenesis()
        let context = NodeSocketChainContext(
            socketPath: FilePath("/nonexistent/node.socket"), network: .preview, genesisLoader: { genesis })
        #expect(try await context.slotTimeline() == .preview)
    }

    @Test("A failing genesis read throws instead of leaving the timeline out")
    func genesisFailure() async throws {
        let context = NodeSocketChainContext(
            socketPath: FilePath("/nonexistent/node.socket"), network: .preview,
            genesisLoader: { throw GenesisUnreadable() })
        await #expect(throws: GenesisUnreadable.self) { _ = try await context.slotTimeline() }
        // Not cached: a later read tries again.
        await #expect(throws: GenesisUnreadable.self) { _ = try await context.genesisParameters() }
    }
}
#endif
