import Testing
import Foundation
import SwiftCardanoCore
@testable import SwiftCardanoChain


// MARK: - Test Suite

@Suite("Ogmios Chain Context Tests")
struct OgmiosChainContextTests {
    
    // Note: These tests require a running Ogmios instance or proper mocking.
    // Since OgmiosClient establishes connections in its initializer,
    // we test the individual conversion and helper methods where possible.
    
    @Test("Test network ID conversion")
    func testNetworkIdConversion() async throws {
        // Test that network IDs are correctly mapped
        let mainnetId = SwiftCardanoCore.Network.mainnet.networkId
        let preprodId = SwiftCardanoCore.Network.preprod.networkId
        let previewId = SwiftCardanoCore.Network.preview.networkId
        
        #expect(mainnetId == .mainnet)
        #expect(preprodId == .testnet)
        #expect(previewId == .testnet)
    }
    
    @Test("Test transaction data conversion")
    func testTransactionDataConversion() async throws {
        // Test TransactionData enum variants
        let cborHex = "84a70081825820b35a4ba9ef3ce21adcd6879d08553642224304704d206c74d3ffb3e6eed3ca28000d80018182581d60cc30497f4ff962f4c1dca54cceefe39f86f1d7179668009f8eb71e598200a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680021a000493e00e8009a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680075820592a2df0e091566969b3044626faa8023dabe6f39c78f33bed9e105e55159221a200828258206443a101bdb948366fc87369336224595d36d8b0eee5602cba8b81a024e584735840846f408dee3b101fda0f0f7ca89e18b724b7ca6266eb29775d3967d6920cae7457accb91def9b77571e15dd2ede38b12cf92496ce7382fa19eb90ab7f73e49008258205797dc2cc919dfec0bb849551ebdf30d96e5cbe0f33f734a87fe826db30f7ef95840bdc771aa7b8c86a8ffcbe1b7a479c68503c8aa0ffde8059443055bf3e54b92f4fca5e0b9ca5bb11ab23b1390bb9ffce414fa398fc0b17f4dc76fe9f7e2c99c09018182018482051a075bcd1582041a075bcd0c8200581c9139e5c0a42f0f2389634c3dd18dc621f5594c5ba825d9a8883c66278200581c835600a2be276a18a4bebf0225d728f090f724f4c0acd591d066fa6ff5d90103a100a11902d1a16b7b706f6c6963795f69647da16d7b706f6c6963795f6e616d657da66b6465736372697074696f6e6a3c6f7074696f6e616c3e65696d6167656a3c72657175697265643e686c6f636174696f6ea367617277656176656a3c6f7074696f6e616c3e6568747470736a3c6f7074696f6e616c3e64697066736a3c72657175697265643e646e616d656a3c72657175697265643e667368613235366a3c72657175697265643e64747970656a3c72657175697265643e"
        
        let tx = try Transaction.fromCBORHex(cborHex)
        
        // Test .transaction variant
        let txData1 = TransactionData.transaction(tx)
        if case .transaction(_) = txData1 {
            // Transaction was parsed and stored successfully
            #expect(true)
        } else {
            #expect(Bool(false), "Expected .transaction case")
        }
        
        // Test .bytes variant
        let cborData = Data(hex: cborHex)
        let txData2 = TransactionData.bytes(cborData)
        if case .bytes(let data) = txData2 {
            #expect(data.toHex == cborHex)
        }
        
        // Test .string variant
        let txData3 = TransactionData.string(cborHex)
        if case .string(let str) = txData3 {
            #expect(str == cborHex)
        }
    }
    
    @Test("Test address parsing")
    func testAddressParsing() async throws {
        let addressBech32 = "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
        
        let address = try Address(from: .string(addressBech32))
        let reconstructed = try address.toBech32()
        
        #expect(reconstructed == addressBech32)
    }
    
    @Test("Test stake address parsing")
    func testStakeAddressParsing() async throws {
        let stakeAddressBech32 = "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n"
        
        let address = try Address(from: .string(stakeAddressBech32))
        
        // Verify it has a staking part
        #expect(address.stakingPart != nil)
    }
    
    @Test("Test execution units structure")
    func testExecutionUnitsStructure() async throws {
        let execUnits = SwiftCardanoCore.ExecutionUnits(
            mem: 1000000,
            steps: 500000000
        )
        
        #expect(execUnits.mem == 1000000)
        #expect(execUnits.steps == 500000000)
    }
    
    @Test("Test ChainTip structure")
    func testChainTipStructure() async throws {
        let tip = ChainTip(
            block: 123456,
            epoch: 500,
            era: "conway",
            hash: "abcd1234",
            slot: 123456789,
            slotInEpoch: 65579,
            slotsToEpochEnd: 20821,
            syncProgress: "100.0"
        )
        
        #expect(tip.block == 123456)
        #expect(tip.epoch == 500)
        #expect(tip.era == "conway")
        #expect(tip.slot == 123456789)
    }
    
    @Test("Test StakeAddressInfo structure")
    func testStakeAddressInfoStructure() async throws {
        let stakeInfo = StakeAddressInfo(
            active: true,
            address: "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",
            rewardAccountBalance: 100000000,
            stakeDelegation: nil,
            voteDelegation: nil
        )
        
        #expect(stakeInfo.active == true)
        #expect(stakeInfo.rewardAccountBalance == 100000000)
    }
    
    @Test("Test UTxO conversion types")
    func testUtxoConversionTypes() async throws {
        // Test that we can create the types needed for UTxO conversion
        let txId = try TransactionId(from: .string("39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58"))
        let txIn = TransactionInput(transactionId: txId, index: 0)
        
        #expect(txIn.transactionId.payload.toHex == "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58")
        #expect(txIn.index == 0)
    }
    
    @Test("Test Value with multi-assets")
    func testValueWithMultiAssets() async throws {
        let policyId = ScriptHash(payload: Data(hex: "2e11e7313e00ccd086cfc4f1c3ebed4962d31b481b6a153c23601c0f"))
        let assetName = try AssetName(payload: Data(hex: "636861726c69335f6164615f6e6674"))
        
        var asset = Asset([:])
        asset[assetName] = 1
        
        var multiAsset = MultiAsset([:])
        multiAsset[policyId] = asset
        
        let value = Value(coin: 1000000, multiAsset: multiAsset)
        
        #expect(value.coin == 1000000)
        #expect(value.multiAsset[policyId] != nil)
        #expect(value.multiAsset[policyId]?[assetName] == 1)
    }
    
    @Test("Test CardanoChainError cases")
    func testCardanoChainErrorCases() async throws {
        let errors: [CardanoChainError] = [
            .blockfrostError("test"),
            .cardanoCLIError("test"),
            .invalidArgument("test"),
            .koiosError("test"),
            .operationError("test"),
            .transactionFailed("test"),
            .unsupportedNetwork("test"),
            .valueError("test")
        ]
        
        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }
}
