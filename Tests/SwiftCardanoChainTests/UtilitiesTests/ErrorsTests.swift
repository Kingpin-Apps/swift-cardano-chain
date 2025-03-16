import Foundation
import Testing

@testable import SwiftCardanoChain

@Suite("CardanoChainError Tests")
struct CardanoChainErrorTests {

    @Test func testBlockfrostError() {
        // Test with custom message
        let customMessage = "API key invalid"
        let error = CardanoChainError.blockfrostError(customMessage)
        #expect(error.description == customMessage)

        // Test with nil message (default message)
        let defaultError = CardanoChainError.blockfrostError(nil)
        #expect(defaultError.description == "Failed to retrieve data from Blockfrost.")
    }

    @Test func testCardanoCLIError() {
        // Test with custom message
        let customMessage = "Command not found"
        let error = CardanoChainError.cardanoCLIError(customMessage)
        #expect(error.description == customMessage)

        // Test with nil message (default message)
        let defaultError = CardanoChainError.cardanoCLIError(nil)
        #expect(defaultError.description == "Failed to execute Cardano CLI command.")
    }

    @Test func testInvalidArgumentError() {
        // Test with custom message
        let customMessage = "Address format is invalid"
        let error = CardanoChainError.invalidArgument(customMessage)
        #expect(error.description == customMessage)

        // Test with nil message (default message)
        let defaultError = CardanoChainError.invalidArgument(nil)
        #expect(defaultError.description == "Invalid argument error occurred.")
    }

    @Test func testTransactionFailedError() {
        // Test with custom message
        let customMessage = "Insufficient funds"
        let error = CardanoChainError.transactionFailed(customMessage)
        #expect(error.description == customMessage)

        // Test with nil message (default message)
        let defaultError = CardanoChainError.transactionFailed(nil)
        #expect(defaultError.description == "Transaction failed error occurred.")
    }

    @Test func testUnsupportedNetworkError() {
        // Test with custom message
        let customMessage = "Network 'testnet' is not supported"
        let error = CardanoChainError.unsupportedNetwork(customMessage)
        #expect(error.description == customMessage)

        // Test with nil message (default message)
        let defaultError = CardanoChainError.unsupportedNetwork(nil)
        #expect(defaultError.description == "The network is not supported.")
    }

    @Test func testValueError() {
        // Test with custom message
        let customMessage = "Value must be positive"
        let error = CardanoChainError.valueError(customMessage)
        #expect(error.description == customMessage)

        // Test with nil message (default message)
        let defaultError = CardanoChainError.valueError(nil)
        #expect(defaultError.description == "The value is invalid.")
    }

    @Test func testErrorEquality() {
        // Test equality for the same error types with same messages
        let error1 = CardanoChainError.blockfrostError("API error")
        let error2 = CardanoChainError.blockfrostError("API error")
        #expect(error1 == error2)

        // Test equality for the same error types with different messages
        let error3 = CardanoChainError.blockfrostError("API error")
        let error4 = CardanoChainError.blockfrostError("Different error")
        #expect(error3 != error4)

        // Test equality for different error types
        let error5 = CardanoChainError.blockfrostError("Error")
        let error6 = CardanoChainError.cardanoCLIError("Error")
        #expect(error5 != error6)

        // Test equality with nil messages
        let error7 = CardanoChainError.valueError(nil)
        let error8 = CardanoChainError.valueError(nil)
        #expect(error7 == error8)

        // Test equality with one nil and one non-nil message
        let error9 = CardanoChainError.transactionFailed(nil)
        let error10 = CardanoChainError.transactionFailed("Failed")
        #expect(error9 != error10)
    }
}
