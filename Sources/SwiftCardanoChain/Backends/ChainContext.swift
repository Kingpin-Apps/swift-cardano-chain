import Foundation
import SwiftCardanoCore

/// Enum representing transaction data input types.
public enum TransactionData {
    case transaction(Transaction)
    case bytes(Data)
    case string(String)
}

/// Enum representing the type of chain context, either online or offline.
public enum ContextType {
    case online
    case offline
}

/// Interfaces through which the library interacts with the Cardano blockchain.
public protocol ChainContext: CustomStringConvertible, CustomDebugStringConvertible {

    /// The name of the chain context
    var name: String { get }

    /// The type of the chain context
    var type: ContextType { get }

    /// Get current protocol parameters
    var protocolParameters: () async throws -> ProtocolParameters { get }

    /// Get chain genesis parameters
    var genesisParameters: () async throws -> GenesisParameters { get }

    /// Get current network id
    var networkId: NetworkId { get }

    /// Current epoch number
    var epoch: () async throws -> Int { get }

    /// Current era
    var era: () async throws -> Era? { get }

    /// Slot number of last block
    var lastBlockSlot: () async throws -> Int { get }

    /// Get all UTxOs associated with an address.
    ///
    /// - Parameter address: An address, potentially bech32 encoded.
    /// - Returns: A list of UTxOs.
    func utxos(address: Address) async throws -> [UTxO]

    /// Get the UTxO for a specific transaction input.
    ///
    /// - Parameter input: A transaction input identifying the UTxO by transaction hash and output index.
    /// - Returns: A tuple of the UTxO and a boolean indicating whether it has been spent,
    ///   or `nil` if the UTxO does not exist or cannot be found.
    ///   Note: backends that only query the live UTxO set (CardanoCLI, Ogmios) will always
    ///   return `isSpent: false` when a result is returned, and `nil` for spent UTxOs.
    func utxo(input: TransactionInput) async throws -> (UTxO, isSpent: Bool)?

    /// Submit a serialized transaction to the blockchain.
    ///
    /// - Parameter cbor: The serialized transaction to be submitted.
    /// - Throws: `InvalidArgumentException` when the transaction is invalid.
    /// - Throws: `TransactionFailedException` when submission fails.
    func submitTxCBOR(cbor: Data) async throws -> String

    /// Evaluate execution units of a transaction.
    ///
    /// - Parameter tx: The transaction to be evaluated.
    /// - Returns: A dictionary mapping redeemer strings to execution units.
    func evaluateTx(tx: Transaction) async throws -> [String: ExecutionUnits]

    /// Evaluate execution units of a transaction.
    ///
    /// - Parameter cbor: The serialized transaction to be evaluated.
    /// - Returns: A dictionary mapping redeemer strings to execution units.
    func evaluateTxCBOR(cbor: Data) async throws -> [String: ExecutionUnits]

    /// Get the stake address information.
    /// - Parameter address: The stake address.
    /// - Returns: List of `StakeAddressInfo` object.
    func stakeAddressInfo(address: Address) async throws -> [StakeAddressInfo]

    /// Get the list of stake pools on the chain.
    /// - Returns: List of `PoolOperator` objects.
    func stakePools() async throws -> [PoolOperator]

    /// Get the KES period information of a stake pool from a given operational certificate and/or pool id.
    /// - Parameters:
    ///   - pool: The pool operator's ID as a Bech32 string. Optional if `opCert` is provided.
    ///   - opCert: The operational certificate as a CBOR-encoded byte array. Optional if `pool` is provided.
    /// - Returns: The KES period information, including the current KES period and the remaining KES periods before the certificate expires.
    func kesPeriodInfo(pool: PoolOperator?, opCert: OperationalCertificate?) async throws
        -> KESPeriodInfo

    /// Get the stake pool information.
    /// - Parameter poolId: The pool ID (Bech32).
    /// - Returns: `StakePoolInfo` object.
    func stakePoolInfo(poolId: String) async throws -> StakePoolInfo
    
    /// Get the treasury balance.
    /// - Returns: The current balance of the treasury as a `Coin` object.
    /// - Throws: An error if the treasury balance cannot be retrieved.
    func treasury() async throws -> Coin
}

// MARK: - Default Implementation
extension ChainContext {
    /// Submit a transaction to the blockchain.
    ///
    /// - Parameter tx: The transaction to be submitted.
    /// - Throws: `InvalidArgumentException` when the transaction is invalid.
    /// - Throws: `TransactionFailedException` when submission fails.
    public func submitTx(tx: TransactionData) async throws -> String {
        switch tx {
        case .transaction(let transaction):
            return try await submitTxCBOR(cbor: transaction.toCBORData())
        case .bytes(let data):
            return try await submitTxCBOR(cbor: data)
        case .string(let string):
            return try await submitTxCBOR(cbor: string.hexStringToData)
        }
    }

    /// Evaluate execution units of a transaction.
    ///
    /// - Parameter tx: The transaction to be evaluated.
    /// - Returns: A dictionary mapping redeemer strings to execution units.
    public func evaluateTx(tx: Transaction) async throws -> [String: ExecutionUnits] {
        return try await evaluateTxCBOR(cbor: tx.toCBORData())
    }
}

// MARK: - StringConvertible Implementation
extension ChainContext {
    public var description: String {
        return name
    }

    public var debugDescription: String {
        return "ChainContext(name: \(name), networkId: \(networkId))"
    }
}
