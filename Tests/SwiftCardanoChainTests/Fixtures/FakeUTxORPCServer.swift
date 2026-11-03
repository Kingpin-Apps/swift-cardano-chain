import Foundation
import GRPCCore
import GRPCInProcessTransport
import SwiftProtobuf
import UTxORPC
import UTxORPCCardanoNode
import UTxORPCClient

@testable import SwiftCardanoChain

/// What the fake UTxO RPC server answers. The defaults are a cardano-node
/// 11.1.x on mainnet: no era summary, no `ReadTx`.
struct FakeUTxORPCChain: Sendable {
    var tipSlot: UInt64 = 202_090_697
    var tipHeight: UInt64 = 14_150_084
    var tipTimestamp: UInt64 = 1_793_000_000_000
    var params = FakeUTxORPCChain.mainnetParams
    var genesis = FakeUTxORPCChain.mainnetGenesis
    /// `false` answers `ReadGenesis` with `UNIMPLEMENTED`, as cardano-node-api does.
    var servesGenesis = true
    /// `nil` answers `ReadEraSummary` with `UNIMPLEMENTED`.
    var eraSummaries: [Utxorpc_V1beta_Cardano_EraSummary]?
    /// Serve `cardano.rpc.Node`, as only cardano-node does.
    var nodeService = true
    var utxos: [Utxorpc_V1beta_Query_AnyUtxoData] = []
    /// `nil` answers `ReadTx` with `UNIMPLEMENTED`.
    var transactions: [Data: Data]?
    var evaluation = Utxorpc_V1beta_Cardano_TxEval()
    /// `false` answers `EvalTx` with `UNIMPLEMENTED`, as cardano-node-api does.
    var servesEvalTx = true
    /// `nil` answers `ReadState` with `UNIMPLEMENTED`, as cardano-node does.
    var poolDistribution: [Utxorpc_V1beta_Cardano_PoolStakeShare]?
    /// A rejection reason makes `SubmitTx` fail with it.
    var submitRejection: String?

    static let mainnetParams = Utxorpc_V1beta_Cardano_PParams.with {
        $0.coinsPerUtxoByte = .lovelace(4_310)
        $0.maxTxSize = 16_384
        $0.minFeeCoefficient = .lovelace(44)
        $0.minFeeConstant = .lovelace(155_381)
        $0.maxBlockBodySize = 90_112
        $0.maxBlockHeaderSize = 1_100
        $0.stakeKeyDeposit = .lovelace(2_000_000)
        $0.poolDeposit = .lovelace(500_000_000)
        $0.poolRetirementEpochBound = 18
        $0.desiredNumberOfPools = 500
        $0.poolInfluence = .ratio(3, 10)
        $0.monetaryExpansion = .ratio(3, 1_000)
        $0.treasuryExpansion = .ratio(1, 5)
        $0.minPoolCost = .lovelace(170_000_000)
        $0.protocolVersion = .with { $0.major = 10; $0.minor = 0 }
        $0.maxValueSize = 5_000
        $0.collateralPercentage = 150
        $0.maxCollateralInputs = 3
        $0.costModels = .with {
            $0.plutusV1 = .with { $0.values = [1, 2, 3] }
            $0.plutusV2 = .with { $0.values = [4, 5] }
            $0.plutusV3 = .with { $0.values = [6, -7] }
        }
        $0.prices = .with { $0.memory = .ratio(577, 10_000); $0.steps = .ratio(721, 10_000_000) }
        $0.maxExecutionUnitsPerTransaction = .with { $0.memory = 16_500_000; $0.steps = 10_000_000_000 }
        $0.maxExecutionUnitsPerBlock = .with { $0.memory = 72_000_000; $0.steps = 20_000_000_000 }
        $0.minFeeScriptRefCostPerByte = .ratio(15, 1)
        // Distinct values, so a mix-up of the CIP-1694 order shows.
        $0.poolVotingThresholds = .with { $0.thresholds = (51...55).map { .ratio(Int32($0), 100) } }
        $0.drepVotingThresholds = .with { $0.thresholds = (61...70).map { .ratio(Int32($0), 100) } }
        $0.minCommitteeSize = 7
        $0.committeeTermLimit = 146
        $0.governanceActionValidityPeriod = 6
        $0.governanceActionDeposit = .lovelace(100_000_000_000)
        $0.drepDeposit = .lovelace(500_000_000)
        $0.drepInactivityPeriod = 20
    }

    static let mainnetGenesis = Utxorpc_V1beta_Cardano_Genesis.with {
        $0.activeSlotsCoeff = .ratio(1, 20)
        $0.epochLength = 432_000
        $0.maxKesEvolutions = 62
        $0.maxLovelaceSupply = .lovelace(45_000_000_000_000_000)
        $0.networkID = "Mainnet"
        $0.networkMagic = 764_824_073
        $0.securityParam = 2_160
        $0.slotLength = 1_000
        $0.slotsPerKesPeriod = 129_600
        $0.systemStart = "2017-09-23T21:44:51Z"
        $0.updateQuorum = 5
    }
}

extension Utxorpc_V1beta_Cardano_BigInt {
    static func lovelace(_ value: Int64) -> Self { .with { $0.int = value } }
}

extension Utxorpc_V1beta_Cardano_RationalNumber {
    static func ratio(_ numerator: Int32, _ denominator: UInt32) -> Self {
        .with { $0.numerator = numerator; $0.denominator = denominator }
    }
}

private func unimplemented(_ method: String) -> RPCError {
    RPCError(code: .unimplemented, message: "Method \(method) not implemented")
}

struct FakeQueryService: Utxorpc_V1beta_Query_QueryService.SimpleServiceProtocol {
    let chain: FakeUTxORPCChain
    let tip: Utxorpc_V1beta_Query_ChainPoint

    func readParams(
        request: Utxorpc_V1beta_Query_ReadParamsRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Query_ReadParamsResponse {
        .with { $0.values.cardano = chain.params; $0.ledgerTip = tip }
    }

    func readUtxos(
        request: Utxorpc_V1beta_Query_ReadUtxosRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Query_ReadUtxosResponse {
        .with {
            $0.items = chain.utxos.filter { utxo in
                request.keys.contains { $0.hash == utxo.txoRef.hash && $0.index == utxo.txoRef.index }
            }
            $0.ledgerTip = tip
        }
    }

    /// Exact-address search only, paginated like cardano-node: the token is
    /// the position after the last item returned.
    func searchUtxos(
        request: Utxorpc_V1beta_Query_SearchUtxosRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Query_SearchUtxosResponse {
        guard case .cardano(let pattern)? = request.predicate.match.utxoPattern,
              !pattern.address.exactAddress.isEmpty
        else {
            throw RPCError(code: .invalidArgument, message: "predicate too broad")
        }
        let matching = chain.utxos.filter { $0.cardano.address == pattern.address.exactAddress }
        let start = request.hasStartToken ? Int(request.startToken) ?? 0 : 0
        let end = min(start + Int(request.maxItems), matching.count)
        return .with {
            $0.items = Array(matching[start..<end])
            $0.ledgerTip = tip
            if end < matching.count { $0.nextToken = String(end) }
        }
    }

    func readData(
        request: Utxorpc_V1beta_Query_ReadDataRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Query_ReadDataResponse {
        throw unimplemented("ReadData")
    }

    func readTx(
        request: Utxorpc_V1beta_Query_ReadTxRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Query_ReadTxResponse {
        guard let transactions = chain.transactions else { throw unimplemented("ReadTx") }
        guard let cbor = transactions[request.hash] else {
            throw RPCError(code: .notFound, message: "transaction not found")
        }
        return .with { $0.tx.nativeBytes = cbor; $0.ledgerTip = tip }
    }

    func readGenesis(
        request: Utxorpc_V1beta_Query_ReadGenesisRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Query_ReadGenesisResponse {
        guard chain.servesGenesis else { throw unimplemented("ReadGenesis") }
        return .with {
            $0.genesis = Data(repeating: 0x1A, count: 32)
            $0.caip2 = "cardano:mainnet"
            $0.cardano = chain.genesis
        }
    }

    func readEraSummary(
        request: Utxorpc_V1beta_Query_ReadEraSummaryRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Query_ReadEraSummaryResponse {
        guard let summaries = chain.eraSummaries else { throw unimplemented("ReadEraSummary") }
        return .with { $0.cardano.summaries = summaries }
    }

    func readState(
        request: Utxorpc_V1beta_Query_ReadStateRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Query_ReadStateResponse {
        guard let pools = chain.poolDistribution else { throw unimplemented("ReadState") }
        let wanted = request.query.cardano.stakePoolDistribution.poolKeyhashes
        return .with {
            $0.result.cardano.stakePoolDistribution.pools = wanted.isEmpty
                ? pools : pools.filter { wanted.contains($0.poolKeyhash) }
            $0.ledgerTip = tip
        }
    }
}

struct FakeSubmitService: Utxorpc_V1beta_Submit_SubmitService.SimpleServiceProtocol {
    let chain: FakeUTxORPCChain

    func evalTx(
        request: Utxorpc_V1beta_Submit_EvalTxRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Submit_EvalTxResponse {
        guard chain.servesEvalTx else { throw unimplemented("EvalTx") }
        return .with { $0.report.cardano = chain.evaluation }
    }

    func submitTx(
        request: Utxorpc_V1beta_Submit_SubmitTxRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Submit_SubmitTxResponse {
        if let reason = chain.submitRejection {
            throw RPCError(code: .invalidArgument, message: reason)
        }
        return .with { $0.ref = Data(repeating: 0xC0, count: 32) }
    }

    func waitForTx(
        request: Utxorpc_V1beta_Submit_WaitForTxRequest,
        response: RPCWriter<Utxorpc_V1beta_Submit_WaitForTxResponse>,
        context: ServerContext
    ) async throws {
        throw unimplemented("WaitForTx")
    }

    func readMempool(
        request: Utxorpc_V1beta_Submit_ReadMempoolRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Submit_ReadMempoolResponse {
        throw unimplemented("ReadMempool")
    }

    func watchMempool(
        request: Utxorpc_V1beta_Submit_WatchMempoolRequest,
        response: RPCWriter<Utxorpc_V1beta_Submit_WatchMempoolResponse>,
        context: ServerContext
    ) async throws {
        throw unimplemented("WatchMempool")
    }
}

struct FakeSyncService: Utxorpc_V1beta_Sync_SyncService.SimpleServiceProtocol {
    let chain: FakeUTxORPCChain

    func fetchBlock(
        request: Utxorpc_V1beta_Sync_FetchBlockRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Sync_FetchBlockResponse {
        throw unimplemented("FetchBlock")
    }

    func dumpHistory(
        request: Utxorpc_V1beta_Sync_DumpHistoryRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Sync_DumpHistoryResponse {
        throw unimplemented("DumpHistory")
    }

    func followTip(
        request: Utxorpc_V1beta_Sync_FollowTipRequest,
        response: RPCWriter<Utxorpc_V1beta_Sync_FollowTipResponse>,
        context: ServerContext
    ) async throws {
        throw unimplemented("FollowTip")
    }

    func readTip(
        request: Utxorpc_V1beta_Sync_ReadTipRequest, context: ServerContext
    ) async throws -> Utxorpc_V1beta_Sync_ReadTipResponse {
        .with {
            $0.tip = .with {
                $0.slot = chain.tipSlot
                $0.hash = Data(repeating: 0xAB, count: 32)
                $0.height = chain.tipHeight
                $0.timestamp = chain.tipTimestamp
            }
        }
    }
}

struct FakeNodeService: Cardano_Rpc_Node.SimpleServiceProtocol {
    func getEra(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Cardano_Rpc_CurrentEra {
        .with { $0.era = .conway }
    }

    func getProtocolParamsJson(
        request: Google_Protobuf_Empty, context: ServerContext
    ) async throws -> Cardano_Rpc_ProtocolParamsJson {
        throw unimplemented("GetProtocolParamsJson")
    }
}

/// Runs each call against the fake services over an in-process transport.
struct FakeUTxORPCConnector: UTxORPCConnector {
    let chain: FakeUTxORPCChain

    func withServices<Result: Sendable>(
        _ body: (UTxORPCServices) async throws -> Result
    ) async throws -> Result {
        let tip = Utxorpc_V1beta_Query_ChainPoint.with { $0.slot = chain.tipSlot }
        var services: [any RegistrableRPCService] = [
            FakeQueryService(chain: chain, tip: tip),
            FakeSubmitService(chain: chain),
            FakeSyncService(chain: chain),
        ]
        if chain.nodeService { services.append(FakeNodeService()) }

        let transport = InProcessTransport()
        return try await withGRPCServer(transport: transport.server, services: services) { _ in
            try await withGRPCClient(transport: transport.client) { client in
                try await body(UTxORPCServices(UTxORPCClient(wrapping: client)))
            }
        }
    }
}
