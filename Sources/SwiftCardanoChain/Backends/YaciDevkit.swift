import Foundation
import OpenAPIRuntime
import SwiftCardanoCore
import SwiftCardanoNetwork
import SwiftYaciAPI

/// A chain context implementation backed by a local [Yaci DevKit](https://github.com/bloxbean/yaci-devkit)
/// devnet.
///
/// `YaciDevkitChainContext` reads chain data through [SwiftYaciAPI](https://github.com/Kingpin-Apps/swift-yaci-api),
/// the generated client for the [Yaci Store](https://github.com/bloxbean/yaci-store) REST API,
/// and reads genesis from the DevKit admin (cluster) API. It is the backend to use when
/// developing against a throw-away local network: no API key, no `cardano-node` socket, no
/// Ogmios process — just the DevKit.
///
/// ## Creating a Context
///
/// ```swift
/// // DevKit defaults: store on 8080, admin API on 10000
/// let context = try YaciDevkitChainContext()
///
/// // Custom endpoints and network magic
/// let context = try YaciDevkitChainContext(
///     apiURL: "http://devkit.local:8080",
///     adminURL: "http://devkit.local:10000",
///     network: .custom(42)
/// )
/// ```
///
/// ## What Yaci Can and Cannot Answer
///
/// Yaci Store indexes *certificates and outputs* rather than ledger state, so several queries
/// are reconstructions from the certificate log, and a few have no data source at all:
///
/// | Query | Source |
/// |---|---|
/// | Genesis parameters, cost models | DevKit admin API (genesis files) |
/// | Stake pools | Folded from pool registration / retirement certificates |
/// | Pool parameters and status | Per-epoch pool state, falling back to the certificate log |
/// | DRep info | Folded from DRep registration / update / retirement certificates |
/// | Governance actions, votes | Proposal + voting-procedure log (no ratified / enacted / expired epochs) |
/// | Committee state | Current committee, with hot keys folded from the certificate log |
/// | KES period info | Latest block minted by the pool |
/// | Treasury, SPO stake distribution | Not available — ``CardanoChainError/notImplemented(_:)`` |
///
/// The DRep stake distribution and the committee's live view read the node through DevKit's
/// local-state endpoints, which are only served when the DevKit cluster is running.
///
/// Transaction evaluation needs Ogmios enabled in the DevKit (`ogmios_enabled=true`).
///
/// ## Topics
///
/// ### Creating a Context
/// - ``init(apiURL:adminURL:network:client:admin:)``
/// - ``init(api:admin:network:)``
///
/// ### Querying Chain State
/// - ``utxos(address:)``
/// - ``utxo(input:)``
/// - ``stakeAddressInfo(address:)``
/// - ``stakePools()``
/// - ``stakePoolInfo(poolId:)``
///
/// ### Transaction Operations
/// - ``submitTxCBOR(cbor:)``
/// - ``evaluateTxCBOR(cbor:)``
public actor YaciDevkitChainContext: ChainContext {

    // MARK: - Properties

    nonisolated public var name: String { "YaciDevkit" }
    nonisolated public var type: ContextType { .online }

    /// The Yaci Store API client.
    public nonisolated let api: Yaci

    /// The DevKit admin API client, which serves the genesis documents.
    public nonisolated let admin: any YaciDevkitAdminFetching

    private let _network: SwiftCardanoCore.Network

    nonisolated public var networkId: NetworkId {
        _network.networkId
    }

    /// Rows requested per page from Yaci's paginated list endpoints.
    private static let pageSize: Int32 = 100

    /// Hard stop on pagination, so a misbehaving endpoint cannot loop forever.
    private static let maxPages = 1000

    /// How long a fetched epoch number is trusted before being re-read. Devnet epochs can be
    /// only a few minutes long, so this is deliberately short.
    private static let epochCacheLifetime: TimeInterval = 10

    private var _epoch: Int?
    private var _epochFetchedAt: TimeInterval = 0
    private var _epochFetch: Task<Int, Error>?
    private var _genesisParameters: GenesisParameters?
    private var _genesisParametersFetch: Task<GenesisParameters, Error>?
    private var _genesisFiles: [String: Data] = [:]
    private var _protocolParameters: ProtocolParameters?
    private var _protocolParametersEpoch: Int?
    private var _protocolParametersFetch: Task<ProtocolParameters, Error>?

    // MARK: - Initialization

    /// Creates a context for a running Yaci DevKit.
    ///
    /// - Parameters:
    ///   - apiURL: Yaci Store's root, e.g. `http://localhost:8080`. A trailing `/api/v1` is
    ///     accepted and dropped, since every endpoint already carries it. Defaults to
    ///     `http://localhost:8080`, which is where DevKit serves it.
    ///   - adminURL: The DevKit admin (cluster) API, which is where genesis comes from — Yaci
    ///     Store serves none. Defaults to port 10000 on the store's host.
    ///   - network: The devnet's network. DevKit's default protocol magic is 42; any value other
    ///     than `.mainnet` maps to the testnet network id.
    ///   - client: An existing generated client to use instead of building one. Tests inject a
    ///     client with a mock transport here.
    ///   - admin: An existing admin client, overriding `adminURL`.
    public init(
        apiURL: String? = nil,
        adminURL: String? = nil,
        network: SwiftCardanoCore.Network = .custom(42),
        client: SwiftYaciAPI.Client? = nil,
        admin: (any YaciDevkitAdminFetching)? = nil
    ) throws {
        var basePath = apiURL.map { path -> String in
            var trimmed = Substring(path)
            while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
            return String(trimmed)
        }
        if let path = basePath, path.hasSuffix("/api/v1") {
            basePath = String(path.dropLast("/api/v1".count))
        }

        do {
            self.api = try Yaci(basePath: basePath, client: client)
        } catch let error as YaciAPIError {
            throw CardanoChainError.invalidArgument(error.description)
        }

        if let admin {
            self.admin = admin
        } else if let adminURL {
            self.admin = try YaciDevkitAdmin(baseURL: adminURL)
        } else {
            self.admin = try YaciDevkitAdmin(derivedFromStoreURL: self.api.baseURL)
        }
        self._network = network
    }

    /// Creates a context around existing clients.
    public init(
        api: Yaci,
        admin: any YaciDevkitAdminFetching,
        network: SwiftCardanoCore.Network = .custom(42)
    ) {
        self.api = api
        self.admin = admin
        self._network = network
    }

    // MARK: - Error handling

    /// Run one generated-client call, mapping its failures onto ``CardanoChainError``.
    private func perform<T>(_ what: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CardanoChainError {
            throw error
        } catch {
            throw CardanoChainError.yaciDevkitError("Failed to \(what): \(error)")
        }
    }

    /// Collect every page of one of Yaci's `page`/`count` endpoints.
    ///
    /// Yaci returns a bare list with no total, so a short page is the only signal that the end
    /// has been reached.
    private func paginate<T>(
        _ what: String,
        _ fetch: (_ page: Int32, _ count: Int32) async throws -> [T]
    ) async throws -> [T] {
        var rows: [T] = []
        for page in 0..<Self.maxPages {
            let chunk = try await perform(what) { try await fetch(Int32(page), Self.pageSize) }
            rows.append(contentsOf: chunk)
            if chunk.count < Int(Self.pageSize) { break }
        }
        return rows
    }

    // MARK: - Epoch / era / slot

    /// The current epoch number, cached for a few seconds.
    public func epoch() async throws -> Int {
        if let cached = _epoch,
            Date().timeIntervalSince1970 - _epochFetchedAt <= Self.epochCacheLifetime
        {
            return cached
        }
        if let inFlight = _epochFetch { return try await inFlight.value }

        // Cache writes happen inside the Task body so the result lands in the cache even if
        // the launching caller is cancelled mid-flight.
        let task = Task<Int, Error> {
            do {
                let value = try await self.fetchEpoch()
                self._epoch = value
                self._epochFetchedAt = Date().timeIntervalSince1970
                self._epochFetch = nil
                return value
            } catch {
                self._epochFetch = nil
                throw error
            }
        }
        _epochFetch = task
        return try await task.value
    }

    private func fetchEpoch() async throws -> Int {
        try await perform("get the latest epoch") {
            Int(try await api.client.getLatestEpoch().ok.body.json.epoch ?? 0)
        }
    }

    private func latestBlock() async throws -> Components.Schemas.BlockDto {
        try await perform("get the latest block") {
            try await api.client.getLatestBlock().ok.body.json
        }
    }

    /// The era the chain is currently in.
    ///
    /// Yaci records the hard-fork combinator's era index on every block rather than an era name,
    /// so this maps that index (`1` Byron through `7` Conway). An index outside that range — a
    /// future era this mapping does not know — is reported as `nil` rather than guessed at.
    public func era() async throws -> Era? {
        try await latestBlock().era.flatMap { Self.era(fromIndex: Int($0)) }
    }

    /// The slot of the latest block Yaci has indexed.
    public func lastBlockSlot() async throws -> Int {
        guard let slot = try await latestBlock().slot else {
            throw CardanoChainError.yaciDevkitError(
                "Yaci DevKit reported a latest block without a slot.")
        }
        return Int(slot)
    }

    /// The current tip of the chain.
    ///
    /// `syncProgress` and `slotsToEpochEnd` are not populated: Yaci reports how far it has
    /// indexed but not how far behind the node it is, so there is nothing to compare against.
    public func chainTip() async throws -> ChainTip {
        let block = try await latestBlock()
        let number = block.number ?? block.height
        return ChainTip(
            block: number.map { BlockNumber($0) },
            epoch: block.epoch.map { EpochNumber($0) },
            era: block.era.flatMap { Self.era(fromIndex: Int($0)) }?.description,
            hash: block.hash,
            slot: block.slot.map { SlotNumber($0) },
            slotInEpoch: block.epochSlot.map { SlotNumber($0) },
            slotsToEpochEnd: nil,
            syncProgress: nil
        )
    }

    static func era(fromIndex index: Int) -> Era? {
        guard index >= 1, index <= Era.allCases.count else { return nil }
        return Era.allCases[index - 1]
    }

    // MARK: - Genesis

    /// Genesis parameters, from the DevKit admin API. Cached for the lifetime of the context.
    public func genesisParameters() async throws -> GenesisParameters {
        if let cached = _genesisParameters { return cached }
        if let inFlight = _genesisParametersFetch { return try await inFlight.value }

        let task = Task<GenesisParameters, Error> {
            do {
                let value = try await self.fetchGenesisFromAdmin()
                self._genesisParameters = value
                self._genesisParametersFetch = nil
                return value
            } catch {
                self._genesisParametersFetch = nil
                throw error
            }
        }
        _genesisParametersFetch = task
        return try await task.value
    }

    private func genesisFile(_ era: String) async throws -> Data {
        if let cached = _genesisFiles[era] { return cached }
        let data = try await admin.genesis(era: era)
        _genesisFiles[era] = data
        return data
    }

    private func fetchGenesisFromAdmin() async throws -> GenesisParameters {
        let shelleyData = try await genesisFile("shelley")
        let alonzoData = try await genesisFile("alonzo")
        let byronData = try await genesisFile("byron")
        let conwayData = try await genesisFile("conway")

        // Prefer the fully typed genesis when every document decodes, so callers also get the
        // per-era sub-documents. Fall back to reading the Shelley genesis field by field, so a
        // DevKit whose Byron or Alonzo layout differs slightly still yields the parameters that
        // matter.
        if let alonzo = try? JSONDecoder().decode(AlonzoGenesis.self, from: alonzoData),
            let byron = try? JSONDecoder().decode(ByronGenesis.self, from: byronData),
            let conway = try? JSONDecoder().decode(ConwayGenesis.self, from: conwayData),
            let shelley = try? JSONDecoder().decode(ShelleyGenesis.self, from: shelleyData)
        {
            let typed = GenesisParameters(
                alonzoGenesis: alonzo,
                byronGenesis: byron,
                conwayGenesis: conway,
                shelleyGenesis: shelley,
                era: .conway
            )
            if typed.systemStart != nil { return typed }
        }

        return try Self.genesisParameters(fromShelleyGenesis: shelleyData, network: _network)
    }

    /// Build `GenesisParameters` from a raw Shelley genesis document.
    static func genesisParameters(
        fromShelleyGenesis data: Data,
        network: SwiftCardanoCore.Network
    ) throws -> GenesisParameters {
        guard let json = Self.jsonObject(data) else {
            throw CardanoChainError.yaciDevkitError("Shelley genesis is not a JSON object")
        }

        func requireInt(_ key: String) throws -> Int {
            guard let value = (json[key] as? NSNumber)?.intValue ?? (json[key] as? String).flatMap(Int.init)
            else { throw CardanoChainError.yaciDevkitError("Shelley genesis is missing \(key)") }
            return value
        }
        func requireDouble(_ key: String) throws -> Double {
            guard let value = (json[key] as? NSNumber)?.doubleValue ?? (json[key] as? String).flatMap(Double.init)
            else { throw CardanoChainError.yaciDevkitError("Shelley genesis is missing \(key)") }
            return value
        }

        guard let systemStartString = json["systemStart"] as? String else {
            throw CardanoChainError.yaciDevkitError("Shelley genesis is missing systemStart")
        }
        guard let systemStart = Self.parseISO8601(systemStartString) else {
            throw CardanoChainError.yaciDevkitError("Cannot parse systemStart: \(systemStartString)")
        }

        return GenesisParameters(
            activeSlotsCoefficient: try requireDouble("activeSlotsCoeff"),
            epochLength: try requireInt("epochLength"),
            maxKesEvolutions: try requireInt("maxKESEvolutions"),
            maxLovelaceSupply: try requireInt("maxLovelaceSupply"),
            networkId: (json["networkId"] as? String) ?? network.description,
            networkMagic: try requireInt("networkMagic"),
            securityParam: try requireInt("securityParam"),
            slotLength: try requireInt("slotLength"),
            slotsPerKesPeriod: try requireInt("slotsPerKESPeriod"),
            systemStart: systemStart,
            updateQuorum: try requireInt("updateQuorum"),
            era: .conway
        )
    }

    static func parseISO8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// Every language's cost model in ledger order, from the genesis files.
    ///
    /// Yaci returns each cost model as a map keyed by operation name. The script data hash covers
    /// the costs in ledger order, which for Plutus V3 is not alphabetical, so a transaction built
    /// from the store's order is refused (`PPViewHashesDontMatch`). Genesis lists them in ledger
    /// order, and a devnet's cost models do not change.
    private func genesisCostModels() async throws -> (v1: [Int64]?, v2: [Int64]?, v3: [Int64]?) {
        let alonzo = Self.jsonObject(try await genesisFile("alonzo"))
        let conway = Self.jsonObject(try await genesisFile("conway"))
        let models = alonzo?["costModels"] as? [String: Any]

        func model(_ names: [String]) -> [Int64]? {
            for name in names {
                if let list = Self.costList(models?[name]) { return list }
            }
            return nil
        }
        return (
            v1: model(["PlutusV1", "plutusV1", "plutus:v1"]),
            v2: model(["PlutusV2", "plutusV2", "plutus:v2"]),
            v3: Self.costList(conway?["plutusV3CostModel"])
                ?? model(["PlutusV3", "plutusV3", "plutus:v3"])
        )
    }

    /// Parse raw JSON bytes into a Foundation dictionary.
    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A cost model as a list of integers. A map is flattened in key order, which is ledger order
    /// for Plutus V1 and V2 — their parameter names sort alphabetically — but not for V3, which
    /// is why V3 is read from the Conway genesis list instead.
    static func costList(_ value: Any?) -> [Int64]? {
        if let array = value as? [Any] {
            return array.compactMap { ($0 as? NSNumber)?.int64Value }
        }
        if let object = value as? [String: Any] {
            return object.keys.sorted().compactMap { (object[$0] as? NSNumber)?.int64Value }
        }
        return nil
    }

    // MARK: - Protocol parameters

    /// The current protocol parameters, cached per epoch.
    public func protocolParameters() async throws -> ProtocolParameters {
        let currentEpoch = try await epoch()
        if let cached = _protocolParameters, _protocolParametersEpoch == currentEpoch {
            return cached
        }
        if let inFlight = _protocolParametersFetch { return try await inFlight.value }

        let task = Task<ProtocolParameters, Error> {
            do {
                let value = try await self.queryCurrentProtocolParams()
                self._protocolParameters = value
                self._protocolParametersEpoch = currentEpoch
                self._protocolParametersFetch = nil
                return value
            } catch {
                self._protocolParametersFetch = nil
                throw error
            }
        }
        _protocolParametersFetch = task
        return try await task.value
    }

    /// Query the current protocol parameters from Yaci Store, with cost models taken from genesis
    /// so they are in ledger order.
    public func queryCurrentProtocolParams() async throws -> ProtocolParameters {
        let params = try await perform("get protocol parameters") {
            try await api.client.getLatestProtocolParams().ok.body.json
        }
        let genesis = (try? await genesisCostModels()) ?? (nil, nil, nil)
        return try Self.decodeProtocolParameters(from: params, genesisCostModels: genesis)
    }

    /// Map Yaci's protocol-parameter payload onto ``ProtocolParameters``.
    ///
    /// Cost models come from `genesisCostModels` when available; otherwise from the store's own
    /// map, flattened in key order.
    static func decodeProtocolParameters(
        from params: Components.Schemas.ProtocolParamsDto,
        genesisCostModels: (v1: [Int64]?, v2: [Int64]?, v3: [Int64]?)
    ) throws -> ProtocolParameters {
        func require<T>(_ value: T?, _ name: String) throws -> T {
            guard let value else {
                throw CardanoChainError.yaciDevkitError("Protocol parameters are missing \(name)")
            }
            return value
        }
        func requireInt64(_ value: String?, _ name: String) throws -> Int64 {
            guard let value, let parsed = Int64(value) else {
                throw CardanoChainError.yaciDevkitError("Protocol parameters are missing \(name)")
            }
            return parsed
        }

        // Each language's costs arrive keyed by operation name; flattening in key order matches
        // the ledger's order for V1 and V2.
        func storeModel(_ names: [String]) -> [Int64] {
            for name in names {
                if let payload = params.costModels?.additionalProperties[name] {
                    let costs = payload.additionalProperties
                    return costs.keys.sorted().compactMap { costs[$0] }
                }
            }
            return []
        }
        let costModels = ProtocolParametersCostModels(
            PlutusV1: genesisCostModels.v1 ?? storeModel(["PlutusV1", "plutusV1", "plutus:v1"]),
            PlutusV2: genesisCostModels.v2 ?? storeModel(["PlutusV2", "plutusV2", "plutus:v2"]),
            PlutusV3: genesisCostModels.v3 ?? storeModel(["PlutusV3", "plutusV3", "plutus:v3"])
        )

        return ProtocolParameters(
            collateralPercentage: Int64(try require(params.collateralPercent, "collateral_percent")),
            committeeMaxTermLength: Int64(params.committeeMaxTermLength ?? 0),
            committeeMinSize: Int64(params.committeeMinSize ?? 0),
            costModels: costModels,
            dRepActivity: Int64(params.drepActivity ?? 0),
            dRepDeposit: Int64(params.drepDeposit ?? 0),
            dRepVotingThresholds: DRepVotingThresholds(
                committeeNoConfidence: params.dvtCommitteeNoConfidence ?? 0,
                committeeNormal: params.dvtCommitteeNormal ?? 0,
                hardForkInitiation: params.dvtHardForkInitiation ?? 0,
                motionNoConfidence: params.dvtMotionNoConfidence ?? 0,
                ppEconomicGroup: params.dvtPpeconomicGroup ?? 0,
                ppGovGroup: params.dvtPpgovGroup ?? 0,
                ppNetworkGroup: params.dvtPpnetworkGroup ?? 0,
                ppTechnicalGroup: params.dvtPptechnicalGroup ?? 0,
                treasuryWithdrawal: params.dvtTreasuryWithdrawal ?? 0,
                updateToConstitution: params.dvtUpdateToConstitution ?? 0
            ),
            executionUnitPrices: ExecutionUnitPrices(
                priceMemory: try require(params.priceMem, "price_mem"),
                priceSteps: try require(params.priceStep, "price_step")
            ),
            govActionDeposit: Int64(params.govActionDeposit ?? 0),
            govActionLifetime: Int64(params.govActionLifetime ?? 0),
            maxBlockBodySize: Int64(try require(params.maxBlockSize, "max_block_size")),
            maxBlockExecutionUnits: ProtocolParametersExecutionUnits(
                memory: try requireInt64(params.maxBlockExMem, "max_block_ex_mem"),
                steps: try requireInt64(params.maxBlockExSteps, "max_block_ex_steps")
            ),
            maxBlockHeaderSize: Int64(try require(params.maxBlockHeaderSize, "max_block_header_size")),
            maxCollateralInputs: Int64(try require(params.maxCollateralInputs, "max_collateral_inputs")),
            maxTxExecutionUnits: ProtocolParametersExecutionUnits(
                memory: try requireInt64(params.maxTxExMem, "max_tx_ex_mem"),
                steps: try requireInt64(params.maxTxExSteps, "max_tx_ex_steps")
            ),
            maxTxSize: Int64(try require(params.maxTxSize, "max_tx_size")),
            maxValueSize: try requireInt64(params.maxValSize, "max_val_size"),
            minFeeRefScriptCostPerByte: params.minFeeRefScriptCostPerByte.map { Int64($0) },
            minPoolCost: try requireInt64(params.minPoolCost, "min_pool_cost"),
            monetaryExpansion: try require(params.rho, "rho"),
            poolPledgeInfluence: try require(params.a0, "a0"),
            poolRetireMaxEpoch: Int64(try require(params.eMax, "e_max")),
            poolVotingThresholds: ProtocolParametersPoolVotingThresholds(
                committeeNoConfidence: params.pvtCommitteeNoConfidence ?? 0,
                committeeNormal: params.pvtCommitteeNormal ?? 0,
                hardForkInitiation: params.pvtHardForkInitiation ?? 0,
                motionNoConfidence: params.pvtMotionNoConfidence ?? 0,
                // Yaci Store spells this parameter two ways across releases.
                ppSecurityGroup: params.pvtppSecurityGroup ?? params.pvtPPSecurityGroup ?? 0
            ),
            protocolVersion: ProtocolParametersProtocolVersion(
                major: Int(try require(params.protocolMajorVer, "protocol_major_ver")),
                minor: Int(params.protocolMinorVer ?? 0)
            ),
            stakeAddressDeposit: try requireInt64(params.keyDeposit, "key_deposit"),
            stakePoolDeposit: try requireInt64(params.poolDeposit, "pool_deposit"),
            stakePoolTargetNum: Int64(try require(params.nOpt, "n_opt")),
            treasuryCut: try require(params.tau, "tau"),
            txFeeFixed: Int64(try require(params.minFeeB, "min_fee_b")),
            txFeePerByte: Int64(try require(params.minFeeA, "min_fee_a")),
            // Babbage and later report the cost per byte; Yaci's Alonzo-era `coins_per_utxo_word`
            // is deprecated and a DevKit devnet is Conway, so only the byte form is read.
            utxoCostPerByte: try requireInt64(params.coinsPerUtxoSize, "coins_per_utxo_size")
        )
    }

    // MARK: - UTxOs

    /// Get all UTxOs associated with an address.
    ///
    /// Every page is fetched: the endpoint returns ten rows unless asked for more, and a wallet
    /// with an eleventh UTxO would otherwise lose it without any error.
    public func utxos(address: Address) async throws -> [UTxO] {
        let bech32 = try address.toBech32()
        let rows = try await addressUtxos(bech32)

        var utxos: [UTxO] = []
        for row in rows {
            guard let txHash = row.txHash, let outputIndex = row.outputIndex else { continue }
            let input = TransactionInput(
                transactionId: try TransactionId(from: .string(txHash)),
                index: UInt16(outputIndex)
            )
            let units: [(unit: String, quantity: Int64)] = (row.amount ?? []).compactMap { item in
                guard let quantity = item.quantity.flatMap({ Int64($0) }) else { return nil }
                if let unit = item.unit, !unit.isEmpty { return (unit, quantity) }
                guard let policy = item.policyId else { return nil }
                return (policy + (item.assetName ?? ""), quantity)
            }
            let output = try await makeOutput(
                address: row.address ?? bech32,
                lovelace: nil,
                units: units,
                dataHash: row.dataHash,
                inlineDatum: row.inlineDatum,
                referenceScriptHash: row.referenceScriptHash
            )
            utxos.append(UTxO(input: input, output: output))
        }
        return utxos
    }

    private func addressUtxos(_ address: String) async throws -> [Components.Schemas.Utxo] {
        try await paginate("get UTxOs for address \(address)") { page, count in
            try await api.client.getUtxos1(
                path: .init(address: address),
                query: .init(count: count, page: page, order: .asc)
            ).ok.body.json
        }
    }

    /// Resolve a single UTxO by the transaction input that identifies it.
    ///
    /// Yaci's output store keeps outputs after they are spent but records no spent flag on them,
    /// so whether the output is still live is decided by looking for it in its own address' live
    /// UTxO set. That costs one extra (paginated) request, and an address with a very large UTxO
    /// set makes it an expensive one.
    ///
    /// - Returns: The UTxO and whether it has been spent, or `nil` if Yaci has not indexed it.
    ///   Yaci retains spent outputs, so unlike a live-UTxO-set backend this can return `true`.
    public func utxo(input: TransactionInput) async throws -> (UTxO, isSpent: Bool)? {
        let txHash = input.transactionId.payload.toHex
        let index = Int32(input.index)

        let output = try await perform("get UTxO \(txHash)#\(index)") {
            try await api.client.getUtxo(path: .init(txHash: txHash, index: index))
        }
        guard case .ok(let ok) = output else { return nil }
        let row = try ok.body.json

        guard let address = row.ownerAddr, !address.isEmpty else { return nil }

        let units: [(unit: String, quantity: Int64)] = (row.amounts ?? []).compactMap { item in
            guard let quantity = item.quantity.map({ Int64($0) }) else { return nil }
            if let unit = item.unit, !unit.isEmpty { return (unit, quantity) }
            guard let policy = item.policyId else { return nil }
            return (policy + (item.assetName ?? ""), quantity)
        }
        let txOut = try await makeOutput(
            address: address,
            lovelace: row.lovelaceAmount.map { Int64($0) },
            units: units,
            dataHash: row.dataHash,
            inlineDatum: row.inlineDatum,
            referenceScriptHash: row.referenceScriptHash
        )

        let live = try await addressUtxos(address)
        let isUnspent = live.contains {
            $0.txHash?.lowercased() == txHash.lowercased() && $0.outputIndex == index
        }
        return (UTxO(input: input, output: txOut), !isUnspent)
    }

    /// Build a `TransactionOutput` from Yaci's flattened representation.
    private func makeOutput(
        address: String,
        lovelace: Int64?,
        units: [(unit: String, quantity: Int64)],
        dataHash: String?,
        inlineDatum: String?,
        referenceScriptHash: String?
    ) async throws -> TransactionOutput {
        var coin = lovelace ?? 0
        var multiAsset = MultiAsset([:])
        for (unit, quantity) in units {
            if unit == "lovelace" {
                coin = quantity
                continue
            }
            // The unit is `<policy id><asset name>`, hex encoded.
            let data = Data(hex: unit)
            guard data.count >= SCRIPT_HASH_SIZE else { continue }
            let policyId = ScriptHash(payload: data.prefix(SCRIPT_HASH_SIZE))
            let assetName = try AssetName(payload: data.suffix(from: SCRIPT_HASH_SIZE))
            if multiAsset[policyId] == nil {
                multiAsset[policyId] = Asset([:])
            }
            multiAsset[policyId]?[assetName] = quantity
        }

        var datumHash: DatumHash? = nil
        var datumOption: DatumOption? = nil
        if let dataHash, !dataHash.isEmpty, inlineDatum == nil {
            datumHash = try DatumHash(from: .string(dataHash))
        }
        if let inlineDatum, let datumData = Data(hexString: inlineDatum), !datumData.isEmpty {
            let plutusData = try PlutusData.fromCBOR(data: datumData)
            datumOption = DatumOption(datum: plutusData)
        }

        var script: ScriptType? = nil
        if let referenceScriptHash, !referenceScriptHash.isEmpty {
            script = try? await getScript(scriptHash: referenceScriptHash)
        }

        return TransactionOutput(
            address: try Address(from: .string(address)),
            amount: Value(coin: coin, multiAsset: multiAsset),
            datumHash: datumHash,
            datumOption: datumOption,
            script: script
        )
    }

    // MARK: - Scripts

    private func getScript(scriptHash: String) async throws -> ScriptType {
        let info = try await perform("get script \(scriptHash)") {
            try await api.client.getScriptByHash(path: .init(scriptHash: scriptHash)).ok.body.json
        }

        switch info._type {
        case .plutusV1, .plutusV2, .plutusV3:
            let cbor = try await perform("get the CBOR of script \(scriptHash)") {
                try await api.client.getScriptCborByHash(path: .init(scriptHash: scriptHash)).ok.body.json
            }
            guard let hex = cbor.cbor, let bytes = Data(hexString: hex), !bytes.isEmpty else {
                throw CardanoChainError.yaciDevkitError("Script \(scriptHash) has no CBOR")
            }
            return try Self.plutusScript(
                type: info._type?.rawValue ?? "", bytes: bytes, expectedHash: scriptHash
            )
        case .timelock, nil:
            let json = try await perform("get the JSON of script \(scriptHash)") {
                try await api.client.getScriptJsonByHash(path: .init(scriptHash: scriptHash)).ok.body.json
            }
            guard let node = json.json,
                let data = try? JSONEncoder().encode(node),
                let text = String(data: data, encoding: .utf8)
            else {
                throw CardanoChainError.yaciDevkitError("Script \(scriptHash) has no JSON")
            }
            // `NativeScript.fromJSON` is the entry point that understands the `{"type": "sig",
            // …}` shape; decoding the type directly goes through its CBOR representation instead.
            return .nativeScript(try NativeScript.fromJSON(text))
        }
    }

    /// Build a Plutus script whose hash matches `expectedHash`, unwrapping one CBOR byte-string
    /// layer if the stored bytes are double-encoded.
    static func plutusScript(type: String, bytes: Data, expectedHash: String) throws -> ScriptType {
        func build(_ data: Data) -> ScriptType {
            switch type {
            case "plutusV1": return .plutusV1Script(PlutusV1Script(data: data))
            case "plutusV2": return .plutusV2Script(PlutusV2Script(data: data))
            default: return .plutusV3Script(PlutusV3Script(data: data))
            }
        }
        func matches(_ script: ScriptType) -> Bool {
            (try? scriptHash(script: script).payload.toHex.lowercased()) == expectedHash.lowercased()
        }

        let candidate = build(bytes)
        if matches(candidate) { return candidate }
        if let unwrapped = Self.unwrapCBORByteString(bytes) {
            let inner = build(unwrapped)
            if matches(inner) { return inner }
        }
        throw CardanoChainError.valueError("Cannot recover script \(expectedHash) from its CBOR.")
    }

    /// If `data` is a single CBOR byte string (major type 2), return its payload.
    static func unwrapCBORByteString(_ data: Data) -> Data? {
        guard let first = data.first, first >= 0x40, first <= 0x5b else { return nil }
        let bytes = [UInt8](data)
        var length = 0
        var offset = 1
        switch first {
        case 0x40...0x57:
            length = Int(first - 0x40)
        case 0x58:
            guard bytes.count >= 2 else { return nil }
            length = Int(bytes[1])
            offset = 2
        case 0x59:
            guard bytes.count >= 3 else { return nil }
            length = Int(bytes[1]) << 8 | Int(bytes[2])
            offset = 3
        case 0x5a:
            guard bytes.count >= 5 else { return nil }
            length = Int(bytes[1]) << 24 | Int(bytes[2]) << 16 | Int(bytes[3]) << 8 | Int(bytes[4])
            offset = 5
        default:
            return nil
        }
        guard bytes.count == offset + length else { return nil }
        return Data(bytes[offset...])
    }

    // MARK: - Transactions

    /// Submit a transaction.
    ///
    /// Posted as raw bytes with `Content-Type: application/cbor`; the store answers 202 with the
    /// transaction hash.
    public func submitTxCBOR(cbor: Data) async throws -> String {
        let output = try await perform("submit the transaction") {
            try await api.client.submitTx1(.init(body: .applicationCbor(HTTPBody(cbor))))
        }
        switch output {
        case .ok(let ok):
            return try ok.body.json
        case .accepted(let accepted):
            return try accepted.body.json
        case .undocumented(let statusCode, let payload):
            throw CardanoChainError.transactionFailed(
                "Failed to submit transaction. Error code: \(statusCode). Error message: \(await Self.text(of: payload))"
            )
        }
    }

    /// Ogmios' names for script purposes, where they differ from the redeemer tags used by the
    /// rest of this library.
    private static let ogmiosPurposes = ["withdraw": "withdrawal", "publish": "certificate"]

    /// Evaluate execution units of a transaction.
    ///
    /// The transaction is sent as hex, which is the form this endpoint takes. It needs Ogmios
    /// enabled in the DevKit (`ogmios_enabled=true`). Both the Ogmios v5 response shape (an
    /// `EvaluationResult` map) and the v6 one (a list of validator budgets) are handled.
    public func evaluateTxCBOR(cbor: Data) async throws -> [String: ExecutionUnits] {
        let output = try await perform("evaluate the transaction") {
            try await api.client.evaluateTx(.init(body: .applicationCbor(HTTPBody(Data(cbor.toHex.utf8)))))
        }

        let container: OpenAPIObjectContainer
        switch output {
        case .ok(let ok):
            container = try ok.body.json
        case .accepted(let accepted):
            container = try accepted.body.json
        case .undocumented(let statusCode, let payload):
            throw CardanoChainError.transactionFailed(
                "Failed to evaluate transaction. Error code: \(statusCode). Error message: \(await Self.text(of: payload))"
            )
        }

        let body = Self.jsonObject(container) ?? [:]
        let result = body["result"] as? [String: Any]

        var units: [String: ExecutionUnits] = [:]
        if let evaluation = result?["EvaluationResult"] as? [String: Any] {
            for (key, value) in evaluation {
                guard let cost = value as? [String: Any] else { continue }
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let purpose = Self.ogmiosPurposes[parts[0]] ?? parts[0]
                units["\(purpose):\(parts[1])"] = ExecutionUnits(
                    mem: (cost["memory"] as? NSNumber)?.int64Value ?? 0,
                    steps: (cost["steps"] as? NSNumber)?.int64Value ?? 0
                )
            }
        } else if let list = body["result"] as? [Any] {
            for entry in list {
                guard let entry = entry as? [String: Any],
                    let validator = entry["validator"] as? [String: Any],
                    let purposeRaw = validator["purpose"] as? String,
                    let index = (validator["index"] as? NSNumber)?.int64Value,
                    let budget = entry["budget"] as? [String: Any]
                else { continue }
                let purpose = Self.ogmiosPurposes[purposeRaw] ?? purposeRaw
                units["\(purpose):\(index)"] = ExecutionUnits(
                    mem: (budget["memory"] as? NSNumber)?.int64Value ?? 0,
                    steps: (budget["cpu"] as? NSNumber)?.int64Value
                        ?? (budget["steps"] as? NSNumber)?.int64Value ?? 0
                )
            }
        } else {
            throw CardanoChainError.transactionFailed("Failed to evaluate transaction: \(body)")
        }
        return units
    }

    /// Re-encode an OpenAPI JSON container as a Foundation dictionary.
    ///
    /// The generated container stores its values as `(any Sendable)?`, so a JSON round-trip is
    /// both shorter and safer than casting through that representation by hand.
    static func jsonObject(_ container: OpenAPIObjectContainer?) -> [String: Any]? {
        guard let container,
            let data = try? JSONEncoder().encode(container),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// The body of an undocumented response, for error messages.
    private static func text(of payload: UndocumentedPayload) async -> String {
        guard let body = payload.body,
            let data = try? await Data(collecting: body, upTo: 8 * 1024)
        else { return "<no body>" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Stake addresses

    /// Get the stake address information.
    ///
    /// Yaci reports the delegated pool and the withdrawable rewards. Vote delegation is read from
    /// the vote-delegation certificate log, on a best-effort basis.
    public func stakeAddressInfo(address: Address) async throws -> [StakeAddressInfo] {
        let bech32 = try address.toBech32()

        let output = try await perform("get stake account \(bech32)") {
            try await api.client.getStakeAccountDetails(path: .init(stakeAddress: bech32))
        }
        guard case .ok(let ok) = output else {
            return [StakeAddressInfo(active: false, address: bech32, rewardAccountBalance: 0)]
        }
        let info = try ok.body.json

        var stakeDelegation: PoolOperator? = nil
        if let poolId = info.poolId, !poolId.isEmpty {
            stakeDelegation = try? Self.poolOperator(from: poolId)
        }
        let voteDelegation = try? await latestVoteDelegation(stakeAddress: bech32)

        return [
            StakeAddressInfo(
                active: true,
                address: info.stakeAddress ?? bech32,
                rewardAccountBalance: Int64(info.withdrawableAmount ?? 0),
                stakeDelegation: stakeDelegation,
                voteDelegation: voteDelegation
            )
        ]
    }

    private func latestVoteDelegation(stakeAddress: String) async throws -> DRep? {
        let rows = try await paginate("get vote delegations for \(stakeAddress)") { page, count in
            try await api.client.getDelegationsByAddress(
                path: .init(address: stakeAddress),
                query: .init(page: page, count: count, order: .asc)
            ).ok.body.json
        }
        guard
            let latest = rows.max(by: {
                Self.certificateOrder($0.slot, $0.certIndex) < Self.certificateOrder($1.slot, $1.certIndex)
            })
        else { return nil }

        switch latest.drepType {
        case .abstain:
            return DRep(credential: .alwaysAbstain)
        case .noConfidence:
            return DRep(credential: .alwaysNoConfidence)
        case .scripthash:
            guard let hash = latest.drepHash, let payload = Data(hexString: hash) else { return nil }
            return DRep(credential: .scriptHash(ScriptHash(payload: payload)))
        case .addrKeyhash:
            guard let hash = latest.drepHash, let payload = Data(hexString: hash) else { return nil }
            return DRep(credential: .verificationKeyHash(VerificationKeyHash(payload: payload)))
        case nil:
            guard let id = latest.drepId else { return nil }
            return try? DRep(from: id)
        }
    }

    /// Ordering key for certificate rows: (slot, certificate index).
    private static func certificateOrder(_ slot: Int64?, _ certIndex: Int64?) -> (Int64, Int64) {
        (slot ?? 0, certIndex ?? 0)
    }

    private static func certificateOrder(_ slot: Int64?, _ certIndex: Int32?) -> (Int64, Int64) {
        (slot ?? 0, Int64(certIndex ?? 0))
    }

    /// Normalise a bech32 or hex pool ID to a `PoolOperator`.
    static func poolOperator(from poolId: String) throws -> PoolOperator {
        if let pool = try? PoolOperator(from: poolId) { return pool }
        if let data = Data(hexString: poolId), data.count == POOL_KEY_HASH_SIZE {
            return try PoolOperator(from: data)
        }
        throw CardanoChainError.invalidArgument("Invalid pool ID: \(poolId)")
    }

    // MARK: - Stake pools

    private struct PoolCertificates {
        let registration: Components.Schemas.PoolRegistration
        let retirement: Components.Schemas.PoolRetirement?
    }

    /// Fold the pool certificate log into the latest state of every pool.
    ///
    /// This is a reconstruction, not a state read. Yaci exposes pool registrations and
    /// retirements as an event log with no current-state view, so the latest registration for a
    /// pool is taken as its live parameters, and a retirement is kept only when no later
    /// registration has superseded it — which is exactly how the ledger resolves them. It goes
    /// wrong if Yaci is pruned or has not finished syncing, since an unseen certificate is
    /// indistinguishable from one that was never submitted.
    ///
    /// - Returns: Keyed by the pool's lowercase hex key hash.
    private func poolCertificates() async throws -> [String: PoolCertificates] {
        let registrations = try await paginate("get pool registrations") { page, count in
            try await api.client.getPoolRegistrations(query: .init(page: page, count: count))
                .ok.body.json
        }
        let retirements = try await paginate("get pool retirements") { page, count in
            try await api.client.getRetirements(query: .init(page: page, count: count)).ok.body.json
        }

        var latestRegistration: [String: Components.Schemas.PoolRegistration] = [:]
        for registration in registrations.sorted(by: {
            Self.certificateOrder($0.slot, $0.certIndex) < Self.certificateOrder($1.slot, $1.certIndex)
        }) {
            if let poolId = registration.poolId?.lowercased(), !poolId.isEmpty {
                latestRegistration[poolId] = registration
            }
        }
        var latestRetirement: [String: Components.Schemas.PoolRetirement] = [:]
        for retirement in retirements.sorted(by: {
            Self.certificateOrder($0.slot, $0.certIndex) < Self.certificateOrder($1.slot, $1.certIndex)
        }) {
            if let poolId = retirement.poolId?.lowercased(), !poolId.isEmpty {
                latestRetirement[poolId] = retirement
            }
        }

        var state: [String: PoolCertificates] = [:]
        for (poolId, registration) in latestRegistration {
            var outstanding = latestRetirement[poolId]
            if let retirement = outstanding, (retirement.slot ?? 0) < (registration.slot ?? 0) {
                // Re-registering after announcing a retirement cancels it.
                outstanding = nil
            }
            state[poolId] = PoolCertificates(registration: registration, retirement: outstanding)
        }
        return state
    }

    /// A retirement takes effect at the start of its retirement epoch, so the pool is still
    /// retiring for every epoch before that one.
    private static func poolStatus(
        retirement: Components.Schemas.PoolRetirement?, epoch: Int
    ) -> PoolStatus {
        guard let retirement else { return .registered }
        if let retiringEpoch = retirement.retirementEpoch, Int32(epoch) < retiringEpoch {
            return .retiring(epoch: UInt(retiringEpoch))
        }
        return .retired
    }

    /// Get every stake pool registered on the chain.
    ///
    /// Reconstructed from Yaci's pool certificate log. Pools whose retirement epoch has already
    /// passed are excluded, so this is the set of pools that are live or still winding down.
    public func stakePools() async throws -> [PoolOperator] {
        let epoch = try await epoch()
        let certificates = try await poolCertificates()
        return try certificates.keys.sorted().compactMap { poolId in
            guard let entry = certificates[poolId] else { return nil }
            if case .retired = Self.poolStatus(retirement: entry.retirement, epoch: epoch) {
                return nil
            }
            return try PoolOperator(from: Data(hex: poolId))
        }
    }

    /// Get a stake pool's registered parameters and status.
    ///
    /// Off-chain metadata is not downloaded; the registered URL and hash are returned as they
    /// appear on-chain. See ``stakePoolInfo(poolId:strict:)`` to verify it.
    public func stakePoolInfo(poolId: String) async throws -> StakePoolInfo {
        try await stakePoolInfo(poolId: poolId, strict: false)
    }

    /// Get a stake pool's registered parameters and status.
    ///
    /// Read from Yaci's per-epoch pool state where that is available, and otherwise
    /// reconstructed from the pool certificate log. Yaci indexes certificates rather than ledger
    /// state, so it reports no stake figures at all: `liveStake`, `livePledge`, `liveSize`,
    /// `activeStake`, `activeSize` and `opcertCounter` are left `nil` rather than guessed at.
    /// `pledge` inside `poolParams` is the *declared* pledge from the certificate, which is not
    /// the same thing as live pledge.
    ///
    /// - Parameters:
    ///   - poolId: The pool's ID, bech32 or hex encoded.
    ///   - strict: When `true`, the pool's off-chain metadata is downloaded and its hash
    ///     verified, and any failure is fatal. When `false`, the registered URL and hash are
    ///     returned without fetching the document.
    public func stakePoolInfo(poolId: String, strict: Bool) async throws -> StakePoolInfo {
        let poolOperator = try Self.poolOperator(from: poolId)
        let poolIdHex = poolOperator.poolKeyHash.payload.toHex.lowercased()
        let currentEpoch = try await epoch()

        if let details = await poolDetails(poolOperator: poolOperator, epoch: currentEpoch) {
            return StakePoolInfo(
                poolParams: try await Self.poolParams(from: details, strict: strict),
                status: Self.poolStatus(from: details, epoch: currentEpoch)
            )
        }

        guard let entry = try await poolCertificates()[poolIdHex] else {
            throw CardanoChainError.valueError("Pool \(poolId) was not found.")
        }
        return StakePoolInfo(
            poolParams: try await Self.poolParams(from: entry.registration, strict: strict),
            status: Self.poolStatus(retirement: entry.retirement, epoch: currentEpoch)
        )
    }

    /// Yaci's per-epoch view of a pool, or `nil` when the store cannot answer for either form of
    /// the pool's ID.
    private func poolDetails(
        poolOperator: PoolOperator, epoch: Int
    ) async -> Components.Schemas.PoolDetailsDto? {
        let ids = [try? poolOperator.id(.bech32), poolOperator.poolKeyHash.payload.toHex]
        for id in ids.compactMap({ $0 }) {
            guard
                let output = try? await api.client.getPoolDetails(
                    path: .init(poolId: id, epoch: Int32(epoch))
                ),
                case .ok(let ok) = output,
                let details = try? ok.body.json,
                details.poolId != nil || details.poolHash != nil
            else { continue }
            return details
        }
        return nil
    }

    private static func poolStatus(from details: Components.Schemas.PoolDetailsDto, epoch: Int)
        -> PoolStatus
    {
        switch details.status {
        case .retired:
            return .retired
        case .retiring:
            if let retiring = details.retireEpoch, Int32(epoch) < retiring {
                return .retiring(epoch: UInt(retiring))
            }
            return .retired
        case .registration, .update, nil:
            return .registered
        }
    }

    /// Map one Yaci relay entry onto the matching relay type.
    ///
    /// Yaci reports every relay with the same four fields and leaves the ones that do not apply
    /// unset, so the shape is inferred from which are populated.
    static func relay(from relay: Components.Schemas.Relay) -> SwiftCardanoCore.Relay? {
        let port = relay.port.map { Int($0) }
        let ipv4 = relay.ipv4.flatMap { $0.isEmpty ? nil : IPv4Address($0) }
        let ipv6 = relay.ipv6.flatMap { $0.isEmpty ? nil : IPv6Address($0) }
        if ipv4 != nil || ipv6 != nil {
            return .singleHostAddr(SingleHostAddr(port: port, ipv4: ipv4, ipv6: ipv6))
        }
        guard let dns = relay.dnsName, !dns.isEmpty else { return nil }
        if let port {
            return .singleHostName(SingleHostName(port: port, dnsName: dns))
        }
        return .multiHostName(MultiHostName(dnsName: dns))
    }

    /// Map one registered pool owner onto its staking key hash.
    ///
    /// Yaci reports owners as raw key hashes, but a bech32 stake address is tolerated too, so a
    /// differently configured store still resolves.
    static func poolOwner(_ owner: String) throws -> VerificationKeyHash {
        if owner.hasPrefix("stake") {
            let address = try Address(from: .string(owner))
            switch address.stakingPart {
            case .verificationKeyHash(let hash):
                return VerificationKeyHash(payload: hash.payload)
            case .scriptHash(let hash):
                return VerificationKeyHash(payload: hash.payload)
            default:
                throw CardanoChainError.valueError("Pool owner has no staking credential: \(owner)")
            }
        }
        guard let data = Data(hexString: owner) else {
            throw CardanoChainError.valueError("Invalid pool owner: \(owner)")
        }
        return VerificationKeyHash(payload: data)
    }

    /// The reward account as its 29-byte on-chain form, from either the bech32 stake address or
    /// the raw hex Yaci reports.
    private static func rewardAccount(bech32: String?, hex: String?) throws -> RewardAccountHash {
        if let bech32, bech32.hasPrefix("stake") {
            return RewardAccountHash(payload: try Address(from: .string(bech32)).toBytes())
        }
        if let hex, let data = Data(hexString: hex), !data.isEmpty {
            return RewardAccountHash(payload: data)
        }
        if let bech32, let data = Data(hexString: bech32), !data.isEmpty {
            return RewardAccountHash(payload: data)
        }
        throw CardanoChainError.valueError("Pool has no reward account")
    }

    private static func poolMetadata(url urlString: String?, hash hashString: String?, strict: Bool)
        async throws -> PoolMetadata?
    {
        guard let urlString, !urlString.isEmpty,
            let hashString, let hashData = Data(hexString: hashString), !hashData.isEmpty
        else { return nil }

        let url = try Url(urlString)
        let hash = PoolMetadataHash(payload: hashData)
        if strict {
            return try await PoolMetadata.fetch(url: url, poolMetadataHash: hash)
        }
        return try PoolMetadata(url: url, poolMetadataHash: hash)
    }

    private static func poolParams(
        from registration: Components.Schemas.PoolRegistration, strict: Bool
    ) async throws -> PoolParams {
        // Prefer the exact registered ratio over the rounded decimal Yaci also reports.
        let margin: UnitInterval
        if let numerator = registration.marginNumerator, let denominator = registration.marginDenominator,
            denominator > 0, numerator >= 0
        {
            margin = UnitInterval(numerator: UInt64(numerator), denominator: UInt64(denominator))
        } else {
            margin = makeUnitInterval(registration.margin ?? 0)
        }

        return PoolParams(
            poolOperator: PoolKeyHash(payload: Data(hex: registration.poolId ?? "")),
            vrfKeyHash: VrfKeyHash(payload: Data(hex: registration.vrfKeyHash ?? "")),
            pledge: registration.pledge ?? 0,
            cost: registration.cost ?? 0,
            margin: margin,
            rewardAccount: try rewardAccount(
                bech32: registration.rewardAccount, hex: registration.rewardAccount
            ),
            poolOwners: .list(try (registration.poolOwners ?? []).map { try poolOwner($0) }),
            relays: (registration.relays ?? []).compactMap { relay(from: $0) },
            poolMetadata: try await poolMetadata(
                url: registration.metadataUrl, hash: registration.metadataHash, strict: strict
            )
        )
    }

    private static func poolParams(
        from details: Components.Schemas.PoolDetailsDto, strict: Bool
    ) async throws -> PoolParams {
        return PoolParams(
            poolOperator: PoolKeyHash(payload: Data(hex: details.poolHash ?? "")),
            vrfKeyHash: VrfKeyHash(payload: Data(hex: details.vrfKeyHash ?? "")),
            pledge: details.pledge.flatMap { Int($0) } ?? 0,
            cost: details.cost.flatMap { Int($0) } ?? 0,
            margin: makeUnitInterval(details.margin.flatMap { Double($0) } ?? 0),
            rewardAccount: try rewardAccount(bech32: details.rewardAccount, hex: details.rewardAccount),
            poolOwners: .list(try (details.poolOwners ?? []).map { try poolOwner($0) }),
            relays: (details.relays ?? []).compactMap { relay(from: $0) },
            poolMetadata: try await poolMetadata(
                url: details.metadataUrl, hash: details.metadataHash, strict: strict
            )
        )
    }

    /// Get the KES period information for a stake pool.
    ///
    /// Yaci has no operational-certificate query, so the counter is read from the most recent
    /// block the pool minted, looking at the current epoch and then the previous one.
    ///
    /// - Throws: ``CardanoChainError/invalidArgument(_:)`` if `pool` is `nil`;
    ///   ``CardanoChainError/yaciDevkitError(_:)`` if the pool has not minted a block recently.
    public func kesPeriodInfo(pool: PoolOperator?, opCert: OperationalCertificate? = nil)
        async throws -> KESPeriodInfo
    {
        guard let pool else {
            throw CardanoChainError.invalidArgument("Pool operator must be provided")
        }
        let poolIdBech32 = try pool.id(.bech32)
        let ids = [pool.poolKeyHash.payload.toHex, poolIdBech32]
        let currentEpoch = try await epoch()

        var blocks: [Components.Schemas.PoolBlock] = []
        for epoch in [currentEpoch, currentEpoch - 1] where epoch >= 0 && blocks.isEmpty {
            for id in ids where blocks.isEmpty {
                blocks =
                    (try? await api.client.getBlocksBySlotLeaderEpoch(
                        path: .init(poolId: id), query: .init(epoch: Int32(epoch))
                    ).ok.body.json) ?? []
            }
        }
        guard let latest = blocks.max(by: { ($0.number ?? 0) < ($1.number ?? 0) }),
            let number = latest.number
        else {
            throw CardanoChainError.yaciDevkitError(
                "Pool \(poolIdBech32) has not minted a block in the current or previous epoch"
            )
        }

        let block = try await perform("get block \(number)") {
            try await api.client.getBlockByNumber(path: .init(numberOrHash: String(number)))
                .ok.body.json
        }
        guard let counter = block.opCertCounter.flatMap({ Int($0) }) else {
            throw CardanoChainError.yaciDevkitError(
                "Block \(number) carries no operational certificate counter"
            )
        }

        if let opCert {
            return KESPeriodInfo(
                onChainOpCertCount: counter,
                onDiskOpCertCount: Int(opCert.sequenceNumber),
                nextChainOpCertCount: counter + 1,
                onDiskKESStart: Int(opCert.kesPeriod)
            )
        }
        return KESPeriodInfo(onChainOpCertCount: counter, nextChainOpCertCount: counter + 1)
    }

    // MARK: - DReps

    /// Every DRep certificate Yaci has indexed, oldest first.
    ///
    /// Yaci splits registrations, updates and retirements across three endpoints; a DRep's
    /// current state is the latest row of the three.
    private func drepCertificates() async throws -> [Components.Schemas.DRepRegistration] {
        let registrations = try await paginate("get DRep registrations") { page, count in
            try await api.client.getDRepRegistrations(query: .init(page: page, count: count, order: .asc))
                .ok.body.json
        }
        let updates = try await paginate("get DRep updates") { page, count in
            try await api.client.getDRepUpdates(query: .init(page: page, count: count, order: .asc))
                .ok.body.json
        }
        let deregistrations = try await paginate("get DRep deregistrations") { page, count in
            try await api.client.getDRepDeRegistrations(query: .init(page: page, count: count, order: .asc))
                .ok.body.json
        }
        return (registrations + updates + deregistrations).sorted {
            Self.certificateOrder($0.slot, $0.certIndex) < Self.certificateOrder($1.slot, $1.certIndex)
        }
    }

    /// Get a delegate representative's registration.
    ///
    /// This is a reconstruction, not a state read: the DRep's status is taken from its latest
    /// certificate. A retirement last means `.retired`, a registration or update last means
    /// `.registered`, and no certificate at all means `.notRegistered`.
    ///
    /// `stake` is the DRep's live voting power, read from DevKit's local-state endpoint. That
    /// endpoint is only served while the DevKit cluster is running, so `stake` falls back to `0`
    /// when it cannot be reached. `expiry` is left `nil`: it depends on the DRep's last activity
    /// including its votes, which Yaci does not aggregate.
    public func drepInfo(drep: DRep) async throws -> DRepInfo {
        let hex: String
        switch drep.credential {
        case .verificationKeyHash(let hash):
            hex = hash.payload.toHex.lowercased()
        case .scriptHash(let hash):
            hex = hash.payload.toHex.lowercased()
        case .alwaysAbstain, .alwaysNoConfidence:
            // Predefined DReps are never registered by a certificate, so Yaci has nothing on them.
            return DRepInfo(
                active: false, drep: drep, anchor: nil, deposit: nil,
                stake: Coin(0), expiry: nil, status: .notRegistered
            )
        }

        let certificates = try await drepCertificates().filter { $0.drepHash?.lowercased() == hex }
        guard let latest = certificates.last else {
            return DRepInfo(
                active: false, drep: drep, anchor: nil, deposit: nil,
                stake: Coin(0), expiry: nil, status: .notRegistered
            )
        }

        let retired = latest._type == .unregDrepCert
        let deposit = certificates.reversed()
            .first { $0._type == .regDrepCert }?
            .deposit.map { Coin(UInt64(max(0, $0))) }

        return DRepInfo(
            active: !retired,
            drep: drep,
            anchor: Self.anchor(url: latest.anchorUrl, hash: latest.anchorHash),
            deposit: deposit,
            stake: await drepStake(hex: hex) ?? Coin(0),
            expiry: nil,
            status: retired ? .retired : .registered
        )
    }

    /// A DRep's live voting power, or `nil` when the local-state endpoint is unavailable.
    private func drepStake(hex: String) async -> Coin? {
        guard let output = try? await api.client.getDRepStakeDistr(path: .init(dRepHash: hex)),
            case .ok(let ok) = output,
            let amount = try? ok.body.json.amount
        else { return nil }
        return Coin(UInt64(max(0, amount)))
    }

    /// Effective stake delegated to each DRep this epoch.
    ///
    /// Yaci has no distribution endpoint, so the registered DReps are enumerated from the
    /// certificate log and each one's live stake is read individually. DReps whose stake cannot
    /// be read are omitted.
    public func drepStakeDistribution() async throws -> [SwiftCardanoNetwork.DRepStakeEntry] {
        var latestByHash: [String: Components.Schemas.DRepRegistration] = [:]
        for certificate in try await drepCertificates() {
            guard let hash = certificate.drepHash?.lowercased(), !hash.isEmpty else { continue }
            latestByHash[hash] = certificate
        }

        var entries: [SwiftCardanoNetwork.DRepStakeEntry] = []
        for hash in latestByHash.keys.sorted() {
            guard let certificate = latestByHash[hash], certificate._type != .unregDrepCert,
                let payload = Data(hexString: hash), !payload.isEmpty,
                let stake = await drepStake(hex: hash)
            else { continue }
            let drep =
                certificate.credType == .scripthash
                ? DRep(credential: .scriptHash(ScriptHash(payload: payload)))
                : DRep(credential: .verificationKeyHash(VerificationKeyHash(payload: payload)))
            entries.append(.init(drep: drep, stake: UInt64(stake)))
        }
        return entries
    }

    /// Build an anchor from the URL and hash Yaci reports beside a certificate, or `nil` when
    /// either half is missing or the hash is not valid hex.
    static func anchor(url: String?, hash: String?) -> Anchor? {
        guard let url, !url.isEmpty,
            let hash, let hashData = Data(hexString: hash), !hashData.isEmpty,
            let anchorUrl = try? Url(url)
        else { return nil }
        return Anchor(anchorUrl: anchorUrl, anchorDataHash: AnchorDataHash(payload: hashData))
    }

    // MARK: - Governance actions

    /// The number of epochs a governance action stays open for voting.
    private func govActionLifetime() async throws -> Int32? {
        try await perform("get protocol parameters") {
            try await api.client.getLatestProtocolParams().ok.body.json.govActionLifetime
        }
    }

    private func findProposal(_ govActionID: GovActionID) async throws
        -> Components.Schemas.GovActionProposal
    {
        let txHash = govActionID.transactionID.payload.toHex
        let proposals = try await perform("get governance proposals of \(txHash)") {
            try await api.client.getGovActionProposalByTx(path: .init(txHash: txHash)).ok.body.json
        }
        guard let proposal = proposals.first(where: { $0.index == Int64(govActionID.govActionIndex) })
        else {
            throw CardanoChainError.valueError("Governance action not found: \(govActionID)")
        }
        return proposal
    }

    private static func govActionID(of proposal: Components.Schemas.GovActionProposal) -> GovActionID? {
        guard let txHash = proposal.txHash, let index = proposal.index else { return nil }
        return GovActionID(
            transactionID: TransactionId(payload: Data(hex: txHash)),
            govActionIndex: UInt16(index)
        )
    }

    /// Get the lifecycle information for a governance action.
    ///
    /// Yaci indexes the proposal certificate, not the ledger's governance state, so it has no
    /// record of whether an action was ratified, enacted, dropped or expired: those four epochs
    /// are always `nil`, which makes `status` report `nil` — "still open" — for every action,
    /// including ones that have long since concluded. `expiresAfter` is derived, not read: it is
    /// the proposal's epoch plus the current `govActionLifetime`, which is wrong for an action
    /// whose lifetime parameter has since changed.
    public func govActionInfo(govActionID: GovActionID) async throws -> GovActionInfo {
        let proposal = try await findProposal(govActionID)
        let lifetime = try await govActionLifetime()
        let proposedIn = proposal.epoch.map { UInt64($0) }
        return GovActionInfo(
            govActionId: govActionID,
            govAction: Self.govAction(from: proposal, id: govActionID),
            proposedIn: proposedIn,
            expiresAfter: Self.expiresAfter(proposedIn: proposedIn, lifetime: lifetime)
        )
    }

    private static func expiresAfter(proposedIn: UInt64?, lifetime: Int32?) -> UInt64? {
        guard let proposedIn, let lifetime, lifetime >= 0 else { return nil }
        return proposedIn + UInt64(lifetime)
    }

    /// Get the votes recorded against a governance action, by voter class.
    ///
    /// The lifecycle epochs carry the same caveat as ``govActionInfo(govActionID:)``: Yaci does
    /// not index governance state, so the outcome epochs are always `nil`.
    public func govActionVotes(govActionID: GovActionID) async throws -> GovActionVotes {
        let proposal = try await findProposal(govActionID)
        let lifetime = try await govActionLifetime()
        return try await govActionVotes(proposal: proposal, id: govActionID, lifetime: lifetime)
    }

    /// Get every governance proposal with its votes.
    ///
    /// The base interface asks for the *active* proposals. Yaci cannot tell an active proposal
    /// from a concluded one — it has no governance state — so this returns every proposal it has
    /// indexed, including expired and enacted ones. Votes are served per proposal, so this makes
    /// at least one further request per proposal.
    public func govActionsAll() async throws -> [GovActionVotes] {
        let lifetime = try await govActionLifetime()
        let proposals = try await paginate("get the governance proposal list") { page, count in
            try await api.client.getGovActionProposalList(
                query: .init(page: page, count: count, order: .asc)
            ).ok.body.json
        }

        var results: [GovActionVotes] = []
        for proposal in proposals {
            guard let id = Self.govActionID(of: proposal) else { continue }
            results.append(try await govActionVotes(proposal: proposal, id: id, lifetime: lifetime))
        }
        return results
    }

    private func govActionVotes(
        proposal: Components.Schemas.GovActionProposal,
        id: GovActionID,
        lifetime: Int32?
    ) async throws -> GovActionVotes {
        let (committee, dreps, pools) = try await votes(
            txHash: proposal.txHash ?? id.transactionID.payload.toHex,
            index: Int32(proposal.index ?? Int64(id.govActionIndex))
        )
        let proposedIn = proposal.epoch.map { UInt64($0) }
        let returnAddress: Data = {
            guard let address = proposal.returnAddress, !address.isEmpty else { return Data() }
            if let bytes = try? Address.fromBech32(address).toBytes() { return bytes }
            return Data(hexString: address) ?? Data()
        }()

        return GovActionVotes(
            govActionId: id,
            govAction: Self.govAction(from: proposal, id: id),
            committeeVotes: committee,
            dRepVotes: dreps,
            stakePoolVotes: pools,
            deposit: Coin(UInt64(max(0, proposal.deposit ?? 0))),
            depositReturnAddr: returnAddress,
            anchor: Self.anchor(url: proposal.anchorUrl, hash: proposal.anchorHash),
            proposedIn: proposedIn,
            expiresAfter: Self.expiresAfter(proposedIn: proposedIn, lifetime: lifetime)
        )
    }

    /// Fetch a proposal's voting procedures and split them by voter role.
    ///
    /// A voter may vote more than once on the same action and only its last vote counts, so rows
    /// are reduced to the latest one per voter before being split.
    private func votes(txHash: String, index: Int32) async throws -> (
        [SwiftCardanoNetwork.CommitteeVote],
        [SwiftCardanoNetwork.DRepVote],
        [SwiftCardanoNetwork.StakePoolVote]
    ) {
        let rows = try await paginate("get votes for \(txHash)#\(index)") { page, count in
            try await api.client.getVotingProceduresForGovActionProposal(
                path: .init(txHash: txHash, indexInTx: index),
                query: .init(page: page, count: count, order: .asc)
            ).ok.body.json
        }.sorted {
            Self.certificateOrder($0.slot, $0.index) < Self.certificateOrder($1.slot, $1.index)
        }

        var latest: [String: Components.Schemas.VotingProcedure] = [:]
        var order: [String] = []
        for row in rows {
            let key = "\(row.voterType?.rawValue ?? ""):\(row.voterHash?.lowercased() ?? "")"
            if latest[key] == nil { order.append(key) }
            latest[key] = row
        }

        var committee: [SwiftCardanoNetwork.CommitteeVote] = []
        var dreps: [SwiftCardanoNetwork.DRepVote] = []
        var pools: [SwiftCardanoNetwork.StakePoolVote] = []

        for key in order {
            guard let row = latest[key],
                let voterHash = row.voterHash, let payload = Data(hexString: voterHash), !payload.isEmpty,
                let vote = GovernanceParsing.parseVote(row.vote?.rawValue)
            else { continue }

            switch row.voterType {
            case .constitutionalCommitteeHotKeyHash:
                committee.append(
                    .init(
                        credential: CommitteeHotCredential(
                            credential: .verificationKeyHash(VerificationKeyHash(payload: payload))),
                        vote: vote
                    ))
            case .constitutionalCommitteeHotScriptHash:
                committee.append(
                    .init(
                        credential: CommitteeHotCredential(
                            credential: .scriptHash(ScriptHash(payload: payload))),
                        vote: vote
                    ))
            case .drepKeyHash:
                dreps.append(
                    .init(
                        credential: DRepCredential(
                            credential: .verificationKeyHash(VerificationKeyHash(payload: payload))),
                        vote: vote
                    ))
            case .drepScriptHash:
                dreps.append(
                    .init(
                        credential: DRepCredential(credential: .scriptHash(ScriptHash(payload: payload))),
                        vote: vote
                    ))
            case .stakingPoolKeyHash:
                pools.append(
                    .init(poolOperator: PoolOperator(poolKeyHash: PoolKeyHash(payload: payload)), vote: vote)
                )
            case nil:
                continue
            }
        }
        return (committee, dreps, pools)
    }

    // MARK: - Governance action parsing

    /// Map a Yaci proposal — its type plus the `details` document the store indexed — onto a
    /// `GovAction`. Unparseable payloads surface as `.infoAction`, so callers can detect the gap
    /// from the variant tag rather than from fabricated inner data.
    static func govAction(from proposal: Components.Schemas.GovActionProposal, id: GovActionID)
        -> GovAction
    {
        let details = jsonObject(proposal.details)
        let type = proposal._type?.rawValue ?? (details?["type"] as? String) ?? ""

        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = details?[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        func object(_ keys: String...) -> [String: Any]? {
            for key in keys {
                if let value = details?[key] as? [String: Any] { return value }
            }
            return nil
        }
        func policyHash() -> ScriptHash? {
            guard let hex = string("policyHash", "policy_hash") else { return nil }
            return try? ScriptHash(from: .string(hex))
        }

        switch type {
        case "INFO_ACTION":
            return .infoAction(InfoAction())

        case "NO_CONFIDENCE":
            return .noConfidence(NoConfidence(id: id))

        case "HARD_FORK_INITIATION_ACTION":
            guard let version = object("protocolVersion", "protocol_version"),
                let major = (version["_1"] ?? version["major"]).flatMap({ ($0 as? NSNumber)?.intValue }),
                let minor = (version["_2"] ?? version["minor"]).flatMap({ ($0 as? NSNumber)?.intValue })
            else { return .infoAction(InfoAction()) }
            return .hardForkInitiationAction(
                HardForkInitiationAction(
                    id: nil, protocolVersion: ProtocolVersion(major: major, minor: minor)
                ))

        case "TREASURY_WITHDRAWALS_ACTION":
            var withdrawals: [RewardAccount: Coin] = [:]
            for (account, amount) in object("withdrawals") ?? [:] {
                guard let lovelace = GovernanceParsing.parseLovelace(amount) else { continue }
                let bytes: Data
                if let decoded = try? Address.fromBech32(account).toBytes() {
                    bytes = decoded
                } else if let hex = Data(hexString: account), !hex.isEmpty {
                    bytes = hex
                } else {
                    continue
                }
                withdrawals[bytes] = Coin(lovelace)
            }
            return .treasuryWithdrawalsAction(
                TreasuryWithdrawalsAction(withdrawals: withdrawals, policyHash: policyHash())
            )

        case "NEW_CONSTITUTION":
            guard let constitution = object("constitution"),
                let anchorJSON = constitution["anchor"] as? [String: Any],
                let urlString = (anchorJSON["anchor_url"] ?? anchorJSON["anchorUrl"] ?? anchorJSON["url"])
                    as? String,
                let url = try? Url(urlString)
            else { return .infoAction(InfoAction()) }

            let hashHex =
                (anchorJSON["anchor_data_hash"] ?? anchorJSON["anchorDataHash"] ?? anchorJSON["dataHash"]
                    ?? anchorJSON["hash"]) as? String ?? ""
            let anchor = Anchor(
                anchorUrl: url, anchorDataHash: AnchorDataHash(payload: Data(hex: hashHex))
            )
            let scriptHash = ((constitution["scripthash"] ?? constitution["scriptHash"]
                ?? constitution["script"]) as? String)
                .flatMap { $0.isEmpty ? nil : try? ScriptHash(from: .string($0)) }
            return .newConstitution(
                NewConstitution(
                    id: id, constitution: Constitution(anchor: anchor, scriptHash: scriptHash)
                ))

        case "UPDATE_COMMITTEE":
            var coldCredentials: Set<CommitteeColdCredential> = []
            var credentialEpochs: [CommitteeColdCredential: UInt64] = [:]

            let removals =
                (details?["membersForRemoval"] ?? details?["members_for_removal"]) as? [Any] ?? []
            for entry in removals {
                if let credential = committeeColdCredential(from: entry) {
                    coldCredentials.insert(credential)
                }
            }
            let additions =
                (details?["newMembersAndTerms"] ?? details?["new_members_and_terms"]) as? [String: Any]
                ?? [:]
            for (key, epoch) in additions {
                guard let credential = committeeColdCredential(fromKey: key),
                    let epochValue = (epoch as? NSNumber)?.int64Value, epochValue >= 0
                else { continue }
                coldCredentials.insert(credential)
                credentialEpochs[credential] = UInt64(epochValue)
            }
            let interval =
                unitInterval(details?["threshold"] ?? details?["quorumThreshold"] ?? details?["quorum"])
                ?? UnitInterval(numerator: 0, denominator: 1)

            return .updateCommittee(
                UpdateCommittee(
                    id: id,
                    coldCredentials: coldCredentials,
                    credentialEpochs: credentialEpochs,
                    interval: interval
                ))

        case "PARAMETER_CHANGE_ACTION":
            // TODO: map yaci's ProtocolParamUpdate JSON onto ProtocolParamUpdate. Until that
            // lands the variant tag is correct but the payload is intentionally empty, which is
            // what the Koios and Ogmios backends also do.
            return .parameterChangeAction(
                ParameterChangeAction(
                    id: id, protocolParamUpdate: ProtocolParamUpdate(), policyHash: policyHash()
                ))

        default:
            return .infoAction(InfoAction())
        }
    }

    /// Yaci serialises a credential as `{"type": "ADDR_KEYHASH" | "SCRIPTHASH", "hash": hex}`.
    private static func committeeColdCredential(from any: Any) -> CommitteeColdCredential? {
        if let key = any as? String { return committeeColdCredential(fromKey: key) }
        guard let dict = any as? [String: Any],
            let hash = dict["hash"] as? String,
            let payload = Data(hexString: hash), !payload.isEmpty
        else { return nil }
        let type = dict["type"] as? String ?? "ADDR_KEYHASH"
        return makeCommitteeColdCredential(payload: payload, isScript: type == "SCRIPTHASH")
    }

    /// Map keys arrive either in cardano-cli form (`keyHash-<hex>` / `scriptHash-<hex>`) or as
    /// Jackson's rendering of a credential (`Credential(type=ADDR_KEYHASH, hash=<hex>)`).
    private static func committeeColdCredential(fromKey key: String) -> CommitteeColdCredential? {
        if key.hasPrefix("keyHash-"),
            let payload = Data(hexString: String(key.dropFirst("keyHash-".count))), !payload.isEmpty
        {
            return makeCommitteeColdCredential(payload: payload, isScript: false)
        }
        if key.hasPrefix("scriptHash-"),
            let payload = Data(hexString: String(key.dropFirst("scriptHash-".count))), !payload.isEmpty
        {
            return makeCommitteeColdCredential(payload: payload, isScript: true)
        }
        if let range = key.range(of: "hash=") {
            let hex = key[range.upperBound...].prefix { $0.isHexDigit }
            if let payload = Data(hexString: String(hex)), !payload.isEmpty {
                return makeCommitteeColdCredential(
                    payload: payload, isScript: key.contains("SCRIPTHASH")
                )
            }
        }
        if let payload = Data(hexString: key), payload.count == SCRIPT_HASH_SIZE {
            return makeCommitteeColdCredential(payload: payload, isScript: false)
        }
        return nil
    }

    private static func makeCommitteeColdCredential(payload: Data, isScript: Bool)
        -> CommitteeColdCredential
    {
        isScript
            ? CommitteeColdCredential(credential: .scriptHash(ScriptHash(payload: payload)))
            : CommitteeColdCredential(
                credential: .verificationKeyHash(VerificationKeyHash(payload: payload)))
    }

    /// Parse a threshold that may arrive as `{numerator, denominator}`, a decimal, or a string.
    static func unitInterval(_ any: Any?) -> UnitInterval? {
        if let dict = any as? [String: Any],
            let numerator = (dict["numerator"] as? NSNumber)?.int64Value,
            let denominator = (dict["denominator"] as? NSNumber)?.int64Value,
            denominator > 0, numerator >= 0
        {
            return UnitInterval(numerator: UInt64(numerator), denominator: UInt64(denominator))
        }
        let value = (any as? NSNumber)?.doubleValue ?? (any as? String).flatMap(Double.init)
        guard let value, value >= 0, value <= 1 else { return nil }
        return makeUnitInterval(value)
    }

    // MARK: - Constitutional committee

    /// Full constitutional committee state.
    ///
    /// Membership, terms and the quorum threshold come from Yaci's current-committee view.
    /// Yaci records no cold→hot authorisation there, so the hot credentials and resignations are
    /// folded from the committee certificate log. A hot credential's own type is not recorded by
    /// that log — only the cold key's — so hot credentials are reported as key hashes.
    public func committeeState() async throws -> CommitteeStateInfo {
        let (genesisMembers, threshold) = try await currentCommittee()
        let currentEpoch = try await epoch()
        let (hotKeys, resigned) = try await committeeAuthorizations()

        func hotCredential(for cold: CommitteeColdCredential) -> CommitteeHotCredential? {
            guard let hex = hotKeys[cold], let payload = Data(hexString: hex), !payload.isEmpty
            else { return nil }
            return CommitteeHotCredential(
                credential: .verificationKeyHash(VerificationKeyHash(payload: payload)))
        }

        var members: [CommitteeStateInfo.Member] = []
        var seen: Set<CommitteeColdCredential> = []
        for member in genesisMembers {
            seen.insert(member.credential)
            let status: CommitteeMemberStatus
            if resigned.contains(member.credential) {
                status = .expired
            } else if let expiration = member.expiration {
                status = expiration >= Int32(currentEpoch) ? .active : .expired
            } else {
                status = .active
            }
            members.append(
                CommitteeStateInfo.Member(
                    coldCredential: member.credential,
                    hotCredential: hotCredential(for: member.credential),
                    expiration: member.expiration.map { EpochNumber($0) },
                    status: status
                ))
        }

        // A cold key that authorised a hot key but is not a current member is surfaced too,
        // rather than silently dropped.
        for cold in Set(hotKeys.keys).union(resigned).subtracting(seen)
            .sorted(by: { $0.credential.payload.toHex < $1.credential.payload.toHex })
        {
            members.append(
                CommitteeStateInfo.Member(
                    coldCredential: cold,
                    hotCredential: hotCredential(for: cold),
                    expiration: nil,
                    status: resigned.contains(cold) ? .expired : .unrecognized
                ))
        }

        return CommitteeStateInfo(members: members, threshold: threshold)
    }

    private struct CommitteeMemberTerm {
        let credential: CommitteeColdCredential
        let expiration: Int32?
    }

    /// The committee's current membership and quorum, from Yaci's indexed view, falling back to
    /// the local-state view served while the DevKit cluster is running.
    private func currentCommittee() async throws -> ([CommitteeMemberTerm], Double) {
        if let output = try? await api.client.getCommitteeMembers(),
            case .ok(let ok) = output,
            let committee = try? ok.body.json,
            let rows = committee.members, !rows.isEmpty
        {
            let members = rows.compactMap { member -> CommitteeMemberTerm? in
                guard let hash = member.hash, let payload = Data(hexString: hash), !payload.isEmpty
                else { return nil }
                return CommitteeMemberTerm(
                    credential: Self.makeCommitteeColdCredential(
                        payload: payload, isScript: member.credType == .scripthash),
                    expiration: member.expiredEpoch
                )
            }
            let numerator = Double(committee.thresholdNumerator ?? 0)
            let denominator = Double(committee.thresholdDenominator ?? 0)
            return (members, denominator == 0 ? 0 : numerator / denominator)
        }

        let live = try await perform("get the current committee") {
            try await api.client.getCommitteeInfo().ok.body.json
        }
        let members = (live.members ?? []).compactMap { member -> CommitteeMemberTerm? in
            guard let hash = member.hash, let payload = Data(hexString: hash), !payload.isEmpty
            else { return nil }
            return CommitteeMemberTerm(
                credential: Self.makeCommitteeColdCredential(
                    payload: payload, isScript: member.credType == .scripthash),
                expiration: member.expiredEpoch
            )
        }
        return (members, live.threshold ?? 0)
    }

    /// The latest cold→hot authorisation and the set of resignations, folded from the committee
    /// certificate log.
    private func committeeAuthorizations() async throws -> (
        hotKeys: [CommitteeColdCredential: String], resigned: Set<CommitteeColdCredential>
    ) {
        enum Event { case authorized(hot: String), resigned }
        var events: [(order: (Int64, Int64), cold: CommitteeColdCredential, event: Event)] = []

        let registrations = try await paginate("get committee registrations") { page, count in
            try await api.client.getCommitteeRegistrations(
                query: .init(page: page, count: count, order: .asc)
            ).ok.body.json
        }
        for row in registrations {
            guard let coldHex = row.coldKey, let payload = Data(hexString: coldHex), !payload.isEmpty,
                let hot = row.hotKey, !hot.isEmpty
            else { continue }
            let cold = Self.makeCommitteeColdCredential(
                payload: payload, isScript: row.credType == .scripthash)
            events.append((Self.certificateOrder(row.slot, row.certIndex), cold, .authorized(hot: hot)))
        }

        let deregistrations = try await paginate("get committee deregistrations") { page, count in
            try await api.client.getCommitteeDeRegistrations(
                query: .init(page: page, count: count, order: .asc)
            ).ok.body.json
        }
        for row in deregistrations {
            guard let coldHex = row.coldKey, let payload = Data(hexString: coldHex), !payload.isEmpty
            else { continue }
            let cold = Self.makeCommitteeColdCredential(
                payload: payload, isScript: row.credType == .scripthash)
            events.append((Self.certificateOrder(row.slot, row.certIndex), cold, .resigned))
        }

        events.sort { $0.order < $1.order }

        var hotKeys: [CommitteeColdCredential: String] = [:]
        var resigned: Set<CommitteeColdCredential> = []
        for event in events {
            switch event.event {
            case .authorized(let hot):
                hotKeys[event.cold] = hot
                resigned.remove(event.cold)
            case .resigned:
                hotKeys[event.cold] = nil
                resigned.insert(event.cold)
            }
        }
        return (hotKeys, resigned)
    }

    /// Get the committee member information for a given cold credential.
    /// See ``committeeState()`` for how the committee is assembled.
    public func committeeMemberInfo(cold: CommitteeColdCredential) async throws -> CommitteeMemberInfo {
        let state = try await committeeState()
        guard let member = state.members.first(where: { $0.coldCredential == cold }) else {
            throw CardanoChainError.valueError("Committee member not found for credential: \(cold)")
        }
        return CommitteeMemberInfo(
            coldCredential: cold,
            hotCredential: member.hotCredential,
            expiration: member.expiration,
            status: member.status
        )
    }

    /// Get the committee member information identified by an authorized hot credential.
    /// See ``committeeState()`` for how the committee is assembled.
    public func committeeMemberInfo(hot: CommitteeHotCredential) async throws -> CommitteeMemberInfo {
        let state = try await committeeState()
        let hotHex = hot.credential.payload.toHex.lowercased()
        guard
            let member = state.members.first(where: {
                $0.hotCredential?.credential.payload.toHex.lowercased() == hotHex
            })
        else {
            throw CardanoChainError.valueError("Committee member not found for hot credential: \(hot)")
        }
        return CommitteeMemberInfo(
            coldCredential: member.coldCredential,
            hotCredential: hot,
            expiration: member.expiration,
            status: member.status
        )
    }
}
