import Foundation
import SwiftCardanoCore
import SystemPackage
import Testing

@testable import SwiftCardanoChain

// MARK: - Test Fixtures

private let testAddressString =
    "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
private let testStakeAddressString =
    "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n"
private let testTxHashHex = "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58"
private let testPoolId = "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy"

// Reuse the signed tx CBOR from BlockfrostTests for submitTxCBOR.
private let testTxCBORHex =
    "84a70081825820b35a4ba9ef3ce21adcd6879d08553642224304704d206c74d3ffb3e6eed3ca28000d80018182581d60cc30497f4ff962f4c1dca54cceefe39f86f1d7179668009f8eb71e598200a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680021a000493e00e8009a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680075820592a2df0e091566969b3044626faa8023dabe6f39c78f33bed9e105e55159221a200828258206443a101bdb948366fc87369336224595d36d8b0eee5602cba8b81a024e584735840846f408dee3b101fda0f0f7ca89e18b724b7ca6266eb29775d3967d6920cae7457accb91def9b77571e15dd2ede38b12cf92496ce7382fa19eb90ab7f73e49008258205797dc2cc919dfec0bb849551ebdf30d96e5cbe0f33f734a87fe826db30f7ef95840bdc771aa7b8c86a8ffcbe1b7a479c68503c8aa0ffde8059443055bf3e54b92f4fca5e0b9ca5bb11ab23b1390bb9ffce414fa398fc0b17f4dc76fe9f7e2c99c09018182018482051a075bcd1582041a075bcd0c8200581c9139e5c0a42f0f2389634c3dd18dc621f5594c5ba825d9a8883c66278200581c835600a2be276a18a4bebf0225d728f090f724f4c0acd591d066fa6ff5d90103a100a11902d1a16b7b706f6c6963795f69647da16d7b706f6c6963795f6e616d657da66b6465736372697074696f6e6a3c6f7074696f6e616c3e65696d6167656a3c72657175697265643e686c6f636174696f6ea367617277656176656a3c6f7074696f6e616c3e6568747470736a3c6f7074696f6e616c3e64697066736a3c72657175697265643e646e616d656a3c72657175697265643e667368613235366a3c72657175697265643e64747970656a3c72657175697265643e"

// MARK: - Helpers

private func makeMinimalProtocolParameters() -> ProtocolParameters {
    ProtocolParameters(
        collateralPercentage: 150,
        committeeMaxTermLength: 146,
        committeeMinSize: 7,
        costModels: ProtocolParametersCostModels(PlutusV1: [], PlutusV2: [], PlutusV3: []),
        dRepActivity: 20,
        dRepDeposit: 500_000_000,
        dRepVotingThresholds: DRepVotingThresholds(
            committeeNoConfidence: 0.67, committeeNormal: 0.67,
            hardForkInitiation: 0.6, motionNoConfidence: 0.6,
            ppEconomicGroup: 0.67, ppGovGroup: 0.75,
            ppNetworkGroup: 0.67, ppTechnicalGroup: 0.67,
            treasuryWithdrawal: 0.67, updateToConstitution: 0.75
        ),
        executionUnitPrices: ExecutionUnitPrices(priceMemory: 0.0577, priceSteps: 0.0000721),
        govActionDeposit: 100_000_000_000,
        govActionLifetime: 6,
        maxBlockBodySize: 90112,
        maxBlockExecutionUnits: ProtocolParametersExecutionUnits(
            memory: 62_000_000, steps: 20_000_000_000),
        maxBlockHeaderSize: 1100,
        maxCollateralInputs: 3,
        maxTxExecutionUnits: ProtocolParametersExecutionUnits(
            memory: 14_000_000, steps: 10_000_000_000),
        maxTxSize: 16384,
        maxValueSize: 5000,
        minPoolCost: 170_000_000,
        monetaryExpansion: 0.003,
        poolPledgeInfluence: 0.3,
        poolRetireMaxEpoch: 18,
        poolVotingThresholds: ProtocolParametersPoolVotingThresholds(
            committeeNoConfidence: 0.51, committeeNormal: 0.51,
            hardForkInitiation: 0.51, motionNoConfidence: 0.51,
            ppSecurityGroup: 0.51
        ),
        protocolVersion: ProtocolParametersProtocolVersion(major: 9, minor: 0),
        stakeAddressDeposit: 2_000_000,
        stakePoolDeposit: 500_000_000,
        stakePoolTargetNum: 500,
        treasuryCut: 0.2,
        txFeeFixed: 155_381,
        txFeePerByte: 44,
        utxoCostPerByte: 4310
    )
}

private func makeMinimalGenesisParameters() -> GenesisParameters {
    GenesisParameters(
        activeSlotsCoefficient: 0.05,
        epochLength: 432_000,
        maxKesEvolutions: 62,
        maxLovelaceSupply: 45_000_000_000_000_000,
        networkId: "Testnet",
        networkMagic: 2,
        securityParam: 2160,
        slotLength: 1,
        slotsPerKesPeriod: 129_600,
        systemStart: Date(timeIntervalSince1970: 1_506_203_091),
        updateQuorum: 5
    )
}

/// Build a temp-file-backed `OfflineTransferChainContext` for testing.
private func makeContext(
    network: Network = .preview,
    extra: (inout OfflineTransfer) -> Void = { _ in }
) throws -> (context: OfflineTransferChainContext, filePath: FilePath) {
    let address = try Address(from: .string(testAddressString))
    let txId = try TransactionId(from: .string(testTxHashHex))
    let txInput = TransactionInput(transactionId: txId, index: 0)
    let txOutput = TransactionOutput(
        address: address,
        amount: Value(coin: 2_000_000)
    )
    let utxo = UTxO(input: txInput, output: txOutput)

    let stakeInfo = StakeAddressInfo(
        active: true,
        address: testStakeAddressString,
        rewardAccountBalance: 319_154_618_165
    )

    let addressInfo = try AddressInfo(
        fromAddressString: testAddressString,
        name: "Test Address"
    )

    var transfer = OfflineTransfer(
        general: OfflineTransferGeneral(onlineVersion: "1.0.0"),
        protocol: OfflineTransferProtocolData(
            protocolParameters: makeMinimalProtocolParameters(),
            genesisParameters: makeMinimalGenesisParameters(),
            era: .conway,
            network: network
        ),
        history: [OfflineTransferHistory(action: .new)],
        addresses: [
            try AddressInfo(
                name: addressInfo.name,
                address: addressInfo.address,
                utxos: [utxo],
                stakeAddressInfo: [stakeInfo]
            )
        ],
        kesPeriodInfos: [
            KESPeriodInfo(
                onChainOpCertCount: 42,
                onDiskOpCertCount: nil,
                nextChainOpCertCount: 43,
                onDiskKESStart: nil
            )
        ],
        treasury: Coin(1_000_000_000_000_000)
    )

    extra(&transfer)

    let tmpPath = FilePath(
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json").path
    )
    try transfer.save(to: tmpPath)

    let context = try OfflineTransferChainContext(filePath: tmpPath, network: network)
    return (context, tmpPath)
}

// MARK: - Tests

@Suite("OfflineTransfer Chain Context Tests")
struct OfflineTransferChainContextTests {

    // MARK: Identity

    @Test("name and type")
    func testNameAndType() throws {
        let (context, _) = try makeContext()
        #expect(context.name == "OfflineTransfer")
        #expect(context.type == .offline)
    }

    @Test(
        "networkId derived from file",
        arguments: [
            (Network.mainnet, NetworkId.mainnet),
            (Network.preprod, NetworkId.testnet),
            (Network.preview, NetworkId.testnet),
        ])
    func testNetworkId(_ pair: (Network, NetworkId)) throws {
        let (context, _) = try makeContext(network: pair.0)
        #expect(context.networkId == pair.1)
    }

    // MARK: Protocol / Genesis Parameters

    @Test("protocolParameters returns stored values")
    func testProtocolParameters() async throws {
        let (context, _) = try makeContext()
        let params = try await context.protocolParameters()
        #expect(params.txFeePerByte == 44)
        #expect(params.txFeeFixed == 155_381)
        #expect(params.utxoCostPerByte == 4310)
    }

    @Test("protocolParameters throws when absent")
    func testProtocolParametersMissing() async throws {
        let (context, _) = try makeContext { transfer in
            transfer.protocol = OfflineTransferProtocolData(
                protocolParameters: nil,
                genesisParameters: makeMinimalGenesisParameters()
            )
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.protocolParameters()
        }
    }

    @Test("genesisParameters returns stored values")
    func testGenesisParameters() async throws {
        let (context, _) = try makeContext()
        let genesis = try await context.genesisParameters()
        #expect(genesis.epochLength == 432_000)
        #expect(genesis.slotLength == 1)
        #expect(genesis.activeSlotsCoefficient == 0.05)
        #expect(genesis.networkMagic == 2)
        #expect(genesis.systemStart == Date(timeIntervalSince1970: 1_506_203_091))
    }

    @Test("genesisParameters throws when absent")
    func testGenesisParametersMissing() async throws {
        let (context, _) = try makeContext { transfer in
            transfer.protocol = OfflineTransferProtocolData(
                protocolParameters: makeMinimalProtocolParameters(),
                genesisParameters: nil
            )
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.genesisParameters()
        }
    }

    // MARK: Era

    @Test("era returns stored era")
    func testEra() async throws {
        let (context, _) = try makeContext()
        let era = try await context.era()
        #expect(era == .conway)
    }

    @Test("era returns nil when absent")
    func testEraAbsent() async throws {
        let (context, _) = try makeContext { transfer in
            transfer.protocol = OfflineTransferProtocolData(
                protocolParameters: makeMinimalProtocolParameters(),
                genesisParameters: makeMinimalGenesisParameters(),
                era: nil
            )
        }
        let era = try await context.era()
        #expect(era == nil)
    }

    // MARK: Epoch / lastBlockSlot

    @Test("epoch returns a non-negative integer")
    func testEpoch() async throws {
        let (context, _) = try makeContext()
        let epoch = try await context.epoch()
        #expect(epoch >= 0)
    }

    @Test("lastBlockSlot returns a non-negative integer")
    func testLastBlockSlot() async throws {
        let (context, _) = try makeContext()
        let slot = try await context.lastBlockSlot()
        #expect(slot >= 0)
    }

    // MARK: UTxOs

    @Test("utxos(address:) returns stored UTxOs")
    func testUTxOs() async throws {
        let (context, _) = try makeContext()
        let address = try Address(from: .string(testAddressString))
        let utxos = try await context.utxos(address: address)
        #expect(utxos.count == 1)
        #expect(utxos[0].input.transactionId.payload.toHex == testTxHashHex)
        #expect(utxos[0].output.amount.coin == 2_000_000)
    }

    @Test("utxos(address:) returns empty for unknown address")
    func testUTxOsUnknownAddress() async throws {
        let (context, _) = try makeContext()
        let unknownAddress = try Address(
            from: .string(
                "addr_test1qz2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3jcu5d8ps7zex2k2xt3uqxgjqnnj83ws8lhrn648jjxtwq2ytjqp"
            )
        )
        let utxos = try await context.utxos(address: unknownAddress)
        #expect(utxos.isEmpty)
    }

    @Test("utxo(input:) returns stored UTxO")
    func testUTxOInput() async throws {
        let (context, _) = try makeContext()
        let txId = try TransactionId(from: .string(testTxHashHex))
        let input = TransactionInput(transactionId: txId, index: 0)
        guard let (utxo, isSpent) = try await context.utxo(input: input) else {
            #expect(Bool(false), "Expected UTxO to be found")
            return
        }
        #expect(utxo.input.transactionId.payload.toHex == testTxHashHex)
        #expect(utxo.output.amount.coin == 2_000_000)
        #expect(isSpent == false)
    }

    @Test("utxo(input:) returns nil for unknown input")
    func testUTxOInputUnknown() async throws {
        let (context, _) = try makeContext()
        let unknownId = try TransactionId(
            from: .string("0000000000000000000000000000000000000000000000000000000000000000"))
        let input = TransactionInput(transactionId: unknownId, index: 0)
        let result = try await context.utxo(input: input)
        #expect(result == nil)
    }

    // MARK: submitTxCBOR

    @Test("submitTxCBOR saves transaction to file and returns tx hash")
    func testSubmitTxCBOR() async throws {
        let (context, filePath) = try makeContext()
        let txData = Data(hexString: testTxCBORHex)!

        let txHash = try await context.submitTxCBOR(cbor: txData)

        // Hash should be a non-empty hex string.
        #expect(!txHash.isEmpty)

        // File on disk should now contain the transaction entry.
        let reloaded = try OfflineTransfer.load(from: filePath)
        #expect(reloaded.transactions.count == 1)
        #expect(reloaded.transactions[0].txJson?.cborHex == testTxCBORHex)

        // History should record the save action.
        let saveEntry = reloaded.history.first(where: {
            if case .saveTransaction = $0.action { return true }
            return false
        })
        #expect(saveEntry != nil)

        try? FileManager.default.removeItem(atPath: filePath.string)
    }

    // MARK: Stake Address Info

    @Test("stakeAddressInfo returns stored info")
    func testStakeAddressInfo() async throws {
        let (context, _) = try makeContext()
        let stakeAddress = try Address(from: .string(testStakeAddressString))
        let infos = try await context.stakeAddressInfo(address: stakeAddress)
        #expect(infos.count == 1)
        #expect(infos[0].address == testStakeAddressString)
        #expect(infos[0].rewardAccountBalance == 319_154_618_165)
    }

    @Test("stakeAddressInfo returns empty for unknown address")
    func testStakeAddressInfoUnknown() async throws {
        let (context, _) = try makeContext()
        // Use a payment address that has no stakeAddressInfo stored for it.
        let unknownAddress = try Address(
            from: .string(
                "addr_test1qz2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3jcu5d8ps7zex2k2xt3uqxgjqnnj83ws8lhrn648jjxtwq2ytjqp"
            )
        )
        let infos = try await context.stakeAddressInfo(address: unknownAddress)
        #expect(infos.isEmpty)
    }

    // MARK: Stake Pools

    @Test("stakePools returns stored pools")
    func testStakePools() async throws {
        let pool = try PoolOperator(from: testPoolId)
        let (context, _) = try makeContext { transfer in
            transfer.stakePools = [pool]
        }
        let pools = try await context.stakePools()
        #expect(pools.count == 1)
        #expect((try? pools[0].id(.bech32)) == testPoolId)
    }

    @Test("stakePools returns empty when none stored")
    func testStakePoolsEmpty() async throws {
        let (context, _) = try makeContext()
        let pools = try await context.stakePools()
        #expect(pools.isEmpty)
    }

    // MARK: stakePoolInfo

    @Test("stakePoolInfo round-trips through JSON")
    func testStakePoolInfoRoundTrip() async throws {
        let poolKeyHash = PoolKeyHash(payload: Data(repeating: 0x01, count: 28))
        let poolParams = PoolParams(
            poolOperator: poolKeyHash,
            vrfKeyHash: VrfKeyHash(payload: Data(repeating: 0x02, count: 32)),
            pledge: 500_000_000,
            cost: 340_000_000,
            margin: UnitInterval(numerator: 1, denominator: 20),
            rewardAccount: RewardAccountHash(payload: Data(repeating: 0x03, count: 29)),
            poolOwners: .list([]),
            relays: nil,
            poolMetadata: nil
        )
        let poolInfo = StakePoolInfo(poolParams: poolParams)
        let poolId = try PoolOperator(poolKeyHash: poolKeyHash).id(.bech32)

        let (context, _) = try makeContext { transfer in
            transfer.stakePoolInfos = [poolInfo]
        }

        let result = try await context.stakePoolInfo(poolId: poolId)
        #expect(result.poolParams.pledge == 500_000_000)
        #expect(result.poolParams.margin.numerator == 1)
        #expect(result.poolParams.margin.denominator == 20)
    }

    @Test("stakePoolInfo throws for unknown pool")
    func testStakePoolInfoUnknown() async throws {
        let (context, _) = try makeContext()
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.stakePoolInfo(poolId: testPoolId)
        }
    }

    // MARK: KES Period Info

    @Test("kesPeriodInfo returns stored info")
    func testKESPeriodInfo() async throws {
        let (context, _) = try makeContext()
        let kesInfo = try await context.kesPeriodInfo(pool: nil, opCert: nil)
        #expect(kesInfo.onChainOpCertCount == 42)
        #expect(kesInfo.nextChainOpCertCount == 43)
    }

    @Test("kesPeriodInfo throws when none stored")
    func testKESPeriodInfoEmpty() async throws {
        let (context, _) = try makeContext { transfer in
            transfer.kesPeriodInfos = []
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.kesPeriodInfo(pool: nil, opCert: nil)
        }
    }

    // MARK: Treasury

    @Test("treasury returns stored balance")
    func testTreasury() async throws {
        let (context, _) = try makeContext()
        let amount = try await context.treasury()
        #expect(amount == Coin(1_000_000_000_000_000))
    }

    @Test("treasury throws when absent")
    func testTreasuryMissing() async throws {
        let (context, _) = try makeContext { transfer in
            transfer.treasury = nil
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.treasury()
        }
    }

    // MARK: evaluateTxCBOR

    @Test("evaluateTxCBOR returns stored evaluation units")
    func testEvaluateTxCBOR() async throws {
        let txData = Data(hexString: testTxCBORHex)!
        let cborHex = txData.toHex
        let expectedUnits = ExecutionUnits(mem: 100_000, steps: 500_000)

        let (context, _) = try makeContext { transfer in
            transfer.evaluations = [
                OfflineTransferEvaluation(
                    txCborHex: cborHex,
                    executionUnits: ["spend:0": expectedUnits]
                )
            ]
        }

        let units = try await context.evaluateTxCBOR(cbor: txData)
        #expect(units["spend:0"]?.mem == 100_000)
        #expect(units["spend:0"]?.steps == 500_000)
    }

    @Test("evaluateTxCBOR throws when no evaluation stored")
    func testEvaluateTxCBORMissing() async throws {
        let (context, _) = try makeContext()
        let txData = Data(hexString: testTxCBORHex)!
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.evaluateTxCBOR(cbor: txData)
        }
    }

    // MARK: DRep Info

    @Test("drepInfo returns stored info")
    func testDRepInfo() async throws {
        let drep = try DRep.fromBech32("drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0")
        let expectedInfo = DRepInfo(
            active: true,
            drep: drep,
            stake: Coin(500_000_000),
            status: .registered
        )

        let (context, _) = try makeContext { transfer in
            transfer.drepInfos = [expectedInfo]
        }

        let result = try await context.drepInfo(drep: drep)
        #expect(result == expectedInfo)
    }

    @Test("drepInfo throws for unknown DRep")
    func testDRepInfoUnknown() async throws {
        let (context, _) = try makeContext()
        let drep = try DRep.fromBech32("drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0")
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.drepInfo(drep: drep)
        }
    }

    // MARK: Gov Action Info

    @Test("govActionInfo round-trips through JSON")
    func testGovActionInfoRoundTrip() async throws {
        let govActionID = GovActionID(
            transactionID: TransactionId(payload: Data(repeating: 0xab, count: 32)),
            govActionIndex: 0
        )
        let govAction = GovAction.infoAction(InfoAction())

        let (context, _) = try makeContext { transfer in
            transfer.govActionInfos = [
                GovActionInfo(govActionId: govActionID, govAction: govAction)
            ]
        }

        let result = try await context.govActionInfo(govActionID: govActionID)
        #expect(result.govActionId == govActionID)
        #expect(result.govAction == govAction)
    }

    @Test("govActionInfo throws for unknown action")
    func testGovActionInfoUnknown() async throws {
        let (context, _) = try makeContext()
        let govActionID = GovActionID(
            transactionID: TransactionId(payload: Data(repeating: 0, count: 32)),
            govActionIndex: 0
        )
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.govActionInfo(govActionID: govActionID)
        }
    }

    // MARK: Committee Member Info

    @Test("committeeMemberInfo returns stored info")
    func testCommitteeMemberInfo() async throws {
        let credential = CommitteeColdCredential(
            credential: .verificationKeyHash(
                VerificationKeyHash(payload: Data(repeating: 0xab, count: 28))
            )
        )
        let expectedInfo = CommitteeMemberInfo(
            coldCredential: credential,
            hotCredential: nil,
            expiration: EpochNumber(300)
        )

        let (context, _) = try makeContext { transfer in
            transfer.committeeMemberInfos = [expectedInfo]
        }

        let result = try await context.committeeMemberInfo(committeeMember: credential)
        #expect(result == expectedInfo)
        #expect(result.expiration == EpochNumber(300))
    }

    @Test("committeeMemberInfo throws for unknown member")
    func testCommitteeMemberInfoUnknown() async throws {
        let (context, _) = try makeContext()
        let credential = CommitteeColdCredential(
            credential: .verificationKeyHash(
                VerificationKeyHash(payload: Data(repeating: 0xff, count: 28))
            )
        )
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.committeeMemberInfo(committeeMember: credential)
        }
    }

    // MARK: Round-trip Persistence

    @Test("OfflineTransfer round-trips through JSON save and load")
    func testRoundTrip() throws {
        let path = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".json").path
        )
        defer { try? FileManager.default.removeItem(atPath: path.string) }

        let original = OfflineTransfer(
            general: OfflineTransferGeneral(onlineVersion: "2.0.0"),
            protocol: OfflineTransferProtocolData(
                protocolParameters: makeMinimalProtocolParameters(),
                genesisParameters: makeMinimalGenesisParameters(),
                era: .conway,
                network: .preview
            ),
            history: [OfflineTransferHistory(date: ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z"), action: .new)],
            treasury: Coin(999)
        )

        try original.save(to: path)
        let loaded = try OfflineTransfer.load(from: path)

        #expect(loaded.general.onlineVersion == "2.0.0")
        #expect(loaded.protocol.era == .conway)
        #expect(loaded.protocol.protocolParameters?.txFeePerByte == 44)
        #expect(loaded.protocol.genesisParameters?.epochLength == 432_000)
        #expect(loaded.treasury == Coin(999))
        #expect(loaded.history.count == 1)
        #expect(loaded.history[0].action == .new)
    }

    @Test("OfflineTransfer.new creates file on disk")
    func testNewCreatesFile() throws {
        let path = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".json").path
        )
        defer { try? FileManager.default.removeItem(atPath: path.string) }

        let transfer = try OfflineTransfer.new(at: path)

        #expect(FileManager.default.fileExists(atPath: path.string))
        #expect(transfer.history.count == 1)
        #expect(transfer.history[0].action == .new)
    }
}
