import Testing
import Foundation
import SwiftCardanoCore
@testable import SwiftCardanoChain

@Suite("CardanoCLI Chain Context Tests", .enabled(if: CardanoCliChainContext<Never>.getCardanoCliPath() != nil && ProcessInfo.processInfo.environment["CARDANO_NODE_SOCKET_PATH"] != nil))
struct CardanoCLIContextTests {
    @Test("Test Initialization")
    func testInit() async throws {
        guard let configFilePath = Bundle.module.path(
            forResource: "config",
            ofType: "json",
            inDirectory: "data") else {
            Issue.record("File not found: config.json")
            try #require(Bool(false))
            return
        }
        
        let chainContext = try CardanoCliChainContext<Never>(
            configFile: URL(fileURLWithPath: configFilePath),
            network: .preview
        )

        _ = try await chainContext.genesisParameters()
        _ = try await chainContext.protocolParameters()
        _ = try await chainContext.lastBlockSlot()
        _ = try await chainContext.epoch()
        let network = chainContext.network
        
        _ = try await chainContext.utxos(address: Address(from: .string("addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3")))
        
        #expect(network == .testnet)
    }
}
