import Foundation
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoChain

@Suite("Evaluation redeemer keys")
struct RedeemerKeyTests {
    /// Every provider's name for a purpose, and the tag it stands for.
    @Test(arguments: [
        ("spend", RedeemerTag.spend), ("mint", .mint),
        ("cert", .cert), ("certificate", .cert), ("publish", .cert),
        ("reward", .reward), ("withdrawal", .reward), ("withdraw", .reward),
        ("voting", .voting), ("vote", .voting),
        ("proposing", .proposing), ("propose", .proposing), ("SPEND", .spend),
    ])
    func purposeNames(_ purpose: String, _ tag: RedeemerTag) throws {
        #expect(try LedgerValues.redeemerTag(purpose: purpose, "test") == tag)
    }

    /// The key is the one the transaction builder builds from a redeemer:
    /// `"\(tag.description()):\(index)"`.
    @Test func keysMatchTheTransactionBuilder() throws {
        let tags: [RedeemerTag] = [.spend, .mint, .cert, .reward, .voting, .proposing]
        for tag in tags {
            #expect(try LedgerValues.redeemerKey(purpose: tag.description(), index: 3, "test") == "\(tag.description()):3")
        }
        #expect(try LedgerValues.redeemerKey("withdrawal:7", "test") == "reward:7")
        #expect(try LedgerValues.redeemerKey("publish:0", "test") == "cert:0")
    }

    @Test(arguments: ["guard:0", "spend", "spend:x", "spend:-1", ":0"])
    func malformedKeysAreRejected(_ key: String) {
        #expect(throws: CardanoChainError.self) { try LedgerValues.redeemerKey(key, "test") }
    }
}
