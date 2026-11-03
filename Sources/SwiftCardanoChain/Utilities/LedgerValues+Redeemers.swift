import Foundation
import SwiftCardanoCore

extension LedgerValues {
    /// Every name a provider uses for a redeemer purpose: the ledger's own
    /// (`RedeemerTag.description()`), Ogmios v6's (`publish`, `withdraw`,
    /// `vote`, `propose`) and Ogmios v5's, which Blockfrost, Koios and Yaci
    /// still return (`certificate`, `withdrawal`).
    private static let redeemerTags: [String: RedeemerTag] = [
        "spend": .spend,
        "mint": .mint,
        "cert": .cert, "certificate": .cert, "publish": .cert,
        "reward": .reward, "withdrawal": .reward, "withdraw": .reward,
        "voting": .voting, "vote": .voting,
        "proposing": .proposing, "propose": .proposing,
    ]

    /// The redeemer tag a provider's purpose name stands for.
    static func redeemerTag(purpose: String, _ what: @autoclosure () -> String) throws -> RedeemerTag {
        guard let tag = redeemerTags[purpose.lowercased()] else {
            throw CardanoChainError.valueError("\(what()): \(purpose) is not a redeemer purpose")
        }
        return tag
    }

    /// The key evaluation results are stored under: `<tag>:<index>` with the
    /// tag as ``RedeemerTag/description()``, which is how the transaction
    /// builder looks each redeemer's execution units up.
    static func redeemerKey(
        purpose: String, index: some BinaryInteger, _ what: @autoclosure () -> String
    ) throws -> String {
        let what = what()
        let tag = try redeemerTag(purpose: purpose, what)
        let index: UInt64 = try index.checked("\(what) index")
        return "\(tag.description()):\(index)"
    }

    /// A provider's `<purpose>:<index>` key in the form ``redeemerKey(purpose:index:_:)`` gives.
    static func redeemerKey(_ key: String, _ what: @autoclosure () -> String) throws -> String {
        let what = what()
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let index = UInt64(parts[1]) else {
            throw CardanoChainError.valueError("\(what): \(key) is not purpose:index")
        }
        return try redeemerKey(purpose: parts[0], index: index, what)
    }
}
