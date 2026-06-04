import Foundation
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoChain

@Suite("GovernanceParsing")
struct GovernanceParsingTests {

    @Suite("parseThreshold")
    struct ParseThresholdTests {

        @Test("Double passes through")
        func doublePassthrough() {
            #expect(GovernanceParsing.parseThreshold(0.51) == 0.51)
        }

        @Test("NSNumber passes through")
        func nsNumberPassthrough() {
            #expect(GovernanceParsing.parseThreshold(NSNumber(value: 0.67)) == 0.67)
        }

        @Test("numeric string parses")
        func stringParses() {
            #expect(GovernanceParsing.parseThreshold("0.75") == 0.75)
        }

        @Test("two-element rational array")
        func rationalArray() {
            #expect(GovernanceParsing.parseThreshold([51, 100]) == 0.51)
        }

        @Test("rational dict with numerator/denominator")
        func rationalDict() {
            let raw: [String: Any] = ["numerator": 2, "denominator": 3]
            let parsed = GovernanceParsing.parseThreshold(raw)
            #expect(abs(parsed - (2.0 / 3.0)) < 1e-9)
        }

        @Test("nil returns 0")
        func nilReturnsZero() {
            #expect(GovernanceParsing.parseThreshold(nil) == 0.0)
        }

        @Test("unparsable value returns 0")
        func garbageReturnsZero() {
            #expect(GovernanceParsing.parseThreshold(["not", "a", "rational"]) == 0.0)
        }

        @Test("zero denominator falls through to 0")
        func zeroDenominator() {
            #expect(GovernanceParsing.parseThreshold([1, 0]) == 0.0)
            let dict: [String: Any] = ["numerator": 1, "denominator": 0]
            #expect(GovernanceParsing.parseThreshold(dict) == 0.0)
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
        func nsNumberPassthrough() {
            #expect(GovernanceParsing.parseLovelace(NSNumber(value: 12345)) == 12345)
        }

        @Test("positive Int parses")
        func intParses() {
            #expect(GovernanceParsing.parseLovelace(42) == 42)
        }

        @Test("numeric string parses")
        func stringParses() {
            #expect(GovernanceParsing.parseLovelace("987654321") == 987_654_321)
        }

        @Test("nested {lovelace: number} unwraps")
        func nestedDictNumber() {
            let raw: [String: Any] = ["lovelace": 500_000_000]
            #expect(GovernanceParsing.parseLovelace(raw) == 500_000_000)
        }

        @Test("nested {lovelace: string} unwraps")
        func nestedDictString() {
            let raw: [String: Any] = ["lovelace": "999"]
            #expect(GovernanceParsing.parseLovelace(raw) == 999)
        }

        @Test("nil returns nil")
        func nilReturnsNil() {
            #expect(GovernanceParsing.parseLovelace(nil) == nil)
        }

        @Test("non-numeric string returns nil")
        func nonNumericString() {
            #expect(GovernanceParsing.parseLovelace("not a number") == nil)
        }
    }
}
