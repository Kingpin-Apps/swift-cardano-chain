import SwiftCardanoCore

/// `numerator/denominator` as a unit interval, for fixtures.
func unit(_ numerator: UInt64, _ denominator: UInt64) -> UnitInterval {
    UnitInterval(numerator: numerator, denominator: denominator)
}

/// `numerator/denominator` as a non-negative interval, for fixtures.
func nonNegative(_ numerator: UInt64, _ denominator: UInt64) -> NonNegativeInterval {
    NonNegativeInterval(numerator: numerator, denominator: denominator)
}
