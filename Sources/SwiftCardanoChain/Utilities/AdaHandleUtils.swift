import Foundation
import SwiftKoios
import SwiftHandlesAPI
import SwiftCardanoCore

public struct AdaHandlePolicyIds: NetworkDependable {
    public typealias T = String

    public var mainnet: String {
        "f0ff48bbb7bbe9d59a40f1ce90e9e9d0ff5002ec48f232b49ca0fb9a"
    }
    
    public var preprod: String? {
        "f0ff48bbb7bbe9d59a40f1ce90e9e9d0ff5002ec48f232b49ca0fb9a"
    }
    
    public var preview: String? {
        "f0ff48bbb7bbe9d59a40f1ce90e9e9d0ff5002ec48f232b49ca0fb9a"
    }

    public var guildnet: String? {""}
}

/// Utilities for resolving ADA Handles (CIP-25, CIP-68, and virtual handles) to Cardano payment addresses.
///
/// This module provides functionality to resolve AdaHandles using the Koios API for root handles
/// and the ADA Handle Public API for sub/virtual handles. The resolution process includes:
/// - CIP-25 format (classic AdaHandles)
/// - CIP-68 format (reference NFT standard)
/// - Virtual/sub-handles (delegated handles)
///
/// ## Topics
/// ### Main Functions
/// - ``resolveAdahandle(handle:config:)``
///
/// ### Helper Functions
/// - ``normalizeHandle(_:)``
/// - ``validatePaymentAddress(_:)``

// MARK: - Constants

public enum AdaHandleConstants {
    /// CIP-68 asset name prefix (hex)
    static let cip68Prefix = "000de140"
    
    /// Virtual handle asset name prefix (hex)
    static let virtualPrefix = "00000000"
    
    /// Hex encoded "resolved_addresses" key for datum parsing
    static let datumResolvedKeyHex = "7265736f6c7665645f616464726573736573"
}

// MARK: - Public Functions

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

/// Resolves an AdaHandle (CIP-25, CIP-68, or virtual) to a Cardano payment address.
///
/// This function handles both root handles (e.g., "$alice") and sub/virtual handles (e.g., "$alice@subdomain").
/// It validates the resolved address and verifies that the handle asset exists on that address.
///
/// - Parameters:
///   - handle: The AdaHandle to resolve (with or without leading '$')
///   - config: The multitool configuration containing network settings and policy IDs
///
/// - Returns: A bech32-encoded Cardano payment address
///
/// - Throws:
///   - ``AdaHandleError/adahandleOfflineMode`` if the config mode is offline
///   - ``AdaHandleError/adahandleNetworkNotSupported(_:)`` if the network is not supported
///   - ``AdaHandleError/adahandleNotFound(_:)`` if the handle cannot be resolved
///   - ``AdaHandleError/adahandleInvalidFormat(_:)`` if the handle format is invalid
///   - ``AdaHandleError/adahandleInvalidAddress(_:)`` if the resolved address is not a payment address
///   - ``AdaHandleError/adahandleAssetNotOnAddress(_:_:)`` if the asset is not found on the resolved address
///   - ``AdaHandleError/adahandleAPIError(_:_:)`` for API-related errors
///   - ``AdaHandleError/adahandleAddressMismatch(_:_:)`` for virtual handle validation failures
///
/// ## Example
/// ```swift
/// let config = try await MultitoolConfig.load()
/// let address = try await resolveAdahandle(handle: "$alice", config: config)
/// print("Resolved to: \(address)")
/// ```
public func resolveAdahandle(
    handle: String,
    network: SwiftCardanoCore.Network
) async throws -> Address {
    // Normalize the handle
    let normalized = normalizeHandle(handle)
    
    // Get policy ID for the network
    let policyId = try getPolicyId(for: network)
    
    // Create Koios client for asset queries
    let koios = try await createKoiosClient(network: network)
    
    // Route to appropriate resolution path
    if isSubHandle(normalized) {
        return try await resolveSubOrVirtualHandle(
            handle: normalized,
            policyId: policyId,
            network: network,
            koios: koios
        )
    } else {
        return try await resolveRootHandle(
            handle: normalized,
            policyId: policyId,
            koios: koios
        )
    }
}

// MARK: - Handle Normalization and Validation

/// Normalizes an AdaHandle by removing the leading '$' and trimming whitespace.
///
/// - Parameter handle: The handle to normalize
/// - Returns: The normalized handle string
public func normalizeHandle(_ handle: String) -> String {
    var normalized = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("$") {
        normalized = String(normalized.dropFirst())
    }
    return normalized.lowercased()
}

/// Checks if a handle is a sub-handle (contains '@') or virtual handle.
///
/// - Parameter handle: The normalized handle to check
/// - Returns: `true` if the handle contains '@', `false` otherwise
public func isSubHandle(_ handle: String) -> Bool {
    return handle.contains("@")
}

/// Validates that an address is a payment address (not stake-only).
///
/// - Parameter addressString: The bech32 address string to validate
/// - Throws: ``AdaHandleError/adahandleInvalidAddress(_:)`` if validation fails
public func validatePaymentAddress(_ addressString: String) throws {
    let address = try Address(from: .string(addressString))
    
    // Ensure the address has a payment part
    guard address.paymentPart != nil else {
        throw AdaHandleError.adahandleInvalidAddress(addressString)
    }
    
    // Ensure the address type is valid for payment
    guard let addressType = address.addressType else {
        throw AdaHandleError.adahandleInvalidAddress(addressString)
    }
    
    // Reject stake-only addresses
    switch addressType {
        case .noneKey, .noneScript:
            throw AdaHandleError.adahandleInvalidAddress(addressString)
        default:
            break
    }
}

// MARK: - Utility Functions

/// Converts an ASCII asset name to its hexadecimal representation.
///
/// - Parameter name: The ASCII asset name
/// - Returns: The hex-encoded asset name (lowercase, no 0x prefix)
public func convertAssetNameToHex(_ name: String) -> String {
    return Data(name.utf8).map { String(format: "%02x", $0) }.joined()
}

/// Creates an asset fingerprint from policy ID and asset name hex.
///
/// - Parameters:
///   - policyId: The policy ID hex string
///   - assetNameHex: The asset name hex string
/// - Returns: The asset fingerprint in the format "policyId.assetNameHex"
public func assetFingerprint(policyId: String, assetNameHex: String) -> String {
    return "\(policyId).\(assetNameHex)"
}

/// Gets the AdaHandle policy ID for the specified network.
///
/// - Parameters:
///   - network: The Cardano network
///   - config: The multitool configuration
/// - Returns: The policy ID hex string
/// - Throws: ``AdaHandleError/adahandleNetworkNotSupported(_:)`` if unsupported
public func getPolicyId(for network: SwiftCardanoCore.Network) throws -> String {
    let adaHandlePolicyIds = AdaHandlePolicyIds()
    switch network {
        case .mainnet:
            return adaHandlePolicyIds.mainnet
        case .preprod:
            return adaHandlePolicyIds.preprod!
        case .preview:
            return adaHandlePolicyIds.preview!
        case .guildnet:
            if let guildnet = adaHandlePolicyIds.guildnet {
                return guildnet
            }
            throw AdaHandleError.adahandleNetworkNotSupported("guildnet")
        default:
            throw AdaHandleError.adahandleNetworkNotSupported("\(network)")
    }
}

/// Creates a Koios client for the specified network.
///
/// - Parameter network: The Cardano network
/// - Returns: A configured Koios instance
/// - Throws: An error if the client cannot be created
public func createKoiosClient(network: SwiftCardanoCore.Network) async throws -> Koios {
    let koiosNetwork: SwiftKoios.Network
    switch network {
    case .mainnet:
        koiosNetwork = .mainnet
    case .guildnet:
        koiosNetwork = .guild
    case .preview:
        koiosNetwork = .preview
    case .preprod:
        koiosNetwork = .preprod
    case .sanchonet:
        koiosNetwork = .sancho
    default:
        throw AdaHandleError.adahandleNetworkNotSupported("\(network)")
    }
    
    return try Koios(network: koiosNetwork, environmentVariable: "KOIOS_API_KEY")
}

/// Creates a Handles API client for the specified network.
///
/// - Parameter network: The Cardano network
/// - Returns: A configured Handles instance
/// - Throws: An error if the client cannot be created
public func createHandlesClient(network: SwiftCardanoCore.Network) throws -> Handles {
    // Currently only mainnet is supported by the Handles API
    guard network == .mainnet else {
        throw AdaHandleError.adahandleNetworkNotSupported("\(network) - Handles API only supports mainnet")
    }
    
    return try Handles(network: .mainnet, environmentVariable: "HANDLES_API_KEY")
}


// MARK: - Root Handle Resolution

/// Resolves a root AdaHandle (without '@') using Koios API.
///
/// Attempts CIP-25 format first, then falls back to CIP-68 format if not found.
///
/// - Parameters:
///   - handle: The normalized handle to resolve
///   - policyId: The AdaHandle policy ID
///   - koios: The Koios client
/// - Returns: The resolved bech32 payment address
/// - Throws: Various ``AdaHandleError`` cases for failures
public func resolveRootHandle(
    handle: String,
    policyId: String,
    koios: Koios
) async throws -> Address {
    let assetNameHex = convertAssetNameToHex(handle)
    
    // Try CIP-25 format first
    if let address = try await tryResolveWithAssetName(
        policyId: policyId,
        assetNameHex: assetNameHex,
        koios: koios
    ) {
        print("Found $adahandle '\(handle)' on Address: \(address)")
        return try Address(from: .string(address))
    }
    
    // Fall back to CIP-68 format
    let cip68AssetNameHex = AdaHandleConstants.cip68Prefix + assetNameHex
    if let address = try await tryResolveWithAssetName(
        policyId: policyId,
        assetNameHex: cip68AssetNameHex,
        koios: koios
    ) {
        print("Found $adahandle '\(handle)' (CIP-68) on Address: \(address)")
        return try Address(from: .string(address))
    }
    
    throw AdaHandleError.adahandleNotFound("Handle '\(handle)' not found in CIP-25 or CIP-68 format")
}

/// Attempts to resolve a handle with a specific asset name format.
///
/// - Parameters:
///   - policyId: The AdaHandle policy ID
///   - assetNameHex: The hex-encoded asset name
///   - koios: The Koios client
/// - Returns: The resolved address if found and valid, nil otherwise
/// - Throws: Errors from API calls or validation
public func tryResolveWithAssetName(
    policyId: String,
    assetNameHex: String,
    koios: Koios
) async throws -> String? {
    // Query asset addresses
    let response = try await withRetry() {
        try await koios.client.assetAddresses(
            Operations.AssetAddresses.Input(
                query: .init(
                    _assetPolicy: policyId,
                    _assetName: assetNameHex
                )
            )
        )
    }
    
    let holders = try response.ok.body.json
    
    // Must have exactly one holder
    guard holders.count == 1,
          let paymentAddressContainer = holders.first?.paymentAddress,
          let address = paymentAddressContainer.value as? String else {
        return nil
    }
    
    // Validate the address
    try validatePaymentAddress(address)
    
    // Verify asset is on the address via UTxO query
    try await verifyAssetOnAddress(
        fingerprint: assetFingerprint(policyId: policyId, assetNameHex: assetNameHex),
        address: address,
        koios: koios
    )
    
    return address
}

// MARK: - Sub/Virtual Handle Resolution

/// Resolves a sub or virtual AdaHandle using the Handles API.
///
/// - Parameters:
///   - handle: The normalized handle to resolve
///   - policyId: The AdaHandle policy ID
///   - network: The Cardano network
///   - koios: The Koios client for verification
/// - Returns: The resolved bech32 payment address
/// - Throws: Various ``AdaHandleError`` cases for failures
public func resolveSubOrVirtualHandle(
    handle: String,
    policyId: String,
    network: SwiftCardanoCore.Network,
    koios: Koios
) async throws -> Address {
    let handles = try createHandlesClient(network: network)
    
    // Query the Handles API
    let response = try await withRetry() {
        try await handles.client.getHandlesHandle(
            Operations.GetHandlesHandle.Input(
                path: .init(handle: handle)
            )
        )
    }
    
    let handleData = try response.ok.body.json
    
    // Extract resolved address
    guard let resolvedAddresses = handleData.resolvedAddresses,
          let adaAddress = resolvedAddresses.ada else {
        throw AdaHandleError.adahandleNotFound("No ADA address found for handle '\(handle)'")
    }
    
    // Validate the address
    try validatePaymentAddress(adaAddress)
    
    // Get the asset hex to determine handle type
    guard let assetHex = handleData.hex else {
        throw AdaHandleError.adahandleAPIError("Missing hex field in handle data", nil)
    }
    
    // Handle based on asset type
    if assetHex.hasPrefix(AdaHandleConstants.cip68Prefix) {
        // CIP-68 sub-handle: verify asset is on address
        try await verifyAssetOnAddress(
            fingerprint: assetFingerprint(policyId: policyId, assetNameHex: assetHex),
            address: adaAddress,
            koios: koios
        )
        print("Found $subhandle '\(handle)' on Address: \(adaAddress)")
    } else if assetHex.hasPrefix(AdaHandleConstants.virtualPrefix) {
        // Virtual handle: cross-verify with Koios datum
        try await verifyVirtualHandle(
            fingerprint: assetFingerprint(policyId: policyId, assetNameHex: assetHex),
            expectedAddress: adaAddress,
            network: network,
            koios: koios
        )
        print("This virtual $adahandle '\(handle)' resolves to Address: \(adaAddress)")
    } else {
        throw AdaHandleError.adahandleAPIError(
            "Unknown asset type for handle '\(handle)' - hex: \(assetHex)",
            nil
        )
    }
    
    return try Address(from: .string(adaAddress))
}

// MARK: - Asset Verification

/// Verifies that an asset exists on a specific address via Koios UTxO query.
///
/// - Parameters:
///   - fingerprint: The asset fingerprint (policyId.assetNameHex)
///   - address: The expected address
///   - koios: The Koios client
/// - Throws: ``AdaHandleError/adahandleAssetNotOnAddress(_:_:)`` if not found
public func verifyAssetOnAddress(
    fingerprint: String,
    address: String,
    koios: Koios
) async throws {
    let parts = fingerprint.split(separator: ".", maxSplits: 1)
    guard parts.count == 2 else {
        throw AdaHandleError.adahandleAPIError("Invalid fingerprint format: \(fingerprint)", nil)
    }
    
    let policyId = String(parts[0])
    let assetNameHex = String(parts[1])
    
    // Query asset UTxOs
    let response = try await withRetry() {
        try await koios.client.assetUtxos(
            Operations.AssetUtxos.Input(
                body: .json(.init(
                    _assetList: [[policyId, assetNameHex]],
                    _extended: true
                ))
            )
        )
    }
    
    let utxos = try response.ok.body.json
    
    // Check if any UTxO is at the expected address
    let found = utxos.contains { utxo in
        utxo.address == address
    }
    
    guard found else {
        throw AdaHandleError.adahandleAssetNotOnAddress(fingerprint, address)
    }
}

/// Verifies a virtual handle by cross-checking the datum with the Handles API response.
///
/// - Parameters:
///   - fingerprint: The asset fingerprint
///   - expectedAddress: The address from the Handles API
///   - network: The Cardano network
///   - koios: The Koios client
/// - Throws: ``AdaHandleError/adahandleAddressMismatch(_:_:)`` if addresses don't match
public func verifyVirtualHandle(
    fingerprint: String,
    expectedAddress: String,
    network: SwiftCardanoCore.Network,
    koios: Koios
) async throws {
    let parts = fingerprint.split(separator: ".", maxSplits: 1)
    guard parts.count == 2 else {
        throw AdaHandleError.adahandleAPIError("Invalid fingerprint format: \(fingerprint)", nil)
    }
    
    let policyId = String(parts[0])
    let assetNameHex = String(parts[1])
    
    // Query asset UTxOs with inline datum
    let response = try await withRetry() {
        try await koios.client.assetUtxos(
            Operations.AssetUtxos.Input(
                body: .json(.init(
                    _assetList: [[policyId, assetNameHex]],
                    _extended: true
                ))
            )
        )
    }
    
    let utxos = try response.ok.body.json
    
    guard utxos.count == 1,
          let inlineDatum = utxos.first?.inlineDatum?.value as? String else {
        throw AdaHandleError.adahandleAPIError("Could not find inline datum for virtual handle", nil)
    }
    
    // Extract address from datum
    guard let datumAddress = try extractResolvedAddressFromDatum(datumHex: inlineDatum, network: network) else {
        throw AdaHandleError.adahandleAPIError("Could not extract address from inline datum", nil)
    }
    
    // Verify addresses match
    guard datumAddress == expectedAddress else {
        throw AdaHandleError.adahandleAddressMismatch(expectedAddress, datumAddress)
    }
}

/// Extracts the resolved ADA address from a virtual handle's inline datum.
///
/// This is a heuristic parser that looks for the "resolved_addresses" key in the CBOR datum
/// and extracts the following address bytes.
///
/// - Parameters:
///   - datumHex: The hex-encoded inline datum
///   - network: The Cardano network for bech32 encoding
/// - Returns: The extracted bech32 address, or nil if extraction fails
public func extractResolvedAddressFromDatum(datumHex: String, network: SwiftCardanoCore.Network) throws -> String? {
    // Look for the resolved_addresses key in the datum
    guard let keyRange = datumHex.range(of: AdaHandleConstants.datumResolvedKeyHex) else {
        return nil
    }
    
    // Extract the portion after the key
    let afterKey = String(datumHex[keyRange.upperBound...])
    
    // Look for "Cada5839" pattern which indicates a Cardano address in CBOR
    // C = CBOR map, ada = "ada" key, 58 = byte string of length, 39 = 57 bytes
    guard let addrPattern = afterKey.range(of: "436164615839") else {
        return nil
    }
    
    let addrStart = addrPattern.upperBound
    guard let addrEnd = afterKey.index(addrStart, offsetBy: 114, limitedBy: afterKey.endIndex) else {
        return nil
    }
    let addrHex = String(afterKey[addrStart..<addrEnd])
    
    // Convert hex to address
    guard let addrData = Data(hexString: addrHex) else {
        return nil
    }
    
    // Convert to bech32
    let address = try Address(from: .bytes(addrData))
    return try address.toBech32()
}
