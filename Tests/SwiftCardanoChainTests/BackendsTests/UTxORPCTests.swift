import BigInt
import Foundation
import SwiftCardanoCore
import Testing
import UTxORPC

@testable import SwiftCardanoChain

@Suite("UTxO RPC chain context")
struct UTxORPCTests {
    static let address =
        "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"

    static func context(
        _ chain: FakeUTxORPCChain = FakeUTxORPCChain(),
        network: SwiftCardanoCore.Network = .mainnet,
        wrapping: (any ChainContext)? = nil
    ) -> UTxORPCChainContext {
        UTxORPCChainContext(connector: FakeUTxORPCConnector(chain: chain), network: network, wrapping: wrapping)
    }

    /// An output at ``address`` holding `lovelace`, as the server sends it:
    /// its reference, its CBOR, and the parsed address the search matches on.
    static func utxo(_ txByte: UInt8, _ index: UInt32, lovelace: UInt64) throws -> Utxorpc_V1beta_Query_AnyUtxoData {
        let address = try Address(from: .string(Self.address))
        let output = TransactionOutput(address: address, amount: Value(coin: BigInt(lovelace)))
        return try .with {
            $0.txoRef = .with { $0.hash = Data(repeating: txByte, count: 32); $0.index = index }
            $0.nativeBytes = try output.toCBORData()
            $0.cardano = .with { $0.address = address.toBytes() }
        }
    }

    // MARK: - Parameters

    @Test func protocolParametersMapEveryField() async throws {
        let params = try await Self.context().protocolParameters()
        #expect(params.txFeeFixed == 155_381)
        #expect(params.txFeePerByte == 44)
        #expect(params.utxoCostPerByte == 4_310)
        #expect(params.maxTxSize == 16_384)
        #expect(params.stakeAddressDeposit == 2_000_000)
        #expect(params.stakePoolDeposit == 500_000_000)
        #expect(params.govActionDeposit == 100_000_000_000)
        #expect(params.dRepDeposit == 500_000_000)
        #expect(params.collateralPercentage == 150)
        #expect(params.protocolVersion == ProtocolParametersProtocolVersion(major: 10, minor: 0))
        #expect(params.executionUnitPrices.priceMemory == NonNegativeInterval(numerator: 577, denominator: 10_000))
        #expect(params.executionUnitPrices.priceSteps == NonNegativeInterval(numerator: 721, denominator: 10_000_000))
        #expect(params.maxTxExecutionUnits == ProtocolParametersExecutionUnits(memory: 16_500_000, steps: 10_000_000_000))
        #expect(params.minFeeRefScriptCostPerByte == NonNegativeInterval(numerator: 15, denominator: 1))
        #expect(params.monetaryExpansion == UnitInterval(numerator: 3, denominator: 1_000))
        #expect(params.treasuryCut == UnitInterval(numerator: 1, denominator: 5))
        #expect(params.costModels == ProtocolParametersCostModels(PlutusV1: [1, 2, 3], PlutusV2: [4, 5], PlutusV3: [6, -7]))
        #expect(params.committeeMaxTermLength == 146)
        #expect(params.govActionLifetime == 6)
        #expect(params.dRepActivity == 20)
    }

    /// The wire lists are in CIP-1694 order; each threshold has its own value
    /// in the fake, so a swapped pair shows.
    @Test func votingThresholdsFollowTheLedgerOrder() async throws {
        let params = try await Self.context().protocolParameters()
        let pool = params.poolVotingThresholds
        #expect(pool.motionNoConfidence.numerator == 51)
        #expect(pool.committeeNormal.numerator == 52)
        #expect(pool.committeeNoConfidence.numerator == 53)
        #expect(pool.hardForkInitiation.numerator == 54)
        #expect(pool.ppSecurityGroup.numerator == 55)
        let drep = params.dRepVotingThresholds
        #expect(drep.ledgerOrder.map(\.numerator) == Array(61...70))
    }

    @Test func thresholdsOfTheWrongCountAreRejected() async throws {
        var chain = FakeUTxORPCChain()
        chain.params.poolVotingThresholds.thresholds.removeLast()
        await #expect(throws: CardanoChainError.self) { try await Self.context(chain).protocolParameters() }
    }

    @Test func aRationalAboveOneIsNotAUnitInterval() async throws {
        var chain = FakeUTxORPCChain()
        chain.params.monetaryExpansion = .ratio(3, 2)
        await #expect(throws: CardanoChainError.self) { try await Self.context(chain).protocolParameters() }
    }

    @Test func genesisParametersMapAndConvertTheSlotLength() async throws {
        var chain = FakeUTxORPCChain()
        chain.genesis.slotLength = 200
        let genesis = try await Self.context(chain).genesisParameters()
        #expect(genesis.epochLength == 432_000)
        #expect(genesis.networkMagic == 764_824_073)
        #expect(genesis.securityParam == 2_160)
        #expect(genesis.slotLength == Decimal(string: "0.2"))
        #expect(genesis.activeSlotsCoefficient == UnitInterval(numerator: 1, denominator: 20))
        #expect(genesis.systemStart == Date(timeIntervalSince1970: 1_506_203_091))
    }

    /// cardano-node sends milliseconds, Dolos the genesis file's seconds.
    @Test(arguments: [(UInt32(1_000), "1"), (1, "1"), (200, "0.2"), (20, "20")])
    func slotLengthInEitherUnit(_ raw: UInt32, _ seconds: String) throws {
        #expect(try UTxORPCMapping.slotLengthSeconds(raw) == Decimal(string: seconds))
    }

    @Test func aZeroSlotLengthIsRejected() {
        #expect(throws: CardanoChainError.self) { try UTxORPCMapping.slotLengthSeconds(0) }
    }

    @Test func aTipWithoutHeightHasNoBlockNumber() async throws {
        var chain = FakeUTxORPCChain()
        chain.tipHeight = 0
        #expect(try await Self.context(chain).chainTip().block == nil)
    }

    // MARK: - Tip and epochs

    /// Node 11.1.x has no era summary: the epoch comes from mainnet's Byron
    /// transition (208 epochs of 21,600 slots) and the genesis epoch length.
    @Test func chainTipWithoutAnEraSummary() async throws {
        let tip = try await Self.context().chainTip()
        #expect(tip.slot == 202_090_697)
        #expect(tip.block == 14_150_084)
        #expect(tip.hash == String(repeating: "ab", count: 32))
        #expect(tip.epoch == 665)
        #expect(tip.slotInEpoch == 173_897)
        #expect(tip.slotsToEpochEnd == 432_000 - 173_897)
        #expect(tip.era == "conway")
        #expect(tip.syncProgress != nil)
    }

    /// With an era summary the epoch counts on from the start of the current era.
    @Test func epochFromTheEraSummary() async throws {
        var chain = FakeUTxORPCChain()
        chain.tipSlot = 1_000 + 3 * 432_000 + 5
        chain.eraSummaries = [
            .with { $0.name = "byron"; $0.start = .with { $0.slot = 0; $0.epoch = 0 } },
            .with { $0.name = "conway"; $0.start = .with { $0.slot = 1_000; $0.epoch = 900 } },
        ]
        chain.nodeService = false
        let context = Self.context(chain, network: .preview)
        #expect(try await context.epoch() == 903)
        #expect(try await context.era() == .conway)
        let tip = try await context.chainTip()
        #expect(tip.slotInEpoch == 5)
    }

    @Test func eraFallsBackToTheEpochWithoutNodeOrSummary() async throws {
        var chain = FakeUTxORPCChain()
        chain.nodeService = false
        #expect(try await Self.context(chain).era() == .conway)
    }

    // MARK: - UTxOs

    @Test func utxosAtAnAddressFollowEveryPage() async throws {
        var chain = FakeUTxORPCChain()
        chain.utxos = try (0..<2_500).map { try Self.utxo(UInt8($0 % 250), UInt32($0), lovelace: 1_000_000 + UInt64($0)) }
        let utxos = try await Self.context(chain).utxos(address: try Address(from: .string(Self.address)))
        #expect(utxos.count == 2_500)
        #expect(utxos.last?.output.amount.coin == 1_002_499)
        #expect(utxos.first?.output.address.toBytes() == (try Address(from: .string(Self.address))).toBytes())
    }

    @Test func utxoByInput() async throws {
        var chain = FakeUTxORPCChain()
        chain.utxos = [try Self.utxo(0x11, 1, lovelace: 5_000_000)]
        let context = Self.context(chain)
        let found = try await context.utxo(
            input: TransactionInput(transactionId: TransactionId(payload: Data(repeating: 0x11, count: 32)), index: 1)
        )
        #expect(found?.0.output.amount.coin == 5_000_000)
        #expect(found?.isSpent == false)
        let missing = try await context.utxo(
            input: TransactionInput(transactionId: TransactionId(payload: Data(repeating: 0x11, count: 32)), index: 2)
        )
        #expect(missing == nil)
    }

    @Test func aUtxoWithoutCBORIsAnError() async throws {
        var chain = FakeUTxORPCChain()
        var item = try Self.utxo(0x11, 0, lovelace: 1)
        item.nativeBytes = Data()
        chain.utxos = [item]
        await #expect(throws: CardanoChainError.self) {
            try await Self.context(chain).utxos(address: try Address(from: .string(Self.address)))
        }
    }

    // MARK: - Transactions

    @Test func submitReturnsTheTransactionId() async throws {
        let id = try await Self.context().submitTxCBOR(cbor: Data([0x84]))
        #expect(id == String(repeating: "c0", count: 32))
    }

    @Test func aRejectedSubmitCarriesTheReason() async throws {
        var chain = FakeUTxORPCChain()
        chain.submitRejection = "BadInputsUTxO"
        do {
            _ = try await Self.context(chain).submitTxCBOR(cbor: Data([0x84]))
            Issue.record("submit should have failed")
        } catch CardanoChainError.transactionFailed(let message) {
            #expect(message?.contains("BadInputsUTxO") == true)
        }
    }

    @Test func evaluationKeysMatchTheTransactionBuilder() async throws {
        var chain = FakeUTxORPCChain()
        chain.evaluation = .with {
            $0.redeemers = [
                .with { $0.purpose = .spend; $0.index = 0; $0.exUnits = .with { $0.memory = 1_700; $0.steps = 476_468 } },
                .with { $0.purpose = .vote; $0.index = 2; $0.exUnits = .with { $0.memory = 10; $0.steps = 20 } },
            ]
        }
        let units = try await Self.context(chain).evaluateTxCBOR(cbor: Data([0x84]))
        #expect(units["spend:0"] == ExecutionUnits(mem: 1_700, steps: 476_468))
        #expect(units["voting:2"] == ExecutionUnits(mem: 10, steps: 20))
    }

    /// A transaction-level error has no purpose and must not read as redeemer 0.
    @Test func evaluationErrorsAreReported() async throws {
        var chain = FakeUTxORPCChain()
        chain.evaluation = .with {
            $0.errors = [
                .with { $0.msg = "script failed"; $0.purpose = .mint; $0.index = 0 },
                .with { $0.msg = "value not conserved" },
            ]
        }
        do {
            _ = try await Self.context(chain).evaluateTxCBOR(cbor: Data([0x84]))
            Issue.record("evaluation should have failed")
        } catch CardanoChainError.transactionFailed(let message) {
            #expect(message?.contains("mint:0: script failed") == true)
            #expect(message?.contains("; value not conserved") == true)
        }
    }

    @Test func transactionCBORFromReadTx() async throws {
        var chain = FakeUTxORPCChain()
        let hash = Data(repeating: 0x22, count: 32)
        chain.transactions = [hash: Data([0x84, 0xA0])]
        let cbor = try await Self.context(chain).transactionCBOR(hash: TransactionId(payload: hash))
        #expect(cbor == Data([0x84, 0xA0]))
    }

    /// cardano-node has no ReadTx; without a wrapped context that is "not implemented".
    @Test func transactionCBORWithoutReadTxNeedsAWrappedContext() async throws {
        do {
            _ = try await Self.context().transactionCBOR(hash: TransactionId(payload: Data(repeating: 0x22, count: 32)))
            Issue.record("transactionCBOR should have failed")
        } catch CardanoChainError.notImplemented(let message) {
            #expect(message?.contains("wrapped context") == true)
        }
    }

    @Test func stakeAndGovernanceGoToTheWrappedContext() async throws {
        let context = Self.context()
        await #expect(throws: CardanoChainError.self) { try await context.treasury() }
        #expect(context.name == "UTxO RPC")
    }
}
