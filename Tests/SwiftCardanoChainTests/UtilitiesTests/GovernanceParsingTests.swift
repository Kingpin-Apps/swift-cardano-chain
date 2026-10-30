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
            #expect(try GovernanceParsing.parseThreshold(0.51) == 0.51)
        }

        @Test("NSNumber passes through")
        func nsNumberPassthrough() throws {
            #expect(try GovernanceParsing.parseThreshold(NSNumber(value: 0.67)) == 0.67)
        }

        @Test("numeric string parses")
        func stringParses() throws {
            #expect(try GovernanceParsing.parseThreshold("0.75") == 0.75)
        }

        @Test("two-element rational array")
        func rationalArray() throws {
            #expect(try GovernanceParsing.parseThreshold([51, 100]) == 0.51)
        }

        @Test("rational dict with numerator/denominator")
        func rationalDict() throws {
            let raw: [String: Any] = ["numerator": 2, "denominator": 3]
            let parsed = try GovernanceParsing.parseThreshold(raw)
            #expect(abs(parsed - (2.0 / 3.0)) < 1e-9)
        }

        @Test("nil throws: a missing threshold is not 0")
        func nilThrows() {
            #expect(throws: CardanoChainError.self) { try GovernanceParsing.parseThreshold(nil) }
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
            let dict: [String: Any] = ["numerator": 1, "denominator": 0]
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
            #expect(GovernanceParsing.parseVote(42) == nil)
        }
    }

    @Suite("parseLovelace")
    struct ParseLovelaceTests {

        @Test("NSNumber passes through")
        func nsNumberPassthrough() throws {
            #expect(try GovernanceParsing.parseLovelace(NSNumber(value: 12345)) == 12345)
        }

        @Test("positive Int parses")
        func intParses() throws {
            #expect(try GovernanceParsing.parseLovelace(42) == 42)
        }

        @Test("numeric string parses")
        func stringParses() throws {
            #expect(try GovernanceParsing.parseLovelace("987654321") == 987_654_321)
        }

        @Test("nested {lovelace: number} unwraps")
        func nestedDictNumber() throws {
            let raw: [String: Any] = ["lovelace": 500_000_000]
            #expect(try GovernanceParsing.parseLovelace(raw) == 500_000_000)
        }

        @Test("nested {lovelace: string} unwraps")
        func nestedDictString() throws {
            let raw: [String: Any] = ["lovelace": "999"]
            #expect(try GovernanceParsing.parseLovelace(raw) == 999)
        }

        @Test("nil returns nil")
        func nilReturnsNil() throws {
            #expect(try GovernanceParsing.parseLovelace(nil) == nil)
        }

        static let badLovelace: [String] = ["not a number", "-5", "1.5", "18446744073709551616"]

        @Test("a present but invalid amount throws", arguments: badLovelace)
        func invalidThrows(_ raw: String) {
            #expect(throws: CardanoChainError.self) { try GovernanceParsing.parseLovelace(raw) }
        }

        @Test("a negative or fractional number throws")
        func negativeNumberThrows() {
            #expect(throws: CardanoChainError.self) { try GovernanceParsing.parseLovelace(-5) }
            #expect(throws: CardanoChainError.self) { try GovernanceParsing.parseLovelace(NSNumber(value: 1.5)) }
        }
    }
}
