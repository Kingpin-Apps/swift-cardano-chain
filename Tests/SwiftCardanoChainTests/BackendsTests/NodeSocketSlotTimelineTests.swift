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

    /// The fixture genesis with `systemStart` replaced, built as the node query builds one.
    private static func genesis(systemStart: String) throws -> ShelleyGenesis {
        let path = try #require(Bundle.module.path(forResource: "shelley-genesis", ofType: "json", inDirectory: "data"))
        let g = try ShelleyGenesis.load(from: path)
        return ShelleyGenesis(
            activeSlotsCoeff: g.activeSlotsCoeff, protocolParams: g.protocolParams, genDelegs: g.genDelegs,
            updateQuorum: g.updateQuorum, networkId: g.networkId, initialFunds: g.initialFunds,
            maxLovelaceSupply: g.maxLovelaceSupply, networkMagic: g.networkMagic, epochLength: g.epochLength,
            systemStart: systemStart, slotsPerKESPeriod: g.slotsPerKESPeriod, slotLength: g.slotLength,
            maxKESEvolutions: g.maxKESEvolutions, securityParam: g.securityParam, staking: g.staking,
            extraConfig: g.extraConfig)
    }

    @Test("A genesis systemStart that does not parse throws instead of becoming the current time")
    func badSystemStart() throws {
        #expect(throws: CardanoChainError.self) {
            try NodeSocketChainContext.convertShelleyGenesis(Self.genesis(systemStart: "not a date"), network: .preview)
        }
        let params = try NodeSocketChainContext.convertShelleyGenesis(
            Self.genesis(systemStart: "2022-10-25T00:00:00.5Z"), network: .preview)
        #expect(params.systemStart == Date(timeIntervalSince1970: 1_666_656_000.5))
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
