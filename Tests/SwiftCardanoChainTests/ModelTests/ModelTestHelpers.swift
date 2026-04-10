import Foundation
import SwiftCardanoCore
import SystemPackage

@testable import SwiftCardanoChain

enum ModelTestFixtures {
    static let paymentAddressString =
        "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
    static let stakeAddressString =
        "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n"

    static func makeDummyPoolParams() -> PoolParams {
        let poolKeyHash = PoolKeyHash(payload: Data(repeating: 0x01, count: 28))
        let vrfKeyHash = VrfKeyHash(payload: Data(repeating: 0x02, count: 32))
        let rewardAccount = RewardAccountHash(payload: Data(repeating: 0x03, count: 29))
        let margin = UnitInterval(numerator: 1, denominator: 20)
        let poolOwners = ListOrOrderedSet<VerificationKeyHash>.list([])
        return PoolParams(
            poolOperator: poolKeyHash,
            vrfKeyHash: vrfKeyHash,
            pledge: 500_000_000,
            cost: 340_000_000,
            margin: margin,
            rewardAccount: rewardAccount,
            poolOwners: poolOwners,
            relays: [],
            poolMetadata: nil
        )
    }

    static func temporaryFilePath(
        named stem: String = UUID().uuidString,
        extension fileExtension: String
    ) -> FilePath {
        FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("\(stem).\(fileExtension)").path
        )
    }

    static func write(_ contents: String, to path: FilePath) throws {
        try contents.write(
            to: URL(fileURLWithPath: path.string),
            atomically: true,
            encoding: .utf8
        )
    }

    static func makeGovActionID(byte: UInt8 = 0xab, index: UInt16 = 0) -> GovActionID {
        GovActionID(
            transactionID: TransactionId(payload: Data(repeating: byte, count: 32)),
            govActionIndex: index
        )
    }
}
