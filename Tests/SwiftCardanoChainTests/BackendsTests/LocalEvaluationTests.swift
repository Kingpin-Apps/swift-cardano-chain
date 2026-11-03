import BigInt
import Foundation
import OpenAPIRuntime
import SwiftBlockfrostAPI
import SwiftCardanoCore
import SwiftCardanoUPLC
import Testing

@testable import SwiftCardanoChain

@Suite("Local evaluation inputs")
struct LocalEvaluationTests {
    func blockfrost() async throws -> BlockFrostChainContext {
        try await BlockFrostChainContext(
            projectId: "fake-project-id",
            network: .mainnet,
            client: SwiftBlockfrostAPI.Client(
                serverURL: URL(string: "https://cardano-mainnet.blockfrost.io/api/v0")!,
                transport: MockTransport()
            )
        )
    }

    @Test("The slot timeline comes from the chain's genesis")
    func slotTimelineFromGenesis() async throws {
        let context = try await blockfrost()
        #expect(try await context.slotTimeline() == .mainnet)
    }

    @Test("Map-form redeemers keep their tag and index")
    func mapRedeemersKeepTheirKeys() throws {
        let transaction = try Transaction.fromCBORHex(try ChainFixtures.mapRedeemerTransactionHex())
        let redeemers = BlockFrostChainContext.extractRedeemers(from: transaction)
        #expect(!redeemers.isEmpty)
        #expect(redeemers.allSatisfy { $0.tag != nil })
        let keys = Set(redeemers.map { "\($0.tag!):\($0.index)" })
        #expect(keys.count == redeemers.count)
    }

    /// A mint under an always-succeeds PlutusV3 policy, evaluated by the CEK
    /// machine, comes back under `mint:0`, the key the transaction builder
    /// looks up, not under the tag's JSON form.
    @Test("Local evaluation keys results the way the transaction builder looks them up")
    func localEvaluationKeys() async throws {
        var parser = UPLCParser()
        let program = try DeBruijnConverter().convert(try parser.parse("(program 1.1.0 (lam ctx (con unit ())))"))
        let script = PlutusV3Script(data: try Primitive.bytes(try FlatEncoder().encode(program)).toCBORData())
        let policy = try scriptHash(script: .plutusV3Script(script))

        let address = try Address(from: .string(
            "addr1q9d34spgg2kdy47n82e7x9pdd6vql6d2engxmpj20jmhuc2047yqd4xnh7u6u5jp4t0q3fkxzckph4tgnzvamlu7k5psuahzcp"))
        let input = TransactionInput(transactionId: TransactionId(payload: Data(repeating: 1, count: 32)), index: 0)
        let spent = UTxO(input: input, output: TransactionOutput(address: address, amount: Value(coin: 10_000_000)))
        let minted = MultiAsset([policy: Asset([AssetName(from: "T"): BigInt(1)])])
        let body = TransactionBody(
            inputs: .list([input]),
            outputs: [TransactionOutput(address: address, amount: Value(coin: 8_000_000, multiAsset: minted))],
            fee: 2_000_000,
            mint: minted,
            collateral: .list([input])
        )
        let redeemer = Redeemer(
            tag: .mint, index: 0, data: try Unit().toPlutusData(),
            exUnits: ExecutionUnits(mem: 14_000_000, steps: 10_000_000_000))
        let tx = Transaction(
            transactionBody: body,
            transactionWitnessSet: TransactionWitnessSet(redeemers: .list([redeemer]), plutusV3Script: .list([script])))

        let context = try await blockfrost()
        let units = try await context.evaluateTx(
            tx: tx, resolvedInputs: [spent], protocolParameters: try await context.protocolParameters())
        #expect(units.keys.sorted() == ["mint:0"])
        #expect((units["mint:0"]?.steps ?? 0) > 0)
    }
}
