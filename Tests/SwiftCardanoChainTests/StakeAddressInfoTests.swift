import Testing
import Foundation
@testable import SwiftCardanoChain

@Suite("StakeAddressInfo Tests")
struct StakeAddressInfoTests {

    // Sample data for testing
    let sampleAddress = "stake1u9ylzsgxaa6xctf4juup682ar3juj85n8tx3hthnljg47zctvm3rc"
    let sampleDelegationDeposit = 2_000_000
    let sampleRewardBalance = 5_000_000
    let sampleStakeDelegation = "pool1abc123def456ghi789jkl"
    let sampleVoteDelegation = "vote1xyz789"
    let sampleDelegateRepresentative = "drep1qwerty123"

    @Test func testInitialization() {
        // Test initialization with all parameters
        let info = StakeAddressInfo(
            address: sampleAddress,
            rewardAccountBalance: sampleRewardBalance,
            delegationDeposit: sampleDelegationDeposit,
            stakeDelegation: sampleStakeDelegation,
            voteDelegation: sampleVoteDelegation,
            delegateRepresentative: sampleDelegateRepresentative
        )

        #expect(info.address == sampleAddress)
        #expect(info.stakeRegistrationDeposit == sampleDelegationDeposit)
        #expect(info.rewardAccountBalance == sampleRewardBalance)
        #expect(info.stakeDelegation == sampleStakeDelegation)
        #expect(info.voteDelegation == sampleVoteDelegation)
        #expect(info.delegateRepresentative == sampleDelegateRepresentative)
    }

    @Test func testEquality() {
        // Create two identical instances
        let info1 = StakeAddressInfo(
            address: sampleAddress,
            rewardAccountBalance: sampleRewardBalance,
            delegationDeposit: sampleDelegationDeposit,
            stakeDelegation: sampleStakeDelegation,
            voteDelegation: sampleVoteDelegation,
            delegateRepresentative: sampleDelegateRepresentative
        )

        let info2 = StakeAddressInfo(
            address: sampleAddress,
            rewardAccountBalance: sampleRewardBalance,
            delegationDeposit: sampleDelegationDeposit,
            stakeDelegation: sampleStakeDelegation,
            voteDelegation: sampleVoteDelegation,
            delegateRepresentative: sampleDelegateRepresentative
        )

        // Test equality
        #expect(info1 == info2)

        // Test inequality with different values
        let info3 = StakeAddressInfo(
            address: sampleAddress,
            rewardAccountBalance: sampleRewardBalance,
            delegationDeposit: sampleDelegationDeposit + 1000,
            stakeDelegation: sampleStakeDelegation,
            voteDelegation: sampleVoteDelegation,
            delegateRepresentative: sampleDelegateRepresentative
        )

        #expect(info1 != info3)
    }

    @Test func testEncoding() throws {
        // Create an instance to encode
        let info = StakeAddressInfo(
            address: sampleAddress,
            rewardAccountBalance: sampleRewardBalance,
            delegationDeposit: sampleDelegationDeposit,
            stakeDelegation: sampleStakeDelegation,
            voteDelegation: sampleVoteDelegation,
            delegateRepresentative: sampleDelegateRepresentative
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(info)

        // Decode the JSON to verify encoding
        let decoder = JSONDecoder()
        let decodedInfo = try decoder.decode(StakeAddressInfo.self, from: encodedData)

        // Verify the decoded object matches the original
        #expect(decodedInfo == info)
    }

    @Test func testDecoding() throws {
        // Create a JSON string with the expected format
        let jsonString = """
            {
                "address": "\(sampleAddress)",
                "stakeRegistrationDeposit": \(sampleDelegationDeposit),
                "rewardAccountBalance": \(sampleRewardBalance),
                "stakeDelegation": "\(sampleStakeDelegation)",
                "voteDelegation": "\(sampleVoteDelegation)",
                "delegateRepresentative": "\(sampleDelegateRepresentative)"
            }
            """

        // Convert string to data
        let jsonData = jsonString.data(using: .utf8)!

        // Decode the JSON
        let decoder = JSONDecoder()
        let decodedInfo = try decoder.decode(StakeAddressInfo.self, from: jsonData)

        // Verify all properties were decoded correctly
        #expect(decodedInfo.address == sampleAddress)
        #expect(decodedInfo.stakeRegistrationDeposit == sampleDelegationDeposit)
        #expect(decodedInfo.rewardAccountBalance == sampleRewardBalance)
        #expect(decodedInfo.stakeDelegation == sampleStakeDelegation)
        #expect(decodedInfo.voteDelegation == sampleVoteDelegation)
        #expect(decodedInfo.delegateRepresentative == sampleDelegateRepresentative)
    }

    @Test func testDecodingWithMissingValues() throws {
        // Create a JSON string with missing optional values
        let jsonString = """
            {
                "address": "\(sampleAddress)",
                "rewardAccountBalance": \(sampleRewardBalance)
            }
            """

        // Convert string to data
        let jsonData = jsonString.data(using: .utf8)!

        // Decode the JSON
        let decoder = JSONDecoder()
        let decodedInfo = try decoder.decode(StakeAddressInfo.self, from: jsonData)

        // Verify required properties were decoded correctly and optional ones are nil
        #expect(decodedInfo.address == sampleAddress)
        #expect(decodedInfo.stakeRegistrationDeposit == 0)
        #expect(decodedInfo.rewardAccountBalance == sampleRewardBalance)
        #expect(decodedInfo.stakeDelegation == nil)
        #expect(decodedInfo.voteDelegation == nil)
        #expect(decodedInfo.delegateRepresentative == nil)
    }

    @Test func testDecodingWithDefaultValues() throws {
        // Create a JSON string with missing numeric values that should use defaults
        let jsonString = """
            {
                "address": "\(sampleAddress)",
                "stakeDelegation": "\(sampleStakeDelegation)"
            }
            """

        // Convert string to data
        let jsonData = jsonString.data(using: .utf8)!

        // Decode the JSON
        let decoder = JSONDecoder()
        let decodedInfo = try decoder.decode(StakeAddressInfo.self, from: jsonData)

        // Verify default values were applied
        #expect(decodedInfo.address == sampleAddress)
        #expect(decodedInfo.stakeRegistrationDeposit == 0)
        #expect(decodedInfo.rewardAccountBalance == 0)
        #expect(decodedInfo.stakeDelegation == sampleStakeDelegation)
        #expect(decodedInfo.voteDelegation == nil)
        #expect(decodedInfo.delegateRepresentative == nil)
    }
}
