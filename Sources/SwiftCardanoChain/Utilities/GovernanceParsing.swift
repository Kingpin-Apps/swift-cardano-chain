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
    /// Returns `0.0` when the value is missing or unparsable.
    static func parseThreshold(_ any: Any?) -> Double {
        guard let any else { return 0.0 }
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String, let d = Double(s) { return d }
        if let arr = any as? [Any], arr.count >= 2,
           let num = (arr[0] as? NSNumber)?.doubleValue,
           let den = (arr[1] as? NSNumber)?.doubleValue, den != 0 {
            return num / den
        }
        if let dict = any as? [String: Any],
           let num = (dict["numerator"] as? NSNumber)?.doubleValue,
           let den = (dict["denominator"] as? NSNumber)?.doubleValue, den != 0 {
            return num / den
        }
        return 0.0
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
    static func parseLovelace(_ any: Any?) -> UInt64? {
        guard let any else { return nil }
        if let n = any as? NSNumber { return n.uint64Value }
        if let i = any as? Int, i >= 0 { return UInt64(i) }
        if let s = any as? String, let u = UInt64(s) { return u }
        if let dict = any as? [String: Any], let lovelace = dict["lovelace"] {
            return parseLovelace(lovelace)
        }
        return nil
    }
}
