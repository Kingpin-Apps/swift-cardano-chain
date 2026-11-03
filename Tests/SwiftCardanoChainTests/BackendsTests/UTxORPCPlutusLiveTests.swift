import BigInt
import Foundation
import SwiftCardanoCore
import SwiftCardanoUPLC
import Testing
import UTxORPC
import UTxORPCClient

@testable import SwiftCardanoChain

/// Evaluates a real Plutus transaction on live servers: one that spends a
/// live output from the tip block and mints a token under an always-succeeds
/// PlutusV3 policy. It is never signed or submitted.
@Suite("UTxO RPC Plutus evaluation, live servers")
struct UTxORPCPlutusLiveTests {
    /// `(program 1.1.0 (lam ctx (con unit ())))`, the policy every mint passes.
    static func alwaysSucceeds() throws -> PlutusV3Script {
        var parser = UPLCParser()
        let program = try DeBruijnConverter().convert(try parser.parse("(program 1.1.0 (lam ctx (con unit ())))"))
        let flat = try FlatEncoder().encode(program)
        return PlutusV3Script(data: try Primitive.bytes(flat).toCBORData())
    }

    /// An unspent key-locked output holding only ADA: one of the tip block's
    /// own outputs, or else one at an address the tip block paid.
    static func liveInput(on server: LiveUTxORPCServer) async throws -> UTxO {
        let context = server.context
        let outputs = try await withUTxORPCClient(endpoint: server.endpoint!) { client in
            let tip = try await client.sync.readTip(Utxorpc_V1beta_Sync_ReadTipRequest()).tip
            let block = try #require(try await client.sync.fetchBlock(.with { $0.ref = [tip] }).block.first)
            return block.cardano.body.tx.flatMap { tx in
                tx.outputs.enumerated().map { (tx.hash, UInt16($0.offset), $0.element.address) }
            }
        }
        func usable(_ utxo: UTxO) -> Bool {
            guard case .verificationKeyHash = utxo.output.address.paymentPart else { return false }
            return utxo.output.amount.multiAsset.count == 0 && utxo.output.amount.coin > 5_000_000
        }
        for (hash, index, _) in outputs {
            let input = TransactionInput(transactionId: TransactionId(payload: hash), index: index)
            if let (utxo, _) = try await context.utxo(input: input), usable(utxo) { return utxo }
        }
        for addressBytes in Set(outputs.map(\.2)).prefix(5) {
            guard let address = try? Address(from: .bytes(addressBytes)),
                  case .verificationKeyHash = address.paymentPart
            else { continue }
            if let utxo = try await context.utxos(address: address).first(where: usable) { return utxo }
        }
        throw CardanoChainError.valueError("no unspent ADA-only key output found near the tip")
    }

    /// The mint transaction over `utxo`, with `fee` lovelace and the redeemer's
    /// budget set to `budget`.
    static func mintTransaction(spending utxo: UTxO, budget: ExecutionUnits) throws -> Transaction {
        let script = try alwaysSucceeds()
        let policy = try scriptHash(script: .plutusV3Script(script))
        let fee: Coin = 2_000_000
        let minted = MultiAsset([policy: Asset([AssetName(from: "UTXORPC"): BigInt(1)])])
        let output = TransactionOutput(
            address: utxo.output.address,
            amount: Value(coin: utxo.output.amount.coin - BigInt(fee), multiAsset: minted)
        )
        let body = TransactionBody(
            inputs: .list([utxo.input]),
            outputs: [output],
            fee: fee,
            mint: minted,
            collateral: .list([utxo.input])
        )
        let redeemer = Redeemer(tag: .mint, index: 0, data: try Unit().toPlutusData(), exUnits: budget)
        let witnesses = TransactionWitnessSet(redeemers: .list([redeemer]), plutusV3Script: .list([script]))
        return Transaction(transactionBody: body, transactionWitnessSet: witnesses)
    }

    /// The node prices the unsigned mint, and the library's own CEK machine,
    /// given the node's protocol parameters, prices it the same.
    @Test(.enabled(if: LiveUTxORPCServer.node.endpoint != nil, "set UTXORPC_NODE_SOCKET"))
    func nodeEvaluatesTheMint() async throws {
        let context = LiveUTxORPCServer.node.context
        let utxo = try await Self.liveInput(on: .node)
        let tx = try Self.mintTransaction(spending: utxo, budget: ExecutionUnits(mem: 14_000_000, steps: 10_000_000_000))

        let units = try await context.evaluateTxCBOR(cbor: try tx.toCBORData())
        let mint = try #require(units["mint:0"])
        #expect(mint.mem > 0 && mint.steps > 0)

        let local = try await context.evaluateTx(
            tx: tx, resolvedInputs: [utxo], protocolParameters: try await context.protocolParameters())
        #expect(local == units)
        print("UTxO RPC eval node: mint:0 \(mint.mem) mem / \(mint.steps) steps, local CEK \(local["mint:0"].map { "\($0.mem) / \($0.steps)" } ?? "-")")
    }

    /// Dolos checks the ledger rules before the scripts, so it refuses a
    /// transaction that isn't signed yet; the context then evaluates the
    /// scripts locally, and prices them as the node would.
    @Test(.enabled(if: LiveUTxORPCServer.hosted.endpoint != nil, "set UTXORPC_URL"))
    func dolosFallsBackToLocalEvaluation() async throws {
        let server = LiveUTxORPCServer.hosted
        let utxo = try await Self.liveInput(on: server)
        let tx = try Self.mintTransaction(spending: utxo, budget: ExecutionUnits(mem: 14_000_000, steps: 10_000_000_000))
        let cbor = try tx.toCBORData()

        let report = try await withUTxORPCClient(endpoint: server.endpoint!) {
            try await $0.submit.evalTx(.with { $0.tx.raw = cbor }).report.cardano
        }
        if !report.errors.contains(where: { $0.msg.contains("VKWitnessMissing") }) {
            Issue.record("Dolos now evaluates unsigned transactions; the local fallback is no longer needed for it")
        }

        let units = try await server.context.evaluateTxCBOR(cbor: cbor)
        let mint = try #require(units["mint:0"])
        #expect(mint == ExecutionUnits(mem: 500, steps: 64_100))
        print("UTxO RPC eval Dolos: local fallback mint:0 \(mint.mem) mem / \(mint.steps) steps")
    }
}
