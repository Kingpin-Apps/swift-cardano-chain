import Foundation
import SwiftCardanoCore
import SwiftKupo
import Testing

@testable import SwiftCardanoChain

@Suite("Kupo chain context")
struct KupoTests {
    static let txId = String(repeating: "ab", count: 32)
    static let address =
        "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
    static let policy = String(repeating: "cd", count: 28)
    static let datumHash = String(repeating: "ef", count: 32)
    /// A native script and a Plutus V1 script from Kupo's API reference.
    static let nativeHex = "8201838200581c3c07030e36bfffe67e2e2ec09e5293d384637cd2f004356ef320f3fe8204186482051896"
    static let plutusWrappedHex = "4d01000033222220051200120011"
    static let plutusFlatHex = "01000033222220051200120011"

    static func nativeHash() throws -> String {
        let native = try NativeScript.fromCBOR(data: Data(hexString: nativeHex)!)
        return try scriptHash(script: .nativeScript(native)).payload.toHex
    }

    static func plutusHash() throws -> String {
        try scriptHash(script: .plutusV1Script(PlutusV1Script(data: Data(hexString: plutusWrappedHex)!))).payload.toHex
    }

    static func input(_ index: UInt16) throws -> TransactionInput {
        TransactionInput(transactionId: try TransactionId(from: .string(txId)), index: index)
    }

    /// What current Kupo returns for a spent output: the point, plus the
    /// spending transaction, its input index and redeemer.
    static let spentAt = """
        {"slot_no": 200, "header_hash": "\(String(repeating: "02", count: 32))",
         "transaction_id": "\(String(repeating: "03", count: 32))", "input_index": 0, "redeemer": "d87980"}
        """

    static func match(
        index: Int, datumType: String?, datum: String?, scriptHash: String?, script: String?, spent: Bool
    ) -> String {
        """
        {"transaction_index": 3, "transaction_id": "\(txId)", "output_index": \(index),
         "address": "\(address)",
         "value": {"coins": 2000000, "assets": {"\(policy).746f6b656e": 18446744073709551, "\(policy)": 7}},
         "datum_hash": \(datumType == nil ? "null" : "\"\(datumHash)\""),
         \(datumType.map { "\"datum_type\": \"\($0)\"," } ?? "")
         "datum": \(datum.map { "\"\($0)\"" } ?? "null"),
         "script_hash": \(scriptHash.map { "\"\($0)\"" } ?? "null"),
         "script": \(script ?? "null"),
         "created_at": {"slot_no": 100, "header_hash": "\(String(repeating: "01", count: 32))"},
         "spent_at": \(spent ? spentAt : "null")}
        """
    }

    static func transport() throws -> KupoMockTransport {
        let nativeHash = try nativeHash()
        let plutusHash = try plutusHash()
        return KupoMockTransport(routes: [
            "/matches/\(address)": .init(
                flags: ["unspent", "resolve_hashes"],
                body: "[" + match(
                    index: 0, datumType: "inline", datum: "d87980", scriptHash: nativeHash,
                    script: #"{"language": "native", "script": "\#(nativeHex)"}"#, spent: false
                ) + "]"
            ),
            "/matches/1@\(txId)": .init(
                flags: ["resolve_hashes"],
                body: "[" + match(index: 1, datumType: "hash", datum: nil, scriptHash: nil, script: nil, spent: true) + "]"
            ),
            "/matches/2@\(txId)": .init(
                flags: ["resolve_hashes"],
                body: "[" + match(
                    index: 2, datumType: "inline", datum: nil, scriptHash: plutusHash, script: nil, spent: false
                ) + "]"
            ),
            "/datums/\(datumHash)": .init(body: #"{"datum": "d87a80"}"#),
            "/scripts/\(plutusHash)": .init(body: #"{"language": "plutus:v1", "script": "\#(plutusFlatHex)"}"#),
        ])
    }

    static func context(
        _ transport: KupoMockTransport, wrapping: (any ChainContext)? = nil
    ) -> KupoChainContext {
        KupoChainContext(
            client: SwiftKupo.Client(serverURL: URL(string: "http://kupo.test")!, transport: transport),
            network: .preview,
            wrapping: wrapping
        )
    }

    // MARK: - What Kupo answers

    @Test("Unspent outputs at an address, with inline datum, assets and reference script")
    func unspentAtAddress() async throws {
        let transport = try Self.transport()
        let utxos = try await Self.context(transport).utxos(address: try Address(from: .string(Self.address)))
        #expect(utxos.count == 1)
        let utxo = try #require(utxos.first)
        #expect(utxo.input.index == 0)
        #expect(utxo.output.amount.coin == 2_000_000)
        let assets = try #require(utxo.output.amount.multiAsset[ScriptHash(payload: Data(hex: Self.policy))])
        #expect(assets[try AssetName(payload: Data(hex: "746f6b656e"))] == 18_446_744_073_709_551)
        #expect(assets[try AssetName(payload: Data())] == 7)
        #expect(utxo.output.datumOption != nil)
        #expect(utxo.output.datumHash == nil)
        guard case .nativeScript? = utxo.output.script else {
            Issue.record("expected the native reference script")
            return
        }
    }

    @Test("A spent output says so, and keeps its datum hash")
    func spentOutput() async throws {
        let (utxo, isSpent) = try #require(try await Self.context(try Self.transport()).utxo(input: try Self.input(1)))
        #expect(isSpent)
        #expect(utxo.output.datumHash?.payload.toHex == Self.datumHash)
        #expect(utxo.output.datumOption == nil)
    }

    @Test("Unresolved datums and scripts are fetched, and the script is checked by hash")
    func resolvesMissingParts() async throws {
        let transport = try Self.transport()
        let (utxo, isSpent) = try #require(try await Self.context(transport).utxo(input: try Self.input(2)))
        #expect(!isSpent)
        #expect(utxo.output.datumOption != nil)
        let script = try #require(utxo.output.script)
        #expect(try scriptHash(script: script).payload.toHex == (try Self.plutusHash()))
        #expect(transport.paths.contains("/datums/\(Self.datumHash)"))
        #expect(transport.paths.contains("/scripts/\(try Self.plutusHash())"))
    }

    @Test("A script that does not hash to its listed hash is refused")
    func wrongScriptHashIsRefused() throws {
        let script = Components.Schemas.Script(language: .plutus_colon_v1, script: Self.plutusFlatHex)
        #expect(throws: CardanoChainError.self) {
            _ = try KupoChainContext.scriptType(script, hash: String(repeating: "00", count: 28))
        }
    }

    @Test("Datums and scripts by hash; unknown ones are nil")
    func datumsAndScriptsByHash() async throws {
        let context = Self.context(try Self.transport())
        let known = try await context.datumCBOR(hash: DatumHash(payload: Data(hex: Self.datumHash)))
        #expect(known == Data(hexString: "d87a80"))
        let script = try await context.script(hash: ScriptHash(payload: Data(hex: try Self.plutusHash())))
        #expect(script != nil)
        #expect(try await context.datum(hash: DatumHash(payload: Data(hex: String(repeating: "99", count: 32)))) == nil)
        #expect(try await context.script(hash: ScriptHash(payload: Data(hex: String(repeating: "99", count: 28)))) == nil)
    }

    @Test("An output Kupo has no record of is nil without a wrapped context")
    func unknownOutputIsNil() async throws {
        #expect(try await Self.context(try Self.transport()).utxo(input: try Self.input(9)) == nil)
    }

    // MARK: - Forwarding

    @Test("Named after itself and what it wraps")
    func names() throws {
        let transport = try Self.transport()
        #expect(Self.context(transport).name == "Kupo")
        #expect(Self.context(transport, wrapping: WrappedChainContext()).name == "Kupo + Wrapped")
        #expect(Self.context(transport).networkId == .testnet)
    }

    @Test("What Kupo does not index goes to the wrapped context")
    func forwardsToWrapped() async throws {
        let wrapped = WrappedChainContext()
        let context = Self.context(try Self.transport(), wrapping: wrapped)
        #expect(try await context.epoch() == 42)
        #expect(try await context.lastBlockSlot() == 7)
        #expect(try await context.submitTxCBOR(cbor: Data([1, 2, 3])) == "wrapped-tx")
        do {
            _ = try await context.protocolParameters()
            Issue.record("expected the wrapped context's error")
        } catch CardanoChainError.operationError(let message) {
            #expect(message == "wrapped protocolParameters")
        }
        #expect(await wrapped.calls == ["epoch", "lastBlockSlot", "submitTxCBOR", "protocolParameters"])
        #expect(await wrapped.submitted == Data([1, 2, 3]))
    }

    @Test("Without a wrapped context, what Kupo does not index is not implemented")
    func notImplementedAlone() async throws {
        let context = Self.context(try Self.transport())
        await #expect(throws: CardanoChainError.self) { _ = try await context.protocolParameters() }
        await #expect(throws: CardanoChainError.self) { _ = try await context.submitTxCBOR(cbor: Data()) }
        await #expect(throws: CardanoChainError.self) { _ = try await context.chainTip() }
        do {
            _ = try await context.epoch()
            Issue.record("expected notImplemented")
        } catch CardanoChainError.notImplemented(let message) {
            #expect(message?.contains("Kupo only indexes outputs") == true)
        }
    }

    @Test("An output Kupo has no record of is asked of the wrapped context")
    func utxoFallsBack() async throws {
        let wrapped = WrappedChainContext()
        let context = Self.context(try Self.transport(), wrapping: wrapped)
        let (utxo, isSpent) = try #require(try await context.utxo(input: try Self.input(9)))
        #expect(utxo.input.index == 9)
        #expect(!isSpent)
        #expect(await wrapped.calls == ["utxo"])

        // Kupo's own record wins over the wrapped context.
        _ = try await context.utxo(input: try Self.input(1))
        #expect(await wrapped.calls == ["utxo"])
    }
}

/// Answers a few calls and records every one it gets.
private actor WrappedChainContext: ChainContext {
    nonisolated let name = "Wrapped"
    nonisolated let type: ContextType = .online
    nonisolated let networkId: NetworkId = .testnet

    var calls: [String] = []
    var submitted: Data?

    func protocolParameters() async throws -> ProtocolParameters {
        calls.append("protocolParameters")
        throw CardanoChainError.operationError("wrapped protocolParameters")
    }

    func genesisParameters() async throws -> GenesisParameters {
        calls.append("genesisParameters")
        throw CardanoChainError.operationError("wrapped genesisParameters")
    }

    func epoch() async throws -> Int {
        calls.append("epoch")
        return 42
    }

    func era() async throws -> Era? {
        calls.append("era")
        return .conway
    }

    func lastBlockSlot() async throws -> Int {
        calls.append("lastBlockSlot")
        return 7
    }

    func submitTxCBOR(cbor: Data) async throws -> String {
        calls.append("submitTxCBOR")
        submitted = cbor
        return "wrapped-tx"
    }

    func utxo(input: TransactionInput) async throws -> (UTxO, isSpent: Bool)? {
        calls.append("utxo")
        let output = TransactionOutput(
            address: try Address(from: .string(KupoTests.address)),
            amount: Value(coin: 1_000_000)
        )
        return (UTxO(input: input, output: output), false)
    }
}
