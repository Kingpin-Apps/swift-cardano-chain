import Foundation
import SwiftCardanoCore
import Testing

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
        let cborHex =
            "84a70081825820b35a4ba9ef3ce21adcd6879d08553642224304704d206c74d3ffb3e6eed3ca28000d80018182581d60cc30497f4ff962f4c1dca54cceefe39f86f1d7179668009f8eb71e598200a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680021a000493e00e8009a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680075820592a2df0e091566969b3044626faa8023dabe6f39c78f33bed9e105e55159221a200828258206443a101bdb948366fc87369336224595d36d8b0eee5602cba8b81a024e584735840846f408dee3b101fda0f0f7ca89e18b724b7ca6266eb29775d3967d6920cae7457accb91def9b77571e15dd2ede38b12cf92496ce7382fa19eb90ab7f73e49008258205797dc2cc919dfec0bb849551ebdf30d96e5cbe0f33f734a87fe826db30f7ef95840bdc771aa7b8c86a8ffcbe1b7a479c68503c8aa0ffde8059443055bf3e54b92f4fca5e0b9ca5bb11ab23b1390bb9ffce414fa398fc0b17f4dc76fe9f7e2c99c09018182018482051a075bcd1582041a075bcd0c8200581c9139e5c0a42f0f2389634c3dd18dc621f5594c5ba825d9a8883c66278200581c835600a2be276a18a4bebf0225d728f090f724f4c0acd591d066fa6ff5d90103a100a11902d1a16b7b706f6c6963795f69647da16d7b706f6c6963795f6e616d657da66b6465736372697074696f6e6a3c6f7074696f6e616c3e65696d6167656a3c72657175697265643e686c6f636174696f6ea367617277656176656a3c6f7074696f6e616c3e6568747470736a3c6f7074696f6e616c3e64697066736a3c72657175697265643e646e616d656a3c72657175697265643e667368613235366a3c72657175697265643e64747970656a3c72657175697265643e"

        let tx = try Transaction.fromCBORHex(cborHex)

        // Test .transaction variant
        let txData1 = TransactionData.transaction(tx)
        if case .transaction(_) = txData1 {
            // Transaction was parsed and stored successfully
            #expect(Bool(true))
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

    @Test("Test ChainTip structure")
    func testChainTipStructure() async throws {
        let tip = ChainTip(
            block: 123456,
            epoch: 500,
            era: "conway",
            hash: "abcd1234",
            slot: 123_456_789,
            slotInEpoch: 65579,
            slotsToEpochEnd: 20821,
            syncProgress: "100.0"
        )

        #expect(tip.block == 123456)
        #expect(tip.epoch == 500)
        #expect(tip.era == "conway")
        #expect(tip.slot == 123_456_789)
    }

    @Test("Test StakeAddressInfo structure")
    func testStakeAddressInfoStructure() async throws {
        let stakeInfo = StakeAddressInfo(
            active: true,
            address: "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",
            rewardAccountBalance: 100_000_000,
            stakeDelegation: nil,
            voteDelegation: nil
        )

        #expect(stakeInfo.active == true)
        #expect(stakeInfo.rewardAccountBalance == 100_000_000)
    }

    @Test("Test UTxO conversion types")
    func testUtxoConversionTypes() async throws {
        // Test that we can create the types needed for UTxO conversion
        let txId = try TransactionId(
            from: .string("39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58"))
        let txIn = TransactionInput(transactionId: txId, index: 0)

        #expect(
            txIn.transactionId.payload.toHex
                == "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58")
        #expect(txIn.index == 0)
    }

    @Test("Test Value with multi-assets")
    func testValueWithMultiAssets() async throws {
        let policyId = ScriptHash(
            payload: Data(hex: "2e11e7313e00ccd086cfc4f1c3ebed4962d31b481b6a153c23601c0f"))
        let assetName = try AssetName(payload: Data(hex: "636861726c69335f6164615f6e6674"))

        var asset = Asset([:])
        asset[assetName] = 1

        var multiAsset = MultiAsset([:])
        multiAsset[policyId] = asset

        let value = Value(coin: 1_000_000, multiAsset: multiAsset)

        #expect(value.coin == 1_000_000)
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
            .valueError("test"),
        ]

        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }

    @Test("Test KESPeriodInfo structure")
    func testKESPeriodInfoStructure() async throws {
        // Test KESPeriodInfo with all fields
        let kesInfoFull = KESPeriodInfo(
            onChainOpCertCount: 42,
            onDiskOpCertCount: 43,
            nextChainOpCertCount: 43,
            onDiskKESStart: 100
        )

        #expect(kesInfoFull.onChainOpCertCount == 42)
        #expect(kesInfoFull.onDiskOpCertCount == 43)
        #expect(kesInfoFull.nextChainOpCertCount == 43)
        #expect(kesInfoFull.onDiskKESStart == 100)

        // Test KESPeriodInfo with partial fields (API-only response)
        let kesInfoPartial = KESPeriodInfo(
            onChainOpCertCount: 42,
            nextChainOpCertCount: 43
        )

        #expect(kesInfoPartial.onChainOpCertCount == 42)
        #expect(kesInfoPartial.onDiskOpCertCount == nil)
        #expect(kesInfoPartial.nextChainOpCertCount == 43)
        #expect(kesInfoPartial.onDiskKESStart == nil)

        // Test KESPeriodInfo indicating pool has never minted
        let kesInfoNeverMinted = KESPeriodInfo(
            onChainOpCertCount: -1,
            nextChainOpCertCount: 0
        )

        #expect(kesInfoNeverMinted.onChainOpCertCount == -1)
        #expect(kesInfoNeverMinted.nextChainOpCertCount == 0)
    }

    @Test("Test KESPeriodInfo Codable")
    func testKESPeriodInfoCodable() async throws {
        let kesInfo = KESPeriodInfo(
            onChainOpCertCount: 42,
            onDiskOpCertCount: 43,
            nextChainOpCertCount: 43,
            onDiskKESStart: 100
        )

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(kesInfo)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(KESPeriodInfo.self, from: data)

        #expect(decoded.onChainOpCertCount == kesInfo.onChainOpCertCount)
        #expect(decoded.onDiskOpCertCount == kesInfo.onDiskOpCertCount)
        #expect(decoded.nextChainOpCertCount == kesInfo.nextChainOpCertCount)
        #expect(decoded.onDiskKESStart == kesInfo.onDiskKESStart)
    }

    // MARK: - Chain Context Integration Tests (using mock client)

    @Test("Test mock chain context initialization")
    func testMockChainContextInit() async throws {
        let context = try await createMockOgmiosChainContext(network: .preview)
        #expect(context.networkId == .testnet)
        #expect(context.name == "Ogmios")
        #expect(context.type == .online)
    }

    @Test("Test mock chain context mainnet network ID")
    func testMockChainContextMainnetNetworkId() async throws {
        let context = try await createMockOgmiosChainContext(network: .mainnet)
        #expect(context.networkId == .mainnet)
    }

    @Test("Test epoch via mock client")
    func testEpochViaMockClient() async throws {
        let context = try await createMockOgmiosChainContext()
        let epoch = try await context.epoch()
        #expect(epoch == 1052)
    }

    @Test("Test lastBlockSlot via mock client")
    func testLastBlockSlotViaMockClient() async throws {
        let context = try await createMockOgmiosChainContext()
        let slot = try await context.lastBlockSlot()
        #expect(slot == 90_918_798)
    }

    @Test("Test queryChainTip via mock client")
    func testQueryChainTipViaMockClient() async throws {
        let context = try await createMockOgmiosChainContext()
        let tip = try await context.queryChainTip()
        #expect(tip.slot == 90_918_798)
        #expect(tip.epoch == 1052)
        #expect(tip.hash == "4dc5188a99ce636e624ab72104f6f18031dcd849c151ce1c8ef4871b7c3913b9")
    }

    @Test("Test genesisParameters via mock client")
    func testGenesisParametersViaMockClient() async throws {
        let context = try await createMockOgmiosChainContext()
        let params = try await context.genesisParameters()

        #expect(params.activeSlotsCoefficient == 0.05)  // "1/20"
        #expect(params.epochLength == 86400)
        #expect(params.maxKesEvolutions == 62)
        #expect(params.slotsPerKesPeriod == 129600)
        #expect(params.slotLength == 1)  // 1000ms / 1000 = 1
        #expect(params.maxLovelaceSupply == 45_000_000_000_000_000)
        #expect(params.securityParam == 432)
        #expect(params.networkMagic == 2)
        #expect(params.updateQuorum == 5)
    }

    @Test("Test protocolParameters via mock client")
    func testProtocolParametersViaMockClient() async throws {
        let context = try await createMockOgmiosChainContext()
        let params = try await context.protocolParameters()

        #expect(params.txFeePerByte == 44)
        #expect(params.txFeeFixed == 155381)
        #expect(params.maxTxSize == 16384)
        #expect(params.stakeAddressDeposit == 2_000_000)
        #expect(params.stakePoolDeposit == 500_000_000)
        #expect(params.stakePoolTargetNum == 500)
        #expect(params.maxBlockBodySize == 90112)
        #expect(params.utxoCostPerByte == 4310)
        #expect(params.collateralPercentage == 150)
        #expect(params.maxCollateralInputs == 3)
    }

    @Test("Test stakePools via mock client")
    func testStakePoolsViaMockClient() async throws {
        let context = try await createMockOgmiosChainContext()
        let pools = try await context.stakePools()

        #expect(pools.count == 2)
        #expect(
            pools.contains(where: {
                (try? $0.id()) == "pool1qqa8tkycj4zck4sy7n8mqr22x5g7tvm8hnp9st95wmuvvtw28th"
            }))
        #expect(
            pools.contains(where: {
                (try? $0.id()) == "pool1qzq896ke4meh0tn9fl0dcnvtn2rzdz75lk3h8nmsuew8z5uln7r"
            }))
    }

    @Test("Test UTxOs via mock client")
    func testUtxosViaMockClient() async throws {
        let context = try await createMockOgmiosChainContext()
        let address = try Address(
            from: .string(
                "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
            ))
        let utxos = try await context.utxos(address: address)

        #expect(utxos.count == 2)
        #expect(utxos[0].output.amount.coin == 5_000_000)
        #expect(utxos[1].output.amount.coin == 2_000_000)
    }

    @Test("Test utxo(input:) via mock client")
    func testUtxoInputViaMockClient() async throws {
        let context = try await createMockOgmiosChainContext()
        let txId = try TransactionId(
            from: .string("39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58"))
        let input = TransactionInput(transactionId: txId, index: 0)

        guard let (utxo, isSpent) = try await context.utxo(input: input) else {
            #expect(Bool(false), "Expected UTxO to be found")
            return
        }

        #expect(
            utxo.input.transactionId.payload.toHex
                == "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58")
        #expect(utxo.input.index == 0)
        #expect(utxo.output.amount.coin == 5_000_000)
        #expect(isSpent == false)
    }

    @Test("Test stakeAddressInfo via mock client")
    func testStakeAddressInfoViaMockClient() async throws {
        let context = try await createMockOgmiosChainContext()
        // Use a base address (has staking part)
        let address = try Address(
            from: .string(
                "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
            ))
        let stakeInfos = try await context.stakeAddressInfo(address: address)

        #expect(stakeInfos.count == 1)
        #expect(stakeInfos[0].rewardAccountBalance == 91_570_554_888)
        #expect(stakeInfos[0].active == true)
    }

    @Test("Test stakeAddressInfo throws for address without staking part")
    func testStakeAddressInfoThrowsForNoStakingPart() async throws {
        let context = try await createMockOgmiosChainContext()
        // Enterprise address has no staking part (addr_test1v... format)
        let enterpriseAddress = try Address(
            from: .string("addr_test1vr2p8st5t5cxqglyjky7vk98k7jtfhdpvhl4e97cezuhn0cqcexl7"))
        await #expect(throws: (any Error).self) {
            _ = try await context.stakeAddressInfo(address: enterpriseAddress)
        }
    }

    @Test("Test submitTxCBOR via mock client")
    func testSubmitTxCBORViaMockClient() async throws {
        let context = try await createMockOgmiosChainContext()
        let cbor = Data(hex: "deadbeef01020304")
        let txId = try await context.submitTxCBOR(cbor: cbor)

        #expect(txId == "a3edaf9627d81c28a51a729b370f97452f485c70b8ac9dca15791e0ae26618ae")
    }

    @Test("Test evaluateTxCBOR via mock client")
    func testEvaluateTxCBORViaMockClient() async throws {
        let context = try await createMockOgmiosChainContext()
        let cbor = Data(hex: "deadbeef01020304")
        let units = try await context.evaluateTxCBOR(cbor: cbor)

        #expect(units.count == 2)
        #expect(units["spend:1"] != nil)
        #expect(units["spend:1"]?.mem == 5_236_222)
        #expect(units["spend:1"]?.steps == 1_212_353)
        #expect(units["mint:0"] != nil)
        #expect(units["mint:0"]?.mem == 5_000)
        #expect(units["mint:0"]?.steps == 42)
    }

    @Test("Test stakePoolInfo via mock client")
    func testStakePoolInfoViaMockClient() async throws {
        let context = try await createMockOgmiosChainContext()
        let poolId = "pool1qqa8tkycj4zck4sy7n8mqr22x5g7tvm8hnp9st95wmuvvtw28th"
        let poolInfo = try await context.stakePoolInfo(poolId: poolId)

        // Verify pool params were set
        #expect(poolInfo.poolParams.cost == 340_000_000)
        #expect(poolInfo.poolParams.pledge == 500_000_000)

        // Verify live stake from stakePoolsPerformances
        #expect(poolInfo.liveStake == 13_492_420_330)
        #expect(poolInfo.livePledge == 2_497_634_194)
        #expect(poolInfo.liveSize != nil)
        #expect(poolInfo.liveSize! > 0)

        // opcertCounter is nil because pool not in operationalCertificates mock
        #expect(poolInfo.opcertCounter == nil)
    }

    @Test("Test stakePoolInfo throws for unknown pool")
    func testStakePoolInfoThrowsForUnknownPool() async throws {
        let context = try await createMockOgmiosChainContext()
        await #expect(throws: (any Error).self) {
            _ = try await context.stakePoolInfo(
                poolId: "pool1unknown000000000000000000000000000000000000000000000")
        }
    }

    @Test("Test parseRatioString indirectly via genesisParameters")
    func testParseRatioStringViaGenesisParameters() async throws {
        // The genesisParameters method uses parseRatioString("1/20") → 0.05
        let context = try await createMockOgmiosChainContext()
        let params = try await context.genesisParameters()
        let asc = try #require(params.activeSlotsCoefficient)
        #expect(abs(asc - 0.05) < 0.0001)
    }

    @Test("Test parseRatioString indirectly via protocolParameters")
    func testParseRatioStringViaProtocolParameters() async throws {
        // protocolParameters uses parseRatio for stakePoolPledgeInfluence "3/10" → 0.3
        let context = try await createMockOgmiosChainContext()
        let params = try await context.protocolParameters()
        #expect(abs(params.poolPledgeInfluence - 0.3) < 0.0001)
        #expect(abs(params.monetaryExpansion - 0.003) < 0.0001)  // "3/1000"
        #expect(abs(params.treasuryCut - 0.2) < 0.0001)  // "1/5"
    }

    @Test("Test epoch caching")
    func testEpochCaching() async throws {
        let context = try await createMockOgmiosChainContext()
        // Call epoch() twice - second call should use cached value
        let epoch1 = try await context.epoch()
        let epoch2 = try await context.epoch()
        #expect(epoch1 == epoch2)
        #expect(epoch1 == 1052)
    }

    @Test("Test genesisParameters caching")
    func testGenesisParametersCaching() async throws {
        let context = try await createMockOgmiosChainContext()
        // Call genesisParameters() twice - second call should use cached value
        let params1 = try await context.genesisParameters()
        let params2 = try await context.genesisParameters()
        #expect(params1.epochLength == params2.epochLength)
        #expect(params1.networkMagic == params2.networkMagic)
    }

    @Test("Test network description in genesisParameters")
    func testNetworkDescriptionInGenesisParameters() async throws {
        let context = try await createMockOgmiosChainContext(network: .preview)
        let params = try await context.genesisParameters()
        #expect(params.networkId == "preview")
    }

    // MARK: - ChainContext Protocol Extension Tests

    @Test("Test submitTx with bytes TransactionData")
    func testSubmitTxWithBytes() async throws {
        let context = try await createMockOgmiosChainContext()
        let cbor = Data(hex: "deadbeef01020304")
        let txId = try await context.submitTx(tx: .bytes(cbor))
        #expect(txId == "a3edaf9627d81c28a51a729b370f97452f485c70b8ac9dca15791e0ae26618ae")
    }

    @Test("Test submitTx with hex string TransactionData")
    func testSubmitTxWithString() async throws {
        let context = try await createMockOgmiosChainContext()
        let txId = try await context.submitTx(tx: .string("deadbeef01020304"))
        #expect(txId == "a3edaf9627d81c28a51a729b370f97452f485c70b8ac9dca15791e0ae26618ae")
    }

    @Test("Test ChainContext description")
    func testChainContextDescription() async throws {
        let context = try await createMockOgmiosChainContext()
        #expect(!context.description.isEmpty)
        #expect(context.description == context.name)
    }

    @Test("Test ChainContext debugDescription")
    func testChainContextDebugDescription() async throws {
        let context = try await createMockOgmiosChainContext()
        let debug = context.debugDescription
        #expect(debug.contains("ChainContext"))
        #expect(debug.contains("networkId"))
    }

    @Test("Test treasury")
    func testTreasury() async throws {
        let context = try await createMockOgmiosChainContext()
        let treasury = try await context.treasury()

        #expect(treasury == Coin(1_000_000_000_000_000))
    }

    @Test("Test drepInfo")
    func testDrepInfo() async throws {
        let context = try await createMockOgmiosChainContext()
        let drepInfo = try await context.drepInfo(
            drep: DRep.fromBech32("drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0")
        )

        let expectedDRepInfo = DRepInfo(
            active: true,
            drep: try DRep.fromBech32("drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0"),
            anchor: Anchor(
                anchorUrl: try Url("https://anchor.test"),
                anchorDataHash: AnchorDataHash(
                    payload: Data(
                        hex: "35aeb21ba4be07cf9fda041b635f107ef978238b3fccae9be1b571518ce9d1b7")
                )
            ),
            deposit: Coin(500_000_000),
            stake: Coin(500_000_000),
            expiry: 639,
            status: .registered
        )

        #expect(drepInfo == expectedDRepInfo)
    }

    @Test
    func testGovActionInfo() async throws {
        let chainContext = try await createMockOgmiosChainContext()

        let txHash = "2dd15e0ef6e6a17841cb9541c27724072ce4d4b79b91e58432fbaa32d9572531"
        let govActionID = GovActionID(
            transactionID: TransactionId(payload: Data(hex: txHash)),
            govActionIndex: 1
        )

        let govActionInfo = try await chainContext.govActionInfo(govActionID: govActionID)

        #expect(govActionInfo.govActionId == govActionID)
        #expect(govActionInfo.proposedIn == 100)
        #expect(govActionInfo.expiresAfter == 130)
    }

    @Test("Test committeeMemberInfo for script credential")
    func testCommitteeMemberInfoScriptCredential() async throws {
        let chainContext = try await createMockOgmiosChainContext()

        let coldCredential = CommitteeColdCredential(
            credential: .scriptHash(
                try ScriptHash(
                    from: .string("1980dbf1ad624b0cb5410359b5ab14d008561994a6c2b6c53fabec00")
                )
            )
        )

        let expectedHotCredential = CommitteeHotCredential(
            credential: .scriptHash(
                try ScriptHash(
                    from: .string("646d1b3ac94568a422b687db6c47acdf849f1674982ae4f9a494be43")
                )
            )
        )

        let memberInfo = try await chainContext.committeeMemberInfo(committeeMember: coldCredential)

        #expect(memberInfo.coldCredential == coldCredential)
        #expect(memberInfo.hotCredential == expectedHotCredential)
        #expect(memberInfo.expiration == 1200)
        #expect(memberInfo.status == .active)
    }

    @Test("Test committeeMemberInfo for verification key credential")
    func testCommitteeMemberInfoVerificationKeyCredential() async throws {
        let chainContext = try await createMockOgmiosChainContext()

        let coldCredential = CommitteeColdCredential(
            credential: .verificationKeyHash(
                try VerificationKeyHash(
                    from: .string("13493790d9b03483a1e1e684ea4faf1ee48a58f402574e7f2246f4d4")
                )
            )
        )

        let expectedHotCredential = CommitteeHotCredential(
            credential: .verificationKeyHash(
                try VerificationKeyHash(
                    from: .string("68bb0b4276021f82364056aa9f4d38ba5ac59b26c166cbeaa9408746")
                )
            )
        )

        let memberInfo = try await chainContext.committeeMemberInfo(committeeMember: coldCredential)

        #expect(memberInfo.coldCredential == coldCredential)
        #expect(memberInfo.hotCredential == expectedHotCredential)
        #expect(memberInfo.expiration == 1300)
        #expect(memberInfo.status == .active)
    }

    @Test("Test committeeMemberInfo throws when member is missing")
    func testCommitteeMemberInfoThrowsWhenMissing() async throws {
        let chainContext = try await createMockOgmiosChainContext()

        let missingCredential = CommitteeColdCredential(
            credential: .scriptHash(
                try ScriptHash(
                    from: .string("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                )
            )
        )

        await #expect(throws: CardanoChainError.self) {
            _ = try await chainContext.committeeMemberInfo(committeeMember: missingCredential)
        }
    }
}
