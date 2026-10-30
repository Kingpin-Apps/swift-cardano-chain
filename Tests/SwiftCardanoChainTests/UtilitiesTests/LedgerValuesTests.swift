import Foundation
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoChain

/// A decimal and the reduced fraction it is exactly.
struct DecimalCase: Sendable, CustomTestStringConvertible {
    let value: Double
    let numerator: UInt64
    let denominator: UInt64
    var testDescription: String { "\(value) = \(numerator)/\(denominator)" }
}

/// Text, from an API, and the reduced fraction it is exactly.
struct TextCase: Sendable, CustomTestStringConvertible {
    let text: String
    let numerator: UInt64
    let denominator: UInt64
    var testDescription: String { "\"\(text)\" = \(numerator)/\(denominator)" }
}

@Suite("LedgerValues converts API numbers to the ledger's exact types")
struct LedgerValuesTests {

    // MARK: Decimals

    /// Mainnet's parameters as Blockfrost, Koios, Yaci and cardano-cli send
    /// them: JSON decimals, which their clients read as Doubles.
    static let decimals: [DecimalCase] = [
        DecimalCase(value: 0.0577, numerator: 577, denominator: 10_000),
        DecimalCase(value: 0.0000721, numerator: 721, denominator: 10_000_000),
        DecimalCase(value: 0.003, numerator: 3, denominator: 1000),
        DecimalCase(value: 0.2, numerator: 1, denominator: 5),
        DecimalCase(value: 0.3, numerator: 3, denominator: 10),
        DecimalCase(value: 0.05, numerator: 1, denominator: 20),
        DecimalCase(value: 0.67, numerator: 67, denominator: 100),
        DecimalCase(value: 0.51, numerator: 51, denominator: 100),
        DecimalCase(value: 0, numerator: 0, denominator: 1),
        DecimalCase(value: 1, numerator: 1, denominator: 1),
        DecimalCase(value: 4.4e-07, numerator: 11, denominator: 25_000_000),
    ]

    @Test("A decimal becomes the exact unit interval it is", arguments: decimals)
    func unitIntervalFromDouble(_ c: DecimalCase) throws {
        let interval = try LedgerValues.unitInterval(try #require(Decimal(string: "\(c.value)")), "test")
        #expect(interval.numerator == c.numerator)
        #expect(interval.denominator == c.denominator)
    }

    @Test("A decimal becomes the exact non-negative interval it is", arguments: decimals)
    func nonNegativeIntervalFromDouble(_ c: DecimalCase) throws {
        let interval = try LedgerValues.nonNegativeInterval(try #require(Decimal(string: "\(c.value)")), "test")
        #expect(interval.numerator == c.numerator)
        #expect(interval.denominator == c.denominator)
    }

    @Test("A Decimal is read exactly, digits a Double would not keep included")
    func unitIntervalFromDecimal() throws {
        let value = try #require(Decimal(string: "0.1234567890123456789"))
        let interval = try LedgerValues.unitInterval(value, "test")
        #expect(interval.numerator == 1_234_567_890_123_456_789)
        #expect(interval.denominator == 10_000_000_000_000_000_000)
    }

    @Test("A non-negative interval may exceed one")
    func nonNegativeAboveOne() throws {
        #expect(try LedgerValues.nonNegativeInterval(15.0, "test") == NonNegativeInterval(numerator: 15, denominator: 1))
        #expect(try LedgerValues.nonNegativeInterval(1.2, "test") == NonNegativeInterval(numerator: 6, denominator: 5))
    }

    // MARK: Text

    /// Ogmios sends fractions; Koios, Yaci and genesis files send decimal text.
    static let texts: [TextCase] = [
        TextCase(text: "1/2", numerator: 1, denominator: 2),
        TextCase(text: "1/20", numerator: 1, denominator: 20),
        TextCase(text: "577/10000", numerator: 577, denominator: 10_000),
        TextCase(text: "721/10000000", numerator: 721, denominator: 10_000_000),
        TextCase(text: "6/10", numerator: 3, denominator: 5),
        TextCase(text: "0/1", numerator: 0, denominator: 1),
        TextCase(text: "0.05", numerator: 1, denominator: 20),
        TextCase(text: "0.0577", numerator: 577, denominator: 10_000),
        TextCase(text: "7.21e-05", numerator: 721, denominator: 10_000_000),
        TextCase(text: "1", numerator: 1, denominator: 1),
    ]

    @Test("Text becomes the exact, reduced unit interval it is", arguments: texts)
    func unitIntervalFromText(_ c: TextCase) throws {
        let interval = try LedgerValues.unitInterval(text: c.text, "test")
        #expect(interval.numerator == c.numerator)
        #expect(interval.denominator == c.denominator)
    }

    @Test("A fraction with a large numerator and denominator is reduced to fit")
    func largeFractionReduced() throws {
        // 2^64 / 2^65 does not fit two UInt64s until it is reduced.
        let interval = try LedgerValues.unitInterval(text: "18446744073709551616/36893488147419103232", "test")
        #expect(interval == UnitInterval(numerator: 1, denominator: 2))
    }

    // MARK: Refusals

    static let badUnitTexts: [String] = [
        "3/2",          // above one
        "1/0",          // no denominator
        "-1/2",         // negative
        "1/2/3",        // not a fraction
        "a/b",
        "",
        "1.5",          // above one
        "-0.1",         // negative
        "abc",
        "18446744073709551617/18446744073709551629",  // does not fit, and cannot be reduced to
    ]

    @Test("Text that is not a unit interval is refused", arguments: badUnitTexts)
    func badUnitText(_ text: String) {
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.unitInterval(text: text, "test")
        }
    }

    static let badDoubles: [Decimal] = [-0.5, 1.7, .nan]

    @Test("A decimal outside the unit interval is refused, not clamped", arguments: badDoubles)
    func badUnitDouble(_ value: Decimal) {
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.unitInterval(value, "test")
        }
    }

    @Test("A decimal too precise for two UInt64s is refused, not rounded")
    func tooPrecise() throws {
        let value = try #require(Decimal(string: "0.000000000000000000001"))
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.unitInterval(value, "test")
        }
    }

    // MARK: Untyped JSON

    @Test("Values JSONSerialization reads are converted exactly")
    func jsonSerializationValues() throws {
        let json = #"""
            {"price": 0.0577, "steps": 7.21e-05, "quorum": {"numerator": 2, "denominator": 3},
             "text": "0.51", "percent": 150, "big": 18446744073709551615, "half": 150.5, "none": null}
            """#
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        #expect(try LedgerValues.nonNegativeInterval(json: object["price"], "price") == NonNegativeInterval(numerator: 577, denominator: 10_000))
        #expect(try LedgerValues.nonNegativeInterval(json: object["steps"], "steps") == NonNegativeInterval(numerator: 721, denominator: 10_000_000))
        #expect(try LedgerValues.unitInterval(json: object["quorum"], "quorum") == UnitInterval(numerator: 2, denominator: 3))
        #expect(try LedgerValues.unitInterval(json: object["text"], "text") == UnitInterval(numerator: 51, denominator: 100))
        #expect(try LedgerValues.unitInterval(json: object["none"], "none") == nil)
        #expect(try LedgerValues.unitInterval(json: object["missing"], "missing") == nil)
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.unitInterval(json: object["percent"], "percent")
        }

        #expect(try LedgerValues.integer(json: object["percent"], as: UInt16.self, "percent") == 150)
        #expect(try LedgerValues.integer(json: object["big"], as: UInt64.self, "big") == UInt64.max)
        #expect(try LedgerValues.bigInt(json: object["big"], "big")?.description == "18446744073709551615")
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.integer(json: object["half"], as: UInt16.self, "half")
        }
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.integer(json: object["big"], as: Int64.self, "big")
        }
    }

    @Test("A JSON boolean is not read as 0 or 1")
    func jsonBooleans() throws {
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(#"{"yes": true, "no": false, "one": 1}"#.utf8))
                as? [String: Any])
        for key in ["yes", "no"] {
            #expect(throws: CardanoChainError.self) { try LedgerValues.integer(json: object[key], as: UInt64.self, key) }
            #expect(throws: CardanoChainError.self) { try LedgerValues.bigInt(json: object[key], key) }
            #expect(throws: CardanoChainError.self) { try LedgerValues.unitInterval(json: object[key], key) }
        }
        // A number 1, and a Swift Int8 (whose NSNumber also reports "c"), still read.
        #expect(try LedgerValues.integer(json: object["one"], as: UInt64.self, "one") == 1)
        #expect(try LedgerValues.integer(json: Int8(1), as: UInt64.self, "int8") == 1)
    }

    // MARK: Integers

    @Test("Integers are converted only when they fit")
    func integers() throws {
        #expect(try LedgerValues.integer(Int64(365), as: UInt32.self, "test") == 365)
        #expect(try LedgerValues.integer(text: "45000000000000000", as: UInt64.self, "test") == 45_000_000_000_000_000)
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.integer(Int64(-1), as: UInt64.self, "test")
        }
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.integer(text: "100000000000", as: UInt32.self, "test")
        }
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.integer(150.5, as: UInt16.self, "test")
        }
        #expect(try LedgerValues.integer(150.0, as: UInt16.self, "test") == 150)
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.integer(text: "12abc", as: UInt64.self, "test")
        }
    }

    @Test("Token quantities above Int64.max are kept")
    func bigQuantities() throws {
        let quantity = try LedgerValues.bigInt(text: "18446744073709551615", "test")
        #expect(quantity.description == "18446744073709551615")
    }
}
