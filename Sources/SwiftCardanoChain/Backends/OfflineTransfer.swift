import Foundation
import SwiftCardanoCore
import SwiftCardanoNetwork
import SystemPackage

/// An offline chain context backed by a JSON transfer file.
///
/// ## Workflow
/// 1. **Online machine**: Build an `OfflineTransfer` model populated with UTxOs,
///    protocol/genesis parameters, evaluations, and any other chain data needed.
///    Save it to disk with `offlineTransfer.save(to:)`.
/// 2. **Transfer**: Copy the JSON file to a cold offline machine (e.g. via USB).
/// 3. **Offline machine**: Initialise `OfflineTransferChainContext(fileURL:)` and use
///    it to build and sign transactions without any network access.
/// 4. **Return**: The signed transaction CBOR is written back into the same JSON file
///    (via `submitTxCBOR`). Transfer the file back and submit the tx online.
public actor OfflineTransferChainContext: ChainContext {

    // MARK: - ChainContext Identity

    nonisolated public var name: String { "OfflineTransfer" }
    nonisolated public var type: ContextType { .offline }

    // MARK: - Private State

    private let filePath: FilePath
    private var offlineTransfer: OfflineTransfer
    private let resolvedNetwork: Network

    // MARK: - networkId

    nonisolated public let networkId: NetworkId

    // MARK: - Async Properties

    public func protocolParameters() async throws -> ProtocolParameters {
        guard let params = offlineTransfer.protocol.protocolParameters else {
            throw CardanoChainError.offlineTransferError(
                "Protocol parameters not found in offline transfer file."
            )
        }
        return params
    }

    public func genesisParameters() async throws -> GenesisParameters {
        guard let params = offlineTransfer.protocol.genesisParameters else {
            throw CardanoChainError.offlineTransferError(
                "Genesis parameters not found in offline transfer file."
            )
        }
        return params
    }

    public func era() async throws -> Era? {
        offlineTransfer.protocol.era
    }

    public func epoch() async throws -> Int {
        try await chainPosition().epoch
    }

    public func lastBlockSlot() async throws -> Int {
        try await chainPosition().slot
    }

    /// The current epoch and slot, worked out from the genesis parameters and
    /// the clock — an offline transfer has no node to ask.
    private func chainPosition() async throws -> (epoch: Int, slot: Int) {
        let genesis = try await genesisParameters()
        guard let systemStart = genesis.systemStart,
              let epochLength = genesis.epochLength,
              let slotLength = genesis.slotLength else {
            throw CardanoChainError.offlineTransferError(
                "Genesis parameters missing systemStart, epochLength, or slotLength."
            )
        }
        return try Self.chainPosition(
            at: Date(),
            network: offlineTransfer.protocol.network ?? resolvedNetwork,
            systemStart: systemStart,
            epochLength: epochLength,
            slotLength: slotLength
        )
    }

    /// The epoch and slot at `date`.
    ///
    /// Mainnet and pre-production began with a Byron era of 21,600 twenty-second
    /// slots per epoch, so their slots are read from core's checked
    /// ``SlotTimeline``; any other network is taken to have had uniform slots
    /// of `slotLength` seconds from `systemStart`.
    static func chainPosition(
        at date: Date,
        network: Network,
        systemStart: Date,
        epochLength: UInt64,
        slotLength: Decimal
    ) throws -> (epoch: Int, slot: Int) {
        let timeline: SlotTimeline
        let byronEpochs: UInt64
        switch network {
        case .mainnet:
            (timeline, byronEpochs) = (.mainnet, 208)
        case .preprod:
            (timeline, byronEpochs) = (.preprod, 4)
        case .preview:
            (timeline, byronEpochs) = (.preview, 0)
        default:
            let milliseconds = slotLength * 1000
            let slotMilliseconds = NSDecimalNumber(decimal: milliseconds).int64Value
            guard slotMilliseconds > 0, Decimal(slotMilliseconds) == milliseconds else {
                throw CardanoChainError.offlineTransferError(
                    "Genesis slot length \(slotLength)s is not a whole number of milliseconds."
                )
            }
            timeline = SlotTimeline(systemStart: systemStart, slotLengthMilliseconds: slotMilliseconds)
            byronEpochs = 0
        }
        guard epochLength > 0 else {
            throw CardanoChainError.offlineTransferError("Genesis epoch length is zero.")
        }

        let slot = timeline.slot(atMilliseconds: Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))
        let byronEpochLength: UInt64 = 21600
        let byronSlots = byronEpochs * byronEpochLength
        let epoch = slot < byronSlots
            ? slot / byronEpochLength
            : byronEpochs + (slot - byronSlots) / epochLength
        guard let epoch = Int(exactly: epoch), let slot = Int(exactly: slot) else {
            throw CardanoChainError.offlineTransferError("Slot \(slot) is out of range.")
        }
        return (epoch, slot)
    }

    // MARK: - Initialiser

    /// Create an `OfflineTransferChainContext` by loading a transfer file from disk.
    ///
    /// - Parameters:
    ///   - filePath: Path to the offline transfer JSON file.
    ///   - network: Fallback network used when the file does not specify one.
    public init(filePath: FilePath, network: Network = .mainnet) throws {
        let loaded = try OfflineTransfer.load(from: filePath)
        let resolved = loaded.protocol.network ?? network
        self.filePath = filePath
        self.resolvedNetwork = resolved
        self.networkId = resolved.networkId
        self.offlineTransfer = loaded
    }

    // MARK: - Chain Tip

    /// Approximate the chain tip from the cached genesis parameters and wall-clock time.
    ///
    /// An offline context cannot observe the live tip, so this returns a derived view:
    /// `slot` and `epoch` are computed from genesis + the current time, and `era` is
    /// taken from the saved protocol metadata. `block`, `hash`, `slotInEpoch`,
    /// `slotsToEpochEnd`, and `syncProgress` are not derivable here and returned as `nil`.
    ///
    /// - Throws: `CardanoChainError.offlineTransferError` if genesis parameters are missing
    ///   the fields required for the calculation.
    public func chainTip() async throws -> ChainTip {
        let currentEpoch = try await self.epoch()
        let currentSlot = try await self.lastBlockSlot()

        return ChainTip(
            block: nil,
            epoch: EpochNumber(currentEpoch),
            era: offlineTransfer.protocol.era?.rawValue,
            hash: nil,
            slot: SlotNumber(currentSlot),
            slotInEpoch: nil,
            slotsToEpochEnd: nil,
            syncProgress: nil
        )
    }

    // MARK: - UTxO Queries

    public func utxos(address: Address) async throws -> [UTxO] {
        let addressString = (try? address.toBech32()) ?? address.description
        return offlineTransfer.addresses
            .first(where: { info in
                guard let infoAddress = info.address else { return false }
                let infoString = (try? infoAddress.toBech32()) ?? infoAddress.description
                return infoString == addressString
            })?
            .utxos ?? []
    }

    public func utxo(input: TransactionInput) async throws -> (UTxO, isSpent: Bool)? {
        for addressInfo in offlineTransfer.addresses {
            if let match = addressInfo.utxos.first(where: { $0.input == input }) {
                return (match, isSpent: false)
            }
        }
        return nil
    }

    // MARK: - Transaction Submission (writes to file)

    /// Saves the signed transaction CBOR into the offline transfer file.
    ///
    /// The transaction is not submitted to the network. Transfer the updated file
    /// back to an online machine and submit from there.
    ///
    /// - Returns: The transaction hash as a hex string.
    public func submitTxCBOR(cbor: Data) async throws -> String {
        let cborHex = cbor.toHex
        let tx = try Transaction.fromCBOR(data: cbor)
        let txHash = tx.id?.payload.toHex ?? cborHex

        let txJSON = OfflineTransferTransactionJSON(
            type: "Tx BabbageEra",
            description: "Signed Transaction",
            cborHex: cborHex
        )
        let txEntry = OfflineTransferTransaction(txJson: txJSON)
        let historyEntry = OfflineTransferHistory(
            action: .saveTransaction(txId: txHash)
        )

        offlineTransfer.transactions.append(txEntry)
        offlineTransfer.history.append(historyEntry)
        try offlineTransfer.save(to: filePath)

        return txHash
    }

    // MARK: - Evaluate (from stored evaluations)

    public func evaluateTxCBOR(cbor: Data) async throws -> [String: ExecutionUnits] {
        let cborHex = cbor.toHex
        guard let evaluation = offlineTransfer.evaluations.first(where: { $0.txCborHex == cborHex }) else {
            throw CardanoChainError.offlineTransferError(
                "No stored evaluation found for the provided transaction CBOR. " +
                "Populate OfflineTransfer.evaluations on the online machine before transferring."
            )
        }
        return evaluation.executionUnits
    }

    // MARK: - Stake Address Info

    public func stakeAddressInfo(address: Address) async throws -> [StakeAddressInfo] {
        let addressString = (try? address.toBech32()) ?? address.description
        for addressInfo in offlineTransfer.addresses {
            let match = addressInfo.stakeAddressInfo.filter { info in
                info.address == addressString
            }
            if !match.isEmpty { return match }
        }
        return []
    }

    // MARK: - Stake Pools

    public func stakePools() async throws -> [PoolOperator] {
        return offlineTransfer.stakePools
    }

    public func stakePoolInfo(poolId: String) async throws -> StakePoolInfo {
        guard let info = offlineTransfer.stakePoolInfos.first(where: { poolInfo in
            let op = PoolOperator(poolKeyHash: poolInfo.poolParams.poolOperator)
            return (try? op.id(.bech32)) == poolId
        }) else {
            throw CardanoChainError.offlineTransferError(
                "Pool info for '\(poolId)' not found in offline transfer file."
            )
        }
        return info
    }

    public func kesPeriodInfo(pool: PoolOperator?, opCert: OperationalCertificate?) async throws -> KESPeriodInfo {
        guard let info = offlineTransfer.kesPeriodInfos.first else {
            throw CardanoChainError.offlineTransferError(
                "No KES period info found in offline transfer file."
            )
        }
        return info
    }

    // MARK: - Treasury

    public func treasury() async throws -> Coin {
        guard let amount = offlineTransfer.treasury else {
            throw CardanoChainError.offlineTransferError(
                "Treasury balance not found in offline transfer file."
            )
        }
        return amount
    }

    // MARK: - Governance

    public func drepInfo(drep: DRep) async throws -> DRepInfo {
        guard let info = offlineTransfer.drepInfos.first(where: { $0.drep == drep }) else {
            throw CardanoChainError.offlineTransferError(
                "DRep info not found in offline transfer file."
            )
        }
        return info
    }

    public func govActionInfo(govActionID: GovActionID) async throws -> GovActionInfo {
        guard let info = offlineTransfer.govActionInfos.first(where: { $0.govActionId == govActionID }) else {
            throw CardanoChainError.offlineTransferError(
                "Governance action info for '\(govActionID)' not found in offline transfer file."
            )
        }
        return info
    }

    public func committeeMemberInfo(cold: CommitteeColdCredential) async throws -> CommitteeMemberInfo {
        guard let info = offlineTransfer.committeeMemberInfos.first(where: { $0.coldCredential == cold }) else {
            throw CardanoChainError.offlineTransferError(
                "Committee member info not found in offline transfer file."
            )
        }
        return info
    }

    public func committeeMemberInfo(hot: CommitteeHotCredential) async throws -> CommitteeMemberInfo {
        guard let info = offlineTransfer.committeeMemberInfos.first(where: { $0.hotCredential == hot }) else {
            throw CardanoChainError.offlineTransferError(
                "Committee member info not found in offline transfer file for hot credential."
            )
        }
        return info
    }

    // MARK: - Votes / Governance State

    public func govActionVotes(govActionID: GovActionID) async throws -> GovActionVotes {
        guard let votes = offlineTransfer.govActionVotesList.first(where: { $0.govActionId == govActionID }) else {
            throw CardanoChainError.offlineTransferError(
                "Gov-action votes for '\(govActionID)' not found in offline transfer file."
            )
        }
        return votes
    }

    public func govActionsAll() async throws -> [GovActionVotes] {
        return offlineTransfer.govActionVotesList
    }

    public func drepStakeDistribution() async throws -> [SwiftCardanoNetwork.DRepStakeEntry] {
        return offlineTransfer.drepStakeEntries
    }

    public func spoStakeDistribution() async throws -> [SwiftCardanoNetwork.SPOStakeEntry] {
        return offlineTransfer.spoStakeEntries
    }

    public func committeeState() async throws -> CommitteeStateInfo {
        guard let state = offlineTransfer.committeeStateSnapshot else {
            throw CardanoChainError.offlineTransferError(
                "Committee state snapshot not found in offline transfer file."
            )
        }
        return state
    }
}
