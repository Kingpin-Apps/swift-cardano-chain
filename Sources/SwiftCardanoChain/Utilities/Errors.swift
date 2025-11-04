import Foundation

enum CardanoChainError: Error, CustomStringConvertible, Equatable {
    case blockfrostError(String?)
    case cardanoCLIError(String?)
    case invalidArgument(String?)
    case invalidAdaHandle(String?)
    case koiosError(String?)
    case transactionFailed(String?)
    case operationError(String?)
    case unsupportedNetwork(String?)
    case valueError(String?)
    
    var description: String {
        switch self {
            case .cardanoCLIError(let message):
                return message ?? "Failed to execute Cardano CLI command."
            case .blockfrostError(let message):
                return message ?? "Failed to retrieve data from Blockfrost."
            case .invalidAdaHandle(let message):
                return message ?? "Invalid ADA Handle."
            case .invalidArgument(let message):
                return message ?? "Invalid argument error occurred."
            case .koiosError(let message):
                return message ?? "Failed to retrieve data from Koios."
            case .operationError(let message):
                return message ?? "Operation failed error occurred."
            case .transactionFailed(let message):
                return message ?? "Transaction failed error occurred."
            case .unsupportedNetwork(let message):
                return message ?? "The network is not supported."
            case .valueError(let message):
                return message ?? "The value is invalid."
        }
    }
}


public enum AdaHandleError: LocalizedError {
    case adahandleOfflineMode
    case adahandleNetworkNotSupported(String)
    case adahandleNotFound(String)
    case adahandleInvalidFormat(String)
    case adahandleInvalidAddress(String)
    case adahandleAssetNotOnAddress(String, String)
    case adahandleAPIError(String, Int?)
    case adahandleAddressMismatch(String, String)
}
