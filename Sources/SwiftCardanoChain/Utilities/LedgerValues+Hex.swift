import Foundation
import SwiftCardanoCore

/// Hex text from a backend, read strictly.
///
/// Core's `hexStringToData` pads odd-length text and turns non-hex text into
/// empty bytes, and `Data(hexString:)` drops a trailing odd digit and accepts a
/// sign; a hash read that way can silently become the wrong bytes. These throw
/// instead, and the typed forms also check the length the ledger requires.
extension LedgerValues {

    /// The bytes `text` spells in hex, or an error when it is odd-length or
    /// holds anything but hex digits.
    static func hexBytes(_ text: String, _ what: @autoclosure () -> String) throws -> Data {
        let utf8 = Array(text.utf8)
        guard utf8.count % 2 == 0 else {
            throw CardanoChainError.valueError("\(what()): \(text) is not hex (odd length)")
        }
        var data = Data(capacity: utf8.count / 2)
        var index = 0
        while index < utf8.count {
            guard let high = nibble(utf8[index]), let low = nibble(utf8[index + 1]) else {
                throw CardanoChainError.valueError("\(what()): \(text) is not hex")
            }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    /// `text` as a `T` (a hash or key hash), or an error when it is not hex or
    /// not the length `T` must be (28 bytes for a key or script hash, 32 for a
    /// transaction id, datum or anchor hash).
    static func hash<T: ConstrainedBytes>(
        hex text: String, as type: T.Type = T.self, _ what: @autoclosure () -> String
    ) throws -> T {
        let what = what()
        let data = try hexBytes(text, what)
        guard data.count >= T.minSize, data.count <= T.maxSize else {
            let size = T.minSize == T.maxSize ? "\(T.maxSize)" : "\(T.minSize) to \(T.maxSize)"
            throw CardanoChainError.valueError("\(what): \(text) is \(data.count) bytes, not \(size)")
        }
        return try T(payload: data)
    }

    /// The 28 bytes of a key, script or pool key hash, from hex.
    static func hash28(hex text: String, _ what: @autoclosure () -> String) throws -> Data {
        try hash(hex: text, as: VerificationKeyHash.self, what()).payload
    }

    /// The policy id and asset name of an asset unit, the policy's 28-byte
    /// hash followed by up to 32 bytes of name, in hex.
    static func asset(unit text: String, _ what: @autoclosure () -> String) throws -> (ScriptHash, AssetName) {
        let what = what()
        let data = try hexBytes(text, what)
        guard data.count >= SCRIPT_HASH_SIZE, data.count <= SCRIPT_HASH_SIZE + 32 else {
            throw CardanoChainError.valueError("\(what): \(text) is not a policy id and asset name")
        }
        return (
            ScriptHash(payload: Data(data.prefix(SCRIPT_HASH_SIZE))),
            try AssetName(payload: Data(data.dropFirst(SCRIPT_HASH_SIZE)))
        )
    }

    /// An asset name from its hex, or an error when it is not hex or longer than 32 bytes.
    static func assetName(hex text: String, _ what: @autoclosure () -> String) throws -> AssetName {
        let what = what()
        let data = try hexBytes(text, what)
        guard data.count <= 32 else {
            throw CardanoChainError.valueError("\(what): \(text) is longer than 32 bytes")
        }
        return try AssetName(payload: data)
    }

    /// A key-hash or script-hash credential from its kind and hex hash.
    static func credential(isScript: Bool, hex: String, _ what: @autoclosure () -> String) throws -> CredentialType {
        isScript
            ? .scriptHash(try hash(hex: hex, as: ScriptHash.self, what()))
            : .verificationKeyHash(try hash(hex: hex, as: VerificationKeyHash.self, what()))
    }

    /// A credential written as JSON the ledger's way: `{"keyHash": hex}` or
    /// `{"scriptHash": hex}`, or as a map key `keyHash-<hex>` / `scriptHash-<hex>`.
    static func credential(json any: Any?, _ what: @autoclosure () -> String) throws -> CredentialType {
        let what = what()
        if let key = any as? String {
            if key.hasPrefix("keyHash-") {
                return try credential(isScript: false, hex: String(key.dropFirst("keyHash-".count)), what)
            }
            if key.hasPrefix("scriptHash-") {
                return try credential(isScript: true, hex: String(key.dropFirst("scriptHash-".count)), what)
            }
        } else if let object = any as? [String: Any], object.count == 1 {
            if let hex = object["keyHash"] as? String {
                return try credential(isScript: false, hex: hex, what)
            }
            if let hex = object["scriptHash"] as? String {
                return try credential(isScript: true, hex: hex, what)
            }
        }
        throw CardanoChainError.valueError("\(what): \(String(describing: any)) is not a credential")
    }

    /// A reward account written as JSON the ledger's way:
    /// `{"network": "Mainnet" | "Testnet", "credential": {"keyHash" | "scriptHash": hex}}`.
    static func rewardAccount(json any: Any?, _ what: @autoclosure () -> String) throws -> RewardAccount {
        let what = what()
        guard let object = any as? [String: Any],
            let network = object["network"] as? String
        else {
            throw CardanoChainError.valueError("\(what): \(String(describing: any)) is not a reward account")
        }
        let networkBit: UInt8
        switch network.lowercased() {
        case "mainnet": networkBit = 1
        case "testnet": networkBit = 0
        default: throw CardanoChainError.valueError("\(what): unknown network \(network)")
        }
        // Header: high nibble 0xE for a key hash, 0xF for a script hash; low nibble the network.
        switch try credential(json: object["credential"], "\(what) credential") {
        case .verificationKeyHash(let hash): return Data([0xE0 | networkBit]) + hash.payload
        case .scriptHash(let hash): return Data([0xF0 | networkBit]) + hash.payload
        }
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
