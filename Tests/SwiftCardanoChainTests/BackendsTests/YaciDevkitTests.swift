import Foundation
import OpenAPIRuntime
import SwiftCardanoCore
import SwiftCardanoNetwork
import SwiftYaciAPI
import Testing

@testable import SwiftCardanoChain

@Suite("Yaci DevKit Chain Context Tests")
struct YaciDevkitChainContextTests {

    // MARK: - Helpers

    private func makeContext(
        transport: MockYaciTransport = MockYaciTransport(),
        admin: MockYaciDevkitAdmin = MockYaciDevkitAdmin(),
        network: SwiftCardanoCore.Network = .custom(42)
    ) throws -> YaciDevkitChainContext {
        try YaciDevkitChainContext(
            apiURL: "http://localhost:8080",
            network: network,
            client: Client(
                serverURL: URL(string: "http://localhost:8080")!,
                transport: transport
            ),
            admin: admin
        )
    }

    private var paymentAddress: Address {
        get throws { try Address(from: .string(YaciMockData.paymentAddress)) }
    }

    private var stakeAddress: Address {
        get throws { try Address(from: .string(YaciMockData.stakeAddress)) }
    }

    // MARK: - Initialization

    @Test("Test initialization defaults to the DevKit endpoints")
    func testInitDefaults() throws {
        let context = try YaciDevkitChainContext()

        #expect(context.name == "YaciDevkit")
        #expect(context.type == .online)
        #expect(context.networkId == .testnet)
        #expect(context.api.baseURL.absoluteString == "http://localhost:8080")
        #expect((context.admin as? YaciDevkitAdmin)?.baseURL.absoluteString == "http://localhost:10000")
    }

    @Test("Test initialization derives the admin URL from the store host")
    func testInitDerivesAdminURL() throws {
        let context = try YaciDevkitChainContext(apiURL: "http://devkit.local:9090/api/v1")

        #expect(context.api.baseURL.absoluteString == "http://devkit.local:9090")
        #expect(
            (context.admin as? YaciDevkitAdmin)?.baseURL.absoluteString
                == "http://devkit.local:10000")
    }

    @Test("Test initialization honours an explicit admin URL")
    func testInitExplicitAdminURL() throws {
        let context = try YaciDevkitChainContext(
            apiURL: "http://devkit.local:8080",
            adminURL: "http://admin.local:11000/"
        )

        #expect((context.admin as? YaciDevkitAdmin)?.baseURL.absoluteString == "http://admin.local:11000")
    }

    @Test(
        "Test initialization maps network to network id",
        arguments: [
            (SwiftCardanoCore.Network.mainnet, NetworkId.mainnet),
            (SwiftCardanoCore.Network.preview, NetworkId.testnet),
            (SwiftCardanoCore.Network.custom(42), NetworkId.testnet),
        ])
    func testInitNetwork(_ networks: (SwiftCardanoCore.Network, NetworkId)) throws {
        let context = try makeContext(network: networks.0)
        #expect(context.networkId == networks.1)
    }

    @Test("Test initialization rejects a relative API URL")
    func testInitRejectsRelativeURL() throws {
        #expect(throws: CardanoChainError.self) {
            _ = try YaciDevkitChainContext(apiURL: "localhost:8080")
        }
    }

    // MARK: - Chain state

    @Test("Test epoch")
    func testEpoch() async throws {
        let context = try makeContext()
        #expect(try await context.epoch() == YaciMockData.currentEpoch)
    }

    @Test("Test epoch is cached between calls")
    func testEpochCaching() async throws {
        let transport = MockYaciTransport()
        let context = try makeContext(transport: transport)

        _ = try await context.epoch()
        _ = try await context.epoch()

        #expect(transport.log.count(of: "getLatestEpoch") == 1)
    }

    @Test("Test era maps the hard-fork combinator index")
    func testEra() async throws {
        let context = try makeContext()
        #expect(try await context.era() == .conway)
    }

    @Test("Test era is nil for an index this mapping does not know")
    func testEraUnknownIndex() async throws {
        let transport = MockYaciTransport(overrides: ["getLatestBlock": #"{"number": 1, "era": 99}"#])
        let context = try makeContext(transport: transport)

        #expect(try await context.era() == nil)
    }

    @Test("Test era index mapping")
    func testEraIndexMapping() {
        #expect(YaciDevkitChainContext.era(fromIndex: 1) == .byron)
        #expect(YaciDevkitChainContext.era(fromIndex: 6) == .babbage)
        #expect(YaciDevkitChainContext.era(fromIndex: 7) == .conway)
        #expect(YaciDevkitChainContext.era(fromIndex: 0) == nil)
        #expect(YaciDevkitChainContext.era(fromIndex: 8) == nil)
    }

    @Test("Test lastBlockSlot")
    func testLastBlockSlot() async throws {
        let context = try makeContext()
        #expect(try await context.lastBlockSlot() == 98765)
    }

    @Test("Test lastBlockSlot throws when the block carries no slot")
    func testLastBlockSlotThrowsWithoutSlot() async throws {
        let transport = MockYaciTransport(overrides: ["getLatestBlock": #"{"number": 1}"#])
        let context = try makeContext(transport: transport)

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.lastBlockSlot()
        }
    }

    @Test("Test chainTip")
    func testChainTip() async throws {
        let context = try makeContext()
        let tip = try await context.chainTip()

        #expect(tip.block == 1234)
        #expect(tip.slot == 98765)
        #expect(tip.epoch == EpochNumber(YaciMockData.currentEpoch))
        #expect(tip.slotInEpoch == 345)
        #expect(tip.era == "conway")
        // Yaci reports how far it has indexed, not how far behind the node it is.
        #expect(tip.syncProgress == nil)
        #expect(tip.slotsToEpochEnd == nil)
    }

    // MARK: - Genesis

    @Test("Test genesisParameters from the admin API")
    func testGenesisParameters() async throws {
        let context = try makeContext()
        let genesis = try await context.genesisParameters()

        #expect(genesis.activeSlotsCoefficient == 0.05)
        #expect(genesis.epochLength == 86400)
        #expect(genesis.maxKesEvolutions == 62)
        #expect(genesis.maxLovelaceSupply == 45_000_000_000_000_000)
        #expect(genesis.networkMagic == 2)
        #expect(genesis.securityParam == 432)
        #expect(genesis.slotLength == 1)
        #expect(genesis.slotsPerKesPeriod == 129600)
        #expect(genesis.updateQuorum == 5)
        #expect(genesis.systemStart != nil)
        // Every document decoded, so the per-era sub-documents come through too.
        #expect(genesis.conwayGenesis != nil)
        #expect(genesis.alonzoGenesis != nil)
    }

    @Test("Test genesisParameters falls back to the Shelley document alone")
    func testGenesisParametersFallback() async throws {
        // A DevKit whose Byron genesis does not decode still yields the parameters that matter.
        let admin = MockYaciDevkitAdmin(overrides: ["byron": "{}"])
        let context = try makeContext(admin: admin)
        let genesis = try await context.genesisParameters()

        #expect(genesis.networkMagic == 2)
        #expect(genesis.epochLength == 86400)
        #expect(genesis.byronGenesis == nil)
    }

    @Test("Test genesisParameters is cached")
    func testGenesisParametersCached() async throws {
        let context = try makeContext()

        let first = try await context.genesisParameters()
        let second = try await context.genesisParameters()

        #expect(first.networkMagic == second.networkMagic)
    }

    @Test("Test genesisParameters throws when the admin API is unreachable")
    func testGenesisParametersThrows() async throws {
        let admin = MockYaciDevkitAdmin(failing: ["shelley"])
        let context = try makeContext(admin: admin)

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.genesisParameters()
        }
    }

    @Test("Test genesisParameters rejects a Shelley document missing a field")
    func testGenesisParametersMissingField() throws {
        let data = Data(#"{"epochLength": 100}"#.utf8)

        #expect(throws: CardanoChainError.self) {
            _ = try YaciDevkitChainContext.genesisParameters(
                fromShelleyGenesis: data, network: .custom(42))
        }
    }

    @Test("Test ISO8601 parsing with and without fractional seconds")
    func testParseISO8601() {
        #expect(YaciDevkitChainContext.parseISO8601("2022-10-25T00:00:00Z") != nil)
        #expect(YaciDevkitChainContext.parseISO8601("2022-10-25T00:00:00.123Z") != nil)
        #expect(YaciDevkitChainContext.parseISO8601("not a date") == nil)
    }

    // MARK: - Protocol parameters

    @Test("Test protocolParameters")
    func testProtocolParameters() async throws {
        let context = try makeContext()
        let params = try await context.protocolParameters()

        #expect(params.txFeePerByte == 44)
        #expect(params.txFeeFixed == 155381)
        #expect(params.utxoCostPerByte == 4310)
        #expect(params.maxTxSize == 16384)
        #expect(params.stakeAddressDeposit == 2_000_000)
        #expect(params.stakePoolDeposit == 500_000_000)
        #expect(params.minPoolCost == 170_000_000)
        #expect(params.protocolVersion.major == 10)
        #expect(params.executionUnitPrices.priceMemory == 0.0577)
        #expect(params.maxTxExecutionUnits.steps == 10_000_000_000)
        #expect(params.dRepVotingThresholds.ppGovGroup == 0.75)
        #expect(params.poolVotingThresholds.ppSecurityGroup == 0.51)
        #expect(params.govActionLifetime == 6)
    }

    @Test("Test protocolParameters takes cost models from genesis in ledger order")
    func testProtocolParametersCostModelsFromGenesis() async throws {
        let context = try makeContext()
        let params = try await context.protocolParameters()

        // The Alonzo genesis fixture carries the full 166-entry Plutus V1 model, and the Conway
        // genesis the 251-entry V3 one — not the two- and three-entry maps the store reports.
        #expect(params.costModels.PlutusV1.count == 166)
        #expect(params.costModels.PlutusV3.count == 251)
        #expect(params.costModels.PlutusV3.first == 100788)
    }

    @Test("Test protocolParameters falls back to the store's cost models")
    func testProtocolParametersCostModelsFromStore() async throws {
        // With no genesis to read, the store's own maps are flattened in key order.
        let admin = MockYaciDevkitAdmin(failing: ["alonzo", "conway"])
        let context = try makeContext(admin: admin)
        let params = try await context.protocolParameters()

        #expect(params.costModels.PlutusV1 == [1, 2])
        #expect(params.costModels.PlutusV2 == [7, 8, 9])
        #expect(params.costModels.PlutusV3 == [1, 2, 3])
    }

    @Test("Test protocolParameters is cached per epoch")
    func testProtocolParametersCached() async throws {
        let transport = MockYaciTransport()
        let context = try makeContext(transport: transport)

        _ = try await context.protocolParameters()
        _ = try await context.protocolParameters()

        #expect(transport.log.count(of: "getLatestProtocolParams") == 1)
    }

    @Test("Test protocolParameters throws when a required field is missing")
    func testProtocolParametersThrowsOnMissingField() async throws {
        let transport = MockYaciTransport(overrides: ["getLatestProtocolParams": #"{"min_fee_a": 44}"#])
        let context = try makeContext(transport: transport)

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.protocolParameters()
        }
    }

    @Test("Test cost model list flattens a map in key order")
    func testCostList() {
        #expect(YaciDevkitChainContext.costList([1, 2, 3] as [Any]) == [1, 2, 3])
        #expect(YaciDevkitChainContext.costList(["b": 2, "a": 1] as [String: Any]) == [1, 2])
        #expect(YaciDevkitChainContext.costList("nonsense") == nil)
        #expect(YaciDevkitChainContext.costList(nil) == nil)
    }

    // MARK: - UTxOs

    @Test("Test utxos")
    func testUtxos() async throws {
        let context = try makeContext()
        let utxos = try await context.utxos(address: try paymentAddress)

        #expect(utxos.count == 2)

        let first = utxos[0]
        #expect(first.input.transactionId.payload.toHex == YaciMockData.utxoTxHash)
        #expect(first.input.index == 0)
        #expect(first.output.amount.coin == 1_000_000)

        let policyId = ScriptHash(payload: Data(hex: YaciMockData.policyId))
        let assetName = try AssetName(payload: Data(hex: YaciMockData.assetNameHex))
        #expect(first.output.amount.multiAsset[policyId]?[assetName] == 50)
        #expect(first.output.datumOption != nil)
        #expect(first.output.datumHash == nil)

        let second = utxos[1]
        #expect(second.output.amount.coin == 2_000_000)
        #expect(second.output.datumHash?.payload.toHex == YaciMockData.dataHash)
        #expect(second.output.datumOption == nil)
    }

    @Test("Test utxos fetches every page")
    func testUtxosPagination() async throws {
        let transport = MockYaciTransport(paginatedUtxos: true)
        let context = try makeContext(transport: transport)

        let utxos = try await context.utxos(address: try paymentAddress)

        // A short page is the only end-of-list signal Yaci gives, so the second page must be read.
        #expect(utxos.count == 105)
        #expect(transport.log.count(of: "getUtxos_1") == 2)
    }

    @Test("Test utxos returns an empty list for an address with nothing on it")
    func testUtxosEmpty() async throws {
        let context = try makeContext()
        let other = try Address(from: .string(YaciMockData.stakeAddress))

        #expect(try await context.utxos(address: other).isEmpty)
    }

    @Test("Test utxo(input:) resolves an unspent output")
    func testUtxoUnspent() async throws {
        let context = try makeContext()
        let input = TransactionInput(
            transactionId: try TransactionId(from: .string(YaciMockData.utxoTxHash)),
            index: 0
        )

        let result = try await context.utxo(input: input)

        #expect(result != nil)
        #expect(result?.isSpent == false)
        #expect(result?.0.output.amount.coin == 1_000_000)
    }

    @Test("Test utxo(input:) reports a spent output")
    func testUtxoSpent() async throws {
        let context = try makeContext()
        let input = TransactionInput(
            transactionId: try TransactionId(from: .string(YaciMockData.spentTxHash)),
            index: 1
        )

        let result = try await context.utxo(input: input)

        // Yaci keeps spent outputs, so absence from the address' live set is what marks it spent.
        #expect(result?.isSpent == true)
        #expect(result?.0.output.amount.coin == 7_000_000)
    }

    @Test("Test utxo(input:) returns nil for an output Yaci has not indexed")
    func testUtxoNotFound() async throws {
        let context = try makeContext()
        let input = TransactionInput(
            transactionId: try TransactionId(from: .string(YaciMockData.utxoTxHash)),
            index: 9
        )

        #expect(try await context.utxo(input: input) == nil)
    }

    // MARK: - Scripts

    @Test("Test a native reference script is resolved")
    func testNativeReferenceScript() async throws {
        let transport = MockYaciTransport(
            referenceScript: (hash: YaciMockData.nativeScriptHash, type: "timelock", cbor: "")
        )
        let context = try makeContext(transport: transport)

        let utxos = try await context.utxos(address: try paymentAddress)

        guard case .nativeScript(let native) = utxos[0].output.script else {
            Issue.record("Expected a native reference script")
            return
        }
        guard case .scriptPubkey(let pubkey) = native else {
            Issue.record("Expected a sig script")
            return
        }
        #expect(pubkey.keyHash.payload.toHex == YaciMockData.ccHotHex)
    }

    @Test("Test a Plutus reference script is recovered and hash-checked")
    func testPlutusReferenceScript() async throws {
        let scriptBytes = Data([0x4E, 0x4D, 0x01, 0x00, 0x00, 0x33, 0x22, 0x22, 0x20, 0x05, 0x12])
        let script = PlutusV2Script(data: scriptBytes)
        let hash = try scriptHash(script: .plutusV2Script(script)).payload.toHex

        let transport = MockYaciTransport(
            referenceScript: (hash: hash, type: "plutusV2", cbor: scriptBytes.toHex)
        )
        let context = try makeContext(transport: transport)

        let utxos = try await context.utxos(address: try paymentAddress)

        guard case .plutusV2Script(let recovered) = utxos[0].output.script else {
            Issue.record("Expected a Plutus V2 reference script")
            return
        }
        #expect(recovered == script)
    }

    @Test("Test a script whose CBOR does not hash to its id is rejected")
    func testPlutusScriptHashMismatch() {
        #expect(throws: CardanoChainError.self) {
            _ = try YaciDevkitChainContext.plutusScript(
                type: "plutusV2",
                bytes: Data([0x01, 0x02, 0x03]),
                expectedHash: String(repeating: "ab", count: 28)
            )
        }
    }

    @Test("Test unwrapping a CBOR byte string")
    func testUnwrapCBORByteString() {
        // 0x43 = byte string of length 3.
        #expect(
            YaciDevkitChainContext.unwrapCBORByteString(Data([0x43, 0x01, 0x02, 0x03]))
                == Data([0x01, 0x02, 0x03]))
        // 0x58 = one-byte length prefix.
        #expect(
            YaciDevkitChainContext.unwrapCBORByteString(Data([0x58, 0x02, 0xAA, 0xBB]))
                == Data([0xAA, 0xBB]))
        // A trailing byte means this is not a single byte string.
        #expect(YaciDevkitChainContext.unwrapCBORByteString(Data([0x43, 0x01, 0x02])) == nil)
        // A major type other than 2.
        #expect(YaciDevkitChainContext.unwrapCBORByteString(Data([0x82, 0x01, 0x02])) == nil)
    }

    // MARK: - Transactions

    @Test("Test submitTxCBOR")
    func testSubmitTxCBOR() async throws {
        let context = try makeContext()
        let hash = try await context.submitTxCBOR(cbor: Data([0x84, 0xA7, 0x00]))

        #expect(hash == YaciMockData.submittedTxHash)
    }

    @Test("Test submitTxCBOR surfaces a rejection")
    func testSubmitTxCBORFailure() async throws {
        let transport = MockYaciTransport(failing: ["submitTx_1": 400])
        let context = try makeContext(transport: transport)

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.submitTxCBOR(cbor: Data([0x84]))
        }
    }

    @Test("Test evaluateTxCBOR renames the Ogmios script purposes")
    func testEvaluateTxCBOR() async throws {
        let context = try makeContext()
        let units = try await context.evaluateTxCBOR(cbor: Data([0x84, 0xA7]))

        #expect(units.count == 3)
        #expect(units["spend:0"]?.mem == 1_000_000)
        #expect(units["spend:0"]?.steps == 500_000_000)
        // Ogmios says `withdraw` and `publish` where this library says `withdrawal` and
        // `certificate`.
        #expect(units["withdrawal:1"]?.mem == 2000)
        #expect(units["certificate:0"]?.steps == 20)
    }

    @Test("Test evaluateTxCBOR handles the Ogmios v6 list shape")
    func testEvaluateTxCBORV6() async throws {
        let transport = MockYaciTransport(
            overrides: [
                "evaluateTx": """
                    {"result": [{"validator": {"purpose": "spend", "index": 2},
                                 "budget": {"memory": 55, "cpu": 66}}]}
                    """
            ])
        let context = try makeContext(transport: transport)

        let units = try await context.evaluateTxCBOR(cbor: Data([0x84]))

        #expect(units["spend:2"]?.mem == 55)
        #expect(units["spend:2"]?.steps == 66)
    }

    @Test("Test evaluateTxCBOR surfaces an evaluation error")
    func testEvaluateTxCBORFailure() async throws {
        let transport = MockYaciTransport(overrides: ["evaluateTx": #"{"error": "no ogmios"}"#])
        let context = try makeContext(transport: transport)

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.evaluateTxCBOR(cbor: Data([0x84]))
        }
    }

    // MARK: - Stake addresses

    @Test("Test stakeAddressInfo")
    func testStakeAddressInfo() async throws {
        let context = try makeContext()
        let info = try await context.stakeAddressInfo(address: try stakeAddress)

        #expect(info.count == 1)
        #expect(info[0].active == true)
        #expect(info[0].address == YaciMockData.stakeAddress)
        #expect(info[0].rewardAccountBalance == 319_154_618_165)
        #expect(try info[0].stakeDelegation?.id(.bech32) == YaciMockData.poolABech32)
        // The latest of two vote-delegation certificates wins.
        #expect(info[0].voteDelegation?.credential == .verificationKeyHash(
            VerificationKeyHash(payload: Data(hex: YaciMockData.drepHex))))
    }

    @Test("Test stakeAddressInfo for an unregistered account")
    func testStakeAddressInfoUnregistered() async throws {
        let context = try makeContext()
        let address = try Address(from: .string(YaciMockData.unknownStakeAddress))

        let info = try await context.stakeAddressInfo(address: address)

        #expect(info.count == 1)
        #expect(info[0].active == false)
        #expect(info[0].rewardAccountBalance == 0)
        #expect(info[0].stakeDelegation == nil)
    }

    // MARK: - Stake pools

    @Test("Test stakePools excludes pools that have already retired")
    func testStakePools() async throws {
        let context = try makeContext()
        let pools = try await context.stakePools()

        let ids = pools.map { $0.poolKeyHash.payload.toHex.lowercased() }
        // Pool A re-registered after announcing retirement, so it is live again.
        #expect(ids.contains(YaciMockData.poolAHex))
        // Pool B is retiring at epoch 20, which has not arrived.
        #expect(ids.contains(YaciMockData.poolBHex))
        // Pool C retired at epoch 5.
        #expect(!ids.contains(YaciMockData.poolCHex))
    }

    @Test("Test stakePoolInfo reads the latest registration")
    func testStakePoolInfo() async throws {
        let context = try makeContext()
        let info = try await context.stakePoolInfo(poolId: YaciMockData.poolABech32)

        // The second registration supersedes the first.
        #expect(info.poolParams.pledge == 2_000_000_000)
        #expect(info.poolParams.cost == 345_000_000)
        // The exact registered ratio is preferred over the rounded decimal.
        #expect(info.poolParams.margin.numerator == 1)
        #expect(info.poolParams.margin.denominator == 20)
        #expect(info.poolParams.relays?.count == 3)
        #expect(info.poolParams.poolMetadata?.poolMetadataHash?.payload.toHex == YaciMockData.anchorHash)
        // A re-registration cancels an announced retirement.
        if case .registered = info.status {} else {
            Issue.record("Expected a registered pool, got \(String(describing: info.status))")
        }
        // Yaci indexes certificates, not ledger state, so there are no stake figures.
        #expect(info.liveStake == nil)
        #expect(info.activeStake == nil)
        #expect(info.opcertCounter == nil)
    }

    @Test("Test stakePoolInfo accepts a hex pool id")
    func testStakePoolInfoHexId() async throws {
        let context = try makeContext()
        let info = try await context.stakePoolInfo(poolId: YaciMockData.poolAHex)

        #expect(info.poolParams.poolOperator.payload.toHex == YaciMockData.poolAHex)
    }

    @Test("Test stakePoolInfo reports a retiring pool")
    func testStakePoolInfoRetiring() async throws {
        let context = try makeContext()
        let info = try await context.stakePoolInfo(poolId: YaciMockData.poolBHex)

        guard case .retiring(let epoch) = info.status else {
            Issue.record("Expected a retiring pool, got \(String(describing: info.status))")
            return
        }
        #expect(epoch == 20)
    }

    @Test("Test stakePoolInfo throws for an unknown pool")
    func testStakePoolInfoUnknown() async throws {
        let context = try makeContext()

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.stakePoolInfo(poolId: String(repeating: "ab", count: 28))
        }
    }

    @Test("Test relay mapping infers the shape from the populated fields")
    func testRelayMapping() {
        let ipv4 = YaciDevkitChainContext.relay(from: .init(port: 3001, ipv4: "203.0.113.7"))
        guard case .singleHostAddr(let addr)? = ipv4 else {
            Issue.record("Expected a single host address")
            return
        }
        #expect(addr.port == 3001)
        #expect(addr.ipv4?.description == "203.0.113.7")

        let named = YaciDevkitChainContext.relay(from: .init(port: 6000, dnsName: "relay.example.com"))
        guard case .singleHostName(let host)? = named else {
            Issue.record("Expected a single host name")
            return
        }
        #expect(host.dnsName == "relay.example.com")

        let srv = YaciDevkitChainContext.relay(from: .init(dnsName: "_cardano._tcp.example.com"))
        guard case .multiHostName? = srv else {
            Issue.record("Expected a multi host name")
            return
        }

        #expect(YaciDevkitChainContext.relay(from: .init()) == nil)
    }

    @Test("Test pool owners accept both key hashes and stake addresses")
    func testPoolOwnerMapping() throws {
        let fromHex = try YaciDevkitChainContext.poolOwner(YaciMockData.ccHotHex)
        #expect(fromHex.payload.toHex == YaciMockData.ccHotHex)

        let fromBech32 = try YaciDevkitChainContext.poolOwner(YaciMockData.stakeAddress)
        #expect(fromBech32.payload.count == 28)

        #expect(throws: CardanoChainError.self) {
            _ = try YaciDevkitChainContext.poolOwner("not-hex")
        }
    }

    // MARK: - KES

    @Test("Test kesPeriodInfo reads the counter from the pool's latest block")
    func testKESPeriodInfo() async throws {
        let context = try makeContext()
        let pool = try PoolOperator(from: YaciMockData.poolABech32)

        let info = try await context.kesPeriodInfo(pool: pool, opCert: nil)

        #expect(info.onChainOpCertCount == 3)
        #expect(info.nextChainOpCertCount == 4)
        #expect(info.onDiskOpCertCount == nil)
    }

    @Test("Test kesPeriodInfo requires a pool")
    func testKESPeriodInfoRequiresPool() async throws {
        let context = try makeContext()

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.kesPeriodInfo(pool: nil, opCert: nil)
        }
    }

    @Test("Test kesPeriodInfo throws when the pool has minted nothing recently")
    func testKESPeriodInfoNoBlocks() async throws {
        let context = try makeContext()
        let pool = try PoolOperator(from: Data(hex: YaciMockData.poolBHex))

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.kesPeriodInfo(pool: pool, opCert: nil)
        }
    }

    // MARK: - DReps

    @Test("Test drepInfo folds the certificate log")
    func testDRepInfo() async throws {
        let context = try makeContext()
        let drep = DRep(
            credential: .verificationKeyHash(VerificationKeyHash(payload: Data(hex: YaciMockData.drepHex))))

        let info = try await context.drepInfo(drep: drep)

        #expect(info.status == .registered)
        #expect(info.active == true)
        #expect(info.deposit == Coin(500_000_000))
        // The update certificate carries the current anchor.
        #expect(info.anchor?.anchorUrl.absoluteString == "https://anchor.test/new")
        // Voting power comes from DevKit's local-state endpoint.
        #expect(info.stake == Coin(4_200_000))
        #expect(info.expiry == nil)
    }

    @Test("Test drepInfo reports a retired DRep")
    func testDRepInfoRetired() async throws {
        let context = try makeContext()
        let drep = DRep(
            credential: .verificationKeyHash(
                VerificationKeyHash(payload: Data(hex: YaciMockData.retiredDrepHex))))

        let info = try await context.drepInfo(drep: drep)

        #expect(info.status == .retired)
        #expect(info.active == false)
        // The local-state endpoint has nothing for this DRep, so stake falls back to zero.
        #expect(info.stake == Coin(0))
    }

    @Test("Test drepInfo reports an unregistered DRep")
    func testDRepInfoUnregistered() async throws {
        let context = try makeContext()
        let drep = DRep(
            credential: .verificationKeyHash(
                VerificationKeyHash(payload: Data(hex: YaciMockData.unknownDrepHex))))

        let info = try await context.drepInfo(drep: drep)

        #expect(info.status == .notRegistered)
        #expect(info.active == false)
    }

    @Test(
        "Test drepInfo reports the predefined DReps as unregistered",
        arguments: [DRepType.alwaysAbstain, DRepType.alwaysNoConfidence])
    func testDRepInfoPredefined(_ credential: DRepType) async throws {
        let context = try makeContext()

        let info = try await context.drepInfo(drep: DRep(credential: credential))

        #expect(info.status == .notRegistered)
        #expect(info.stake == Coin(0))
    }

    @Test("Test drepStakeDistribution covers the registered DReps")
    func testDRepStakeDistribution() async throws {
        let context = try makeContext()
        let entries = try await context.drepStakeDistribution()

        // The retired DRep is excluded, and so is any DRep whose stake cannot be read.
        #expect(entries.count == 1)
        #expect(entries[0].stake == 4_200_000)
        #expect(
            entries[0].drep.credential
                == .verificationKeyHash(VerificationKeyHash(payload: Data(hex: YaciMockData.drepHex))))
    }

    @Test("Test spoStakeDistribution is not available")
    func testSPOStakeDistributionUnavailable() async throws {
        let context = try makeContext()

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.spoStakeDistribution()
        }
    }

    @Test("Test treasury is not available")
    func testTreasuryUnavailable() async throws {
        let context = try makeContext()

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.treasury()
        }
    }

    // MARK: - Governance actions

    @Test("Test govActionInfo derives the expiry from the proposal epoch")
    func testGovActionInfo() async throws {
        let context = try makeContext()
        let id = GovActionID(
            transactionID: TransactionId(payload: Data(hex: YaciMockData.proposalTxHash)),
            govActionIndex: 0
        )

        let info = try await context.govActionInfo(govActionID: id)

        #expect(info.proposedIn == 10)
        // proposed epoch + govActionLifetime
        #expect(info.expiresAfter == 16)
        // Yaci does not index governance state, so every outcome epoch is unknown.
        #expect(info.ratifiedEpoch == nil)
        #expect(info.enactedEpoch == nil)
        #expect(info.status == nil)

        guard case .treasuryWithdrawalsAction(let action) = info.govAction else {
            Issue.record("Expected a treasury withdrawals action")
            return
        }
        #expect(action.withdrawals.count == 1)
        #expect(action.withdrawals.values.first == Coin(8_035_714_000_000))
    }

    @Test("Test govActionInfo throws for an unknown action")
    func testGovActionInfoUnknown() async throws {
        let context = try makeContext()
        let id = GovActionID(
            transactionID: TransactionId(payload: Data(hex: YaciMockData.proposalTxHash)),
            govActionIndex: 7
        )

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.govActionInfo(govActionID: id)
        }
    }

    @Test("Test govActionVotes keeps only each voter's latest vote")
    func testGovActionVotes() async throws {
        let context = try makeContext()
        let id = GovActionID(
            transactionID: TransactionId(payload: Data(hex: YaciMockData.proposalTxHash)),
            govActionIndex: 0
        )

        let votes = try await context.govActionVotes(govActionID: id)

        #expect(votes.committeeVotes.count == 1)
        #expect(votes.committeeVotes[0].vote == .yes)
        // The DRep voted twice; the later vote wins.
        #expect(votes.dRepVotes.count == 1)
        #expect(votes.dRepVotes[0].vote == .yes)
        #expect(votes.stakePoolVotes.count == 1)
        #expect(votes.stakePoolVotes[0].vote == .abstain)

        #expect(votes.deposit == Coin(100_000_000_000))
        #expect(!votes.depositReturnAddr.isEmpty)
        #expect(votes.anchor?.anchorUrl.absoluteString == "https://example.com")
    }

    @Test("Test govActionsAll returns every indexed proposal")
    func testGovActionsAll() async throws {
        let context = try makeContext()
        let all = try await context.govActionsAll()

        #expect(all.count == 2)
        // Yaci cannot tell an active proposal from a concluded one, so status is always nil.
        #expect(all.allSatisfy { $0.status == nil })

        guard let info = all.first(where: { $0.govActionId.transactionID.payload.toHex == YaciMockData.infoProposalTxHash })
        else {
            Issue.record("Expected the info action in the list")
            return
        }
        guard case .infoAction = info.govAction else {
            Issue.record("Expected an info action")
            return
        }
        #expect(info.committeeVotes.isEmpty)
    }

    @Test("Test governance action parsing covers each variant")
    func testGovActionParsing() throws {
        let id = GovActionID(
            transactionID: TransactionId(payload: Data(hex: YaciMockData.proposalTxHash)),
            govActionIndex: 0
        )

        func action(_ type: String, details: String) throws -> GovAction {
            let json = """
                {"tx_hash": "\(YaciMockData.proposalTxHash)", "index": 0,
                 "type": "\(type)", "details": \(details)}
                """
            let proposal = try JSONDecoder().decode(
                Components.Schemas.GovActionProposal.self, from: Data(json.utf8))
            return YaciDevkitChainContext.govAction(from: proposal, id: id)
        }

        guard case .infoAction = try action("INFO_ACTION", details: "{}") else {
            Issue.record("Expected an info action")
            return
        }
        guard case .noConfidence = try action("NO_CONFIDENCE", details: "{}") else {
            Issue.record("Expected a no-confidence action")
            return
        }

        let hardFork = try action(
            "HARD_FORK_INITIATION_ACTION", details: #"{"protocolVersion": {"_1": 10, "_2": 1}}"#)
        guard case .hardForkInitiationAction(let fork) = hardFork else {
            Issue.record("Expected a hard fork action")
            return
        }
        #expect(fork.protocolVersion.major == 10)
        #expect(fork.protocolVersion.minor == 1)

        let constitution = try action(
            "NEW_CONSTITUTION",
            details: """
                {"constitution": {"anchor": {"anchor_url": "https://constitution.test",
                                             "anchor_data_hash": "\(YaciMockData.anchorHash)"}}}
                """)
        guard case .newConstitution(let new) = constitution else {
            Issue.record("Expected a new constitution action")
            return
        }
        #expect(new.constitution.anchor.anchorUrl.absoluteString == "https://constitution.test")

        let committee = try action(
            "UPDATE_COMMITTEE",
            details: """
                {"membersForRemoval": [{"type": "ADDR_KEYHASH", "hash": "\(YaciMockData.ccColdHex)"}],
                 "newMembersAndTerms": {"scriptHash-\(YaciMockData.ccColdResignedHex)": 500},
                 "threshold": {"numerator": 2, "denominator": 3}}
                """)
        guard case .updateCommittee(let update) = committee else {
            Issue.record("Expected an update committee action")
            return
        }
        #expect(update.coldCredentials.count == 2)
        #expect(update.credentialEpochs.values.first == 500)
        #expect(update.interval.numerator == 2)
        #expect(update.interval.denominator == 3)

        // An unparseable payload keeps the variant honest rather than inventing contents.
        guard case .infoAction = try action("HARD_FORK_INITIATION_ACTION", details: "{}") else {
            Issue.record("Expected a fallback info action")
            return
        }
    }

    @Test("Test threshold parsing accepts ratios, decimals and strings")
    func testUnitIntervalParsing() {
        let ratio = YaciDevkitChainContext.unitInterval(["numerator": 2, "denominator": 3])
        #expect(ratio?.numerator == 2)
        #expect(ratio?.denominator == 3)

        #expect(YaciDevkitChainContext.unitInterval(0.5) != nil)
        #expect(YaciDevkitChainContext.unitInterval("0.5") != nil)
        #expect(YaciDevkitChainContext.unitInterval(2.0) == nil)
        #expect(YaciDevkitChainContext.unitInterval(nil) == nil)
    }

    @Test("Test anchor construction rejects incomplete input")
    func testAnchorConstruction() {
        #expect(
            YaciDevkitChainContext.anchor(url: "https://a.test", hash: YaciMockData.anchorHash) != nil)
        #expect(YaciDevkitChainContext.anchor(url: nil, hash: YaciMockData.anchorHash) == nil)
        #expect(YaciDevkitChainContext.anchor(url: "https://a.test", hash: nil) == nil)
        #expect(YaciDevkitChainContext.anchor(url: "", hash: YaciMockData.anchorHash) == nil)
    }

    // MARK: - Constitutional committee

    @Test("Test committeeState merges the current committee with its hot-key certificates")
    func testCommitteeState() async throws {
        let context = try makeContext()
        let state = try await context.committeeState()

        #expect(state.threshold == 2.0 / 3.0)
        #expect(state.members.count == 2)

        let cold = CommitteeColdCredential(
            credential: .scriptHash(ScriptHash(payload: Data(hex: YaciMockData.ccColdHex))))
        guard let authorized = state.members.first(where: { $0.coldCredential == cold }) else {
            Issue.record("Expected the authorized member")
            return
        }
        #expect(authorized.hotCredential?.credential.payload.toHex == YaciMockData.ccHotHex)
        #expect(authorized.status == .active)
        #expect(authorized.expiration == 726)

        let resignedCold = CommitteeColdCredential(
            credential: .scriptHash(ScriptHash(payload: Data(hex: YaciMockData.ccColdResignedHex))))
        guard let resigned = state.members.first(where: { $0.coldCredential == resignedCold }) else {
            Issue.record("Expected the resigned member")
            return
        }
        #expect(resigned.hotCredential == nil)
        #expect(resigned.status == .expired)
    }

    @Test("Test committeeState falls back to the live committee view")
    func testCommitteeStateFallback() async throws {
        let transport = MockYaciTransport(emptyIndexedCommittee: true)
        let context = try makeContext(transport: transport)

        let state = try await context.committeeState()

        #expect(state.threshold == 0.6)
        // The live view lists one member; the resigned cold key is still surfaced, as
        // unrecognized membership rather than silently dropped.
        #expect(state.members.count == 2)
    }

    @Test("Test committeeMemberInfo by cold credential")
    func testCommitteeMemberInfoByCold() async throws {
        let context = try makeContext()
        let cold = CommitteeColdCredential(
            credential: .scriptHash(ScriptHash(payload: Data(hex: YaciMockData.ccColdHex))))

        let info = try await context.committeeMemberInfo(cold: cold)

        #expect(info.coldCredential == cold)
        #expect(info.hotCredential?.credential.payload.toHex == YaciMockData.ccHotHex)
        #expect(info.status == .active)
    }

    @Test("Test committeeMemberInfo by hot credential")
    func testCommitteeMemberInfoByHot() async throws {
        let context = try makeContext()
        let hot = CommitteeHotCredential(
            credential: .verificationKeyHash(VerificationKeyHash(payload: Data(hex: YaciMockData.ccHotHex))))

        let info = try await context.committeeMemberInfo(hot: hot)

        #expect(info.hotCredential == hot)
        #expect(info.coldCredential.credential.payload.toHex == YaciMockData.ccColdHex)
    }

    @Test("Test committeeMemberInfo throws for an unknown credential")
    func testCommitteeMemberInfoUnknown() async throws {
        let context = try makeContext()
        let cold = CommitteeColdCredential(
            credential: .verificationKeyHash(
                VerificationKeyHash(payload: Data(hex: YaciMockData.unknownDrepHex))))

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.committeeMemberInfo(cold: cold)
        }
    }

    // MARK: - Error surface

    @Test("Test a store failure surfaces as a yaciDevkitError")
    func testStoreFailureSurfaces() async throws {
        let transport = MockYaciTransport(failing: ["getLatestEpoch": 500])
        let context = try makeContext(transport: transport)

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.epoch()
        }
    }

    @Test("Test the error description")
    func testErrorDescription() {
        #expect(CardanoChainError.yaciDevkitError("boom").description == "boom")
        #expect(
            CardanoChainError.yaciDevkitError(nil).description
                == "Failed to retrieve data from Yaci DevKit.")
    }
}
