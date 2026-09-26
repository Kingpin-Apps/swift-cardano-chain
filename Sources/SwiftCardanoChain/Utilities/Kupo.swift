import Foundation
import SwiftCardanoCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A client for a [Kupo](https://cardanosolutions.github.io/kupo) chain index.
///
/// Kupo indexes outputs by address, asset or output reference, with their
/// datums and scripts, and — unless it prunes them — keeps spent outputs with
/// the point they were spent at. Paired with Ogmios, it answers what a node
/// alone answers slowly or not at all: every output at an address, and whether
/// an output was spent.
public struct KupoClient: Sendable {
    /// The Kupo server, for example `http://localhost:1442`.
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// The outputs matching `pattern` — an address, `*@<tx id>`,
    /// `<index>@<tx id>`, or a policy id with an optional `.asset name` —
    /// newest first.
    ///
    /// - Parameters:
    ///   - unspent: Only outputs not yet spent.
    ///   - resolveHashes: Include each output's datum and reference script.
    public func matches(pattern: String, unspent: Bool = false, resolveHashes: Bool = true) async throws -> [KupoMatch] {
        var query: [URLQueryItem] = []
        if unspent { query.append(URLQueryItem(name: "unspent", value: nil)) }
        if resolveHashes { query.append(URLQueryItem(name: "resolve_hashes", value: nil)) }
        let data = try await get("matches/\(pattern)", query: query) ?? Data("[]".utf8)
        do {
            return try JSONDecoder().decode([KupoMatch].self, from: data)
        } catch {
            throw CardanoChainError.valueError("Kupo returned matches that did not decode: \(error)")
        }
    }

    /// The datum whose hash is `hash`, as CBOR, or `nil` when Kupo has not
    /// seen it.
    public func datum(hash: String) async throws -> Data? {
        struct Body: Decodable { var datum: String }
        guard let data = try await get("datums/\(hash)"),
            let body = try JSONDecoder().decode(Body?.self, from: data)
        else { return nil }
        return Data(hexString: body.datum)
    }

    /// The script whose hash is `hash`, or `nil` when Kupo has not seen it.
    public func script(hash: String) async throws -> KupoScript? {
        guard let data = try await get("scripts/\(hash)") else { return nil }
        return try JSONDecoder().decode(KupoScript?.self, from: data)
    }

    /// The body of a GET, or `nil` for a 404.
    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw CardanoChainError.invalidArgument("Invalid Kupo URL for \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw CardanoChainError.invalidArgument("Invalid Kupo URL for \(path)")
        }
        var request = URLRequest(url: url)
        // Quantities as strings, since an asset quantity can exceed what a
        // JSON number holds exactly.
        request.setValue("application/json;asset-quantity=string", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 404 { return nil }
        guard (200..<300).contains(status) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw CardanoChainError.operationError("Kupo \(path) failed with HTTP \(status): \(message)")
        }
        return data
    }
}

/// A script as Kupo returns it.
public struct KupoScript: Decodable, Sendable, Hashable {
    /// `native`, `plutus:v1`, `plutus:v2` or `plutus:v3`.
    public var language: String
    /// The serialized script, hex.
    public var script: String
}

/// An output Kupo matched.
public struct KupoMatch: Decodable, Sendable {
    public struct Point: Decodable, Sendable, Hashable {
        public var slotNo: UInt64
        public var headerHash: String

        enum CodingKeys: String, CodingKey {
            case slotNo = "slot_no"
            case headerHash = "header_hash"
        }
    }

    public struct SpentAt: Decodable, Sendable, Hashable {
        public var slotNo: UInt64
        public var headerHash: String
        /// The spending transaction, when Kupo recorded it.
        public var transactionId: String?

        enum CodingKeys: String, CodingKey {
            case slotNo = "slot_no"
            case headerHash = "header_hash"
            case transactionId = "transaction_id"
        }
    }

    public struct Value: Decodable, Sendable, Hashable {
        /// Lovelace, as a string.
        public var coins: String
        /// Quantities by `<policy id>` or `<policy id>.<asset name>`, as strings.
        public var assets: [String: String]?
    }

    public var transactionId: String
    public var outputIndex: Int
    public var address: String
    public var value: Value
    public var datumHash: String?
    /// `hash` or `inline`, when there is a datum.
    public var datumType: String?
    /// The datum's CBOR, hex, when resolved.
    public var datum: String?
    public var scriptHash: String?
    /// The reference script, when resolved.
    public var script: KupoScript?
    public var createdAt: Point
    public var spentAt: SpentAt?

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case outputIndex = "output_index"
        case address
        case value
        case datumHash = "datum_hash"
        case datumType = "datum_type"
        case datum
        case scriptHash = "script_hash"
        case script
        case createdAt = "created_at"
        case spentAt = "spent_at"
    }

    public var isSpent: Bool { spentAt != nil }

    /// The output as a UTxO. An inline datum or reference script that was
    /// not resolved is fetched through `client`.
    public func utxo(client: KupoClient? = nil) async throws -> UTxO {
        let input = TransactionInput(
            transactionId: try TransactionId(from: .string(transactionId)),
            index: UInt16(outputIndex)
        )

        guard let coin = Int64(value.coins) else {
            throw CardanoChainError.valueError("Kupo coin quantity \(value.coins) is out of range")
        }
        var multiAsset = MultiAsset([:])
        for (unit, quantityText) in value.assets ?? [:] {
            let parts = unit.split(separator: ".", maxSplits: 1).map(String.init)
            guard let quantity = Int64(quantityText) else {
                throw CardanoChainError.valueError("Kupo asset quantity \(quantityText) is out of range")
            }
            let policy = ScriptHash(payload: Data(hex: parts[0]))
            let name = try AssetName(payload: Data(hex: parts.count > 1 ? parts[1] : ""))
            var asset = multiAsset[policy] ?? Asset([:])
            asset[name] = quantity
            multiAsset[policy] = asset
        }

        var outputDatumHash: DatumHash?
        var datumOption: DatumOption?
        if let hash = datumHash, datumType == "inline" {
            var cbor = datum.flatMap { Data(hexString: $0) }
            if cbor == nil, let client { cbor = try await client.datum(hash: hash) }
            guard let cbor else {
                throw CardanoChainError.valueError("Inline datum \(hash) of \(outputIndex)@\(transactionId) is not known to Kupo")
            }
            datumOption = DatumOption(datum: try PlutusData.fromCBOR(data: cbor))
        } else if let hash = datumHash {
            outputDatumHash = try DatumHash(from: .string(hash))
        }

        var referenceScript: ScriptType?
        if let hash = scriptHash {
            var resolved = script
            if resolved == nil, let client { resolved = try await client.script(hash: hash) }
            guard let resolved else {
                throw CardanoChainError.valueError("Reference script \(hash) of \(outputIndex)@\(transactionId) is not known to Kupo")
            }
            referenceScript = try Self.scriptType(resolved, hash: hash)
        }

        let output = TransactionOutput(
            address: try Address(from: .string(address)),
            amount: SwiftCardanoCore.Value(coin: coin, multiAsset: multiAsset),
            datumHash: outputDatumHash,
            datumOption: datumOption,
            script: referenceScript
        )
        return UTxO(input: input, output: output)
    }

    /// A script Kupo returned, checked against the hash it was listed under.
    ///
    /// Plutus scripts are held with one layer of CBOR byte-string wrapping,
    /// and sources disagree on whether they carry it, so both readings are
    /// tried and the one with the right hash kept.
    static func scriptType(_ script: KupoScript, hash: String) throws -> ScriptType {
        guard let bytes = Data(hexString: script.script) else {
            throw CardanoChainError.valueError("Script \(hash) is not hex")
        }
        func make(_ data: Data) -> ScriptType? {
            switch script.language {
            case "plutus:v1": return .plutusV1Script(PlutusV1Script(data: data))
            case "plutus:v2": return .plutusV2Script(PlutusV2Script(data: data))
            case "plutus:v3": return .plutusV3Script(PlutusV3Script(data: data))
            default: return nil
            }
        }
        if script.language == "native" {
            return .nativeScript(try NativeScript.fromCBOR(data: bytes))
        }
        var candidates = [bytes]
        if case .bytes(let inner)? = try? Primitive.fromCBOR(data: bytes) { candidates.append(inner) }
        if let wrapped = try? Primitive.bytes(bytes).toCBORData() { candidates.append(wrapped) }
        for candidate in candidates {
            if let type = make(candidate), (try? SwiftCardanoCore.scriptHash(script: type))?.payload.toHex == hash {
                return type
            }
        }
        throw CardanoChainError.valueError("Script \(hash) (\(script.language)) does not hash to \(hash)")
    }
}
