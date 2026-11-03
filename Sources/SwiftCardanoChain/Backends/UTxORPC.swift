import Foundation
import GRPCCore
import SwiftCardanoCore
import SwiftCardanoNetwork
import SwiftProtobuf
import Synchronization
import UTxORPC
import UTxORPCCardanoNode
import UTxORPCClient

/// The UTxO RPC service clients one call runs against, whatever transport
/// carries them.
public struct UTxORPCServices: Sendable {
    public let query: any Utxorpc_V1beta_Query_QueryService.ClientProtocol
    public let submit: any Utxorpc_V1beta_Submit_SubmitService.ClientProtocol
    public let sync: any Utxorpc_V1beta_Sync_SyncService.ClientProtocol
    /// cardano-node's own `cardano.rpc.Node` service; other servers answer
    /// `UNIMPLEMENTED`.
    public let node: any Cardano_Rpc_Node.ClientProtocol

    public init<Transport>(_ client: UTxORPCClient<Transport>) {
        query = client.query
        submit = client.submit
        sync = client.sync
        node = client.node
    }
}

/// Runs a call against a UTxO RPC server.
///
/// ``UTxORPCEndpointConnector`` opens a connection per call. Tests conform
/// their own connector to run over an in-process transport.
public protocol UTxORPCConnector: Sendable {
    func withServices<Result: Sendable>(
        _ body: (UTxORPCServices) async throws -> Result
    ) async throws -> Result
}

/// Runs every call over one long-lived connection, which reconnects on its own
/// and closes when the last context holding it goes away.
public struct UTxORPCConnectionConnector: UTxORPCConnector {
    public let connection: UTxORPCConnection

    public init(connection: UTxORPCConnection) {
        self.connection = connection
    }

    public init(endpoint: UTxORPCEndpoint) throws {
        self.init(connection: try UTxORPCConnection(endpoint: endpoint))
    }

    public func withServices<Result: Sendable>(
        _ body: (UTxORPCServices) async throws -> Result
    ) async throws -> Result {
        try await body(UTxORPCServices(connection.client))
    }
}

/// Connects to an endpoint for each call and closes the connection after it:
/// nothing stays open between calls, at the cost of a new connection (and for
/// TLS, a handshake) every time.
public struct UTxORPCEndpointConnector: UTxORPCConnector {
    public let endpoint: UTxORPCEndpoint

    public init(endpoint: UTxORPCEndpoint) {
        self.endpoint = endpoint
    }

    public func withServices<Result: Sendable>(
        _ body: (UTxORPCServices) async throws -> Result
    ) async throws -> Result {
        try await withUTxORPCClient(endpoint: endpoint) { client in
            try await body(UTxORPCServices(client))
        }
    }
}

/// A chain context backed by a [UTxO RPC](https://utxorpc.org) server: the
/// gRPC interface built into cardano-node 11.x, Dolos, Demeter, or
/// cardano-node-api.
///
/// It answers the tip, protocol and genesis parameters, UTxOs by address or
/// output reference, and submits and evaluates transactions. Servers differ
/// in what else they implement:
///
/// - **cardano-node** serves a live ledger view, so it cannot look up a
///   transaction by hash and its `SearchUtxos` only takes exact addresses.
///   Node 11.1.x has no era summary; the epoch is then worked out from the
///   genesis parameters.
/// - **Dolos** also serves ``transactionCBOR(hash:)``.
/// - **cardano-node-api** speaks only the older v1alpha API: give the endpoint
///   `apiVersion: .v1alpha`. It has no `ReadGenesis`, `EvalTx` or `ReadTx`
///   (transactions are evaluated locally),
///   and its `ReadParams` leaves out the Conway governance parameters, so
///   the protocol and genesis parameters, and with them the epoch and tip,
///   come from the wrapped context.
///
/// Of the stake queries, UTxO RPC v1beta's `ReadState` answers only
/// ``stakePools()``, and it has no governance queries. Those, and anything the
/// server answers `UNIMPLEMENTED`, go to the context it wraps; without one they
/// throw `CardanoChainError.notImplemented`. The wrapped context is optional:
/// on its own the context answers everything the server does.
///
/// ```swift
/// // A local cardano-node started with "EnableRpc": true
/// let node = try UTxORPCChainContext(
///     endpoint: .unixSocket("/opt/cardano/mainnet/socket/rpc.sock"),
///     network: .mainnet
/// )
///
/// // Demeter, with governance from Blockfrost
/// let demeter = try UTxORPCChainContext(
///     endpoint: try UTxORPCEndpoint(
///         url: URL(string: "https://preview.utxorpc-v0.demeter.run")!,
///         headers: ["dmtr-api-key": apiKey]
///     ),
///     network: .preview,
///     wrapping: blockfrost
/// )
/// ```
public struct UTxORPCChainContext: ChainContext {

    // MARK: - Properties

    /// How each call reaches the server.
    public let connector: any UTxORPCConnector

    /// The context that answers what UTxO RPC cannot, if any.
    public let wrapped: (any ChainContext)?

    private let network: SwiftCardanoCore.Network
    private let cache = Cache()

    /// Most UTxOs one `SearchUtxos` page asks for; the node allows up to 10,000.
    static let searchPageSize: Int32 = 1_000

    public var name: String {
        wrapped.map { "UTxO RPC + \($0.name)" } ?? "UTxO RPC"
    }

    public var type: ContextType { .online }

    public var networkId: NetworkId { network.networkId }

    // MARK: - Initializers

    /// A context that reaches the server through `connector`.
    public init(
        connector: any UTxORPCConnector,
        network: SwiftCardanoCore.Network = .mainnet,
        wrapping: (any ChainContext)? = nil
    ) {
        self.connector = connector
        self.network = network
        self.wrapped = wrapping
    }

    /// A context over the server at `endpoint`, keeping one connection open
    /// for all its calls. Pass a ``UTxORPCEndpointConnector`` to
    /// ``init(connector:network:wrapping:)`` to connect per call instead.
    public init(
        endpoint: UTxORPCEndpoint,
        network: SwiftCardanoCore.Network = .mainnet,
        wrapping: (any ChainContext)? = nil
    ) throws {
        self.init(connector: try UTxORPCConnectionConnector(endpoint: endpoint), network: network, wrapping: wrapping)
    }

    // MARK: - Chain state

    /// The current protocol parameters from `ReadParams`.
    ///
    /// A server that leaves out the Conway governance parameters
    /// (cardano-node-api) cannot fill them in, so the wrapped context answers
    /// instead.
    public func protocolParameters() async throws -> ProtocolParameters {
        let response = try await call("ReadParams") {
            try await $0.query.readParams(Utxorpc_V1beta_Query_ReadParamsRequest())
        }
        guard case .cardano(let params)? = response.values.params else {
            throw CardanoChainError.valueError("UTxO RPC ReadParams returned no Cardano parameters")
        }
        guard UTxORPCMapping.hasGovernanceParameters(params) else {
            return try await forward("Conway governance parameters in ReadParams").protocolParameters()
        }
        return try UTxORPCMapping.protocolParameters(params)
    }

    /// The Shelley genesis parameters, read once and kept: they never change.
    ///
    /// From `ReadGenesis`, or from the wrapped context on a server without it
    /// (cardano-node-api).
    public func genesisParameters() async throws -> GenesisParameters {
        if let cached = cache.state.withLock({ $0.genesis }) { return cached }
        let parameters: GenesisParameters
        if let response = try await callIfImplemented("ReadGenesis", {
            try await $0.query.readGenesis(Utxorpc_V1beta_Query_ReadGenesisRequest())
        }) {
            guard case .cardano(let genesis)? = response.config else {
                throw CardanoChainError.valueError("UTxO RPC ReadGenesis returned no Cardano genesis")
            }
            parameters = try UTxORPCMapping.genesisParameters(genesis)
        } else {
            parameters = try await forward("genesisParameters()").genesisParameters()
        }
        cache.state.withLock { $0.genesis = parameters }
        return parameters
    }

    public func epoch() async throws -> Int {
        let slot = try await tip().slot
        return try await epochPosition(slot: slot).epoch.checked("UTxO RPC epoch")
    }

    /// The node's own era when it serves `cardano.rpc.Node`, otherwise the
    /// last era of the era summary, otherwise the era the epoch falls in.
    public func era() async throws -> Era? {
        if let era = try await nodeEra() { return era }
        if let summaries = try await eraSummaries(),
           let last = summaries.last,
           let era = Era(rawValue: last.name.lowercased()) {
            return era
        }
        return Era.fromEpoch(epoch: try await epoch().checked("UTxO RPC epoch"))
    }

    public func lastBlockSlot() async throws -> Int {
        try await tip().slot.checked("UTxO RPC tip slot")
    }

    public func chainTip() async throws -> ChainTip {
        let tip = try await tip()
        let position = try await epochPosition(slot: tip.slot)
        let era = try await era()
        return ChainTip(
            // Dolos leaves the height unset; only the genesis block is height 0.
            block: tip.height > 0 ? tip.height : nil,
            epoch: position.epoch,
            era: era?.rawValue,
            hash: tip.hash.toHex,
            slot: tip.slot,
            slotInEpoch: position.slotInEpoch,
            slotsToEpochEnd: position.epochLength - position.slotInEpoch,
            syncProgress: try await syncProgress(tipMilliseconds: tip.timestamp)
        )
    }

    // MARK: - UTxOs

    /// Every unspent output at `address`, fetched a page at a time.
    public func utxos(address: Address) async throws -> [UTxO] {
        let addressBytes = address.toBytes()
        var utxos: [UTxO] = []
        var token: String?
        repeat {
            let request = Utxorpc_V1beta_Query_SearchUtxosRequest.with {
                $0.predicate.match.cardano.address.exactAddress = addressBytes
                $0.maxItems = Self.searchPageSize
                if let token { $0.startToken = token }
            }
            let response = try await call("SearchUtxos") { try await $0.query.searchUtxos(request) }
            utxos += try response.items.map(UTxORPCMapping.utxo)
            token = response.hasNextToken ? response.nextToken : nil
        } while token != nil
        return utxos
    }

    /// The unspent output `input` names.
    ///
    /// UTxO RPC only reads the live UTxO set, so a spent output is not found.
    /// The wrapped context, if any, is then asked, since an index such as
    /// Kupo can say the output was spent.
    public func utxo(input: TransactionInput) async throws -> (UTxO, isSpent: Bool)? {
        let request = Utxorpc_V1beta_Query_ReadUtxosRequest.with {
            $0.keys = [UTxORPCMapping.txoRef(input)]
        }
        let response = try await call("ReadUtxos") { try await $0.query.readUtxos(request) }
        if let item = response.items.first {
            return (try UTxORPCMapping.utxo(item), false)
        }
        return try await wrapped?.utxo(input: input)
    }

    // MARK: - Transactions

    /// The transaction's CBOR from `ReadTx`, which Dolos serves and
    /// cardano-node does not; then from the wrapped context.
    public func transactionCBOR(hash: TransactionId) async throws -> Data {
        let request = Utxorpc_V1beta_Query_ReadTxRequest.with { $0.hash = hash.payload }
        guard let response = try await callIfImplemented("ReadTx", { try await $0.query.readTx(request) }) else {
            return try await forward("transactionCBOR(hash:)").transactionCBOR(hash: hash)
        }
        guard !response.tx.nativeBytes.isEmpty else {
            throw CardanoChainError.valueError("UTxO RPC ReadTx returned no CBOR for \(hash)")
        }
        return response.tx.nativeBytes
    }

    /// Submits the transaction and returns its id.
    ///
    /// - Throws: ``CardanoChainError/transactionFailed(_:)`` with the server's
    ///   reason when the transaction is rejected.
    public func submitTxCBOR(cbor: Data) async throws -> String {
        let request = Utxorpc_V1beta_Submit_SubmitTxRequest.with { $0.tx.raw = cbor }
        do {
            let response = try await connector.withServices { try await $0.submit.submitTx(request) }
            return response.ref.toHex
        } catch let error as RPCError {
            throw CardanoChainError.transactionFailed("UTxO RPC SubmitTx rejected the transaction (\(error.code)): \(error.message)")
        }
    }

    /// The execution units of each redeemer, keyed `<tag>:<index>`.
    ///
    /// The server evaluates the scripts against its current ledger state.
    /// Evaluation is about the scripts, as with Ogmios: a transaction being
    /// built is not signed or balanced yet, so ledger-rule complaints are
    /// expected. When the server reports only those, with no script error
    /// (Dolos, and so Demeter, refuses an unsigned transaction with
    /// `VKWitnessMissing`), or has no `EvalTx` at all (cardano-node-api), the
    /// scripts are evaluated locally instead, with inputs from `ReadUtxos`.
    /// Local evaluation prices scripts with the server's own cost models, which
    /// on Demeter can lag the network's.
    ///
    /// - Throws: ``CardanoChainError/transactionFailed(_:)`` when a script
    ///   fails, or when the server's ledger-rule errors stand because local
    ///   evaluation can't run either.
    public func evaluateTxCBOR(cbor: Data) async throws -> [String: ExecutionUnits] {
        let request = Utxorpc_V1beta_Submit_EvalTxRequest.with { $0.tx.raw = cbor }
        guard let response = try await callIfImplemented("EvalTx", { try await $0.submit.evalTx(request) }) else {
            return try await evaluateLocally(cbor: cbor)
        }
        guard case .cardano(let report)? = response.report.chain else {
            throw CardanoChainError.valueError("UTxO RPC EvalTx returned no Cardano report")
        }
        if !report.errors.isEmpty, !report.errors.contains(where: UTxORPCMapping.isRedeemerError) {
            do {
                return try await evaluateLocally(cbor: cbor)
            } catch {
                return try UTxORPCMapping.executionUnits(report)
            }
        }
        return try UTxORPCMapping.executionUnits(report)
    }

    /// Evaluates the transaction's scripts with the local CEK machine: its
    /// inputs and reference inputs from the live UTxO set (or the wrapped
    /// context), and this context's protocol parameters and slot timeline.
    func evaluateLocally(cbor: Data) async throws -> [String: ExecutionUnits] {
        let tx: Transaction
        do {
            tx = try Transaction.fromCBOR(data: cbor)
        } catch {
            throw CardanoChainError.invalidArgument("Failed to decode transaction CBOR: \(error)")
        }
        let inputs = tx.transactionBody.inputs.asArray + (tx.transactionBody.referenceInputs?.asList ?? [])
        let request = Utxorpc_V1beta_Query_ReadUtxosRequest.with { $0.keys = inputs.map(UTxORPCMapping.txoRef) }
        let found = try await call("ReadUtxos") { try await $0.query.readUtxos(request) }.items.map(UTxORPCMapping.utxo)

        var resolved: [UTxO] = []
        for input in inputs {
            if let utxo = found.first(where: { $0.input == input }) {
                resolved.append(utxo)
            } else if let (utxo, _) = try await wrapped?.utxo(input: input) {
                resolved.append(utxo)
            } else {
                throw CardanoChainError.valueError("Cannot evaluate transaction: input \(input) not found in the live UTxO set")
            }
        }
        return try await evaluateTx(
            tx: tx,
            resolvedInputs: resolved,
            protocolParameters: try await protocolParameters(),
            slotTimeline: try await slotTimeline()
        )
    }

    // MARK: - Stake pools

    /// The registered stake pools: from the wrapped context when there is one,
    /// otherwise the pools in the ledger's stake pool distribution, from
    /// `ReadState`.
    ///
    /// The distribution lists only pools with delegated stake, so a pool that
    /// is registered but has none is left out. The wrapped context's list is
    /// complete, so it comes first: callers use the list to tell a new pool
    /// from a registered one.
    public func stakePools() async throws -> [PoolOperator] {
        if let wrapped { return try await wrapped.stakePools() }
        let request = Utxorpc_V1beta_Query_ReadStateRequest.with {
            $0.query.cardano.stakePoolDistribution = .init()
        }
        guard let response = try await callIfImplemented("ReadState", { try await $0.query.readState(request) }) else {
            return try await forward("stakePools()").stakePools()
        }
        guard case .cardano(let state)? = response.result.result,
              case .stakePoolDistribution(let distribution)? = state.result
        else {
            throw CardanoChainError.valueError("UTxO RPC ReadState returned no stake pool distribution")
        }
        return distribution.pools.map { PoolOperator(poolKeyHash: PoolKeyHash(payload: $0.poolKeyhash)) }
    }

    // MARK: - Forwarded to the wrapped context

    public func stakeAddressInfo(address: Address) async throws -> [StakeAddressInfo] {
        try await forward("stakeAddressInfo(address:)").stakeAddressInfo(address: address)
    }

    public func kesPeriodInfo(pool: PoolOperator?, opCert: OperationalCertificate?) async throws -> KESPeriodInfo {
        try await forward("kesPeriodInfo(pool:opCert:)").kesPeriodInfo(pool: pool, opCert: opCert)
    }

    public func stakePoolInfo(poolId: String) async throws -> StakePoolInfo {
        try await forward("stakePoolInfo(poolId:)").stakePoolInfo(poolId: poolId)
    }

    public func stakePoolInfo(poolId: String, strict: Bool) async throws -> StakePoolInfo {
        try await forward("stakePoolInfo(poolId:strict:)").stakePoolInfo(poolId: poolId, strict: strict)
    }

    public func treasury() async throws -> Coin {
        try await forward("treasury()").treasury()
    }

    public func drepInfo(drep: DRep) async throws -> DRepInfo {
        try await forward("drepInfo(drep:)").drepInfo(drep: drep)
    }

    public func govActionInfo(govActionID: GovActionID) async throws -> GovActionInfo {
        try await forward("govActionInfo(govActionID:)").govActionInfo(govActionID: govActionID)
    }

    public func committeeMemberInfo(cold: CommitteeColdCredential) async throws -> CommitteeMemberInfo {
        try await forward("committeeMemberInfo(cold:)").committeeMemberInfo(cold: cold)
    }

    public func committeeMemberInfo(hot: CommitteeHotCredential) async throws -> CommitteeMemberInfo {
        try await forward("committeeMemberInfo(hot:)").committeeMemberInfo(hot: hot)
    }

    public func govActionVotes(govActionID: GovActionID) async throws -> GovActionVotes {
        try await forward("govActionVotes(govActionID:)").govActionVotes(govActionID: govActionID)
    }

    public func govActionsAll() async throws -> [GovActionVotes] {
        try await forward("govActionsAll()").govActionsAll()
    }

    public func openGovActions() async throws -> [OpenGovAction] {
        try await forward("openGovActions()").openGovActions()
    }

    public func drepStakeDistribution() async throws -> [SwiftCardanoNetwork.DRepStakeEntry] {
        try await forward("drepStakeDistribution()").drepStakeDistribution()
    }

    public func spoStakeDistribution() async throws -> [SwiftCardanoNetwork.SPOStakeEntry] {
        try await forward("spoStakeDistribution()").spoStakeDistribution()
    }

    public func committeeState() async throws -> CommitteeStateInfo {
        try await forward("committeeState()").committeeState()
    }

    /// The wrapped context, or the error saying there is none to ask.
    private func forward(_ call: String) throws -> any ChainContext {
        guard let wrapped else {
            throw CardanoChainError.notImplemented(
                "UTxO RPC has no \(call); configure a wrapped context such as Blockfrost or Ogmios for it."
            )
        }
        return wrapped
    }

    // MARK: - Calls

    /// Runs `body`, turning a gRPC error into a ``CardanoChainError``:
    /// `UNIMPLEMENTED` becomes ``CardanoChainError/notImplemented(_:)``.
    func call<Result: Sendable>(
        _ method: String, _ body: (UTxORPCServices) async throws -> Result
    ) async throws -> Result {
        guard let result = try await callIfImplemented(method, body) else {
            throw CardanoChainError.notImplemented("The UTxO RPC server does not implement \(method).")
        }
        return result
    }

    /// Runs `body`, or returns `nil` when the server does not implement the method.
    func callIfImplemented<Result: Sendable>(
        _ method: String, _ body: (UTxORPCServices) async throws -> Result
    ) async throws -> Result? {
        do {
            return try await connector.withServices(body)
        } catch let error as RPCError where error.code == .unimplemented {
            return nil
        } catch let error as RPCError {
            throw CardanoChainError.operationError("UTxO RPC \(method) failed (\(error.code)): \(error.message)")
        }
    }

    // MARK: - Tip, eras and epochs

    private func tip() async throws -> Utxorpc_V1beta_Sync_BlockRef {
        let response = try await call("ReadTip") {
            try await $0.sync.readTip(Utxorpc_V1beta_Sync_ReadTipRequest())
        }
        guard response.hasTip else {
            throw CardanoChainError.operationError("UTxO RPC ReadTip returned no tip: the chain is at its origin")
        }
        return response.tip
    }

    /// The era from cardano-node's `GetEra`, or `nil` from any other server.
    private func nodeEra() async throws -> Era? {
        if cache.state.withLock({ $0.nodeServiceMissing }) { return nil }
        guard let response = try await callIfImplemented("GetEra", {
            try await $0.node.getEra(Google_Protobuf_Empty())
        }) else {
            cache.state.withLock { $0.nodeServiceMissing = true }
            return nil
        }
        switch response.era {
        case .byron: return .byron
        case .shelley: return .shelley
        case .allegra: return .allegra
        case .mary: return .mary
        case .alonzo: return .alonzo
        case .babbage: return .babbage
        case .conway: return .conway
        case .UNRECOGNIZED: return nil
        }
    }

    /// The era summary, or `nil` when the server has none (cardano-node 11.1.x).
    private func eraSummaries() async throws -> [Utxorpc_V1beta_Cardano_EraSummary]? {
        if cache.state.withLock({ $0.eraSummaryMissing }) { return nil }
        guard let response = try await callIfImplemented("ReadEraSummary", {
            try await $0.query.readEraSummary(Utxorpc_V1beta_Query_ReadEraSummaryRequest())
        }) else {
            cache.state.withLock { $0.eraSummaryMissing = true }
            return nil
        }
        guard case .cardano(let summaries)? = response.summary else { return nil }
        return summaries.summaries
    }

    /// Where `slot` falls: its epoch, its slot within that epoch, and the
    /// epoch's length.
    ///
    /// From the era summary when the server has one: the epoch counts on from
    /// the start of the era the slot is in. Otherwise from the network's known
    /// Byron→Shelley transition, as ``NodeSocketChainContext`` does.
    func epochPosition(slot: UInt64) async throws -> (epoch: UInt64, slotInEpoch: UInt64, epochLength: UInt64) {
        let genesis = try await genesisParameters()
        guard let shelleyEpochLength = genesis.epochLength, shelleyEpochLength > 0 else {
            throw CardanoChainError.valueError("UTxO RPC genesis has no epoch length")
        }

        if let summaries = try await eraSummaries(),
           let era = summaries.last(where: { $0.start.slot <= slot }) {
            let length = era.name.lowercased() == "byron" ? Self.byronEpochLength : shelleyEpochLength
            let slots = slot - era.start.slot
            return (era.start.epoch + slots / length, slots % length, length)
        }

        let byronEpochs = Self.byronTransitionEpoch(for: network)
        let byronSlots = byronEpochs * Self.byronEpochLength
        if slot < byronSlots {
            return (slot / Self.byronEpochLength, slot % Self.byronEpochLength, Self.byronEpochLength)
        }
        let slots = slot - byronSlots
        return (byronEpochs + slots / shelleyEpochLength, slots % shelleyEpochLength, shelleyEpochLength)
    }

    /// How far the server's tip is behind the wall clock, as a percentage to
    /// two places, or `nil` when the server gives the tip no timestamp.
    private func syncProgress(tipMilliseconds: UInt64) async throws -> String? {
        guard tipMilliseconds > 0, let systemStart = try await genesisParameters().systemStart else { return nil }
        let tipSeconds = Double(tipMilliseconds) / 1000 - systemStart.timeIntervalSince1970
        let wallClockSeconds = Date().timeIntervalSince(systemStart)
        guard wallClockSeconds > 0 else { return "0.00" }
        return String(format: "%.2f", max(0, min(100, tipSeconds / wallClockSeconds * 100)))
    }

    /// Byron→Shelley transition epoch per network.
    static func byronTransitionEpoch(for network: SwiftCardanoCore.Network) -> UInt64 {
        switch network {
        case .mainnet: return 208
        case .preprod: return 4
        default: return 0
        }
    }

    /// Slots in a Byron epoch, the same on every network.
    static let byronEpochLength: UInt64 = 21_600

    // MARK: - Cache

    /// What the context learns once and keeps.
    private final class Cache: Sendable {
        struct State {
            var genesis: GenesisParameters?
            var eraSummaryMissing = false
            var nodeServiceMissing = false
        }

        let state = Mutex(State())
    }
}
