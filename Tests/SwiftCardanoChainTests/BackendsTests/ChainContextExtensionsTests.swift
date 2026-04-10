import Foundation
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoChain

@Suite("ChainContext Extensions Tests")
struct ChainContextExtensionsTests {

    private let testCborHex =
        "84a70081825820b35a4ba9ef3ce21adcd6879d08553642224304704d206c74d3ffb3e6eed3ca28000d80018182581d60cc30497f4ff962f4c1dca54cceefe39f86f1d7179668009f8eb71e598200a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680021a000493e00e8009a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680075820592a2df0e091566969b3044626faa8023dabe6f39c78f33bed9e105e55159221a200828258206443a101bdb948366fc87369336224595d36d8b0eee5602cba8b81a024e584735840846f408dee3b101fda0f0f7ca89e18b724b7ca6266eb29775d3967d6920cae7457accb91def9b77571e15dd2ede38b12cf92496ce7382fa19eb90ab7f73e49008258205797dc2cc919dfec0bb849551ebdf30d96e5cbe0f33f734a87fe826db30f7ef95840bdc771aa7b8c86a8ffcbe1b7a479c68503c8aa0ffde8059443055bf3e54b92f4fca5e0b9ca5bb11ab23b1390bb9ffce414fa398fc0b17f4dc76fe9f7e2c99c09018182018482051a075bcd1582041a075bcd0c8200581c9139e5c0a42f0f2389634c3dd18dc621f5594c5ba825d9a8883c66278200581c835600a2be276a18a4bebf0225d728f090f724f4c0acd591d066fa6ff5d90103a100a11902d1a16b7b706f6c6963795f69647da16d7b706f6c6963795f6e616d657da66b6465736372697074696f6e6a3c6f7074696f6e616c3e65696d6167656a3c72657175697265643e686c6f636174696f6ea367617277656176656a3c6f7074696f6e616c3e6568747470736a3c6f7074696f6e616c3e64697066736a3c72657175697265643e646e616d656a3c72657175697265643e667368613235366a3c72657175697265643e64747970656a3c72657175697265643e"

    @Test("submitTx(tx:.transaction) forwards CBOR to submitTxCBOR")
    func testSubmitTxTransactionForwardsCBOR() async throws {
        let context = RecordingChainContext()
        let tx = try Transaction.fromCBORHex(testCborHex)

        let txId = try await context.submitTx(tx: .transaction(tx))
        let submittedCBOR = try #require(context.submittedCBOR)
        let submittedTx = try Transaction.fromCBOR(data: submittedCBOR)

        #expect(txId == context.submitResult)
        #expect(submittedTx.id == tx.id)
    }

    @Test("evaluateTx(tx:) forwards CBOR to evaluateTxCBOR")
    func testEvaluateTxForwardsCBOR() async throws {
        let context = RecordingChainContext()
        let tx = try Transaction.fromCBORHex(testCborHex)

        let result = try await context.evaluateTx(tx: tx)

        let evaluatedCBOR = try #require(context.evaluatedCBOR)
        let evaluatedTx = try Transaction.fromCBOR(data: evaluatedCBOR)
        #expect(result == context.evaluateResult)
        #expect(evaluatedTx.id == tx.id)
    }

    @Test("description and debugDescription use ChainContext extension defaults")
    func testDescriptionAndDebugDescription() {
        let context = RecordingChainContext()

        #expect(context.description == context.name)
        #expect(context.debugDescription.contains("ChainContext(name: \(context.name)"))
        #expect(context.debugDescription.contains("networkId"))
    }

    @Test("default ChainContext protocol methods throw notImplemented")
    func testDefaultProtocolMethodsThrowNotImplemented() async throws {
        let context = DefaultOnlyChainContext()
        let paymentAddress = try Address(
            from: .string(
                "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
            )
        )
        let txInput = TransactionInput(
            transactionId: TransactionId(payload: Data(repeating: 0xaa, count: 32)),
            index: 0
        )
        let poolOperator = PoolOperator(
            poolKeyHash: PoolKeyHash(payload: Data(repeating: 0x01, count: 28)))
        let govActionID = GovActionID(
            transactionID: TransactionId(payload: Data(repeating: 0xab, count: 32)),
            govActionIndex: 0
        )
        let committeeCredential = CommitteeColdCredential(
            credential: .verificationKeyHash(
                VerificationKeyHash(payload: Data(repeating: 0x02, count: 28))
            )
        )

        await #expect(throws: CardanoChainError.self) {
            _ = try await context.utxos(address: paymentAddress)
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.utxo(input: txInput)
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.submitTxCBOR(cbor: Data(hex: "deadbeef"))
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.evaluateTxCBOR(cbor: Data(hex: "deadbeef"))
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.stakeAddressInfo(address: paymentAddress)
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.stakePools()
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.kesPeriodInfo(pool: poolOperator, opCert: nil)
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.stakePoolInfo(poolId: "pool1test")
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.treasury()
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.drepInfo(drep: DRep(credential: .alwaysAbstain))
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.govActionInfo(govActionID: govActionID)
        }
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.committeeMemberInfo(committeeMember: committeeCredential)
        }
    }
}

private final class RecordingChainContext: ChainContext {
    let name = "RecordingContext"
    let type: ContextType = .online
    let networkId: NetworkId = .testnet

    var submittedCBOR: Data?
    var evaluatedCBOR: Data?

    let submitResult = "mock-tx-hash"
    let evaluateResult: [String: ExecutionUnits] = [
        "spend:0": ExecutionUnits(mem: 1, steps: 2)
    ]

    var protocolParameters: () async throws -> ProtocolParameters {
        { throw CardanoChainError.notImplemented("protocolParameters") }
    }

    var genesisParameters: () async throws -> GenesisParameters {
        { throw CardanoChainError.notImplemented("genesisParameters") }
    }

    var epoch: () async throws -> Int { { 0 } }

    var era: () async throws -> Era? { { .conway } }

    var lastBlockSlot: () async throws -> Int { { 0 } }

    func submitTxCBOR(cbor: Data) async throws -> String {
        submittedCBOR = cbor
        return submitResult
    }

    func evaluateTxCBOR(cbor: Data) async throws -> [String: ExecutionUnits] {
        evaluatedCBOR = cbor
        return evaluateResult
    }
}

private struct DefaultOnlyChainContext: ChainContext {
    let name = "DefaultOnly"
    let type: ContextType = .online
    let networkId: NetworkId = .testnet

    var protocolParameters: () async throws -> ProtocolParameters {
        { throw CardanoChainError.notImplemented("protocolParameters") }
    }

    var genesisParameters: () async throws -> GenesisParameters {
        { throw CardanoChainError.notImplemented("genesisParameters") }
    }

    var epoch: () async throws -> Int { { 0 } }

    var era: () async throws -> Era? { { nil } }

    var lastBlockSlot: () async throws -> Int { { 0 } }
}
