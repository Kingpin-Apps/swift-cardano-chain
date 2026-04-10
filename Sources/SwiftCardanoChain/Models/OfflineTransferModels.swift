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

// MARK: - HistoryType

/// The action recorded in an ``OfflineTransferHistory`` entry.
///
/// Simple cases carry a fixed description string. Parameterised cases mirror
/// Python's `partial`-based enum values: they carry their arguments as
/// associated values and produce the same formatted string via ``description``.
/// A ``raw(_:)`` catch-all case is used when decoding an unrecognised string
/// from an existing JSON file.
public enum HistoryType: Sendable, Equatable {
    // MARK: Simple cases
    case clearFiles
    case clearHistory
    case clearTransactions
    case new

    // MARK: Parameterised cases
    case addUtxoInfo(fileName: String)
    case addStakeAddr(fileName: String)
    case attach(fileName: String)
    case extractedFile(fileName: String)
    case saveTransaction(txId: String)
    case submitTransaction(txId: String, fromName: String, toName: String)
    case submitRewardsTransaction(txId: String, stakeName: String, toName: String)
    case submitStakeTransaction(txId: String, transactionType: String, stakeName: String, fromName: String)
    case submitPoolTransaction(txId: String, transactionType: String, poolTicker: String, fromName: String)
    case signedPoolRegistrationTransaction(poolTicker: String, payName: String)
    case signedPoolDeregistrationTransaction(poolTicker: String, payName: String)
    case signedStakeKeyRegistrationTransaction(stakeAddr: String, fromAddr: String)
    case signedDelegationTransaction(stakeAddr: String, fromAddr: String)
    case signedStakeKeyDeregistrationTransaction(stakeAddr: String, fromAddr: String)
    case signedUtxoTransaction(fromAddr: String, toAddr: String)
    case signedRewardsWithdrawal(stakeAddr: String, toAddr: String, paymentAddr: String)

    // MARK: Fallback for decoding unrecognised strings from existing JSON files
    case raw(String)
}

extension HistoryType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .clearFiles:
            return "attached files cleared"
        case .clearHistory:
            return "history cleared"
        case .clearTransactions:
            return "cleared all transactions"
        case .new:
            return "new file created"
        case .addUtxoInfo(let fileName):
            return "added utxo-info for \(fileName)"
        case .addStakeAddr(let fileName):
            return "added stake address rewards-state for \(fileName)"
        case .attach(let fileName):
            return "attached file \(fileName)"
        case .extractedFile(let fileName):
            return "extracted file \(fileName)"
        case .saveTransaction(let txId):
            return "tx save \(txId)"
        case .submitTransaction(let txId, let fromName, let toName):
            return "tx submit \(txId) - utxo from \(fromName) to \(toName)"
        case .submitRewardsTransaction(let txId, let stakeName, let toName):
            return "tx submit \(txId) - withdrawal from \(stakeName) to \(toName)"
        case .submitStakeTransaction(let txId, let transactionType, let stakeName, let fromName):
            return "tx submit \(txId) - \(transactionType) for \(stakeName), payment via \(fromName)"
        case .submitPoolTransaction(let txId, let transactionType, let poolTicker, let fromName):
            return "tx submit \(txId) - \(transactionType) for Pool \(poolTicker), payment via \(fromName)"
        case .signedPoolRegistrationTransaction(let poolTicker, let payName):
            return "signed pool registration transaction for \(poolTicker), payment via \(payName)"
        case .signedPoolDeregistrationTransaction(let poolTicker, let payName):
            return "signed pool retirement transaction for \(poolTicker), payment via \(payName)"
        case .signedStakeKeyRegistrationTransaction(let stakeAddr, let fromAddr):
            return "signed staking key registration transaction for '\(stakeAddr)', payment via '\(fromAddr)'"
        case .signedDelegationTransaction(let stakeAddr, let fromAddr):
            return "signed delegation cert registration transaction for '\(stakeAddr)', payment via '\(fromAddr)'"
        case .signedStakeKeyDeregistrationTransaction(let stakeAddr, let fromAddr):
            return "signed staking key deregistration transaction for '\(stakeAddr)', payment via '\(fromAddr)'"
        case .signedUtxoTransaction(let fromAddr, let toAddr):
            return "signed utxo transaction from '\(fromAddr)' to '\(toAddr)'"
        case .signedRewardsWithdrawal(let stakeAddr, let toAddr, let paymentAddr):
            return "signed rewards withdrawal from '\(stakeAddr)' to '\(toAddr)', payment via '\(paymentAddr)'"
        case .raw(let value):
            return value
        }
    }
}

extension HistoryType {
    /// Parse a `HistoryType` from its description string.
    ///
    /// Returns `.raw(string)` if the string does not match any known pattern.
    public static func from(_ string: String) -> HistoryType {
        // Simple fixed-string cases.
        switch string {
            case "attached files cleared":   return .clearFiles
            case "history cleared":          return .clearHistory
            case "cleared all transactions": return .clearTransactions
            case "new file created":         return .new
            default: break
        }

        // Strip a known prefix; returns the remainder or nil.
        func drop(_ prefix: String) -> String? {
            string.hasPrefix(prefix) ? String(string.dropFirst(prefix.count)) : nil
        }

        // Split a string on the first occurrence of a separator.
        func split(_ sep: String, in s: String) -> (String, String)? {
            guard let r = s.range(of: sep) else { return nil }
            return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
        }

        if let rest = drop("added utxo-info for ") {
            return .addUtxoInfo(fileName: rest)
        }
        if let rest = drop("added stake address rewards-state for ") {
            return .addStakeAddr(fileName: rest)
        }
        if let rest = drop("attached file ") {
            return .attach(fileName: rest)
        }
        if let rest = drop("extracted file ") {
            return .extractedFile(fileName: rest)
        }
        if let rest = drop("tx save ") {
            return .saveTransaction(txId: rest)
        }
        // "tx submit {txId} - …"
        if let rest = drop("tx submit "), let (txId, suffix) = split(" - ", in: rest) {
            if let fromRest = suffix.hasPrefix("utxo from ") ? String(suffix.dropFirst("utxo from ".count)) : nil,
               let (fromName, toName) = split(" to ", in: fromRest) {
                return .submitTransaction(txId: txId, fromName: fromName, toName: toName)
            }
            if let fromRest = suffix.hasPrefix("withdrawal from ") ? String(suffix.dropFirst("withdrawal from ".count)) : nil,
               let (stakeName, toName) = split(" to ", in: fromRest) {
                return .submitRewardsTransaction(txId: txId, stakeName: stakeName, toName: toName)
            }
            // Pool variant must be checked before the generic stake variant.
            if let (typeAndPool, fromName) = split(", payment via ", in: suffix),
               let (txType, poolTicker) = split(" for Pool ", in: typeAndPool) {
                return .submitPoolTransaction(txId: txId, transactionType: txType, poolTicker: poolTicker, fromName: fromName)
            }
            if let (typeAndStake, fromName) = split(", payment via ", in: suffix),
               let (txType, stakeName) = split(" for ", in: typeAndStake) {
                return .submitStakeTransaction(txId: txId, transactionType: txType, stakeName: stakeName, fromName: fromName)
            }
        }
        if let rest = drop("signed pool registration transaction for "),
           let (ticker, payName) = split(", payment via ", in: rest) {
            return .signedPoolRegistrationTransaction(poolTicker: ticker, payName: payName)
        }
        if let rest = drop("signed pool retirement transaction for "),
           let (ticker, payName) = split(", payment via ", in: rest) {
            return .signedPoolDeregistrationTransaction(poolTicker: ticker, payName: payName)
        }
        if let rest = drop("signed staking key registration transaction for '"),
           let (stakeAddr, fromRest) = split("', payment via '", in: rest) {
            return .signedStakeKeyRegistrationTransaction(stakeAddr: stakeAddr, fromAddr: String(fromRest.dropLast()))
        }
        if let rest = drop("signed delegation cert registration transaction for '"),
           let (stakeAddr, fromRest) = split("', payment via '", in: rest) {
            return .signedDelegationTransaction(stakeAddr: stakeAddr, fromAddr: String(fromRest.dropLast()))
        }
        if let rest = drop("signed staking key deregistration transaction for '"),
           let (stakeAddr, fromRest) = split("', payment via '", in: rest) {
            return .signedStakeKeyDeregistrationTransaction(stakeAddr: stakeAddr, fromAddr: String(fromRest.dropLast()))
        }
        if let rest = drop("signed utxo transaction from '"),
           let (fromAddr, toRest) = split("' to '", in: rest) {
            return .signedUtxoTransaction(fromAddr: fromAddr, toAddr: String(toRest.dropLast()))
        }
        if let rest = drop("signed rewards withdrawal from '"),
           let (stakeAddr, toRest) = split("' to '", in: rest),
           let (toAddr, payRest) = split("', payment via '", in: toRest) {
            return .signedRewardsWithdrawal(stakeAddr: stakeAddr, toAddr: toAddr, paymentAddr: String(payRest.dropLast()))
        }

        return .raw(string)
    }
}

extension HistoryType: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = HistoryType.from(value)
    }
}

// MARK: - OfflineTransferHistory

/// A history entry recording an action performed on the offline transfer file.
public struct OfflineTransferHistory: Sendable {
    public var date: Date?
    public var action: HistoryType?

    public init(date: Date? = nil, action: HistoryType? = nil) {
        self.date = date ?? Date()
        self.action = action
    }
}

extension OfflineTransferHistory: Codable {
    enum CodingKeys: String, CodingKey { case date, action }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try container.decodeIfPresent(String.self, forKey: .date) {
            date = ISO8601DateFormatter().date(from: raw)
        }
        action = try container.decodeIfPresent(HistoryType.self, forKey: .action)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let date {
            try container.encode(ISO8601DateFormatter().string(from: date), forKey: .date)
        }
        try container.encodeIfPresent(action, forKey: .action)
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
        let transfer = OfflineTransfer(
            history: [OfflineTransferHistory(action: .new)]
        )
        try transfer.save(to: path)
        return transfer
    }
}
