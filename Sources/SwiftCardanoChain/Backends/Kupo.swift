import Foundation
import SwiftCardanoCore
import SwiftCardanoNetwork
import SwiftKupo

/// A chain context backed by a [Kupo](https://cardanosolutions.github.io/kupo) chain index.
///
/// Kupo indexes outputs by address, asset or output reference, with their datums
/// and scripts, and — unless it prunes them — keeps spent outputs with the point
/// they were spent at. It answers what a node alone answers slowly or not at all:
/// every output at an address, and whether an output was spent.
///
/// Kupo only indexes outputs. Everything else — protocol parameters, the tip,
/// submitting and evaluating transactions, stake and governance queries — goes to
/// the context it wraps, usually an ``OgmiosChainContext`` talking to the same
/// node. Without one, those calls throw `CardanoChainError.notImplemented`.
///
/// ```swift
/// let ogmios = try await OgmiosChainContext(host: "localhost", port: 1337, network: .preview)
/// let context = try KupoChainContext(
///     url: URL(string: "http://localhost:1442")!,
///     network: .preview,
///     wrapping: ogmios
/// )
/// ```
public struct KupoChainContext: ChainContext {

    // MARK: - Properties

    /// The swift-kupo client every Kupo request goes through.
    public let client: SwiftKupo.Client

    /// The context that answers what Kupo cannot, if any.
    public let wrapped: (any ChainContext)?

    private let network: SwiftCardanoCore.Network

    public var name: String {
        wrapped.map { "Kupo + \($0.name)" } ?? "Kupo"
    }

    public var type: ContextType { .online }

    public var networkId: NetworkId { network.networkId }

    // MARK: - Initializers

    /// A context over a swift-kupo client.
    ///
    /// - Parameters:
    ///   - client: The client to query Kupo with.
    ///   - network: The network Kupo indexes.
    ///   - wrapping: The context for everything Kupo does not index.
    public init(
        client: SwiftKupo.Client,
        network: SwiftCardanoCore.Network = .mainnet,
        wrapping: (any ChainContext)? = nil
    ) {
        self.client = client
        self.network = network
        self.wrapped = wrapping
    }

    /// A context over a swift-kupo `Kupo`.
    public init(
        kupo: SwiftKupo.Kupo,
        network: SwiftCardanoCore.Network = .mainnet,
        wrapping: (any ChainContext)? = nil
    ) {
        self.init(client: kupo.client, network: network, wrapping: wrapping)
    }

    /// A context over the Kupo server at `url`.
    public init(
        url: URL = URL(string: "http://localhost:1442")!,
        network: SwiftCardanoCore.Network = .mainnet,
        wrapping: (any ChainContext)? = nil
    ) throws {
        self.init(kupo: try SwiftKupo.Kupo(basePath: url.absoluteString), network: network, wrapping: wrapping)
    }

    // MARK: - What Kupo answers

    /// The unspent outputs at `address`, from Kupo's index.
    public func utxos(address: Address) async throws -> [UTxO] {
        let pattern = Components.Parameters.Pattern(
            addressPattern: .init(shelleyAddressPattern: .bech32(try address.toBech32()))
        )
        var utxos: [UTxO] = []
        for match in try await matches(pattern, unspent: true) {
            utxos.append(try await utxo(from: match))
        }
        return utxos
    }

    /// The output `input` names and whether it was spent.
    ///
    /// Kupo keeps spent outputs unless it prunes them, so it can say an output
    /// was spent. When Kupo has no record of the output, the wrapped context is
    /// asked; without one the answer is `nil`.
    public func utxo(input: TransactionInput) async throws -> (UTxO, isSpent: Bool)? {
        let pattern = Components.Parameters.Pattern(
            outputReferencePattern: "\(input.index)@\(input.transactionId.payload.toHex)"
        )
        if let match = try await matches(pattern, unspent: false).first {
            return (try await utxo(from: match), match.spentAt != nil)
        }
        return try await wrapped?.utxo(input: input)
    }

    /// The CBOR of the datum whose hash is `hash`, or `nil` when Kupo has not
    /// seen it.
    public func datumCBOR(hash: DatumHash) async throws -> Data? {
        try await datumCBOR(hex: hash.payload.toHex)
    }

    /// The datum whose hash is `hash`, or `nil` when Kupo has not seen it.
    public func datum(hash: DatumHash) async throws -> PlutusData? {
        try await datumCBOR(hash: hash).map { try PlutusData.fromCBOR(data: $0) }
    }

    /// The script whose hash is `hash`, checked against that hash, or `nil`
    /// when Kupo has not seen it.
    public func script(hash: ScriptHash) async throws -> ScriptType? {
        let hex = hash.payload.toHex
        return try await script(hex: hex).map { try Self.scriptType($0, hash: hex) }
    }

    // MARK: - Forwarded to the wrapped context

    public func protocolParameters() async throws -> ProtocolParameters {
        try await forward("protocolParameters()").protocolParameters()
    }

    public func genesisParameters() async throws -> GenesisParameters {
        try await forward("genesisParameters()").genesisParameters()
    }

    public func epoch() async throws -> Int {
        try await forward("epoch()").epoch()
    }

    public func era() async throws -> Era? {
        try await forward("era()").era()
    }

    public func lastBlockSlot() async throws -> Int {
        try await forward("lastBlockSlot()").lastBlockSlot()
    }

    public func chainTip() async throws -> ChainTip {
        try await forward("chainTip()").chainTip()
    }

    public func transactionCBOR(hash: TransactionId) async throws -> Data {
        try await forward("transactionCBOR(hash:)").transactionCBOR(hash: hash)
    }

    public func submitTxCBOR(cbor: Data) async throws -> String {
        try await forward("submitTxCBOR(cbor:)").submitTxCBOR(cbor: cbor)
    }

    public func evaluateTx(tx: Transaction) async throws -> [String: ExecutionUnits] {
        try await forward("evaluateTx(tx:)").evaluateTx(tx: tx)
    }

    public func evaluateTxCBOR(cbor: Data) async throws -> [String: ExecutionUnits] {
        try await forward("evaluateTxCBOR(cbor:)").evaluateTxCBOR(cbor: cbor)
    }

    public func stakeAddressInfo(address: Address) async throws -> [StakeAddressInfo] {
        try await forward("stakeAddressInfo(address:)").stakeAddressInfo(address: address)
    }

    public func stakePools() async throws -> [PoolOperator] {
        try await forward("stakePools()").stakePools()
    }

    public func kesPeriodInfo(pool: PoolOperator?, opCert: OperationalCertificate?) async throws -> KESPeriodInfo {
        try await forward("kesPeriodInfo(pool:opCert:)").kesPeriodInfo(pool: pool, opCert: opCert)
    }

    public func stakePoolInfo(poolId: String) async throws -> StakePoolInfo {
        try await forward("stakePoolInfo(poolId:)").stakePoolInfo(poolId: poolId)
    }

    public func stakePoolInfo(poolId: String, strict: Bool) async throws -> StakePoolInfo {
        try await forward("stakePoolInfo(poolId:strict:)").stakePoolInfo(poolId: poolId, strict: strict)
    }

    public func treasury() async throws -> Coin {
        try await forward("treasury()").treasury()
    }

    public func drepInfo(drep: DRep) async throws -> DRepInfo {
        try await forward("drepInfo(drep:)").drepInfo(drep: drep)
    }

    public func govActionInfo(govActionID: GovActionID) async throws -> GovActionInfo {
        try await forward("govActionInfo(govActionID:)").govActionInfo(govActionID: govActionID)
    }

    public func committeeMemberInfo(cold: CommitteeColdCredential) async throws -> CommitteeMemberInfo {
        try await forward("committeeMemberInfo(cold:)").committeeMemberInfo(cold: cold)
    }

    public func committeeMemberInfo(hot: CommitteeHotCredential) async throws -> CommitteeMemberInfo {
        try await forward("committeeMemberInfo(hot:)").committeeMemberInfo(hot: hot)
    }

    public func govActionVotes(govActionID: GovActionID) async throws -> GovActionVotes {
        try await forward("govActionVotes(govActionID:)").govActionVotes(govActionID: govActionID)
    }

    public func govActionsAll() async throws -> [GovActionVotes] {
        try await forward("govActionsAll()").govActionsAll()
    }

    public func drepStakeDistribution() async throws -> [SwiftCardanoNetwork.DRepStakeEntry] {
        try await forward("drepStakeDistribution()").drepStakeDistribution()
    }

    public func spoStakeDistribution() async throws -> [SwiftCardanoNetwork.SPOStakeEntry] {
        try await forward("spoStakeDistribution()").spoStakeDistribution()
    }

    public func committeeState() async throws -> CommitteeStateInfo {
        try await forward("committeeState()").committeeState()
    }

    /// The wrapped context, or the error saying there is none to ask.
    private func forward(_ call: String) throws -> any ChainContext {
        guard let wrapped else {
            throw CardanoChainError.notImplemented(
                "Kupo only indexes outputs; configure a wrapped context such as Ogmios for \(call)."
            )
        }
        return wrapped
    }

    // MARK: - Kupo requests

    /// The matches for `pattern`, newest first, with datums and scripts resolved.
    func matches(
        _ pattern: Components.Parameters.Pattern, unspent: Bool
    ) async throws -> [Components.Schemas.Match] {
        let response = try await client.getMatches(
            path: .init(pattern: pattern),
            query: .init(resolveHashes: true, unspent: unspent ? true : nil)
        )
        switch response {
        case .ok(let ok):
            return try ok.body.applicationJsonCharsetUtf8
        default:
            throw Self.failure("matches", response: response)
        }
    }

    /// The CBOR of the datum whose hash is `hex`, or `nil` when Kupo has not seen it.
    func datumCBOR(hex: String) async throws -> Data? {
        let response = try await client.getDatumByHash(path: .init(datumHash: hex))
        switch response {
        case .ok(let ok):
            guard case .Datum(let datum) = try ok.body.applicationJsonCharsetUtf8 else { return nil }
            guard let cbor = Data(hexString: datum.datum) else {
                throw CardanoChainError.valueError("Kupo returned datum \(hex) that is not hex")
            }
            return cbor
        case .undocumented(statusCode: 404, _):
            return nil
        default:
            throw Self.failure("datums/\(hex)", response: response)
        }
    }

    /// The script whose hash is `hex`, as Kupo holds it, or `nil` when Kupo has not seen it.
    func script(hex: String) async throws -> Components.Schemas.Script? {
        let response = try await client.getScriptByHash(path: .init(scriptHash: hex))
        switch response {
        case .ok(let ok):
            guard case .Script(let script) = try ok.body.applicationJsonCharsetUtf8 else { return nil }
            return script
        case .undocumented(statusCode: 404, _):
            return nil
        default:
            throw Self.failure("scripts/\(hex)", response: response)
        }
    }

    private static func failure(_ path: String, response: some Sendable) -> CardanoChainError {
        .operationError("Kupo \(path) failed: \(response)")
    }

    // MARK: - Matches to UTxOs

    /// A match as a UTxO. An inline datum or reference script that Kupo did not
    /// resolve is fetched by its hash.
    func utxo(from match: Components.Schemas.Match) async throws -> UTxO {
        let reference = "\(match.outputIndex)@\(match.transactionId)"
        guard let index = UInt16(exactly: match.outputIndex) else {
            throw CardanoChainError.valueError("Kupo output index of \(reference) is out of range")
        }
        let input = TransactionInput(
            transactionId: try TransactionId(from: .string(match.transactionId)),
            index: index
        )

        guard let coin = Int64(exactly: match.value.coins) else {
            throw CardanoChainError.valueError("Kupo coin quantity \(match.value.coins) is out of range")
        }
        var multiAsset = MultiAsset([:])
        for (unit, count) in match.value.assets?.additionalProperties ?? [:] {
            let parts = unit.split(separator: ".", maxSplits: 1).map(String.init)
            guard let quantity = Int64(exactly: count) else {
                throw CardanoChainError.valueError("Kupo asset quantity \(count) is out of range")
            }
            let policy = ScriptHash(payload: Data(hex: parts[0]))
            let name = try AssetName(payload: Data(hex: parts.count > 1 ? parts[1] : ""))
            var asset = multiAsset[policy] ?? Asset([:])
            asset[name] = quantity
            multiAsset[policy] = asset
        }

        var outputDatumHash: DatumHash?
        var datumOption: DatumOption?
        if case .case1(let hash?)? = match.datumHash {
            if match.datumType == .inline {
                var cbor = match.datum.flatMap { Data(hexString: $0) }
                if cbor == nil { cbor = try await datumCBOR(hex: hash) }
                guard let cbor else {
                    throw CardanoChainError.valueError("Inline datum \(hash) of \(reference) is not known to Kupo")
                }
                datumOption = DatumOption(datum: try PlutusData.fromCBOR(data: cbor))
            } else {
                outputDatumHash = try DatumHash(from: .string(hash))
            }
        }

        var referenceScript: ScriptType?
        if case .case1(let hash?)? = match.scriptHash {
            var resolved = match.script
            if resolved == nil { resolved = try await script(hex: hash) }
            guard let resolved else {
                throw CardanoChainError.valueError("Reference script \(hash) of \(reference) is not known to Kupo")
            }
            referenceScript = try Self.scriptType(resolved, hash: hash)
        }

        guard let address = match.address.value1?.string ?? match.address.value2?.string else {
            throw CardanoChainError.valueError("Kupo returned no address for \(reference)")
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
    /// Plutus scripts are held with one layer of CBOR byte-string wrapping, and
    /// sources disagree on whether they carry it, so the bytes as given,
    /// unwrapped one layer and wrapped one layer are all tried, and the one with
    /// the right hash kept.
    static func scriptType(_ script: Components.Schemas.Script, hash: String) throws -> ScriptType {
        guard let bytes = Data(hexString: script.script) else {
            throw CardanoChainError.valueError("Script \(hash) is not hex")
        }
        func make(_ data: Data) -> ScriptType? {
            switch script.language {
            case .plutus_colon_v1: return .plutusV1Script(PlutusV1Script(data: data))
            case .plutus_colon_v2: return .plutusV2Script(PlutusV2Script(data: data))
            case .plutus_colon_v3: return .plutusV3Script(PlutusV3Script(data: data))
            case .native: return nil
            }
        }
        if script.language == .native {
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
        throw CardanoChainError.valueError("Script \(hash) (\(script.language.rawValue)) does not hash to \(hash)")
    }
}

extension Components.Schemas.Address.Value1Payload {
    fileprivate var string: String {
        switch self {
        case .case1(let text), .case2(let text): return text
        }
    }
}

extension Components.Schemas.Address.Value2Payload {
    fileprivate var string: String {
        switch self {
        case .case1(let text), .case2(let text): return text
        }
    }
}
