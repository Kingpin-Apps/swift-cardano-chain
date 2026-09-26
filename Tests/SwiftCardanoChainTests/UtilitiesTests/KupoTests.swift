import Foundation
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoChain

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serves canned Kupo responses by path and query.
final class KupoURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let key = url.path + (url.query.map { "?\($0)" } ?? "")
        let body = Self.routes[key]
        let response = HTTPURLResponse(
            url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "null").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Kupo client", .serialized)
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

    static func match(
        index: Int, datumType: String?, datum: String?, scriptHash: String?, script: String?, spent: Bool
    ) -> String {
        """
        {"transaction_index": 3, "transaction_id": "\(txId)", "output_index": \(index),
         "address": "\(address)",
         "value": {"coins": "2000000", "assets": {"\(policy).746f6b656e": "18446744073709551", "\(policy)": "7"}},
         "datum_hash": \(datumType == nil ? "null" : "\"\(datumHash)\""),
         \(datumType.map { "\"datum_type\": \"\($0)\"," } ?? "")
         "datum": \(datum.map { "\"\($0)\"" } ?? "null"),
         "script_hash": \(scriptHash.map { "\"\($0)\"" } ?? "null"),
         "script": \(script ?? "null"),
         "created_at": {"slot_no": 100, "header_hash": "\(String(repeating: "01", count: 32))"},
         "spent_at": \(spent ? "{\"slot_no\": 200, \"header_hash\": \"\(String(repeating: "02", count: 32))\", \"transaction_id\": null, \"input_index\": null, \"redeemer\": null}" : "null")}
        """
    }

    func client() throws -> KupoClient {
        let nativeHash = try Self.nativeHash()
        let plutusHash = try Self.plutusHash()
        KupoURLProtocol.routes = [
            "/matches/\(Self.address)?unspent&resolve_hashes": "[" + Self.match(
                index: 0, datumType: "inline", datum: "d87980", scriptHash: nativeHash,
                script: #"{"language": "native", "script": "\#(Self.nativeHex)"}"#, spent: false
            ) + "]",
            "/matches/1@\(Self.txId)?resolve_hashes": "[" + Self.match(
                index: 1, datumType: "hash", datum: nil, scriptHash: nil, script: nil, spent: true
            ) + "]",
            "/matches/2@\(Self.txId)?resolve_hashes": "[" + Self.match(
                index: 2, datumType: "inline", datum: nil, scriptHash: plutusHash, script: nil, spent: false
            ) + "]",
            "/datums/\(Self.datumHash)": #"{"datum": "d87a80"}"#,
            "/scripts/\(plutusHash)": #"{"language": "plutus:v1", "script": "\#(Self.plutusFlatHex)"}"#,
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KupoURLProtocol.self]
        return KupoClient(baseURL: URL(string: "http://kupo.test")!, session: URLSession(configuration: configuration))
    }

    @Test("Unspent outputs at an address, with inline datum, assets and reference script")
    func unspentAtAddress() async throws {
        let kupo = try client()
        let matches = try await kupo.matches(pattern: Self.address, unspent: true)
        #expect(matches.count == 1)
        let utxo = try await matches[0].utxo(client: kupo)
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
        let kupo = try client()
        let match = try #require(try await kupo.matches(pattern: "1@\(Self.txId)").first)
        #expect(match.isSpent)
        let utxo = try await match.utxo(client: kupo)
        #expect(utxo.output.datumHash?.payload.toHex == Self.datumHash)
        #expect(utxo.output.datumOption == nil)
    }

    @Test("Unresolved datums and scripts are fetched, and the script is checked by hash")
    func resolvesMissingParts() async throws {
        let kupo = try client()
        let match = try #require(try await kupo.matches(pattern: "2@\(Self.txId)").first)
        #expect(match.datum == nil && match.script == nil)
        let utxo = try await match.utxo(client: kupo)
        #expect(utxo.output.datumOption != nil)
        let script = try #require(utxo.output.script)
        #expect(try scriptHash(script: script).payload.toHex == (try Self.plutusHash()))
    }

    @Test("Without a client, an unresolved inline datum is an error")
    func unresolvedWithoutClient() async throws {
        let kupo = try client()
        let match = try #require(try await kupo.matches(pattern: "2@\(Self.txId)").first)
        await #expect(throws: CardanoChainError.self) {
            _ = try await match.utxo()
        }
    }

    @Test("A script that does not hash to its listed hash is refused")
    func wrongScriptHashIsRefused() throws {
        let script = KupoScript(language: "plutus:v1", script: Self.plutusFlatHex)
        #expect(throws: CardanoChainError.self) {
            _ = try KupoMatch.scriptType(script, hash: String(repeating: "00", count: 28))
        }
    }

    @Test("Unknown datums and scripts are nil")
    func unknownIsNil() async throws {
        let kupo = try client()
        #expect(try await kupo.datum(hash: String(repeating: "99", count: 32)) == nil)
        #expect(try await kupo.script(hash: String(repeating: "99", count: 28)) == nil)
    }
}
