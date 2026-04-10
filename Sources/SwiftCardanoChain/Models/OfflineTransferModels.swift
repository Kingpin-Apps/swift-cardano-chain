import Foundation
import SwiftCardanoCore
import SystemPackage

// MARK: - OfflineTransferGeneral

/// Version metadata for the offline transfer file.
public struct OfflineTransferGeneral: Codable, Sendable {
    public var offlineVersion: String?
    public var onlineVersion: String?

    public init(
        offlineVersion: String? = nil,
        onlineVersion: String? = nil
    ) {
        self.offlineVersion = offlineVersion
        self.onlineVersion = onlineVersion
    }

    enum CodingKeys: String, CodingKey {
        case offlineVersion = "offline_version"
        case onlineVersion = "online_version"
    }
}

// MARK: - OfflineTransferProtocolData

/// Protocol and genesis parameters stored in the offline transfer file.
///
/// Named `OfflineTransferProtocolData` to avoid collision with Swift's `protocol` keyword.
public struct OfflineTransferProtocolData: Codable {
    public var protocolParameters: ProtocolParameters?
    public var genesisParameters: GenesisParameters?
    public var era: Era?
    public var network: Network?

    public init(
        protocolParameters: ProtocolParameters? = nil,
        genesisParameters: GenesisParameters? = nil,
        era: Era? = nil,
        network: Network? = nil
    ) {
        self.protocolParameters = protocolParameters
        self.genesisParameters = genesisParameters
        self.era = era
        self.network = network
    }

    enum CodingKeys: String, CodingKey {
        case protocolParameters = "protocol_parameters"
        case genesisParameters = "genesis_parameters"
        case era
        case network
    }
}

// MARK: - OfflineTransferHistory

/// A history entry recording an action performed on the offline transfer file.
public struct OfflineTransferHistory: Codable, Sendable {
    public var date: String?
    public var action: String?

    public init(date: String? = nil, action: String? = nil) {
        self.date = date ?? ISO8601DateFormatter().string(from: Date())
        self.action = action
    }
}

// MARK: - OfflineTransferFileEntry

/// A file attachment embedded in the offline transfer file (e.g. keys, scripts).
public struct OfflineTransferFileEntry: Codable, Sendable {
    public var name: String?
    public var date: String?
    public var size: Int?
    public var base64: Data?

    public init(
        name: String? = nil,
        date: String? = nil,
        size: Int? = nil,
        base64: Data? = nil
    ) {
        self.name = name
        self.date = date ?? ISO8601DateFormatter().string(from: Date())
        self.size = size
        self.base64 = base64
    }
}

// MARK: - OfflineTransferTransactionJSON

/// The raw JSON envelope of a serialized Cardano transaction (type / description / cborHex).
public struct OfflineTransferTransactionJSON: Codable, Sendable {
    public var type: String?
    public var description: String?
    public var cborHex: String?

    public init(type: String? = nil, description: String? = nil, cborHex: String? = nil) {
        self.type = type
        self.description = description
        self.cborHex = cborHex
    }

    /// Convenience: build from any `TextEnvelopable` value.
    ///
    /// Uses the `_type`, `_description`, and `_payload` protocol requirements so no
    /// serialisation round-trip is needed.
    public init(from envelopable: some TextEnvelopable) {
        self.type = envelopable._type
        self.description = envelopable._description
        self.cborHex = envelopable._payload.toHex
    }

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case cborHex = "cborHex"
    }
}

// MARK: - OfflineTransferTransaction

/// A transaction entry in the offline transfer file.
///
/// `txJson` uses the concrete `OfflineTransferTransactionJSON` type so the struct
/// can conform to `Codable`. To populate it from any `TextEnvelopable`, use the
/// `OfflineTransferTransactionJSON(from:)` convenience initialiser or
/// `mutating func setTxJson(_:)`.
public struct OfflineTransferTransaction: Codable, Sendable {
    public var date: String?
    public var era: Era?
    public var stakeAddress: String?
    public var fromAddress: String?
    public var fromName: String?
    public var toAddress: String?
    public var toName: String?
    public var txJson: OfflineTransferTransactionJSON?

    public init(
        date: String? = nil,
        era: Era? = nil,
        stakeAddress: String? = nil,
        fromAddress: String? = nil,
        fromName: String? = nil,
        toAddress: String? = nil,
        toName: String? = nil,
        txJson: OfflineTransferTransactionJSON? = nil
    ) {
        self.date = date ?? ISO8601DateFormatter().string(from: Date())
        self.era = era
        self.stakeAddress = stakeAddress
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.toAddress = toAddress
        self.toName = toName
        self.txJson = txJson
    }

    /// Convenience: set `txJson` from any `TextEnvelopable`.
    public mutating func setTxJson(_ envelopable: some TextEnvelopable) {
        txJson = OfflineTransferTransactionJSON(from: envelopable)
    }

    enum CodingKeys: String, CodingKey {
        case date
        case era
        case stakeAddress = "stake_address"
        case fromAddress = "from_address"
        case fromName = "from_name"
        case toAddress = "to_address"
        case toName = "to_name"
        case txJson = "tx_json"
    }
}

// MARK: - OfflineTransferEvaluation

/// A stored Plutus script evaluation result, keyed by tx CBOR hex.
///
/// Populate this on the online machine before transferring the file offline,
/// so that `evaluateTxCBOR` can be served without network access.
public struct OfflineTransferEvaluation: Codable, Sendable {
    public var txCborHex: String
    public var executionUnits: [String: ExecutionUnits]

    public init(txCborHex: String, executionUnits: [String: ExecutionUnits]) {
        self.txCborHex = txCborHex
        self.executionUnits = executionUnits
    }

    enum CodingKeys: String, CodingKey {
        case txCborHex = "tx_cbor_hex"
        case executionUnits = "execution_units"
    }
}

// MARK: - OfflineTransfer (Root Model)

/// The root model for the offline transfer JSON file.
///
/// Populate this on an online machine and save to disk, then transfer to a cold
/// offline machine via USB. The `OfflineTransferChainContext` reads this file to
/// serve chain data without network access.
public struct OfflineTransfer: Codable {
    public var general: OfflineTransferGeneral
    public var `protocol`: OfflineTransferProtocolData
    public var history: [OfflineTransferHistory]
    public var files: [OfflineTransferFileEntry]
    public var transactions: [OfflineTransferTransaction]
    public var addresses: [AddressInfo]
    public var stakePools: [PoolOperator]
    public var stakePoolInfos: [StakePoolInfo]
    public var kesPeriodInfos: [KESPeriodInfo]
    public var treasury: Coin?
    public var drepInfos: [DRepInfo]
    public var govActionInfos: [GovActionInfo]
    public var committeeMemberInfos: [CommitteeMemberInfo]
    public var evaluations: [OfflineTransferEvaluation]

    public init(
        general: OfflineTransferGeneral = OfflineTransferGeneral(),
        protocol protocolData: OfflineTransferProtocolData = OfflineTransferProtocolData(),
        history: [OfflineTransferHistory] = [],
        files: [OfflineTransferFileEntry] = [],
        transactions: [OfflineTransferTransaction] = [],
        addresses: [AddressInfo] = [],
        stakePools: [PoolOperator] = [],
        stakePoolInfos: [StakePoolInfo] = [],
        kesPeriodInfos: [KESPeriodInfo] = [],
        treasury: Coin? = nil,
        drepInfos: [DRepInfo] = [],
        govActionInfos: [GovActionInfo] = [],
        committeeMemberInfos: [CommitteeMemberInfo] = [],
        evaluations: [OfflineTransferEvaluation] = []
    ) {
        self.general = general
        self.protocol = protocolData
        self.history = history
        self.files = files
        self.transactions = transactions
        self.addresses = addresses
        self.stakePools = stakePools
        self.stakePoolInfos = stakePoolInfos
        self.kesPeriodInfos = kesPeriodInfos
        self.treasury = treasury
        self.drepInfos = drepInfos
        self.govActionInfos = govActionInfos
        self.committeeMemberInfos = committeeMemberInfos
        self.evaluations = evaluations
    }

    enum CodingKeys: String, CodingKey {
        case general
        case `protocol` = "protocol"
        case history
        case files
        case transactions
        case addresses
        case stakePools = "stake_pools"
        case stakePoolInfos = "stake_pool_infos"
        case kesPeriodInfos = "kes_period_infos"
        case treasury
        case drepInfos = "drep_infos"
        case govActionInfos = "gov_action_infos"
        case committeeMemberInfos = "committee_member_infos"
        case evaluations
    }

    // MARK: - Persistence

    /// Load an `OfflineTransfer` from a JSON file on disk.
    public static func load(from path: FilePath) throws -> OfflineTransfer {
        let data = try Data(contentsOf: URL(fileURLWithPath: path.string))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OfflineTransfer.self, from: data)
    }

    /// Save this `OfflineTransfer` to a JSON file on disk.
    public func save(to path: FilePath) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: path.string), options: .atomic)
    }

    /// Create a new, empty `OfflineTransfer` file with an initial history entry, save it, and return it.
    public static func new(at path: FilePath) throws -> OfflineTransfer {
        let now = ISO8601DateFormatter().string(from: Date())
        let transfer = OfflineTransfer(
            history: [OfflineTransferHistory(date: now, action: "NEW")]
        )
        try transfer.save(to: path)
        return transfer
    }
}
