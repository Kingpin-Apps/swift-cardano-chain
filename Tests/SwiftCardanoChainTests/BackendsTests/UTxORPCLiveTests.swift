import Foundation
import SwiftCardanoCore
import SwiftProtobuf
import Testing
import UTxORPC
import UTxORPCCardanoNode
import UTxORPCClient
#if NODESOCKET
import SystemPackage
#endif

@testable import SwiftCardanoChain

/// Talks to a real cardano-node. Off unless `UTXORPC_NODE_SOCKET` names its
/// `rpc.sock` (node started with `"EnableRpc": true`); `UTXORPC_NETWORK`
/// (default `mainnet`) names the network it runs.
@Suite("UTxO RPC chain context, live node")
struct UTxORPCLiveTests {
    static let socket = ProcessInfo.processInfo.environment["UTXORPC_NODE_SOCKET"]
    static let network: SwiftCardanoCore.Network = switch ProcessInfo.processInfo.environment["UTXORPC_NETWORK"] {
    case "preprod": .preprod
    case "preview": .preview
    default: .mainnet
    }

    static var endpoint: UTxORPCEndpoint { .unixSocket(socket!) }
    static var context: UTxORPCChainContext { UTxORPCChainContext(endpoint: endpoint, network: network) }

    /// The `ReadParams` mapping agrees with the node's own JSON, which core
    /// decodes the way it decodes `cardano-cli query protocol-parameters`.
    @Test(.enabled(if: socket != nil, "set UTXORPC_NODE_SOCKET"))
    func protocolParametersMatchTheNodeJSON() async throws {
        let mapped = try await Self.context.protocolParameters()
        let json = try await withUTxORPCClient(endpoint: Self.endpoint) {
            try await $0.node.getProtocolParamsJson(Google_Protobuf_Empty()).json
        }
        let decoded = try JSONDecoder().decode(ProtocolParameters.self, from: json)

        #expect(mapped.txFeeFixed == decoded.txFeeFixed)
        #expect(mapped.txFeePerByte == decoded.txFeePerByte)
        #expect(mapped.utxoCostPerByte == decoded.utxoCostPerByte)
        #expect(mapped.maxTxSize == decoded.maxTxSize)
        #expect(mapped.maxValueSize == decoded.maxValueSize)
        #expect(mapped.maxBlockBodySize == decoded.maxBlockBodySize)
        #expect(mapped.maxBlockHeaderSize == decoded.maxBlockHeaderSize)
        #expect(mapped.stakeAddressDeposit == decoded.stakeAddressDeposit)
        #expect(mapped.stakePoolDeposit == decoded.stakePoolDeposit)
        #expect(mapped.minPoolCost == decoded.minPoolCost)
        #expect(mapped.collateralPercentage == decoded.collateralPercentage)
        #expect(mapped.maxCollateralInputs == decoded.maxCollateralInputs)
        #expect(mapped.maxTxExecutionUnits == decoded.maxTxExecutionUnits)
        #expect(mapped.maxBlockExecutionUnits == decoded.maxBlockExecutionUnits)
        #expect(mapped.protocolVersion == decoded.protocolVersion)
        #expect(mapped.costModels == decoded.costModels)
        #expect(mapped.dRepDeposit == decoded.dRepDeposit)
        #expect(mapped.govActionDeposit == decoded.govActionDeposit)
        #expect(mapped.govActionLifetime == decoded.govActionLifetime)
        #expect(mapped.dRepActivity == decoded.dRepActivity)
        #expect(mapped.committeeMinSize == decoded.committeeMinSize)
        #expect(mapped.committeeMaxTermLength == decoded.committeeMaxTermLength)
        #expect(mapped.poolRetireMaxEpoch == decoded.poolRetireMaxEpoch)
        #expect(mapped.stakePoolTargetNum == decoded.stakePoolTargetNum)
        // Rationals by value: the JSON prints decimals, the wire sends fractions.
        func same(_ a: (UInt64, UInt64), _ b: (UInt64, UInt64)) -> Bool { a.0 * b.1 == b.0 * a.1 }
        #expect(same(Self.pair(mapped.executionUnitPrices.priceMemory), Self.pair(decoded.executionUnitPrices.priceMemory)))
        #expect(same(Self.pair(mapped.executionUnitPrices.priceSteps), Self.pair(decoded.executionUnitPrices.priceSteps)))
        #expect(same(Self.pair(mapped.monetaryExpansion), Self.pair(decoded.monetaryExpansion)))
        #expect(same(Self.pair(mapped.treasuryCut), Self.pair(decoded.treasuryCut)))
        #expect(same(Self.pair(mapped.poolPledgeInfluence), Self.pair(decoded.poolPledgeInfluence)))
        for (a, b) in zip(mapped.dRepVotingThresholds.ledgerOrder, decoded.dRepVotingThresholds.ledgerOrder) {
            #expect(same(Self.pair(a), Self.pair(b)))
        }
        for (a, b) in zip(mapped.poolVotingThresholds.ledgerOrder, decoded.poolVotingThresholds.ledgerOrder) {
            #expect(same(Self.pair(a), Self.pair(b)))
        }
        if let a = mapped.minFeeRefScriptCostPerByte, let b = decoded.minFeeRefScriptCostPerByte {
            #expect(same(Self.pair(a), Self.pair(b)))
        }
    }

    static func pair(_ value: UnitInterval) -> (UInt64, UInt64) { (value.numerator, value.denominator) }
    static func pair(_ value: NonNegativeInterval) -> (UInt64, UInt64) { (value.numerator, value.denominator) }

    @Test(.enabled(if: socket != nil, "set UTXORPC_NODE_SOCKET"))
    func tipGenesisAndEra() async throws {
        let context = Self.context
        let genesis = try await context.genesisParameters()
        #expect(genesis.networkMagic == UInt32(Self.network.testnetMagic ?? 764_824_073))
        #expect(genesis.epochLength ?? 0 > 0)
        #expect(genesis.systemStart != nil)

        let tip = try await context.chainTip()
        #expect((tip.slot ?? 0) > 0)
        #expect(tip.hash?.count == 64)
        #expect(tip.era == "conway")
        #expect(try await context.era() == .conway)
        #expect(try await context.lastBlockSlot() >= Int(tip.slot ?? 0))
        print("UTxO RPC live tip: epoch \(tip.epoch ?? 0), slot \(tip.slot ?? 0) (\(tip.slotInEpoch ?? 0) in epoch), sync \(tip.syncProgress ?? "-")%")
    }

    #if NODESOCKET
    /// The epoch worked out from slots agrees with the node's own epoch.
    @Test(.enabled(if: socket != nil, "set UTXORPC_NODE_SOCKET"))
    func epochMatchesTheNodeSocket() async throws {
        let nodeSocket = (Self.socket! as NSString).deletingLastPathComponent + "/node.socket"
        let socketContext = NodeSocketChainContext(socketPath: FilePath(nodeSocket), network: Self.network)
        #expect(try await Self.context.epoch() == (try await socketContext.epoch()))
    }
    #endif

    /// An output from the tip block reads back by reference and by address.
    @Test(.enabled(if: socket != nil, "set UTXORPC_NODE_SOCKET"))
    func outputsFromTheTipBlock() async throws {
        let (txHash, index, address) = try await withUTxORPCClient(endpoint: Self.endpoint) { client in
            let tip = try await client.sync.readTip(Utxorpc_V1beta_Sync_ReadTipRequest()).tip
            let blocks = try await client.sync.fetchBlock(.with { $0.ref = [tip] }).block
            let tx = try #require(blocks.first?.cardano.body.tx.first { !$0.outputs.isEmpty })
            return (tx.hash, UInt16(tx.outputs.count - 1), tx.outputs[tx.outputs.count - 1].address)
        }
        let context = Self.context
        let input = TransactionInput(transactionId: TransactionId(payload: txHash), index: index)
        // Spent since the tip was read is possible but unlikely; nil is then fine.
        if let (utxo, isSpent) = try await context.utxo(input: input) {
            #expect(!isSpent)
            #expect(utxo.output.address.toBytes() == address)
            let atAddress = try await context.utxos(address: utxo.output.address)
            #expect(atAddress.contains { $0.input == input })
            print("UTxO RPC live: \(atAddress.count) UTxOs at the tip block's output address")
        }
    }

    @Test(.enabled(if: socket != nil, "set UTXORPC_NODE_SOCKET"))
    func evaluatingGarbageFails() async throws {
        await #expect(throws: CardanoChainError.self) {
            try await Self.context.evaluateTxCBOR(cbor: Data([0x80]))
        }
    }
}
