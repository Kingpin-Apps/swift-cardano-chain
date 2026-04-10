import Foundation
import SwiftCardanoCore
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
public class OfflineTransferChainContext: ChainContext {

    // MARK: - ChainContext Identity

    public var name: String { "OfflineTransfer" }
    public var type: ContextType { .offline }

    // MARK: - Private State

    private let filePath: FilePath
    private var offlineTransfer: OfflineTransfer
    private let _network: Network
    private var _protocolParameters: ProtocolParameters?
    private var _genesisParameters: GenesisParameters?

    // MARK: - networkId

    public var networkId: NetworkId {
        (offlineTransfer.protocol.network ?? _network).networkId
    }

    // MARK: - Lazy Async Properties

    public lazy var protocolParameters: () async throws -> ProtocolParameters = { [weak self] in
        guard let self else {
            throw CardanoChainError.offlineTransferError("Self is nil")
        }
        if self._protocolParameters == nil {
            guard let params = self.offlineTransfer.protocol.protocolParameters else {
                throw CardanoChainError.offlineTransferError(
                    "Protocol parameters not found in offline transfer file."
                )
            }
            self._protocolParameters = params
        }
        return self._protocolParameters!
    }

    public lazy var genesisParameters: () async throws -> GenesisParameters = { [weak self] in
        guard let self else {
            throw CardanoChainError.offlineTransferError("Self is nil")
        }
        if self._genesisParameters == nil {
            guard let params = self.offlineTransfer.protocol.genesisParameters else {
                throw CardanoChainError.offlineTransferError(
                    "Genesis parameters not found in offline transfer file."
                )
            }
            self._genesisParameters = params
        }
        return self._genesisParameters!
    }

    public lazy var era: () async throws -> Era? = { [weak self] in
        guard let self else {
            throw CardanoChainError.offlineTransferError("Self is nil")
        }
        return self.offlineTransfer.protocol.era
    }

    public lazy var epoch: () async throws -> Int = { [weak self] in
        guard let self else {
            throw CardanoChainError.offlineTransferError("Self is nil")
        }
        let genesis = try await self.genesisParameters()
        guard let systemStart = genesis.systemStart,
              let epochLength = genesis.epochLength,
              let slotLength = genesis.slotLength else {
            throw CardanoChainError.offlineTransferError(
                "Genesis parameters missing systemStart, epochLength, or slotLength."
            )
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(systemStart)
        let slotDurationSeconds = Double(slotLength)
        let epochDurationSeconds = Double(epochLength) * slotDurationSeconds
        guard epochDurationSeconds > 0 else {
            throw CardanoChainError.offlineTransferError("Epoch duration is zero.")
        }
        return Int(elapsed / epochDurationSeconds)
    }

    public lazy var lastBlockSlot: () async throws -> Int = { [weak self] in
        guard let self else {
            throw CardanoChainError.offlineTransferError("Self is nil")
        }
        let genesis = try await self.genesisParameters()
        let currentEpoch = try await self.epoch()

        guard let systemStart = genesis.systemStart,
              let epochLength = genesis.epochLength,
              let slotLength = genesis.slotLength else {
            throw CardanoChainError.offlineTransferError(
                "Genesis parameters missing systemStart, epochLength, or slotLength."
            )
        }

        // Byron→Shelley hard fork transition epoch per network.
        // mainnet=208, preprod=4, preview=0, everything else=0.
        let network = self.offlineTransfer.protocol.network ?? self._network
        let byronTransitionEpoch: Int
        switch network {
        case .mainnet:
            byronTransitionEpoch = 208
        case .preprod:
            byronTransitionEpoch = 4
        default:
            byronTransitionEpoch = 0
        }

        // Byron era: 21600 slots per epoch, 20-second slot interval.
        let byronEpochLength = 21600
        let byronSlotLengthSeconds = 20
        let byronSlots = byronTransitionEpoch * byronEpochLength * byronSlotLengthSeconds

        // Shelley+ era: slots from genesis parameters.
        let slotDurationSeconds = Double(slotLength)
        let shelleyEpochs = max(0, currentEpoch - byronTransitionEpoch)
        let shelleySlots = shelleyEpochs * epochLength

        // Slots elapsed in the current epoch.
        let now = Date()
        let elapsed = now.timeIntervalSince(systemStart)
        let epochDurationSeconds = Double(epochLength) * slotDurationSeconds
        let currentEpochElapsedSeconds = elapsed.truncatingRemainder(dividingBy: epochDurationSeconds)
        let slotsInCurrentEpoch = Int(currentEpochElapsedSeconds / slotDurationSeconds)

        return byronSlots + shelleySlots + slotsInCurrentEpoch
    }

    // MARK: - Initialiser

    /// Create an `OfflineTransferChainContext` by loading a transfer file from disk.
    ///
    /// - Parameters:
    ///   - filePath: Path to the offline transfer JSON file.
    ///   - network: Fallback network used when the file does not specify one.
    public init(filePath: FilePath, network: Network = .mainnet) throws {
        self.filePath = filePath
        self._network = network
        self.offlineTransfer = try OfflineTransfer.load(from: filePath)
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

    public func committeeMemberInfo(committeeMember: CommitteeColdCredential) async throws -> CommitteeMemberInfo {
        guard let info = offlineTransfer.committeeMemberInfos.first(where: { $0.coldCredential == committeeMember }) else {
            throw CardanoChainError.offlineTransferError(
                "Committee member info not found in offline transfer file."
            )
        }
        return info
    }
}
