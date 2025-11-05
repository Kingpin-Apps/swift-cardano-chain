import Foundation

/// Convert asset name from ASCII to HEX representation
/// - Parameter assetName: The asset name in ASCII format
/// - Returns: The asset name in HEX format
public func convertAssetNameASCII2HEX(assetName: String) -> String {
    return assetName.toData.toHex
}

/// Convert asset name from HEX to ASCII representation
/// - Parameter assetName: The asset name in HEX format
/// - Returns: The asset name in ASCII format
public func convertAssetNameHEX2ASCII(assetName: String) -> String {
    return assetName.hexStringToData.toString
}


// MARK: - Retry Logic

/// Executes an async operation with exponential backoff retry logic.
///
/// - Parameters:
///   - maxAttempts: Maximum number of retry attempts (default: 5)
///   - operation: The async operation to retry
/// - Returns: The result of the operation
/// - Throws: The last error encountered if all retries fail
public func withRetry<T>(
    maxRetryAttempts: UInt64 = 5,
    baseRetryDelay: UInt64 = 200,
    operation: () async throws -> T
) async throws -> T {
    var lastError: Error?
    
    for attempt in 0..<maxRetryAttempts {
        do {
            return try await operation()
        } catch {
            lastError = error
            
            // Don't retry on the last attempt
            if attempt < maxRetryAttempts - 1 {
                // Exponential backoff with jitter
                let baseDelay = baseRetryDelay * UInt64(1 << attempt)
                let jitter = UInt64.random(in: 0..<(baseDelay / 2))
                let delay = baseDelay + jitter
                
                try await Task.sleep(nanoseconds: delay * 1_000_000) // Convert ms to ns
            }
        }
    }
    
    throw lastError ?? CardanoChainError.operationError("Operation error during retry: \(String(describing: lastError))")
}
