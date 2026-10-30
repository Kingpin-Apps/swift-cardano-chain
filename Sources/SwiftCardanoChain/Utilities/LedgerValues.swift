import BigInt
import Foundation
import SwiftCardanoCore

/// Converting the numbers chain APIs return into the ledger's exact types.
///
/// The ledger holds every rational parameter as a reduced fraction of two
/// `Word64`s, and every amount, count and size as an unsigned integer of a
/// fixed width. The APIs hand them over as `"n/d"` strings, as JSON decimal
/// numbers, or as integers of some other width; these helpers convert each
/// one exactly, and throw rather than round, truncate or trap.
enum LedgerValues {

    // MARK: Rationals

    /// A unit interval from a decimal such as `0.0577` or `5.77e-05`.
    static func unitInterval(_ value: Double, _ what: @autoclosure () -> String) throws -> UnitInterval {
        let (n, d) = try fraction(decimalText: try decimalText(value, what()), what())
        return try unitInterval(n, d, what())
    }

    /// A unit interval from a `Decimal`.
    static func unitInterval(_ value: Decimal, _ what: @autoclosure () -> String) throws -> UnitInterval {
        let (n, d) = try fraction(decimal: value, what())
        return try unitInterval(n, d, what())
    }

    /// A unit interval from decimal text such as `"0.0577"`, or from a
    /// fraction such as `"1/20"`.
    static func unitInterval(text: String, _ what: @autoclosure () -> String) throws -> UnitInterval {
        let (n, d) = try fraction(text: text, what())
        return try unitInterval(n, d, what())
    }

    /// A non-negative interval from a decimal such as `4.4e-07`.
    static func nonNegativeInterval(_ value: Double, _ what: @autoclosure () -> String) throws -> NonNegativeInterval {
        let (n, d) = try fraction(decimalText: try decimalText(value, what()), what())
        return NonNegativeInterval(numerator: n, denominator: d)
    }

    /// A non-negative interval from a `Decimal`.
    static func nonNegativeInterval(_ value: Decimal, _ what: @autoclosure () -> String) throws -> NonNegativeInterval {
        let (n, d) = try fraction(decimal: value, what())
        return NonNegativeInterval(numerator: n, denominator: d)
    }

    /// A non-negative interval from decimal text, or from a fraction such as
    /// `"577/10000"`.
    static func nonNegativeInterval(text: String, _ what: @autoclosure () -> String) throws -> NonNegativeInterval {
        let (n, d) = try fraction(text: text, what())
        return NonNegativeInterval(numerator: n, denominator: d)
    }

    // MARK: Untyped JSON

    /// A unit interval from a value `JSONSerialization` read: a
    /// `{"numerator", "denominator"}` object, a decimal number, or text.
    /// `nil` when `any` is absent or `null`.
    static func unitInterval(json any: Any?, _ what: @autoclosure () -> String) throws -> UnitInterval? {
        guard let (n, d) = try fraction(json: any, what()) else { return nil }
        return try unitInterval(n, d, what())
    }

    /// A non-negative interval from a value `JSONSerialization` read.
    static func nonNegativeInterval(json any: Any?, _ what: @autoclosure () -> String) throws -> NonNegativeInterval? {
        guard let (n, d) = try fraction(json: any, what()) else { return nil }
        return NonNegativeInterval(numerator: n, denominator: d)
    }

    /// An integer from a value `JSONSerialization` read: a whole number, or
    /// integer text. `nil` when `any` is absent or `null`.
    static func integer<T: FixedWidthInteger>(
        json any: Any?, as type: T.Type = T.self, _ what: @autoclosure () -> String
    ) throws -> T? {
        guard let any, !(any is NSNull) else { return nil }
        if let value = any as? any BinaryInteger { return try integer(value, as: T.self, what()) }
        // Bridging an NSNumber to Int64 or UInt64 succeeds only when it holds
        // that whole number exactly.
        if let value = any as? Int64 { return try integer(value, as: T.self, what()) }
        if let value = any as? UInt64 { return try integer(value, as: T.self, what()) }
        if let text = any as? String { return try integer(text: text, as: T.self, what()) }
        // A Double (OpenAPIRuntime's containers hold JSON numbers as one) is
        // accepted only when it is a whole number in range.
        if let value = any as? Double { return try integer(value, as: T.self, what()) }
        throw CardanoChainError.valueError("\(what()): \(any) is not a whole number")
    }

    /// A token quantity from a value `JSONSerialization` read, which may
    /// exceed `Int64.max`. `nil` when `any` is absent or `null`.
    static func bigInt(json any: Any?, _ what: @autoclosure () -> String) throws -> BigInt? {
        guard let any, !(any is NSNull) else { return nil }
        if let value = any as? any BinaryInteger { return BigInt(value) }
        if let value = any as? Int64 { return BigInt(value) }
        if let value = any as? UInt64 { return BigInt(value) }
        if let text = any as? String { return try bigInt(text: text, what()) }
        if let decimal = any as? NSDecimalNumber {
            var value = decimal.decimalValue
            var whole = Decimal()
            NSDecimalRound(&whole, &value, 0, .plain)
            if whole == decimal.decimalValue, let integer = BigInt(whole.description) { return integer }
        }
        throw CardanoChainError.valueError("\(what()): \(any) is not a whole number")
    }

    private static func fraction(json any: Any?, _ what: String) throws -> (UInt64, UInt64)? {
        guard let any, !(any is NSNull) else { return nil }
        if let object = any as? [String: Any] {
            let n: UInt64? = try integer(json: object["numerator"], "\(what) numerator")
            let d: UInt64? = try integer(json: object["denominator"], "\(what) denominator")
            guard let n, let d else {
                throw CardanoChainError.valueError("\(what): \(object) is not a fraction")
            }
            return try reduced(BigInt(n), BigInt(d), what)
        }
        if let text = any as? String { return try fraction(text: text, what) }
        if let decimal = any as? NSDecimalNumber { return try fraction(decimal: decimal.decimalValue, what) }
        if let value = any as? any BinaryInteger { return try reduced(BigInt(value), 1, what) }
        if let value = any as? UInt64 { return try reduced(BigInt(value), 1, what) }
        if let value = any as? Double {
            // `JSONSerialization` reads a decimal as a Double; its shortest
            // description is the decimal it read.
            return try fraction(decimalText: try decimalText(value, what), what)
        }
        throw CardanoChainError.valueError("\(what): \(any) is not a number")
    }

    // MARK: Presence

    /// `value`, or an error naming the missing field.
    static func required<T>(_ value: T?, _ what: @autoclosure () -> String) throws -> T {
        guard let value else {
            throw CardanoChainError.valueError("\(what()) is missing")
        }
        return value
    }

    // MARK: Integers

    /// `value` as a `T`, or an error when it is negative or too large.
    static func integer<T: FixedWidthInteger, S: BinaryInteger>(
        _ value: S, as type: T.Type = T.self, _ what: @autoclosure () -> String
    ) throws -> T {
        guard let result = T(exactly: value) else {
            throw CardanoChainError.valueError("\(what()): \(value) does not fit a \(T.self)")
        }
        return result
    }

    /// `value` as a `T` when it is a whole number in range, an error otherwise.
    static func integer<T: FixedWidthInteger>(
        _ value: Double, as type: T.Type = T.self, _ what: @autoclosure () -> String
    ) throws -> T {
        guard let result = T(exactly: value) else {
            throw CardanoChainError.valueError("\(what()): \(value) is not a whole \(T.self)")
        }
        return result
    }

    /// Integer text such as `"45000000000000000"` as a `T`.
    static func integer<T: FixedWidthInteger>(
        text: String, as type: T.Type = T.self, _ what: @autoclosure () -> String
    ) throws -> T {
        guard let result = T(text) else {
            throw CardanoChainError.valueError("\(what()): \(text) is not a whole \(T.self)")
        }
        return result
    }

    /// Integer text as a `BigInt`, for token quantities.
    static func bigInt(text: String, _ what: @autoclosure () -> String) throws -> BigInt {
        guard let result = BigInt(text) else {
            throw CardanoChainError.valueError("\(what()): \(text) is not a whole number")
        }
        return result
    }

    // MARK: - Implementation

    /// The JSON text a `Double` was read from: its shortest description reads
    /// back as the same `Double`, so it is the decimal the API sent, unless
    /// the API sent more digits than a `Double` holds.
    private static func decimalText(_ value: Double, _ what: String) throws -> String {
        guard value.isFinite else {
            throw CardanoChainError.valueError("\(what): \(value) is not a number")
        }
        return String(value)
    }

    /// `"n/d"` or decimal text, reduced to fit two `UInt64`s.
    private static func fraction(text: String, _ what: String) throws -> (UInt64, UInt64) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return try fraction(decimalText: trimmed, what)
        case 2:
            guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  let n = BigInt(String(parts[0])), let d = BigInt(String(parts[1])) else {
                throw CardanoChainError.valueError("\(what): \(text) is not a fraction n/d")
            }
            return try reduced(n, d, what)
        default:
            throw CardanoChainError.valueError("\(what): \(text) is not a fraction n/d")
        }
    }

    /// Decimal text such as `"0.0577"`, `"1"` or `"7.21e-05"`, exactly.
    private static func fraction(decimalText text: String, _ what: String) throws -> (UInt64, UInt64) {
        let allowed = Set("0123456789.eE+-")
        guard !text.isEmpty, text.allSatisfy({ allowed.contains($0) }),
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            throw CardanoChainError.valueError("\(what): \(text) is not a decimal number")
        }
        return try fraction(decimal: value, what)
    }

    /// `significand × 10^exponent` as a reduced fraction.
    private static func fraction(decimal value: Decimal, _ what: String) throws -> (UInt64, UInt64) {
        guard !value.isNaN, value.isFinite else {
            throw CardanoChainError.valueError("\(what): \(value) is not a number")
        }
        guard value.sign == .plus || value.isZero else {
            throw CardanoChainError.valueError("\(what): \(value) is negative")
        }
        guard let significand = BigInt(value.significand.description) else {
            throw CardanoChainError.valueError("\(what): \(value) is not a decimal number")
        }
        // A Decimal's exponent is within -128...127, so the power is small.
        let exponent = Int(value.exponent)
        if exponent >= 0 {
            return try reduced(significand * BigInt(10).power(exponent), 1, what)
        }
        return try reduced(significand, BigInt(10).power(-exponent), what)
    }

    /// `n / d` reduced by their greatest common divisor, both fitting a `UInt64`.
    private static func reduced(_ n: BigInt, _ d: BigInt, _ what: String) throws -> (UInt64, UInt64) {
        guard d > 0 else {
            throw CardanoChainError.valueError("\(what): \(n)/\(d) has no positive denominator")
        }
        guard n >= 0 else {
            throw CardanoChainError.valueError("\(what): \(n)/\(d) is negative")
        }
        let g = BigInt(n.magnitude.greatestCommonDivisor(with: d.magnitude))
        let (rn, rd) = g > 1 ? (n / g, d / g) : (n, d)
        guard let num = UInt64(exactly: rn), let den = UInt64(exactly: rd) else {
            throw CardanoChainError.valueError("\(what): \(rn)/\(rd) does not fit a ledger fraction of two UInt64s")
        }
        return (num, den)
    }

    private static func unitInterval(_ n: UInt64, _ d: UInt64, _ what: String) throws -> UnitInterval {
        guard n <= d else {
            throw CardanoChainError.valueError("\(what): \(n)/\(d) is above one, so not a unit interval")
        }
        return UnitInterval(numerator: n, denominator: d)
    }
}

extension BinaryInteger {
    /// The value as a `T`, or a ``CardanoChainError/valueError(_:)`` naming
    /// `what` when it is negative or too large for `T`: a value from the
    /// network or a file never traps and is never clamped.
    func checked<T: FixedWidthInteger>(_ what: @autoclosure () -> String) throws -> T {
        try LedgerValues.integer(self, as: T.self, what())
    }
}

extension Double {
    /// The value as a `T` when it is a whole number in range, a
    /// ``CardanoChainError/valueError(_:)`` naming `what` otherwise. APIs
    /// whose clients read every number as a `Double` (Koios) go through this
    /// instead of `T(_:)`, which truncates fractions and traps on overflow.
    func checked<T: FixedWidthInteger>(_ what: @autoclosure () -> String) throws -> T {
        try LedgerValues.integer(self, as: T.self, what())
    }
}
