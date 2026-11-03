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

/// A real UTxO RPC server the live tests can reach.
enum LiveUTxORPCServer: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// cardano-node's `rpc.sock`, from `UTXORPC_NODE_SOCKET`.
    case node
    /// A hosted server such as Demeter (Dolos), from `UTXORPC_URL` and
    /// optionally `UTXORPC_API_KEY`, sent as `dmtr-api-key`.
    case hosted
    /// A v1alpha-only server such as cardano-node-api, from `UTXORPC_V1ALPHA_URL`.
    case v1alpha

    static let environment = ProcessInfo.processInfo.environment

    /// The servers the environment names; the live tests are off without one.
    static let available = allCases.filter { $0.endpoint != nil }

    /// The network both servers run, from `UTXORPC_NETWORK` (default `mainnet`).
    static let network: SwiftCardanoCore.Network = switch environment["UTXORPC_NETWORK"] {
    case "preprod": .preprod
    case "preview": .preview
    default: .mainnet
    }

    var endpoint: UTxORPCEndpoint? {
        switch self {
        case .node:
            return Self.environment["UTXORPC_NODE_SOCKET"].map { .unixSocket($0) }
        case .hosted:
            guard let url = Self.environment["UTXORPC_URL"].flatMap(URL.init(string:)) else { return nil }
            let headers = Self.environment["UTXORPC_API_KEY"].map { ["dmtr-api-key": $0] } ?? [:]
            return try? UTxORPCEndpoint(url: url, headers: headers)
        case .v1alpha:
            guard let url = Self.environment["UTXORPC_V1ALPHA_URL"].flatMap(URL.init(string:)) else { return nil }
            return try? UTxORPCEndpoint(url: url, apiVersion: .v1alpha)
        }
    }

    /// The v1alpha server has no ReadGenesis, so it wraps the node's context.
    var context: UTxORPCChainContext {
        let wrapped = self == .v1alpha ? Self.node.endpoint.map { _ in Self.node.context } : nil
        return try! UTxORPCChainContext(endpoint: endpoint!, network: Self.network, wrapping: wrapped)
    }

    var testDescription: String { rawValue }
}

@Suite("UTxO RPC chain context, live servers")
struct UTxORPCLiveTests {
    /// The v1beta servers; the v1alpha one has its own test below.
    static let servers = LiveUTxORPCServer.available.filter { $0 != .v1alpha }
    static let both = servers.contains(.node) && servers.contains(.hosted)

    static func pair(_ value: UnitInterval) -> (UInt64, UInt64) { (value.numerator, value.denominator) }
    static func pair(_ value: NonNegativeInterval) -> (UInt64, UInt64) { (value.numerator, value.denominator) }
    /// Two fractions by value: one source may print decimals, the other send fractions.
    static func same(_ a: (UInt64, UInt64), _ b: (UInt64, UInt64)) -> Bool { a.0 * b.1 == b.0 * a.1 }

    /// The `ReadParams` mapping agrees with the node's own JSON, which core
    /// decodes the way it decodes `cardano-cli query protocol-parameters`.
    @Test(.enabled(if: LiveUTxORPCServer.node.endpoint != nil, "set UTXORPC_NODE_SOCKET"))
    func protocolParametersMatchTheNodeJSON() async throws {
        let server = LiveUTxORPCServer.node
        let mapped = try await server.context.protocolParameters()
        let json = try await withUTxORPCClient(endpoint: server.endpoint!) {
            try await $0.node.getProtocolParamsJson(Google_Protobuf_Empty()).json
        }
        Self.expectSame(mapped, try JSONDecoder().decode(ProtocolParameters.self, from: json))
    }

    /// The node and a hosted server on the same network report the same chain.
    @Test(.enabled(if: both, "set UTXORPC_NODE_SOCKET and UTXORPC_URL"))
    func nodeAndHostedServerAgree() async throws {
        let node = LiveUTxORPCServer.node.context
        let hosted = LiveUTxORPCServer.hosted.context
        let (nodeParams, hostedParams) = (try await node.protocolParameters(), try await hosted.protocolParameters())
        Self.expectSame(hostedParams, nodeParams, includingDolosGaps: false)
        // Seen on Demeter mainnet (Dolos) on 2026-11-02: protocol version 10.0
        // against the node's 11.0, the pre-11.0 cost models, committee minimum 7
        // against 5, and a pool retirement bound of 0. Server-side, not mapping:
        // the node's ReadParams matches its own JSON.
        withKnownIssue("Dolos protocol parameters lag the node", isIntermittent: true) {
            #expect(hostedParams.protocolVersion == nodeParams.protocolVersion)
            #expect(hostedParams.costModels == nodeParams.costModels)
            #expect(hostedParams.committeeMinSize == nodeParams.committeeMinSize)
            #expect(hostedParams.poolRetireMaxEpoch == nodeParams.poolRetireMaxEpoch)
        }

        let (a, b) = (try await node.genesisParameters(), try await hosted.genesisParameters())
        #expect(a.slotLength == b.slotLength)
        #expect(a.epochLength == b.epochLength)
        #expect(a.systemStart == b.systemStart)
        #expect(a.networkMagic == b.networkMagic)
        #expect(a.activeSlotsCoefficient == b.activeSlotsCoefficient)
        #expect(try await node.epoch() == (try await hosted.epoch()))
    }

    /// Every field the two share; `includingDolosGaps: false` leaves out the
    /// four Dolos gets wrong, which the caller checks separately.
    static func expectSame(_ mapped: ProtocolParameters, _ other: ProtocolParameters, includingDolosGaps: Bool = true) {
        if includingDolosGaps {
            #expect(mapped.protocolVersion == other.protocolVersion)
            #expect(mapped.costModels == other.costModels)
            #expect(mapped.committeeMinSize == other.committeeMinSize)
            #expect(mapped.poolRetireMaxEpoch == other.poolRetireMaxEpoch)
        }
        #expect(mapped.txFeeFixed == other.txFeeFixed)
        #expect(mapped.txFeePerByte == other.txFeePerByte)
        #expect(mapped.utxoCostPerByte == other.utxoCostPerByte)
        #expect(mapped.maxTxSize == other.maxTxSize)
        #expect(mapped.maxValueSize == other.maxValueSize)
        #expect(mapped.maxBlockBodySize == other.maxBlockBodySize)
        #expect(mapped.maxBlockHeaderSize == other.maxBlockHeaderSize)
        #expect(mapped.stakeAddressDeposit == other.stakeAddressDeposit)
        #expect(mapped.stakePoolDeposit == other.stakePoolDeposit)
        #expect(mapped.minPoolCost == other.minPoolCost)
        #expect(mapped.collateralPercentage == other.collateralPercentage)
        #expect(mapped.maxCollateralInputs == other.maxCollateralInputs)
        #expect(mapped.maxTxExecutionUnits == other.maxTxExecutionUnits)
        #expect(mapped.maxBlockExecutionUnits == other.maxBlockExecutionUnits)
        #expect(mapped.dRepDeposit == other.dRepDeposit)
        #expect(mapped.govActionDeposit == other.govActionDeposit)
        #expect(mapped.govActionLifetime == other.govActionLifetime)
        #expect(mapped.dRepActivity == other.dRepActivity)
        #expect(mapped.committeeMaxTermLength == other.committeeMaxTermLength)
        #expect(mapped.stakePoolTargetNum == other.stakePoolTargetNum)
        #expect(same(pair(mapped.executionUnitPrices.priceMemory), pair(other.executionUnitPrices.priceMemory)))
        #expect(same(pair(mapped.executionUnitPrices.priceSteps), pair(other.executionUnitPrices.priceSteps)))
        #expect(same(pair(mapped.monetaryExpansion), pair(other.monetaryExpansion)))
        #expect(same(pair(mapped.treasuryCut), pair(other.treasuryCut)))
        #expect(same(pair(mapped.poolPledgeInfluence), pair(other.poolPledgeInfluence)))
        for (a, b) in zip(mapped.dRepVotingThresholds.ledgerOrder, other.dRepVotingThresholds.ledgerOrder) {
            #expect(same(pair(a), pair(b)))
        }
        for (a, b) in zip(mapped.poolVotingThresholds.ledgerOrder, other.poolVotingThresholds.ledgerOrder) {
            #expect(same(pair(a), pair(b)))
        }
        if let a = mapped.minFeeRefScriptCostPerByte, let b = other.minFeeRefScriptCostPerByte {
            #expect(same(pair(a), pair(b)))
        }
    }

    @Test(arguments: servers)
    func tipGenesisAndEra(_ server: LiveUTxORPCServer) async throws {
        let context = server.context
        let genesis = try await context.genesisParameters()
        #expect(genesis.networkMagic == UInt32(LiveUTxORPCServer.network.testnetMagic ?? 764_824_073))
        #expect(genesis.epochLength ?? 0 > 0)
        #expect(genesis.slotLength == 1)
        #expect(genesis.systemStart != nil)

        let tip = try await context.chainTip()
        #expect((tip.slot ?? 0) > 0)
        #expect(tip.hash?.count == 64)
        #expect(tip.era == "conway")
        #expect(try await context.era() == .conway)
        #expect(try await context.lastBlockSlot() >= Int(tip.slot ?? 0))
        print("UTxO RPC live \(server): epoch \(tip.epoch ?? 0), slot \(tip.slot ?? 0) (\(tip.slotInEpoch ?? 0) in epoch), block \(tip.block.map(String.init) ?? "-"), sync \(tip.syncProgress ?? "-")%")
    }

    #if NODESOCKET
    /// The epoch worked out from slots agrees with the node's own epoch.
    @Test(arguments: servers)
    func epochMatchesTheNodeSocket(_ server: LiveUTxORPCServer) async throws {
        let socket = try #require(LiveUTxORPCServer.environment["UTXORPC_NODE_SOCKET"], "needs the node too")
        let nodeSocket = (socket as NSString).deletingLastPathComponent + "/node.socket"
        let socketContext = NodeSocketChainContext(socketPath: FilePath(nodeSocket), network: LiveUTxORPCServer.network)
        #expect(try await server.context.epoch() == (try await socketContext.epoch()))
    }
    #endif

    /// An output from the tip block reads back by reference and by address,
    /// and where the server has `ReadTx`, its transaction by hash.
    @Test(arguments: servers)
    func outputsFromTheTipBlock(_ server: LiveUTxORPCServer) async throws {
        let (txHash, index, address) = try await withUTxORPCClient(endpoint: server.endpoint!) { client in
            let tip = try await client.sync.readTip(Utxorpc_V1beta_Sync_ReadTipRequest()).tip
            let blocks = try await client.sync.fetchBlock(.with { $0.ref = [tip] }).block
            let tx = try #require(blocks.first?.cardano.body.tx.first { !$0.outputs.isEmpty })
            return (tx.hash, UInt16(tx.outputs.count - 1), tx.outputs[tx.outputs.count - 1].address)
        }
        let context = server.context
        let id = TransactionId(payload: txHash)
        let input = TransactionInput(transactionId: id, index: index)
        // Spent since the tip was read is possible but unlikely; nil is then fine.
        if let (utxo, isSpent) = try await context.utxo(input: input) {
            #expect(!isSpent)
            #expect(utxo.output.address.toBytes() == address)
            let atAddress = try await context.utxos(address: utxo.output.address)
            #expect(atAddress.contains { $0.input == input })
            print("UTxO RPC live \(server): \(atAddress.count) UTxOs at the tip block's output address")
        }

        do {
            // Decodes and checks the id is the hash of the bytes returned.
            let transaction = try await context.transaction(hash: id)
            #expect(transaction.transactionBody.outputs.count == Int(index) + 1)
        } catch CardanoChainError.notImplemented {
            #expect(server == .node, "only cardano-node lacks ReadTx")
        }
    }

    @Test(arguments: servers)
    func evaluatingGarbageFails(_ server: LiveUTxORPCServer) async throws {
        await #expect(throws: CardanoChainError.self) {
            try await server.context.evaluateTxCBOR(cbor: Data([0x80]))
        }
    }

    /// cardano-node-api reads the same node over v1alpha: the same parameters,
    /// tip and UTxOs as the node's own v1beta server.
    @Test(.enabled(
        if: LiveUTxORPCServer.v1alpha.endpoint != nil && LiveUTxORPCServer.node.endpoint != nil,
        "set UTXORPC_V1ALPHA_URL and UTXORPC_NODE_SOCKET"))
    func v1alphaServerMatchesTheNode() async throws {
        let node = LiveUTxORPCServer.node.context
        let v1alpha = LiveUTxORPCServer.v1alpha.context
        Self.expectSame(try await v1alpha.protocolParameters(), try await node.protocolParameters())

        // The pre-Conway fields it does send agree with the node's.
        func rawParams(_ server: LiveUTxORPCServer) async throws -> Utxorpc_V1beta_Cardano_PParams {
            try await withUTxORPCClient(endpoint: server.endpoint!) {
                try await $0.query.readParams(Utxorpc_V1beta_Query_ReadParamsRequest()).values.cardano
            }
        }
        let (alphaRaw, nodeRaw) = (try await rawParams(.v1alpha), try await rawParams(.node))
        #expect(!UTxORPCMapping.hasGovernanceParameters(alphaRaw))
        #expect(alphaRaw.minFeeConstant == nodeRaw.minFeeConstant)
        #expect(alphaRaw.minFeeCoefficient == nodeRaw.minFeeCoefficient)
        #expect(alphaRaw.coinsPerUtxoByte == nodeRaw.coinsPerUtxoByte)
        #expect(alphaRaw.maxTxSize == nodeRaw.maxTxSize)
        #expect(alphaRaw.prices == nodeRaw.prices)
        #expect(alphaRaw.maxExecutionUnitsPerTransaction == nodeRaw.maxExecutionUnitsPerTransaction)
        // gouroboros v0.160.2, which the archived cardano-node-api pins, maps the
        // ledger's language ids 1...3 to V1...V3 where they are 0...2: V1 is lost,
        // V2 arrives as V1 and V3 as V2. Another reason its parameters are not used.
        withKnownIssue("cardano-node-api shifts the cost models by one") {
            #expect(alphaRaw.costModels == nodeRaw.costModels)
        }
        #expect(alphaRaw.costModels.plutusV1 == nodeRaw.costModels.plutusV2)
        #expect(alphaRaw.costModels.plutusV2 == nodeRaw.costModels.plutusV3)
        #expect(alphaRaw.protocolVersion == nodeRaw.protocolVersion)

        let (nodeTip, alphaTip) = (try await node.chainTip(), try await v1alpha.chainTip())
        #expect(alphaTip.epoch == nodeTip.epoch)
        #expect(abs(Int(alphaTip.slot ?? 0) - Int(nodeTip.slot ?? 0)) < 600)
        #expect(alphaTip.era == "conway")

        // An address the node's tip block paid, read through both servers.
        let address = try await withUTxORPCClient(endpoint: LiveUTxORPCServer.node.endpoint!) { client in
            let tip = try await client.sync.readTip(Utxorpc_V1beta_Sync_ReadTipRequest()).tip
            let block = try #require(try await client.sync.fetchBlock(.with { $0.ref = [tip] }).block.first)
            return try #require(block.cardano.body.tx.lazy.flatMap(\.outputs).last?.address)
        }
        let decoded = try Address(from: .bytes(address))
        let (fromNode, fromAlpha) = (try await node.utxos(address: decoded), try await v1alpha.utxos(address: decoded))
        // Blocks may land between the two reads; compare what both saw.
        let common = Set(fromNode.map(\.input)).intersection(fromAlpha.map(\.input))
        #expect(!common.isEmpty)
        for utxo in fromAlpha where common.contains(utxo.input) {
            #expect(fromNode.first { $0.input == utxo.input } == utxo)
        }
        if let first = fromAlpha.first {
            #expect(try await v1alpha.utxo(input: first.input)?.0 == first)
        }

        await #expect(throws: CardanoChainError.self) { try await v1alpha.evaluateTxCBOR(cbor: Data([0x80])) }
        print("UTxO RPC live v1alpha: epoch \(alphaTip.epoch ?? 0), slot \(alphaTip.slot ?? 0), \(fromAlpha.count) UTxOs at the address (node \(fromNode.count))")
    }
}
