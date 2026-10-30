import Foundation
import SwiftCardanoCore

/// Shared parsing helpers used by the backends that decode governance JSON
/// (cardano-cli, Koios, Yaci). Numbers are read exactly from ``ChainJSON``.
enum GovernanceParsing {
    /// Parse a quorum / voting threshold that may arrive as:
    /// - a JSON number (e.g. `0.51`)
    /// - a two-element rational array (e.g. `[51, 100]`)
    /// - an object (`{"numerator": 51, "denominator": 100}`)
    /// - a string ("0.51")
    ///
    /// The value is read exactly and must lie in `[0, 1]`.
    ///
    /// - Returns: `nil` when the value is absent or `null` (no committee).
    /// - Throws: ``CardanoChainError/valueError(_:)`` when the value is
    ///   present but is not a unit interval.
    static func parseThreshold(_ json: ChainJSON?) throws -> UnitInterval? {
        var value = json
        if let pair = json?.array {
            guard pair.count == 2 else {
                throw CardanoChainError.valueError("Threshold \(pair) is not a [numerator, denominator] pair")
            }
            value = .object(["numerator": pair[0], "denominator": pair[1]])
        }
        return try LedgerValues.unitInterval(json: value, "threshold")
    }

    /// Parse a Vote enum from a string ("yes" / "no" / "abstain") or the
    /// `voteyes` / `voteno` / `voteabstain` variants seen in cardano-cli JSON.
    /// Case-insensitive. Returns `nil` for unrecognized input.
    static func parseVote(_ text: String?) -> Vote? {
        switch text?.lowercased() {
        case "yes", "voteyes": .yes
        case "no", "voteno": .no
        case "abstain", "voteabstain": .abstain
        default: nil
        }
    }

    /// Parse a lovelace value that may arrive as a number, a numeric string,
    /// or an object wrapping the `lovelace` key (e.g. `{"lovelace": 123}`).
    ///
    /// - Returns: `nil` when the value is absent (`nil` or `null`).
    /// - Throws: ``CardanoChainError/valueError(_:)`` when it is present but
    ///   negative, fractional, too large or not a number.
    static func parseLovelace(_ json: ChainJSON?) throws -> UInt64? {
        if let object = json?.object {
            guard let lovelace = object["lovelace"] else {
                throw CardanoChainError.valueError("Lovelace object \(object) has no lovelace key")
            }
            return try parseLovelace(lovelace)
        }
        return try LedgerValues.integer(json: json, as: UInt64.self, "lovelace")
    }

    /// Parse lovelace written as integer text; `nil` when absent.
    static func parseLovelace(_ text: String?) throws -> UInt64? {
        try text.map { try LedgerValues.integer(text: $0, as: UInt64.self, "lovelace") }
    }
}
