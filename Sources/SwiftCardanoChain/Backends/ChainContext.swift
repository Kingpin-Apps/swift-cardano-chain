import Foundation
import SwiftCardanoCore

/// Enum representing transaction data input types.
public enum TransactionData{
    case transaction(Transaction)
    case bytes(Data)
    case string(String)
}

/// Interfaces through which the library interacts with the Cardano blockchain.
public protocol ChainContext: CustomStringConvertible, CustomDebugStringConvertible {
    
    /// The name of the chain context
    var name: String { get }
    
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
}

// MARK: - Default Implementation
public extension ChainContext {
    /// Submit a transaction to the blockchain.
    ///
    /// - Parameter tx: The transaction to be submitted.
    /// - Throws: `InvalidArgumentException` when the transaction is invalid.
    /// - Throws: `TransactionFailedException` when submission fails.
    func submitTx(tx: TransactionData) async throws -> String {
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
    func evaluateTx(tx: Transaction) async throws -> [String: ExecutionUnits] {
        return try await evaluateTxCBOR(cbor: tx.toCBORData())
    }
}

// MARK: - StringConvertible Implementation
public extension ChainContext {
    var description: String {
        return name
    }
    
    var debugDescription: String {
        return "ChainContext(name: \(name), networkId: \(networkId))"
    }
}
