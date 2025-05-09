import Testing
import Foundation
import SwiftCardanoCore
@testable import SwiftCardanoChain

@Suite("Blockfrost Chain Context Tests", .enabled(if: ProcessInfo.processInfo.environment["BLOCKFROST_API_KEY"] != nil))
struct BlockfrostChainContextTests {
    @Test("Test Initialization")
    func testInit() async throws {
        let chainContext = try await BlockFrostChainContext<Never>(
            network: .preview,
            environmentVariable: "BLOCKFROST_API_KEY"
        )
        
        let genesisParam = try await chainContext.genesisParameters()
        let protocolParam = try await chainContext.protocolParameters()
        let lastBlockSlot = try await chainContext.lastBlockSlot()
        let epoch = try await chainContext.epoch()
        let network = chainContext.network
        
        let utxos = try await chainContext.utxos(address: Address(from: .string("addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3")))
        
        #expect(chainContext != nil)
        #expect(genesisParam != nil)
        #expect(protocolParam != nil)
        #expect(lastBlockSlot != nil)
        #expect(epoch != nil)
        #expect(utxos != nil)
        #expect(network == .testnet)
    }
}
