import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoUtils
import Mockable
import Command
import SystemPackage
@testable import SwiftCardanoChain

@Suite("CardanoCLI Chain Context Tests")
struct CardanoCLIContextTests {
    
    @Test("Test Initialization", arguments: [
        (Network.mainnet, NetworkId.mainnet),
        (Network.preprod, NetworkId.testnet),
        (Network.preview, NetworkId.testnet),
        
    ])
    func testInit(_ networks: (Network, NetworkId)) async throws {
        let config = createMockConfig()
        let runner = createCardaonCLIMockCommandRunner(config: config)
        
        let cli = try await CardanoCLI(configuration: config, commandRunner: runner)
        
        let chainContext = try await CardanoCliChainContext(
            nodeConfig: FilePath(configFilePath!),
            network: networks.0,
            cli: cli
        )
        
        let epoch = try await chainContext.epoch()
        let network = chainContext.networkId
        
        #expect(network == networks.1)
        #expect(epoch == 450)
    }
    
    @Test("Test lastBlockSlot")
    func testLastBlockSlot() async throws {
        let config = createMockConfig()
        let runner = createCardaonCLIMockCommandRunner(config: config)
        
        let cli = try await CardanoCLI(configuration: config, commandRunner: runner)
        
        let chainContext = try await CardanoCliChainContext(
            nodeConfig: FilePath(configFilePath!),
            network: .preview,
            cli: cli
        )
        
        let lastBlockSlot = try await chainContext.lastBlockSlot()
        
        #expect(lastBlockSlot == 123456789)
    }
    
    @Test("Test genesisParameters")
    func testGenesisParameters() async throws {
        let config = createMockConfig()
        let runner = createCardaonCLIMockCommandRunner(config: config)
        
        let cli = try await CardanoCLI(configuration: config, commandRunner: runner)
        
        let chainContext = try await CardanoCliChainContext(
            nodeConfig: FilePath(configFilePath!),
            network: .preview,
            cli: cli
        )
        
        let genesisParameters = try await chainContext.genesisParameters()
        
        #expect(genesisParameters.activeSlotsCoefficient == 0.05)
        #expect(genesisParameters.epochLength == 86400)
        #expect(genesisParameters.maxKesEvolutions == 62)
        #expect(genesisParameters.maxLovelaceSupply == 45000000000000000)
        #expect(genesisParameters.networkId == "Testnet")
        #expect(genesisParameters.networkMagic == 2)
        #expect(genesisParameters.slotLength == 1)
        #expect(genesisParameters.securityParam == 432)
        #expect(genesisParameters.slotsPerKesPeriod == 129600)
        #expect(genesisParameters.systemStart == ISO8601DateFormatter().date(from: "2022-10-25T00:00:00Z"))
        #expect(genesisParameters.updateQuorum == 5)
    }
    
    @Test("Test protocolParameters")
    func testProtocolParameters() async throws {
        let config = createMockConfig()
        let runner = createCardaonCLIMockCommandRunner(config: config)
        
        given(runner)
            .run(
                arguments: .value([config.cardano!.cli!.string] + CLICommands.protocolParams),
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput([UInt8](CLIResponse.protocolParams.utf8))
                    )
                    continuation.finish()
                }
            )
        
        let cli = try await CardanoCLI(configuration: config, commandRunner: runner)
        
        let chainContext = try await CardanoCliChainContext(
            nodeConfig: FilePath(configFilePath!),
            network: .preview,
            cli: cli
        )
        
        let protocolParameters = try await chainContext.protocolParameters()
        
        #expect(protocolParameters.txFeePerByte == 44)
        #expect(protocolParameters.txFeeFixed == 155381)
    }
    
    @Test("Test utxos")
    func testUTxOs() async throws {
        let config = createMockConfig()
        let runner = createCardaonCLIMockCommandRunner(config: config)
        
        given(runner)
            .run(
                arguments: .value([config.cardano!.cli!.string] + CLICommands.utxos),
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput([UInt8](CLIResponse.utxos.utf8))
                    )
                    continuation.finish()
                }
            )
        
        let cli = try await CardanoCLI(configuration: config, commandRunner: runner)
        
        let chainContext = try await CardanoCliChainContext(
            nodeConfig: FilePath(configFilePath!),
            network: .preview,
            cli: cli
        )
        
        let address = try Address(
            from: .string(
                "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
            )
        )
        
        let utxos = try await chainContext.utxos(address: address)
        
        #expect(
            utxos[0].input.transactionId.payload.toHex == "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58"
        )
    }
    
    @Test("Test submitTxCBOR")
    func testSubmitTxCBOR() async throws {
        let config = createMockConfig()
        let runner = createCardaonCLIMockCommandRunner(config: config)
        
        given(runner)
            .run(
                arguments: .value([config.cardano!.cli!.string] + CLICommands.queryTip),
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput([UInt8](CLIResponse.tip100.utf8))
                    )
                    continuation.finish()
                }
            )
            .run(
                arguments: .any,
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput([])
                    )
                    continuation.finish()
                }
            )
            .run(
                arguments: .any,
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput(
                            [UInt8]("d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908".utf8)
                        )
                    )
                    continuation.finish()
                }
            )
            .run(
                arguments: .value([config.cardano!.cli!.string] + CLICommands.queryTip),
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput([UInt8](CLIResponse.tip100.utf8))
                    )
                    continuation.finish()
                }
            )
            .run(
                arguments: .any,
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput([])
                    )
                    continuation.finish()
                }
            )
            .run(
                arguments: .any,
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput(
                            [UInt8]("d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908".utf8)
                        )
                    )
                    continuation.finish()
                }
            )
            .run(
                arguments: .value([config.cardano!.cli!.string] + CLICommands.queryTip),
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput([UInt8](CLIResponse.tip100.utf8))
                    )
                    continuation.finish()
                }
            )
            .run(
                arguments: .any,
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput([])
                    )
                    continuation.finish()
                }
            )
            .run(
                arguments: .any,
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput(
                            [UInt8]("d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908".utf8)
                        )
                    )
                    continuation.finish()
                }
            )
        
        let cli = try await CardanoCLI(configuration: config, commandRunner: runner)
        
        let chainContext = try await CardanoCliChainContext(
            nodeConfig: FilePath(configFilePath!),
            network: .preview,
            cli: cli
        )
        
        let txCBOR = "84a70081825820b35a4ba9ef3ce21adcd6879d08553642224304704d206c74d3ffb3e6eed3ca28000d80018182581d60cc30497f4ff962f4c1dca54cceefe39f86f1d7179668009f8eb71e598200a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680021a000493e00e8009a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680075820592a2df0e091566969b3044626faa8023dabe6f39c78f33bed9e105e55159221a200828258206443a101bdb948366fc87369336224595d36d8b0eee5602cba8b81a024e584735840846f408dee3b101fda0f0f7ca89e18b724b7ca6266eb29775d3967d6920cae7457accb91def9b77571e15dd2ede38b12cf92496ce7382fa19eb90ab7f73e49008258205797dc2cc919dfec0bb849551ebdf30d96e5cbe0f33f734a87fe826db30f7ef95840bdc771aa7b8c86a8ffcbe1b7a479c68503c8aa0ffde8059443055bf3e54b92f4fca5e0b9ca5bb11ab23b1390bb9ffce414fa398fc0b17f4dc76fe9f7e2c99c09018182018482051a075bcd1582041a075bcd0c8200581c9139e5c0a42f0f2389634c3dd18dc621f5594c5ba825d9a8883c66278200581c835600a2be276a18a4bebf0225d728f090f724f4c0acd591d066fa6ff5d90103a100a11902d1a16b7b706f6c6963795f69647da16d7b706f6c6963795f6e616d657da66b6465736372697074696f6e6a3c6f7074696f6e616c3e65696d6167656a3c72657175697265643e686c6f636174696f6ea367617277656176656a3c6f7074696f6e616c3e6568747470736a3c6f7074696f6e616c3e64697066736a3c72657175697265643e646e616d656a3c72657175697265643e667368613235366a3c72657175697265643e64747970656a3c72657175697265643e"
        
        let tx = try Transaction.fromCBORHex(txCBOR)
        
        let txId1 = try await chainContext.submitTx(tx: .transaction(tx))
        let txId2 = try await chainContext.submitTx(tx: .bytes(txCBOR.toData))
        let txId3 = try await chainContext.submitTx(tx: .string(txCBOR))
        
        #expect(
            txId1 == "d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908"
        )
        #expect(
            txId2 == "d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908"
        )
        #expect(
            txId3 == "d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908"
        )
    }
    
    @Test("Test stakeAddressInfo")
    func testStakeAddressInfo() async throws {
        let config = createMockConfig()
        let runner = createCardaonCLIMockCommandRunner(config: config)
        
        given(runner)
            .run(
                arguments: .value([config.cardano!.cli!.string] + CLICommands.stakeAddressInfo),
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput([UInt8](CLIResponse.stakeAddressInfo.utf8))
                    )
                    continuation.finish()
                }
            )
        
        let cli = try await CardanoCLI(configuration: config, commandRunner: runner)
        
        let chainContext = try await CardanoCliChainContext(
            nodeConfig: FilePath(configFilePath!),
            network: .preview,
            cli: cli
        )
        
        let address = try Address(
            from: .string(
                "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n"
            )
        )
        
        let stakeAddressInfo = try await chainContext.stakeAddressInfo(address: address)
        
        #expect(
            stakeAddressInfo[0].address == "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n"
        )
        #expect(
            stakeAddressInfo[0].stakeRegistrationDeposit == 2000000
        )
        #expect(
            stakeAddressInfo[0].rewardAccountBalance == 100000000000
        )
        #expect(
            try stakeAddressInfo[0].stakeDelegation?.id() == "pool1m5947rydk4n0ywe6ctlav0ztt632lcwjef7fsy93sflz7ctcx6z"
        )
        #expect(
            try stakeAddressInfo[0].voteDelegation?
                .id((.hex, .cip105)) == "b02f7b335aebf284bbdc20bdc3b59e4e183ae2cfc47ad2d8bc19a241"
        )
    }
    
    @Test("Test stakePools")
    func testStakePools() async throws {
        let config = createMockConfig()
        let runner = createCardaonCLIMockCommandRunner(config: config)
        
        given(runner)
            .run(
                arguments: .value([config.cardano!.cli!.string] + CLICommands.stakePools),
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput([UInt8](CLIResponse.stakePools.utf8))
                    )
                    continuation.finish()
                }
            )
        
        let cli = try await CardanoCLI(configuration: config, commandRunner: runner)
        
        let chainContext = try await CardanoCliChainContext(
            nodeConfig: FilePath(configFilePath!),
            network: .preview,
            cli: cli
        )
        
        let stakePools = try await chainContext.stakePools()
        
        #expect(
            stakePools[0] == "pool1qqa8tkycj4zck4sy7n8mqr22x5g7tvm8hnp9st95wmuvvtw28th"
        )
    }
    
    @Test("Test kesPeriodInfo throws without opCert")
    func testKESPeriodInfoThrowsWithoutOpCert() async throws {
        let config = createMockConfig()
        let runner = createCardaonCLIMockCommandRunner(config: config)
        
        let cli = try await CardanoCLI(configuration: config, commandRunner: runner)
        
        let chainContext = try await CardanoCliChainContext(
            nodeConfig: FilePath(configFilePath!),
            network: .preview,
            cli: cli
        )
        
        await #expect(throws: CardanoChainError.self) {
            _ = try await chainContext.kesPeriodInfo(pool: nil, opCert: nil)
        }
    }
    
    @Test("Test stakePoolInfo")
    func testStakePoolInfo() async throws {
        let config = createMockConfig()
        let runner = createCardaonCLIMockCommandRunner(config: config)
        
        given(runner)
            .run(
                arguments: .value([config.cardano!.cli!.string] + CLICommands.poolState),
                environment: .any,
                workingDirectory: .any
            )
            .willReturn(
                AsyncThrowingStream<CommandEvent, any Error> { continuation in
                    continuation.yield(
                        .standardOutput([UInt8](CLIResponse.poolState.utf8))
                    )
                    continuation.finish()
                }
            )
        
        let cli = try await CardanoCLI(configuration: config, commandRunner: runner)
        
        let chainContext = try await CardanoCliChainContext(
            nodeConfig: FilePath(configFilePath!),
            network: .preview,
            cli: cli
        )
        
        let poolParams = try await chainContext.stakePoolInfo(
            poolId: "pool1m5947rydk4n0ywe6ctlav0ztt632lcwjef7fsy93sflz7ctcx6z"
        )
        
        // Verify pool operator
        let poolOperator = PoolOperator(poolKeyHash: poolParams.poolOperator)
        #expect(
            try poolOperator.id(.hex) == "da2be8326fad9bdc9d9d617f58f12b5d14afe1d2ca5e4c109630a7e2"
        )
        
        // Verify VRF key hash
        #expect(
            poolParams.vrfKeyHash.payload.toHex == "adbafc4eae2ee532f0f0dc47e502debbfd1436bd16abfafe24e2af6db4bd149d"
        )
        
        // Verify pledge and cost
        #expect(poolParams.pledge == 10000000000)
        #expect(poolParams.cost == 340000000)
        
        // Verify margin (0.05 = 5%)
        let expectedMargin = Double(poolParams.margin.numerator) / Double(poolParams.margin.denominator)
        #expect(abs(expectedMargin - 0.05) < 0.0001)
        
        // Verify pool owners
        #expect(poolParams.poolOwners.count == 1)
        #expect(
            poolParams.poolOwners.asArray[0].payload.toHex == "89218aeaab042f371399f159a08168b43a23f7c3b3db5c3a4c77a18e"
        )
        
        // Verify relays
        #expect(poolParams.relays?.count == 2)
        if case .singleHostAddr(let addr) = poolParams.relays?[0] {
            #expect(addr.port == 3001)
            #expect(addr.ipv4?.address == "34.141.108.51")
        } else {
            Issue.record("Expected singleHostAddr relay")
        }
        if case .singleHostName(let name) = poolParams.relays?[1] {
            #expect(name.port == 3002)
            #expect(name.dnsName == "relay1.example.com")
        } else {
            Issue.record("Expected singleHostName relay")
        }
        
        // Verify metadata
        #expect(poolParams.poolMetadata != nil)
        #expect(poolParams.poolMetadata?.url?.absoluteString == "https://meta.wavepool.digital/midnight02.json")
        #expect(
            poolParams.poolMetadata?.poolMetadataHash?.payload.toHex == "db7b7e2943b84fe628fd75eb3cc01fc5c136a0a1dbc2cfb5fdeee6afdd943af1"
        )
    }
}
