import Foundation
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoChain

@Suite("GovernanceParsing")
struct GovernanceParsingTests {

    @Suite("parseThreshold")
    struct ParseThresholdTests {

        @Test("Double passes through")
        func doublePassthrough() throws {
            #expect(try GovernanceParsing.parseThreshold(0.51) == unit(51, 100))
        }

        @Test("a decimal with more digits than a Double holds is exact")
        func exactDecimal() throws {
            let value = ChainJSON.number(Decimal(string: "0.1234567890123456789")!)
            #expect(try GovernanceParsing.parseThreshold(value) == unit(1_234_567_890_123_456_789, 10_000_000_000_000_000_000))
        }

        @Test("numeric string parses")
        func stringParses() throws {
            #expect(try GovernanceParsing.parseThreshold("0.75") == unit(3, 4))
        }

        @Test("two-element rational array")
        func rationalArray() throws {
            #expect(try GovernanceParsing.parseThreshold([51, 100]) == unit(51, 100))
        }

        @Test("rational dict with numerator/denominator")
        func rationalDict() throws {
            let raw: ChainJSON = ["numerator": 2, "denominator": 3]
            #expect(try GovernanceParsing.parseThreshold(raw) == unit(2, 3))
        }

        @Test("absent or null is nil: no committee, not a quorum of 0")
        func absentIsNil() throws {
            #expect(try GovernanceParsing.parseThreshold(nil) == nil)
            #expect(try GovernanceParsing.parseThreshold(ChainJSON.null) == nil)
        }

        @Test("unparsable value throws")
        func garbageThrows() {
            #expect(throws: CardanoChainError.self) {
                try GovernanceParsing.parseThreshold(["not", "a", "rational"])
            }
        }

        @Test("zero denominator throws")
        func zeroDenominator() {
            #expect(throws: CardanoChainError.self) { try GovernanceParsing.parseThreshold([1, 0]) }
            let dict: ChainJSON = ["numerator": 1, "denominator": 0]
            #expect(throws: CardanoChainError.self) { try GovernanceParsing.parseThreshold(dict) }
        }

        @Test("above one throws")
        func aboveOne() {
            #expect(throws: CardanoChainError.self) { try GovernanceParsing.parseThreshold(1.5) }
        }
    }

    @Suite("parseVote")
    struct ParseVoteTests {

        @Test("yes / no / abstain")
        func canonicalNames() {
            #expect(GovernanceParsing.parseVote("yes") == .yes)
            #expect(GovernanceParsing.parseVote("no") == .no)
            #expect(GovernanceParsing.parseVote("abstain") == .abstain)
        }

        @Test("vote-prefixed aliases")
        func voteAliases() {
            #expect(GovernanceParsing.parseVote("voteyes") == .yes)
            #expect(GovernanceParsing.parseVote("voteno") == .no)
            #expect(GovernanceParsing.parseVote("voteabstain") == .abstain)
        }

        @Test("case-insensitive")
        func caseInsensitive() {
            #expect(GovernanceParsing.parseVote("YES") == .yes)
            #expect(GovernanceParsing.parseVote("Abstain") == .abstain)
            #expect(GovernanceParsing.parseVote("VoteNo") == .no)
        }

        @Test("nil returns nil")
        func nilReturnsNil() {
            #expect(GovernanceParsing.parseVote(nil) == nil)
        }

        @Test("unknown string returns nil")
        func unknownReturnsNil() {
            #expect(GovernanceParsing.parseVote("maybe") == nil)
        }
    }

    @Suite("parseLovelace")
    struct ParseLovelaceTests {

        @Test("UInt64.max is exact")
        func maxIsExact() throws {
            #expect(try GovernanceParsing.parseLovelace(ChainJSON.number(Decimal(string: "18446744073709551615")!)) == UInt64.max)
        }

        @Test("positive Int parses")
        func intParses() throws {
            #expect(try GovernanceParsing.parseLovelace(42 as ChainJSON) == 42)
        }

        @Test("numeric string parses")
        func stringParses() throws {
            #expect(try GovernanceParsing.parseLovelace("987654321" as ChainJSON) == 987_654_321)
            #expect(try GovernanceParsing.parseLovelace("987654321" as String) == 987_654_321)
        }

        @Test("nested {lovelace: number} unwraps")
        func nestedDictNumber() throws {
            let raw: ChainJSON = ["lovelace": 500_000_000]
            #expect(try GovernanceParsing.parseLovelace(raw) == 500_000_000)
        }

        @Test("nested {lovelace: string} unwraps")
        func nestedDictString() throws {
            let raw: ChainJSON = ["lovelace": "999"]
            #expect(try GovernanceParsing.parseLovelace(raw) == 999)
        }

        @Test("nil returns nil")
        func nilReturnsNil() throws {
            #expect(try GovernanceParsing.parseLovelace(nil as ChainJSON?) == nil)
        }

        static let badLovelace: [String] = ["not a number", "-5", "1.5", "18446744073709551616"]

        @Test("a present but invalid amount throws", arguments: badLovelace)
        func invalidThrows(_ raw: String) {
            #expect(throws: CardanoChainError.self) { try GovernanceParsing.parseLovelace(ChainJSON.string(raw)) }
        }

        @Test("a negative or fractional number throws")
        func negativeNumberThrows() {
            #expect(throws: CardanoChainError.self) { try GovernanceParsing.parseLovelace(-5 as ChainJSON) }
            #expect(throws: CardanoChainError.self) { try GovernanceParsing.parseLovelace(1.5 as ChainJSON) }
            #expect(throws: CardanoChainError.self) { try GovernanceParsing.parseLovelace(true as ChainJSON) }
        }
    }
}
