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

/// Validates an Ada Handle (root or sub/virtual) and returns a normalized value.
///
/// This function accepts both root handles (for example: `$alice`) and sub/virtual handles (for example: `$alice@bob`).
/// The check is case-insensitive; on success the returned string is lowercased to provide a normalized representation.
///
/// - Parameter handle: The Ada Handle to check.
/// - Throws: `CardanoChainError.invalidAdaHandle` if the format is invalid or `handle` is `nil`.
/// - Returns: The valid, lowercased Ada Handle.
public func checkAdaHandleFormat(_ handle: String?) throws -> String {
    guard let handle = handle else {
        throw CardanoChainError.invalidAdaHandle(handle)
    }
    
    let pattern = /^\$[a-z0-9_.-]{1,15}(@[a-z0-9_.-]{1,15})?$/
        .ignoresCase()
    
    if handle.wholeMatch(of: pattern) != nil {
        return handle.lowercased()
    } else {
        throw CardanoChainError.invalidAdaHandle(handle)
    }
}

/// Checks if the given string is a valid root Ada Handle (no subhandle part).
///
/// A valid root handle matches the pattern `$[a-z0-9_.-]{1,15}` (case-insensitive).
/// Examples of valid root handles: `$alice`, `$a_b-1`.
///
/// - Parameter handle: The string to validate.
/// - Returns: `true` if the string is a valid root Ada Handle; otherwise, `false`.
public func isValidAdaRootHandle(_ handle: String?) -> Bool {
    guard let handle else { return false }
    let pattern = /^\$[a-z0-9_.-]{1,15}$/
        .ignoresCase()
    return handle.wholeMatch(of: pattern) != nil
}

/// Checks if the given string is a valid sub/virtual Ada Handle (with a subhandle part).
///
/// A valid sub/virtual handle matches the pattern `$[a-z0-9_.-]{1,15}@[a-z0-9_.-]{1,15}` (case-insensitive).
/// Examples of valid subhandles: `$alice@bob`, `$root-1@sub_2`.
///
/// - Parameter handle: The string to validate.
/// - Returns: `true` if the string is a valid sub/virtual Ada Handle; otherwise, `false`.
public func isValidAdaSubHandle(_ handle: String?) -> Bool {
    guard let handle else { return false }
    let pattern = /^\$[a-z0-9_.-]{1,15}@[a-z0-9_.-]{1,15}$/
        .ignoresCase()
    return handle.wholeMatch(of: pattern) != nil
}
