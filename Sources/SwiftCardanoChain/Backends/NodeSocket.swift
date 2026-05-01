import Foundation
import SwiftCardanoCore
import SwiftCardanoNetwork
import SwiftCardanoUPLC
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
public final class NodeSocketChainContext: ChainContext, @unchecked Sendable {

    // MARK: - Identity

    public var name: String { "NodeSocket" }
    public var type: ContextType { .online }

    // MARK: - State

    private let _networkConfig: CardanoNetworkConfiguration
    private let _network: Network
    private var _genesisParameters: GenesisParameters?
    private var _protocolParameters: ProtocolParameters?
    private var _epoch: Int?
    private var lastEpochFetch: TimeInterval = 0
    private let epochCacheTTL: TimeInterval = 60

    public var networkId: NetworkId { _network.networkId }

    // MARK: - Lazy Async Properties

    public lazy var era: () async throws -> Era? = { [weak self] in
        guard let self else {
            throw CardanoChainError.operationError("Self is nil")
        }
        return Era.fromEpoch(epoch: EpochNumber(try await self.epoch()))
    }

    public lazy var epoch: () async throws -> Int = { [weak self] in
        guard let self else {
            throw CardanoChainError.operationError("Self is nil")
        }
        if self._epoch == nil
            || (Date().timeIntervalSince1970 - self.lastEpochFetch) > self.epochCacheTTL
        {
            let response = try await self.withClient { try await $0.queryEpochNo() }
            self._epoch = Int(response)
            self.lastEpochFetch = Date().timeIntervalSince1970
        }
        return self._epoch ?? 0
    }

    public lazy var lastBlockSlot: () async throws -> Int = { [weak self] in
        guard let self else {
            throw CardanoChainError.operationError("Self is nil")
        }
        let tip = try await self.withClient { try await $0.queryLedgerTip() }
        return Self.slot(from: tip)
    }

    public lazy var genesisParameters: () async throws -> GenesisParameters = { [weak self] in
        guard let self else {
            throw CardanoChainError.operationError("Self is nil")
        }
        if self._genesisParameters == nil {
            let config = try await self.withClient { try await $0.queryGenesisConfig() }
            guard case .shelley(let shelley) = config else {
                throw CardanoChainError.operationError(
                    "Unexpected genesis configuration era; expected Shelley")
            }
            self._genesisParameters = try Self.convertShelleyGenesis(
                shelley, network: self._network
            )
        }
        return self._genesisParameters!
    }

    public lazy var protocolParameters: () async throws -> ProtocolParameters = { [weak self] in
        guard let self else {
            throw CardanoChainError.operationError("Self is nil")
        }
        let currentEpoch = try await self.epoch()
        if self._protocolParameters == nil || self._epoch != currentEpoch {
            self._protocolParameters = try await self.withClient {
                try await $0.queryProtocolParameters()
            }
        }
        return self._protocolParameters!
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

        let phaseTwo = try PhaseTwo(protocolParameters: pp)
        let result = try await phaseTwo.evaluate(transaction: tx, resolvedInputs: resolved)

        let redeemers: [Redeemer] = Self.extractRedeemers(from: tx)

        var out: [String: ExecutionUnits] = [:]
        for r in result.redeemers {
            guard r.passed, r.index < redeemers.count else { continue }
            let original = redeemers[r.index]
            let tag = original.tag.map { "\($0)" } ?? "unknown"
            let key = "\(tag):\(original.index)"
            let consumedMem = Int(ExBudget.restricted.mem - r.remainingBudget.mem)
            let consumedSteps = Int(ExBudget.restricted.cpu - r.remainingBudget.cpu)
            out[key] = ExecutionUnits(
                mem: max(0, consumedMem),
                steps: max(0, consumedSteps)
            )
        }
        return out
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
                rewardAccountBalance: Int(rewards.lovelace),
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

    private static func extractRedeemers(from tx: Transaction) -> [Redeemer] {
        guard let rs = tx.transactionWitnessSet.redeemers else { return [] }
        switch rs {
        case .list(let list):
            return list.compactMap { $0 as? Redeemer }
        case .map(let map):
            return map.dictionary.values.compactMap { v in
                Redeemer(tag: nil, index: 0, data: v.data, exUnits: v.exUnits)
            }
        }
    }

    // MARK: - Private: scoped connection helper

    @discardableResult
    private func withClient<Result: Sendable>(
        _ body: @Sendable (NodeToClientConnection) async throws -> Result
    ) async throws -> Result {
        try await CardanoNode.withClient(config: _networkConfig, body: body)
    }
}
