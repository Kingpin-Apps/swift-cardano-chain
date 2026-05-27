import Foundation
import SwiftCardanoCore
import SwiftCardanoNetwork
import SwiftCardanoUtils
import SystemPackage

/// A chain context implementation that talks to a local `cardano-node` over its
/// Unix domain socket using the Node-to-Client (NtC) Ouroboros mini-protocols.
///
/// Backed by the [`swift-cardano-network`](https://github.com/Kingpin-Apps/swift-cardano-network)
/// library. The socket path and network can be supplied directly or pulled from
/// a `CardanoConfig`.
///
/// Each query method opens a fresh connection via `CardanoNode.withClient`, runs
/// the query, and closes the connection automatically — even if the query throws.
/// No explicit `close()` call is needed.
///
/// ## Creating a Context
///
/// ```swift
/// // From a CardanoConfig (the most common case)
/// let context = try NodeSocketChainContext(cardanoConfig: cardanoConfig)
///
/// // Direct: socket path + network preset
/// let context = NodeSocketChainContext(
///     socketPath: FilePath("/ipc/node.socket"),
///     network: .mainnet
/// )
///
/// // Custom CardanoNetworkConfiguration (override timeouts, NtC versions, etc.)
/// var networkConfig = CardanoNetworkConfiguration.preview
/// networkConfig.connection.connectTimeoutSeconds = 30
/// networkConfig.connection.socketPath = "/ipc/node.socket"
/// let context = try NodeSocketChainContext(
///     networkConfig: networkConfig,
///     network: .preview
/// )
/// ```
public actor NodeSocketChainContext: ChainContext {

    // MARK: - Identity

    nonisolated public var name: String { "NodeSocket" }
    nonisolated public var type: ContextType { .online }

    // MARK: - State

    private let _networkConfig: CardanoNetworkConfiguration
    private let _network: Network
    private var _genesisParameters: GenesisParameters?
    private var _genesisParametersFetch: Task<GenesisParameters, Error>?
    private var _protocolParameters: ProtocolParameters?
    private var _protocolParametersEpoch: Int?
    private var _protocolParametersFetch: Task<ProtocolParameters, Error>?
    private var _epoch: Int?
    private var lastEpochFetch: TimeInterval = 0
    private var _epochFetch: Task<Int, Error>?
    private let epochCacheTTL: TimeInterval = 60

    nonisolated public var networkId: NetworkId { _network.networkId }

    // MARK: - Async Properties

    public func era() async throws -> Era? {
        Era.fromEpoch(epoch: EpochNumber(try await epoch()))
    }

    public func epoch() async throws -> Int {
        if let cached = _epoch,
           (Date().timeIntervalSince1970 - lastEpochFetch) <= epochCacheTTL {
            return cached
        }
        if let inFlight = _epochFetch { return try await inFlight.value }

        // Cache writes happen inside the Task body so the result lands in the
        // cache even if the launching caller is cancelled mid-flight.
        let task = Task<Int, Error> {
            do {
                let value = try await self.fetchEpochFromNode()
                self._epoch = value
                self.lastEpochFetch = Date().timeIntervalSince1970
                self._epochFetch = nil
                return value
            } catch {
                self._epochFetch = nil
                throw error
            }
        }
        _epochFetch = task
        return try await task.value
    }

    private func fetchEpochFromNode() async throws -> Int {
        let response = try await withClient { try await $0.queryEpochNo() }
        return Int(response)
    }

    public func lastBlockSlot() async throws -> Int {
        let tip = try await withClient { try await $0.queryLedgerTip() }
        return Self.slot(from: tip)
    }

    public func genesisParameters() async throws -> GenesisParameters {
        if let cached = _genesisParameters { return cached }
        if let inFlight = _genesisParametersFetch { return try await inFlight.value }

        let task = Task<GenesisParameters, Error> {
            do {
                let value = try await self.fetchGenesisFromNode()
                self._genesisParameters = value
                self._genesisParametersFetch = nil
                return value
            } catch {
                self._genesisParametersFetch = nil
                throw error
            }
        }
        _genesisParametersFetch = task
        return try await task.value
    }

    private func fetchGenesisFromNode() async throws -> GenesisParameters {
        let config = try await withClient { try await $0.queryGenesisConfig() }
        guard case .shelley(let shelley) = config else {
            throw CardanoChainError.operationError(
                "Unexpected genesis configuration era; expected Shelley")
        }
        return try Self.convertShelleyGenesis(shelley, network: _network)
    }

    public func protocolParameters() async throws -> ProtocolParameters {
        let currentEpoch = try await epoch()
        if let cached = _protocolParameters,
           _protocolParametersEpoch == currentEpoch {
            return cached
        }
        if let inFlight = _protocolParametersFetch { return try await inFlight.value }

        let task = Task<ProtocolParameters, Error> {
            do {
                let value = try await self.fetchProtocolParametersFromNode()
                self._protocolParameters = value
                self._protocolParametersEpoch = currentEpoch
                self._protocolParametersFetch = nil
                return value
            } catch {
                self._protocolParametersFetch = nil
                throw error
            }
        }
        _protocolParametersFetch = task
        return try await task.value
    }

    private func fetchProtocolParametersFromNode() async throws -> ProtocolParameters {
        try await withClient { try await $0.queryProtocolParameters() }
    }

    // MARK: - Initialization

    /// Direct initializer using an already-built `CardanoNetworkConfiguration`.
    ///
    /// - Parameters:
    ///   - networkConfig: The network configuration (must include `connection.socketPath`).
    ///   - network: The Cardano `Network` this context represents.
    /// - Throws: `CardanoChainError.valueError` if `socketPath` is missing.
    public init(
        networkConfig: CardanoNetworkConfiguration,
        network: Network = .mainnet
    ) throws {
        guard networkConfig.connection.socketPath != nil else {
            throw CardanoChainError.valueError(
                "CardanoNetworkConfiguration.connection.socketPath is required for NodeSocketChainContext"
            )
        }
        self._network = network
        self._networkConfig = networkConfig
    }

    /// Convenience initializer that builds a `CardanoNetworkConfiguration` from a socket
    /// path and a network preset.
    public init(
        socketPath: FilePath,
        network: Network = .mainnet
    ) {
        var config = Self.networkConfigPreset(for: network)
        config.connection.socketPath = socketPath.string
        self._network = network
        self._networkConfig = config
    }

    /// Builds a `NodeSocketChainContext` from a `CardanoConfig`, pulling the socket path
    /// and network off it.
    ///
    /// - Parameters:
    ///   - cardanoConfig: The Cardano configuration; `socket` must be non-nil.
    ///   - networkConfig: Optional base `CardanoNetworkConfiguration` to honor (e.g. with
    ///     custom `connectTimeoutSeconds`, `protocol.ntcVersions`, etc.). The
    ///     `socketPath` from `cardanoConfig` always wins; everything else is preserved.
    /// - Throws: `CardanoChainError.valueError` if `cardanoConfig.socket` is nil.
    public init(
        cardanoConfig: CardanoConfig,
        networkConfig: CardanoNetworkConfiguration? = nil
    ) throws {
        guard let socket = cardanoConfig.socket else {
            throw CardanoChainError.valueError(
                "CardanoConfig.socket is required for NodeSocketChainContext")
        }

        let merged = Self.makeNetworkConfig(
            socketPath: socket.string,
            network: cardanoConfig.network,
            base: networkConfig
        )

        self._network = cardanoConfig.network
        self._networkConfig = merged
    }

    // MARK: - ChainContext: Chain tip

    /// Fetch the current network tip — including block height — via the ChainSync
    /// mini-protocol.
    ///
    /// Local-state-query does not expose the block number, but every ChainSync
    /// `RollForward` / `RollBackward` message carries a `Tip` that does. This method
    /// opens a fresh connection, starts a `follow` stream from `origin`, takes the
    /// `Tip` off the first event, and tears the stream down — so the caller pays the
    /// cost of receiving exactly one (small) Byron block per call.
    ///
    /// - Returns: A `Tip` with the current network `point` (slot + hash) and `blockNo`.
    /// - Throws: `CardanoChainError.operationError` if the chain-sync stream finishes
    ///   without yielding an event.
    public func currentTip() async throws -> Tip {
        try await withClient { try await Self.fetchTip(via: $0) }
    }

    /// Query the current chain tip and enrich it with derived epoch / sync data.
    ///
    /// Combines three NtC queries plus a ChainSync round-trip on a single connection:
    /// - `LocalStateQuery.queryEpochNo` for the current epoch number,
    /// - `LocalStateQuery.queryGenesisConfig` for `systemStart`, `epochLength`, and
    ///   `slotLength`,
    /// - `ChainSync.follow` (one event) for the network `Tip`, which provides the
    ///   block height that LSQ does not expose.
    ///
    /// `slotInEpoch` and `slotsToEpochEnd` are derived from the slot using the
    /// network's Byron→Shelley transition epoch (mainnet=208, preprod=4, others=0).
    /// `syncProgress` is the wall-clock time of the tip slot divided by the wall-clock
    /// time elapsed since `systemStart`, expressed as a percentage with two decimals.
    public func chainTip() async throws -> ChainTip {
        let network = self._network
        let (tip, epochNo, epochLength, slotLength, systemStart) = try await withClient {
            connection in
            // LocalStateQuery uses a single state machine per connection — Acquire→Query→
            // Release — so the LSQ calls must be sequential. Run them first, finish their
            // sessions, then do the ChainSync round-trip last so its cancellation doesn't
            // overlap with anything else on the wire.
            let resolvedEpoch = try await connection.queryEpochNo()
            let genConfig = try await connection.queryGenesisConfig()
            guard case .shelley(let shelley) = genConfig else {
                throw CardanoChainError.operationError(
                    "Unexpected genesis configuration era; expected Shelley")
            }
            let params = try Self.convertShelleyGenesis(shelley, network: network)
            let resolvedTip = try await Self.fetchTip(via: connection)
            return (
                resolvedTip,
                resolvedEpoch,
                params.epochLength,
                params.slotLength,
                params.systemStart
            )
        }

        let currentEpoch = Int(epochNo)
        let era = Era.fromEpoch(epoch: epochNo).rawValue
        let slotInt: Int
        let hashHex: String?
        switch tip.point {
        case .origin:
            slotInt = 0
            hashHex = nil
        case .blockPoint(let slot, let hash):
            slotInt = Int(slot)
            hashHex = hash.map { String(format: "%02x", $0) }.joined()
        }

        let (slotInEpoch, slotsToEpochEnd) = Self.epochSlotPosition(
            absoluteSlot: slotInt,
            network: network,
            shelleyEpochLength: epochLength
        )

        let syncProgress = Self.syncProgressString(
            absoluteSlot: slotInt,
            network: network,
            systemStart: systemStart,
            shelleySlotLengthSeconds: slotLength
        )

        return ChainTip(
            block: BlockNumber(exactly: tip.blockNo),
            epoch: EpochNumber(currentEpoch),
            era: era,
            hash: hashHex,
            slot: SlotNumber(slotInt),
            slotInEpoch: slotInEpoch.map { SlotNumber($0) },
            slotsToEpochEnd: slotsToEpochEnd.map { SlotNumber($0) },
            syncProgress: syncProgress
        )
    }

    // MARK: - ChainContext: UTxOs

    public func utxos(address: Address) async throws -> [UTxO] {
        try await withClient { try await $0.queryUTxO(for: [address]) }
    }

    public func utxo(input: TransactionInput) async throws -> (UTxO, isSpent: Bool)? {
        let results = try await withClient { try await $0.queryUTxO(for: [input]) }
        guard let utxo = results.first else { return nil }
        return (utxo, false)
    }

    // MARK: - ChainContext: Submission and evaluation

    public func submitTxCBOR(cbor: Data) async throws -> String {
        let tx: Transaction
        do {
            tx = try Transaction.fromCBOR(data: cbor)
        } catch {
            throw CardanoChainError.invalidArgument(
                "Failed to decode transaction CBOR: \(error)")
        }

        do {
            let txId = try await withClient { try await $0.submitChecked(tx) }
            return txId.payload.toHex
        } catch {
            throw CardanoChainError.transactionFailed(
                "Failed to submit transaction: \(error)")
        }
    }

    /// Evaluate execution units of a transaction by running every Plutus script
    /// through the local CEK machine (via `swift-cardano-uplc`).
    ///
    /// All inputs are resolved and protocol parameters are fetched in a single
    /// connection scope, then the connection is closed before local evaluation
    /// begins.
    public func evaluateTxCBOR(cbor: Data) async throws -> [String: ExecutionUnits] {
        let tx: Transaction
        do {
            tx = try Transaction.fromCBOR(data: cbor)
        } catch {
            throw CardanoChainError.invalidArgument(
                "Failed to decode transaction CBOR: \(error)")
        }

        let regularInputs = tx.transactionBody.inputs.asArray
        let referenceInputs = tx.transactionBody.referenceInputs?.asList ?? []
        let allInputs = regularInputs + referenceInputs

        // Resolve all inputs and fetch protocol params in one connection.
        let (resolved, pp) = try await withClient { connection in
            var utxos: [UTxO] = []
            for input in allInputs {
                let results = try await connection.queryUTxO(for: [input])
                guard let utxo = results.first else {
                    throw CardanoChainError.valueError(
                        "Cannot evaluate transaction: input \(input) not found in live UTxO set"
                    )
                }
                utxos.append(utxo)
            }
            let pp = try await connection.queryProtocolParameters()
            return (utxos, pp)
        }

        return try await evaluateTx(
            tx: tx,
            resolvedInputs: resolved,
            protocolParameters: pp
        )
    }

    // MARK: - ChainContext: Stake addresses

    public func stakeAddressInfo(address: Address) async throws -> [StakeAddressInfo] {
        guard let stakePart = address.stakingPart else {
            throw CardanoChainError.invalidArgument(
                "Address does not have a staking part")
        }

        let credential: StakeCredential
        switch stakePart {
        case .verificationKeyHash(let hash):
            credential = StakeCredential(credential: .verificationKeyHash(hash))
        case .scriptHash(let hash):
            credential = StakeCredential(credential: .scriptHash(hash))
        case .pointerAddress:
            throw CardanoChainError.invalidArgument(
                "Pointer addresses are not supported for stake info queries")
        }

        let response = try await withClient {
            try await $0.queryFilteredDelegationsAndRewardAccounts([credential])
        }

        let credPayload = stakePart.hash()
        let bech32 = (try? address.toBech32()) ?? address.description

        let rewards = response.rewardAccounts.first { $0.credential.credential.payload == credPayload }
        let delegation = response.delegations.first { $0.credential.credential.payload == credPayload }

        guard let rewards else { return [] }

        return [
            StakeAddressInfo(
                active: true,
                address: bech32,
                rewardAccountBalance: Int64(rewards.lovelace),
                stakeDelegation: delegation?.poolOperator,
                voteDelegation: nil
            )
        ]
    }

    // MARK: - ChainContext: Stake pools

    public func stakePools() async throws -> [PoolOperator] {
        let response = try await withClient { try await $0.queryStakePools() }
        return response.poolOperators
    }

    // MARK: - ChainContext: Treasury

    public func treasury() async throws -> Coin {
        let response = try await withClient { try await $0.queryAccountState() }
        return Coin(response.treasury)
    }

    // MARK: - ChainContext: KES period info

    /// Returns KES period information for a stake pool by querying the consensus
    /// protocol state via the Node-to-Client `DebugChainDepState` query.
    ///
    /// The on-chain operational certificate counter is read from the node's
    /// `ChainDepState.operationalCertCounters` map (keyed by `PoolOperator`).
    /// On-disk values (`onDiskOpCertCount`, `onDiskKESStart`) are extracted from the
    /// supplied `opCert` when provided, mirroring the Ogmios backend behaviour.
    public func kesPeriodInfo(
        pool: PoolOperator?,
        opCert: OperationalCertificate?
    ) async throws -> KESPeriodInfo {
        guard let pool else {
            throw CardanoChainError.invalidArgument("Pool operator must be provided")
        }

        let chainDepState = try await withClient { try await $0.queryProtocolState() }
        let counter = chainDepState.operationalCertCounters[pool]

        let onChainOpCertCount: Int
        let nextChainOpCertCount: Int
        if let counter {
            onChainOpCertCount = Int(counter)
            nextChainOpCertCount = onChainOpCertCount + 1
        } else {
            // Pool has never minted a block; no entry in the counters map.
            onChainOpCertCount = -1
            nextChainOpCertCount = 0
        }

        if let opCert {
            return KESPeriodInfo(
                onChainOpCertCount: onChainOpCertCount,
                onDiskOpCertCount: Int(opCert.sequenceNumber),
                nextChainOpCertCount: nextChainOpCertCount,
                onDiskKESStart: Int(opCert.kesPeriod)
            )
        }

        return KESPeriodInfo(
            onChainOpCertCount: onChainOpCertCount,
            nextChainOpCertCount: nextChainOpCertCount
        )
    }

    public func stakePoolInfo(poolId: String) async throws -> StakePoolInfo {
        let poolOperator: PoolOperator
        do {
            poolOperator = try PoolOperator(from: poolId)
        } catch {
            throw CardanoChainError.invalidArgument("Invalid pool ID '\(poolId)': \(error)")
        }

        return try await withClient { connection in
            let paramsResult = try await connection.queryStakePoolParams(for: [poolOperator])
            guard let entry = paramsResult.entries.first(where: { $0.poolOperator == poolOperator }) else {
                throw CardanoChainError.valueError("Pool not found: \(poolId)")
            }

            var liveStake: UInt? = nil
            var liveSize: Decimal? = nil
            var retiringEpoch: UInt64? = nil

            if let stateEntry = try? await connection.queryPoolState([poolOperator]).entries
                .first(where: { $0.poolOperator == poolOperator })
            {
                retiringEpoch = stateEntry.retiring
            }

            if let distrEntry = try? await connection.queryPoolDistr([poolOperator]).entries
                .first(where: { $0.poolOperator == poolOperator })
            {
                liveStake = distrEntry.absoluteStake.map { UInt($0) }
                if distrEntry.stakeDenominator != 0 {
                    liveSize = Decimal(distrEntry.stakeNumerator) / Decimal(distrEntry.stakeDenominator)
                }
            }

            let status: PoolStatus = retiringEpoch.map { .retiring(epoch: UInt($0)) } ?? .registered

            return StakePoolInfo(
                poolParams: entry.params,
                liveStake: liveStake,
                liveSize: liveSize,
                status: status
            )
        }
    }

    public func drepInfo(drep: DRep) async throws -> DRepInfo {
        let state = try await withClient { try await $0.queryDRepState([drep]) }

        guard let entry = state.entries.first(where: {
            (try? $0.drep.toPrimitive()) == (try? drep.toPrimitive())
        }) else {
            return DRepInfo(
                active: false,
                drep: drep,
                anchor: nil,
                deposit: nil,
                stake: Coin(0),
                expiry: nil,
                status: .notRegistered
            )
        }

        var anchor: Anchor? = nil
        if let la = entry.anchor, let url = try? Url(la.url) {
            anchor = Anchor(
                anchorUrl: url,
                anchorDataHash: AnchorDataHash(payload: la.dataHash)
            )
        }

        return DRepInfo(
            active: true,
            drep: drep,
            anchor: anchor,
            deposit: Coin(entry.deposit),
            stake: Coin(0),
            expiry: entry.expiry,
            status: .registered
        )
    }

    public func govActionInfo(govActionID: GovActionID) async throws -> GovActionInfo {
        let proposals = try await withClient { try await $0.queryProposals([govActionID]) }

        guard let proposal = proposals.proposals.first(where: {
            $0.govActionId.transactionID == govActionID.transactionID
                && $0.govActionId.govActionIndex == govActionID.govActionIndex
        }) else {
            throw CardanoChainError.valueError("Governance action not found: \(govActionID)")
        }

        return GovActionInfo(
            govActionId: govActionID,
            govAction: proposal.proposalProcedure.govAction,
            proposedIn: proposal.proposedIn,
            expiresAfter: proposal.expiresAfter
        )
    }

    public func committeeMemberInfo(
        committeeMember: CommitteeColdCredential
    ) async throws -> CommitteeMemberInfo {
        let filter = CommitteeMembersFilter(coldCredentials: [committeeMember])
        let state = try await withClient { try await $0.queryCommitteeMembersState(filter) }

        guard let entry = state.members.first(where: {
            (try? $0.coldCredential.toPrimitive()) == (try? committeeMember.toPrimitive())
        }) else {
            throw CardanoChainError.valueError(
                "Committee member not found for credential: \(committeeMember)")
        }

        let hotCredential: CommitteeHotCredential?
        switch entry.state.hotCredentialStatus {
        case .authorised(let cred), .resigned(let cred):
            hotCredential = cred
        case .notAuthorised:
            hotCredential = nil
        }

        let status: CommitteeMemberStatus
        switch entry.state.memberStatus {
        case .active:        status = .active
        case .expired:       status = .expired
        case .unrecognised:  status = .unrecognized
        }

        return CommitteeMemberInfo(
            coldCredential: committeeMember,
            hotCredential: hotCredential,
            expiration: entry.state.termExpiry.map { EpochNumber($0) },
            status: status
        )
    }

    // MARK: - Internal helpers (exposed for testing via @testable import)

    /// Build a `CardanoNetworkConfiguration` for the given socket and network,
    /// honoring an optional caller-supplied base configuration. The `socketPath`
    /// always wins; any other tunables on `base` are preserved.
    static func makeNetworkConfig(
        socketPath: String,
        network: Network,
        base: CardanoNetworkConfiguration?
    ) -> CardanoNetworkConfiguration {
        var config = base ?? networkConfigPreset(for: network)
        config.connection.socketPath = socketPath
        return config
    }

    /// Pick the matching `CardanoNetworkConfiguration` preset for a `Network`.
    static func networkConfigPreset(for network: Network) -> CardanoNetworkConfiguration {
        switch network {
        case .mainnet: return .mainnet
        case .preview: return .preview
        case .preprod: return .preprod
        default: return CardanoNetworkConfiguration()
        }
    }

    /// Convert a `ShelleyGenesis` returned by the node into `GenesisParameters`.
    static func convertShelleyGenesis(
        _ genesis: ShelleyGenesis,
        network: Network
    ) throws -> GenesisParameters {
        let formatter = ISO8601DateFormatter()
        let systemStartDate = formatter.date(from: genesis.systemStart) ?? Date()

        return GenesisParameters(
            activeSlotsCoefficient: genesis.activeSlotsCoeff,
            epochLength: Int(genesis.epochLength),
            maxKesEvolutions: Int(genesis.maxKESEvolutions),
            maxLovelaceSupply: Int(genesis.maxLovelaceSupply),
            networkId: genesis.networkId,
            networkMagic: Int(genesis.networkMagic),
            securityParam: Int(genesis.securityParam),
            slotLength: Int(genesis.slotLength),
            slotsPerKesPeriod: Int(genesis.slotsPerKESPeriod),
            systemStart: systemStartDate,
            updateQuorum: genesis.updateQuorum
        )
    }

    /// Extract a slot number from a chain `Point`. Returns `0` for `.origin`.
    static func slot(from point: Point) -> Int {
        switch point {
        case .origin:
            return 0
        case .blockPoint(let slot, _):
            return Int(slot)
        }
    }

    /// Take the first ChainSync event off `connection.follow(from: [])` and return
    /// the `Tip` it carries. The stream is cancelled on return so we receive exactly
    /// one Byron block per call.
    static func fetchTip(via connection: NodeToClientConnection) async throws -> Tip {
        for try await event in connection.follow(from: []) {
            switch event {
            case .rollForward(_, let tip):
                return tip
            case .rollBackward(_, let tip):
                return tip
            }
        }
        throw CardanoChainError.operationError(
            "ChainSync stream ended without yielding a tip")
    }

    /// Byron→Shelley transition epoch per network. After this many Byron-era epochs
    /// the chain switched to Shelley slot timings.
    static func byronTransitionEpoch(for network: Network) -> Int {
        switch network {
        case .mainnet: return 208
        case .preprod: return 4
        default:       return 0
        }
    }

    /// Byron-era constants (fixed across all networks).
    static let byronEpochLength: Int = 21600
    static let byronSlotLengthSeconds: Int = 20

    /// Compute (slotInEpoch, slotsToEpochEnd) for an absolute slot, accounting for
    /// the Byron→Shelley transition. Returns `(nil, nil)` when `shelleyEpochLength`
    /// is missing or non-positive.
    static func epochSlotPosition(
        absoluteSlot: Int,
        network: Network,
        shelleyEpochLength: Int?
    ) -> (Int?, Int?) {
        let byronTotalSlots = byronTransitionEpoch(for: network) * byronEpochLength
        if absoluteSlot < byronTotalSlots {
            let inEpoch = absoluteSlot % byronEpochLength
            return (inEpoch, byronEpochLength - inEpoch)
        }
        guard let epochLength = shelleyEpochLength, epochLength > 0 else {
            return (nil, nil)
        }
        let slotsSinceShelley = absoluteSlot - byronTotalSlots
        let inEpoch = slotsSinceShelley % epochLength
        return (inEpoch, epochLength - inEpoch)
    }

    /// Format `syncProgress` as a percentage string (e.g. `"99.87"`) by dividing the
    /// wall-clock time of the tip slot by the wall-clock time elapsed since
    /// `systemStart`. Returns `nil` if any required genesis field is missing.
    static func syncProgressString(
        absoluteSlot: Int,
        network: Network,
        systemStart: Date?,
        shelleySlotLengthSeconds: Int?
    ) -> String? {
        guard let systemStart,
              let shelleySlotLengthSeconds,
              shelleySlotLengthSeconds > 0
        else { return nil }

        let byronTotalSlots = byronTransitionEpoch(for: network) * byronEpochLength
        let tipSecondsSinceStart: Double
        if absoluteSlot < byronTotalSlots {
            tipSecondsSinceStart = Double(absoluteSlot * byronSlotLengthSeconds)
        } else {
            let byronSeconds = Double(byronTotalSlots * byronSlotLengthSeconds)
            let shelleySeconds = Double((absoluteSlot - byronTotalSlots) * shelleySlotLengthSeconds)
            tipSecondsSinceStart = byronSeconds + shelleySeconds
        }

        let wallClockSeconds = Date().timeIntervalSince(systemStart)
        guard wallClockSeconds > 0 else { return "0.00" }
        let pct = max(0.0, min(100.0, (tipSecondsSinceStart / wallClockSeconds) * 100.0))
        return String(format: "%.2f", pct)
    }

    // MARK: - Private: scoped connection helper

    @discardableResult
    private func withClient<Result: Sendable>(
        _ body: @Sendable (NodeToClientConnection) async throws -> Result
    ) async throws -> Result {
        try await CardanoNode.withClient(config: _networkConfig, body: body)
    }
}
