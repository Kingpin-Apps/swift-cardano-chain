import Foundation
import SwiftCardanoCore

/// Shared parsing helpers used by every backend that decodes governance JSON
/// from cardano-cli, Koios, or Blockfrost. Lifting these out keeps each
/// backend's mapping code focused on the response shape rather than the
/// recurring "is this number a `Double`, a rational, or a quoted string"
/// detail.
enum GovernanceParsing {
    /// Parse a quorum / voting threshold that may arrive as:
    /// - a JSON number (e.g. `0.51`)
    /// - a two-element rational array (e.g. `[51, 100]`)
    /// - an object (`{"numerator": 51, "denominator": 100}`)
    /// - a string ("0.51")
    ///
    /// The value is read exactly and must lie in `[0, 1]`.
    ///
    /// - Throws: ``CardanoChainError/valueError(_:)`` when the value is
    ///   missing or is not a unit interval; a missing threshold is not 0.
    static func parseThreshold(_ any: Any?) throws -> Double {
        var value = any
        if let arr = any as? [Any] {
            guard arr.count == 2 else {
                throw CardanoChainError.valueError("Threshold \(arr) is not a [numerator, denominator] pair")
            }
            value = ["numerator": arr[0], "denominator": arr[1]] as [String: Any]
        }
        guard let interval = try LedgerValues.unitInterval(json: value, "threshold") else {
            throw CardanoChainError.valueError("Threshold is missing")
        }
        return Double(interval.numerator) / Double(interval.denominator)
    }

    /// Parse a Vote enum from a string ("yes" / "no" / "abstain") or the
    /// `voteyes` / `voteno` / `voteabstain` variants seen in cardano-cli JSON.
    /// Case-insensitive. Returns `nil` for unrecognized input.
    static func parseVote(_ any: Any?) -> Vote? {
        guard let s = (any as? String)?.lowercased() else { return nil }
        switch s {
        case "yes", "voteyes": return .yes
        case "no", "voteno": return .no
        case "abstain", "voteabstain": return .abstain
        default: return nil
        }
    }

    /// Parse a lovelace value that may arrive as a number, a numeric string,
    /// or an object wrapping the `lovelace` key (e.g. `{"lovelace": 123}`).
    ///
    /// - Returns: `nil` when the value is absent (`nil` or `null`).
    /// - Throws: ``CardanoChainError/valueError(_:)`` when it is present but
    ///   negative, fractional, too large or not a number.
    static func parseLovelace(_ any: Any?) throws -> UInt64? {
        if let dict = any as? [String: Any] {
            guard let lovelace = dict["lovelace"] else {
                throw CardanoChainError.valueError("Lovelace object \(dict) has no lovelace key")
            }
            return try parseLovelace(lovelace)
        }
        return try LedgerValues.integer(json: any, as: UInt64.self, "lovelace")
    }
}
