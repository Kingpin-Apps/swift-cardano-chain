import Foundation
import SwiftCardanoCore

/// Anchors, URLs and relays as a backend reports them.
///
/// Absent is `nil` where the caller's API has an optional for it; present but
/// invalid throws. Data that is on chain always passes these checks, so a
/// failure means the backend sent something corrupt — it is never dropped or
/// replaced with a made-up value.
extension LedgerValues {

    // MARK: URLs and hashes

    /// `text` as a ledger URL, or an error when it is longer than 128 bytes.
    static func url(_ text: String, _ what: @autoclosure () -> String) throws -> Url {
        do {
            return try Url(text)
        } catch {
            throw CardanoChainError.valueError("\(what()): \(error)")
        }
    }

    /// The bytes of a 32-byte hash written in hex, or an error when `hex` is
    /// not hex or not 32 bytes.
    static func hash32(hex: String, _ what: @autoclosure () -> String) throws -> Data {
        guard hex.count == 64, let data = Data(hexString: hex) else {
            throw CardanoChainError.valueError("\(what()): \(hex) is not a 32-byte hex hash")
        }
        return data
    }

    /// `data` as an anchor data hash, or an error when it is not 32 bytes.
    static func anchorDataHash(_ data: Data, _ what: @autoclosure () -> String) throws -> AnchorDataHash {
        guard data.count == 32 else {
            throw CardanoChainError.valueError("\(what()): an anchor data hash is 32 bytes, got \(data.count)")
        }
        return AnchorDataHash(payload: data)
    }

    // MARK: Anchors

    /// An anchor from its URL and hex data hash, or an error when either is invalid.
    static func anchor(url: String, hash: String, _ what: @autoclosure () -> String) throws -> Anchor {
        let what = what()
        return Anchor(
            anchorUrl: try self.url(url, "\(what) URL"),
            anchorDataHash: AnchorDataHash(payload: try hash32(hex: hash, "\(what) data hash"))
        )
    }

    /// An anchor from a URL and hex data hash that a backend may leave out.
    ///
    /// Each half is a string, or `nil`/JSON null for absent. `nil` when both
    /// halves are absent or empty; an error when only one is there, when either
    /// is not a string, or when either is invalid.
    static func optionalAnchor(url: Any?, hash: Any?, _ what: @autoclosure () -> String) throws -> Anchor? {
        let what = what()
        let url = try optionalString(url, "\(what) URL")
        let hash = try optionalString(hash, "\(what) data hash")
        switch (url, hash) {
        case (nil, nil), ("", ""), ("", nil), (nil, ""):
            return nil
        case let (url?, hash?):
            return try anchor(url: url, hash: hash, what)
        default:
            throw CardanoChainError.valueError("\(what) has a URL or a data hash but not both")
        }
    }

    /// An anchor written as JSON: `{"url": …, "dataHash": …}` (also read:
    /// `anchorDataHash`, and Yaci's `anchor_url`/`anchor_data_hash` spellings).
    ///
    /// `nil` for no value or JSON null; an error for anything that is not such
    /// an object with both fields valid.
    static func anchor(json any: Any?, _ what: @autoclosure () -> String) throws -> Anchor? {
        let what = what()
        guard let any, !(any is NSNull) else { return nil }
        guard let object = any as? [String: Any] else {
            throw CardanoChainError.valueError("\(what) is not an object: \(any)")
        }
        let url = object["url"] ?? object["anchorUrl"] ?? object["anchor_url"]
        let hash = object["dataHash"] ?? object["anchorDataHash"] ?? object["anchor_data_hash"] ?? object["hash"]
        return try anchor(
            url: required(optionalString(url, "\(what) URL"), "\(what) URL"),
            hash: required(optionalString(hash, "\(what) data hash"), "\(what) data hash"),
            what
        )
    }

    // MARK: Relays

    /// A single-host-name relay, or an error when the DNS name is too long.
    static func singleHostName(port: Int?, dnsName: String, _ what: @autoclosure () -> String) throws -> SwiftCardanoCore.Relay {
        do {
            return .singleHostName(try SingleHostName(port: port, dnsName: dnsName))
        } catch {
            throw CardanoChainError.valueError("\(what()): \(error)")
        }
    }

    /// A multi-host-name relay, or an error when the DNS name is too long.
    static func multiHostName(dnsName: String, _ what: @autoclosure () -> String) throws -> SwiftCardanoCore.Relay {
        do {
            return .multiHostName(try MultiHostName(dnsName: dnsName))
        } catch {
            throw CardanoChainError.valueError("\(what()): \(error)")
        }
    }

    /// An IPv4 address, or an error when `text` is not one.
    static func ipv4(_ text: String, _ what: @autoclosure () -> String) throws -> IPv4Address {
        guard let address = IPv4Address(text) else {
            throw CardanoChainError.valueError("\(what()): \(text) is not an IPv4 address")
        }
        return address
    }

    /// An IPv6 address, or an error when `text` is not one.
    static func ipv6(_ text: String, _ what: @autoclosure () -> String) throws -> IPv6Address {
        guard let address = IPv6Address(text) else {
            throw CardanoChainError.valueError("\(what()): \(text) is not an IPv6 address")
        }
        return address
    }

    /// A relay a backend reports as a flat row of optional fields, the shape
    /// db-sync stores: an address relay when it has an IP, else a named relay.
    ///
    /// A row with no host at all is a single-host-address relay with neither
    /// address, which the ledger allows — not a row to drop.
    static func relay(
        port: Int?, ipv4: String?, ipv6: String?, dnsName: String?, srvName: String?,
        _ what: @autoclosure () -> String
    ) throws -> SwiftCardanoCore.Relay {
        let what = what()
        let v4 = try ipv4.map { try self.ipv4($0, "\(what) IPv4") }
        let v6 = try ipv6.map { try self.ipv6($0, "\(what) IPv6") }
        if v4 != nil || v6 != nil {
            return .singleHostAddr(SingleHostAddr(port: port, ipv4: v4, ipv6: v6))
        }
        if let dnsName {
            return try singleHostName(port: port, dnsName: dnsName, "\(what) DNS name")
        }
        if let srvName {
            return try multiHostName(dnsName: srvName, "\(what) SRV name")
        }
        return .singleHostAddr(SingleHostAddr(port: port, ipv4: nil, ipv6: nil))
    }

    // MARK: Helpers

    /// `any` as a string: `nil` for no value or JSON null, an error for anything else.
    private static func optionalString(_ any: Any?, _ what: @autoclosure () -> String) throws -> String? {
        guard let any, !(any is NSNull) else { return nil }
        guard let string = any as? String else {
            throw CardanoChainError.valueError("\(what()) is not a string: \(any)")
        }
        return string
    }
}
