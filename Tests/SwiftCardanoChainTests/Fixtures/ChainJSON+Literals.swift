import Foundation

@testable import SwiftCardanoChain

/// Literal JSON in tests. A float literal is read through its shortest
/// description, which is the decimal written in the test.
extension ChainJSON: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByNilLiteral
{
    public init(integerLiteral value: Int) { self = .number(Decimal(value)) }
    public init(floatLiteral value: Double) { self = .number(Decimal(string: String(value))!) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: ChainJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, ChainJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(nilLiteral: ()) { self = .null }
}
