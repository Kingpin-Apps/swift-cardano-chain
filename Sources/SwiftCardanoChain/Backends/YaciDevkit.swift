import BigInt
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
            Int(try LedgerValues.required(
                try await api.client.getLatestEpoch().ok.body.json.epoch, "Yaci latest epoch"))
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
            block: try number.map { try $0.checked("Yaci block number") },
            epoch: try block.epoch.map { try $0.checked("Yaci block epoch") },
            era: block.era.flatMap { Self.era(fromIndex: Int($0)) }?.description,
            hash: block.hash,
            slot: try block.slot.map { try $0.checked("Yaci block slot") },
            slotInEpoch: try block.epochSlot.map { try $0.checked("Yaci block epoch_slot") },
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

        // The numbers are read again from the JSON text, as Decimals, so the
        // active slot coefficient and slot length are exact.
        let numbers: ShelleyGenesisNumbers
        do {
            numbers = try JSONDecoder().decode(ShelleyGenesisNumbers.self, from: data)
        } catch {
            throw CardanoChainError.yaciDevkitError("Shelley genesis numbers are invalid: \(error)")
        }
        func require(_ value: Decimal?, _ key: String) throws -> Decimal {
            guard let value else { throw CardanoChainError.yaciDevkitError("Shelley genesis is missing \(key)") }
            return value
        }
        func requireInt<T: FixedWidthInteger>(_ value: Decimal?, _ key: String) throws -> T {
            let value = try require(value, key)
            guard let integer = T(exactly: NSDecimalNumber(decimal: value).uint64Value),
                  Decimal(string: integer.description) == value else {
                throw CardanoChainError.yaciDevkitError("Shelley genesis \(key) \(value) is not a whole \(T.self)")
            }
            return integer
        }

        guard let systemStartString = json["systemStart"] as? String else {
            throw CardanoChainError.yaciDevkitError("Shelley genesis is missing systemStart")
        }
        guard let systemStart = Self.parseISO8601(systemStartString) else {
            throw CardanoChainError.yaciDevkitError("Cannot parse systemStart: \(systemStartString)")
        }

        return GenesisParameters(
            activeSlotsCoefficient: try LedgerValues.unitInterval(
                try require(numbers.activeSlotsCoeff, "activeSlotsCoeff"), "Shelley genesis activeSlotsCoeff"),
            epochLength: try requireInt(numbers.epochLength, "epochLength"),
            maxKesEvolutions: try requireInt(numbers.maxKESEvolutions, "maxKESEvolutions"),
            maxLovelaceSupply: try requireInt(numbers.maxLovelaceSupply, "maxLovelaceSupply"),
            networkId: (json["networkId"] as? String) ?? network.description,
            networkMagic: try requireInt(numbers.networkMagic, "networkMagic"),
            securityParam: try requireInt(numbers.securityParam, "securityParam"),
            slotLength: try require(numbers.slotLength, "slotLength"),
            slotsPerKesPeriod: try requireInt(numbers.slotsPerKESPeriod, "slotsPerKESPeriod"),
            systemStart: systemStart,
            updateQuorum: try requireInt(numbers.updateQuorum, "updateQuorum"),
            era: .conway
        )
    }

    /// The numbers of a Shelley genesis file, each read exactly from its JSON
    /// text (or from a string holding one).
    private struct ShelleyGenesisNumbers: Decodable {
        let activeSlotsCoeff: Decimal?
        let epochLength: Decimal?
        let maxKESEvolutions: Decimal?
        let maxLovelaceSupply: Decimal?
        let networkMagic: Decimal?
        let securityParam: Decimal?
        let slotLength: Decimal?
        let slotsPerKESPeriod: Decimal?
        let updateQuorum: Decimal?

        private enum CodingKeys: String, CodingKey {
            case activeSlotsCoeff, epochLength, maxKESEvolutions, maxLovelaceSupply, networkMagic,
                 securityParam, slotLength, slotsPerKESPeriod, updateQuorum
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func number(_ key: CodingKeys) throws -> Decimal? {
                guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
                if let text = try? c.decode(String.self, forKey: key) {
                    guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
                        throw DecodingError.dataCorruptedError(
                            forKey: key, in: c, debugDescription: "\(text) is not a number")
                    }
                    return value
                }
                return try c.decode(Decimal.self, forKey: key)
            }
            activeSlotsCoeff = try number(.activeSlotsCoeff)
            epochLength = try number(.epochLength)
            maxKESEvolutions = try number(.maxKESEvolutions)
            maxLovelaceSupply = try number(.maxLovelaceSupply)
            networkMagic = try number(.networkMagic)
            securityParam = try number(.securityParam)
            slotLength = try number(.slotLength)
            slotsPerKESPeriod = try number(.slotsPerKESPeriod)
            updateQuorum = try number(.updateQuorum)
        }
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
        // The genesis files are the cost models' ledger-ordered source; failing to read them is
        // an error, not a reason to use the store's alphabetical order.
        let genesis = try await genesisCostModels()
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
        // Yaci's client reads each ratio as the exact decimal Yaci sent.
        // A missing threshold is not 0.
        func unit(_ value: Decimal?, _ name: String) throws -> UnitInterval {
            try LedgerValues.unitInterval(try require(value, name), "Yaci protocol parameter \(name)")
        }
        func nonNegative(_ value: Decimal?, _ name: String) throws -> NonNegativeInterval {
            try LedgerValues.nonNegativeInterval(try require(value, name), "Yaci protocol parameter \(name)")
        }
        func int<T: FixedWidthInteger, S: BinaryInteger>(_ value: S?, _ name: String) throws -> T {
            try LedgerValues.integer(try require(value, name), as: T.self, "Yaci protocol parameter \(name)")
        }
        func int<T: FixedWidthInteger>(_ text: String?, _ name: String) throws -> T {
            try LedgerValues.integer(text: try require(text, name), as: T.self, "Yaci protocol parameter \(name)")
        }

        // Each language's costs arrive keyed by operation name; flattening in key order matches
        // the ledger's order for V1 and V2.
        // A missing cost model is an error, not an empty one: the script
        // data hash covers it.
        func storeModel(_ names: [String]) throws -> [Int64] {
            for name in names {
                if let payload = params.costModels?.additionalProperties[name] {
                    let costs = payload.additionalProperties
                    return costs.keys.sorted().compactMap { costs[$0] }
                }
            }
            throw CardanoChainError.yaciDevkitError("Protocol parameters are missing the \(names[0]) cost model")
        }
        let costModels = ProtocolParametersCostModels(
            PlutusV1: try genesisCostModels.v1 ?? storeModel(["PlutusV1", "plutusV1", "plutus:v1"]),
            PlutusV2: try genesisCostModels.v2 ?? storeModel(["PlutusV2", "plutusV2", "plutus:v2"]),
            // The store's V3 map is not in ledger order, so V3 comes from genesis or not at all.
            PlutusV3: try LedgerValues.required(genesisCostModels.v3, "Yaci genesis Plutus V3 cost model")
        )

        return ProtocolParameters(
            collateralPercentage: try int(params.collateralPercent, "collateral_percent"),
            committeeMaxTermLength: try int(params.committeeMaxTermLength, "committee_max_term_length"),
            committeeMinSize: try int(params.committeeMinSize, "committee_min_size"),
            costModels: costModels,
            dRepActivity: try int(params.drepActivity, "drep_activity"),
            dRepDeposit: try int(params.drepDeposit, "drep_deposit"),
            dRepVotingThresholds: DRepVotingThresholds(
                committeeNoConfidence: try unit(params.dvtCommitteeNoConfidence, "dvt_committee_no_confidence"),
                committeeNormal: try unit(params.dvtCommitteeNormal, "dvt_committee_normal"),
                hardForkInitiation: try unit(params.dvtHardForkInitiation, "dvt_hard_fork_initiation"),
                motionNoConfidence: try unit(params.dvtMotionNoConfidence, "dvt_motion_no_confidence"),
                ppEconomicGroup: try unit(params.dvtPpeconomicGroup, "dvt_ppeconomic_group"),
                ppGovGroup: try unit(params.dvtPpgovGroup, "dvt_ppgov_group"),
                ppNetworkGroup: try unit(params.dvtPpnetworkGroup, "dvt_ppnetwork_group"),
                ppTechnicalGroup: try unit(params.dvtPptechnicalGroup, "dvt_pptechnical_group"),
                treasuryWithdrawal: try unit(params.dvtTreasuryWithdrawal, "dvt_treasury_withdrawal"),
                updateToConstitution: try unit(params.dvtUpdateToConstitution, "dvt_update_to_constitution")
            ),
            executionUnitPrices: ExecutionUnitPrices(
                priceMemory: try nonNegative(params.priceMem, "price_mem"),
                priceSteps: try nonNegative(params.priceStep, "price_step")
            ),
            govActionDeposit: try int(params.govActionDeposit, "gov_action_deposit"),
            govActionLifetime: try int(params.govActionLifetime, "gov_action_lifetime"),
            maxBlockBodySize: try int(params.maxBlockSize, "max_block_size"),
            maxBlockExecutionUnits: ProtocolParametersExecutionUnits(
                memory: try int(params.maxBlockExMem, "max_block_ex_mem"),
                steps: try int(params.maxBlockExSteps, "max_block_ex_steps")
            ),
            maxBlockHeaderSize: try int(params.maxBlockHeaderSize, "max_block_header_size"),
            maxCollateralInputs: try int(params.maxCollateralInputs, "max_collateral_inputs"),
            maxTxExecutionUnits: ProtocolParametersExecutionUnits(
                memory: try int(params.maxTxExMem, "max_tx_ex_mem"),
                steps: try int(params.maxTxExSteps, "max_tx_ex_steps")
            ),
            maxTxSize: try int(params.maxTxSize, "max_tx_size"),
            maxValueSize: try int(params.maxValSize, "max_val_size"),
            minFeeRefScriptCostPerByte: try params.minFeeRefScriptCostPerByte.map {
                try LedgerValues.nonNegativeInterval($0, "Yaci protocol parameter min_fee_ref_script_cost_per_byte")
            },
            minPoolCost: try int(params.minPoolCost, "min_pool_cost"),
            monetaryExpansion: try unit(params.rho, "rho"),
            poolPledgeInfluence: try nonNegative(params.a0, "a0"),
            poolRetireMaxEpoch: try int(params.eMax, "e_max"),
            poolVotingThresholds: ProtocolParametersPoolVotingThresholds(
                committeeNoConfidence: try unit(params.pvtCommitteeNoConfidence, "pvt_committee_no_confidence"),
                committeeNormal: try unit(params.pvtCommitteeNormal, "pvt_committee_normal"),
                hardForkInitiation: try unit(params.pvtHardForkInitiation, "pvt_hard_fork_initiation"),
                motionNoConfidence: try unit(params.pvtMotionNoConfidence, "pvt_motion_no_confidence"),
                // Yaci Store spells this parameter two ways across releases.
                ppSecurityGroup: try unit(params.pvtppSecurityGroup ?? params.pvtPPSecurityGroup, "pvt_pp_security_group")
            ),
            protocolVersion: ProtocolParametersProtocolVersion(
                major: try int(params.protocolMajorVer, "protocol_major_ver"),
                minor: try int(params.protocolMinorVer, "protocol_minor_ver")
            ),
            stakeAddressDeposit: try int(params.keyDeposit, "key_deposit"),
            stakePoolDeposit: try int(params.poolDeposit, "pool_deposit"),
            stakePoolTargetNum: try int(params.nOpt, "n_opt"),
            treasuryCut: try unit(params.tau, "tau"),
            txFeeFixed: try int(params.minFeeB, "min_fee_b"),
            txFeePerByte: try int(params.minFeeA, "min_fee_a"),
            // Babbage and later report the cost per byte; Yaci's Alonzo-era `coins_per_utxo_word`
            // is deprecated and a DevKit devnet is Conway, so only the byte form is read.
            utxoCostPerByte: try int(params.coinsPerUtxoSize, "coins_per_utxo_size")
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
                transactionId: try LedgerValues.hash(hex: txHash, as: TransactionId.self, "Yaci TransactionId"),
                index: try LedgerValues.integer(outputIndex, "Yaci output index")
            )
            let units: [(unit: String, quantity: BigInt)] = try (row.amount ?? []).compactMap { item in
                guard let quantity = try item.quantity.map({
                    try LedgerValues.bigInt(text: $0, "Yaci quantity")
                }) else { return nil }
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

        // Yaci's client reads these quantities as Int, so one above Int.max
        // cannot arrive here.
        let units: [(unit: String, quantity: BigInt)] = (row.amounts ?? []).compactMap { item in
            guard let quantity = item.quantity.map({ BigInt($0) }) else { return nil }
            if let unit = item.unit, !unit.isEmpty { return (unit, quantity) }
            guard let policy = item.policyId else { return nil }
            return (policy + (item.assetName ?? ""), quantity)
        }
        let txOut = try await makeOutput(
            address: address,
            lovelace: row.lovelaceAmount.map { BigInt($0) },
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
        lovelace: BigInt?,
        units: [(unit: String, quantity: BigInt)],
        dataHash: String?,
        inlineDatum: String?,
        referenceScriptHash: String?
    ) async throws -> TransactionOutput {
        var coin: BigInt? = lovelace
        var multiAsset = MultiAsset([:])
        for (unit, quantity) in units {
            if unit == "lovelace" {
                coin = quantity
                continue
            }
            // The unit is `<policy id><asset name>`, hex encoded.
            let (policyId, assetName) = try LedgerValues.asset(unit: unit, "Yaci asset unit")
            if multiAsset[policyId] == nil {
                multiAsset[policyId] = Asset([:])
            }
            multiAsset[policyId]?[assetName] = quantity
        }

        var datumHash: DatumHash? = nil
        var datumOption: DatumOption? = nil
        if let dataHash, !dataHash.isEmpty, inlineDatum == nil {
            datumHash = try LedgerValues.hash(hex: dataHash, as: DatumHash.self, "Yaci DatumHash")
        }
        if let inlineDatum, !inlineDatum.isEmpty {
            let datumData = try LedgerValues.hexBytes(inlineDatum, "Yaci inline datum")
            let plutusData = try PlutusData.fromCBOR(data: datumData)
            datumOption = DatumOption(datum: plutusData)
        }

        var script: ScriptType? = nil
        if let referenceScriptHash, !referenceScriptHash.isEmpty {
            script = try await getScript(scriptHash: referenceScriptHash)
        }

        return TransactionOutput(
            address: try Address(from: .string(address)),
            // Every output holds lovelace; none reported is an error, not 0.
            amount: Value(
                coin: try LedgerValues.required(coin, "Yaci output lovelace for \(address)"), multiAsset: multiAsset),
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
            guard let hex = cbor.cbor, !hex.isEmpty else {
                throw CardanoChainError.yaciDevkitError("Script \(scriptHash) has no CBOR")
            }
            let bytes = try LedgerValues.hexBytes(hex, "Yaci script \(scriptHash) CBOR")
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
                    mem: try LedgerValues.required(
                        LedgerValues.integer(json: cost["memory"], "Yaci evaluation \(key) memory"),
                        "Yaci evaluation \(key) memory"),
                    steps: try LedgerValues.required(
                        LedgerValues.integer(json: cost["steps"], "Yaci evaluation \(key) steps"),
                        "Yaci evaluation \(key) steps")
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
                    mem: try LedgerValues.required(
                        LedgerValues.integer(json: budget["memory"], "Yaci evaluation memory"),
                        "Yaci evaluation memory"),
                    steps: try LedgerValues.required(
                        LedgerValues.integer(json: budget["cpu"] ?? budget["steps"], "Yaci evaluation cpu"),
                        "Yaci evaluation cpu")
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
    /// Yaci reports the delegated pool and the withdrawable rewards. Registration is folded from
    /// the stake certificate log, and vote delegation from the vote-delegation log, both on a
    /// best-effort basis.
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
        let voteDelegation = try await latestVoteDelegation(stakeAddress: bech32)
        let active = try await isStakeRegistered(address: bech32)

        return [
            StakeAddressInfo(
                active: active,
                address: info.stakeAddress ?? bech32,
                rewardAccountBalance: try LedgerValues.required(
                    info.withdrawableAmount, "Yaci withdrawable_amount").checked("Yaci withdrawable_amount"),
                stakeDelegation: stakeDelegation,
                voteDelegation: voteDelegation
            )
        ]
    }

    /// Whether a stake address is currently registered, folded from the stake certificate log.
    ///
    /// The account endpoint cannot answer this. Yaci serves it with zeroed amounts and a null
    /// pool for any well-formed stake address, including one it has never seen, so a successful
    /// response says nothing about registration. Registrations and deregistrations are indexed
    /// as separate certificate logs instead, and the latest certificate for the address wins.
    private func isStakeRegistered(address: String) async throws -> Bool {
        let registrations = try await paginate("get stake registrations") { page, count in
            try await api.client.getStakeRegistrations(query: .init(page: page, count: count))
                .ok.body.json
        }
        let deregistrations = try await paginate("get stake deregistrations") { page, count in
            try await api.client.getStakeDeRegistrations(query: .init(page: page, count: count))
                .ok.body.json
        }

        let rows = (registrations + deregistrations)
            .filter { $0.address == address }
            .sorted {
                Self.certificateOrder($0.slot, $0.certIndex) < Self.certificateOrder($1.slot, $1.certIndex)
            }

        guard let latest = rows.last else { return false }
        switch latest._type {
        case .stakeDeregistration, .unregCert:
            return false
        default:
            return true
        }
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
            let hash = try LedgerValues.required(latest.drepHash, "Yaci delegation drep_hash")
            return DRep(credential: .scriptHash(try LedgerValues.hash(hex: hash, as: ScriptHash.self, "Yaci delegation drep_hash")))
        case .addrKeyhash:
            let hash = try LedgerValues.required(latest.drepHash, "Yaci delegation drep_hash")
            return DRep(credential: .verificationKeyHash(
                try LedgerValues.hash(hex: hash, as: VerificationKeyHash.self, "Yaci delegation drep_hash")))
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
        guard let hash = try? LedgerValues.hash(hex: poolId, as: PoolKeyHash.self, "pool ID") else {
            throw CardanoChainError.invalidArgument("Invalid pool ID: \(poolId)")
        }
        return PoolOperator(poolKeyHash: hash)
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

        var latestRegistration: [String: Components.Schemas.PoolRegistration] = [:]
        for registration in registrations.sorted(by: {
            Self.certificateOrder($0.slot, $0.certIndex) < Self.certificateOrder($1.slot, $1.certIndex)
        }) {
            if let poolId = registration.poolId?.lowercased(), !poolId.isEmpty {
                latestRegistration[poolId] = registration
            }
        }
        let latestRetirement = try await poolRetirements()

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

    /// The latest retirement certificate for every pool that has one, keyed by lowercase hex
    /// pool id.
    private func poolRetirements() async throws -> [String: Components.Schemas.PoolRetirement] {
        let rows = try await paginate("get pool retirements") { page, count in
            try await api.client.getRetirements(query: .init(page: page, count: count)).ok.body.json
        }
        var latest: [String: Components.Schemas.PoolRetirement] = [:]
        for retirement in rows.sorted(by: {
            Self.certificateOrder($0.slot, $0.certIndex) < Self.certificateOrder($1.slot, $1.certIndex)
        }) {
            if let poolId = retirement.poolId?.lowercased(), !poolId.isEmpty {
                latest[poolId] = retirement
            }
        }
        return latest
    }

    /// Pools set up in the Shelley genesis rather than by a registration certificate, keyed by
    /// lowercase hex pool id.
    ///
    /// A devnet's own block producer is one of these, so it never appears in Yaci's pool
    /// certificate log and the certificate reconstruction alone cannot see it. Its parameters
    /// come from the genesis document instead.
    ///
    /// Every pool is read strictly, relays included: genesis encodes relays as
    /// `{"single host address" | "single host name" | "multi host name": {…}}`, and an entry in
    /// any other shape, or one the ledger would refuse, throws rather than being dropped.
    private func genesisPools() async throws -> [String: PoolParams] {
        try Self.genesisPools(from: try await genesisFile("shelley"))
    }

    /// The pools in a Shelley genesis document; none when it declares no `staking.pools`.
    static func genesisPools(from data: Data) throws -> [String: PoolParams] {
        guard let genesis = jsonObject(data) else {
            throw CardanoChainError.valueError("Yaci Shelley genesis is not a JSON object")
        }
        guard let staking = genesis["staking"], !(staking is NSNull) else { return [:] }
        guard let pools = (staking as? [String: Any]).map({ $0["pools"] }) else {
            throw CardanoChainError.valueError("Yaci Shelley genesis staking is not an object")
        }
        guard let pools, !(pools is NSNull) else { return [:] }
        guard let pools = pools as? [String: Any] else {
            throw CardanoChainError.valueError("Yaci Shelley genesis staking.pools is not an object")
        }

        var result: [String: PoolParams] = [:]
        for (poolId, value) in pools {
            guard let pool = value as? [String: Any] else {
                throw CardanoChainError.valueError("Yaci genesis pool \(poolId) is not an object")
            }
            let id = ((pool["publicKey"] as? String) ?? poolId).lowercased()
            let poolKeyHash = try LedgerValues.hash(hex: id, as: PoolKeyHash.self, "Yaci genesis pool id")

            guard let ownerList = pool["owners"] as? [Any] else {
                throw CardanoChainError.valueError("Yaci genesis pool \(id) has no owner list")
            }
            let owners: [VerificationKeyHash] = try ownerList.map { owner in
                guard let owner = owner as? String else {
                    throw CardanoChainError.valueError("Yaci genesis pool \(id) owner \(owner) is not a string")
                }
                return try Self.poolOwner(owner)
            }

            var metadata: PoolMetadata? = nil
            if let meta = pool["metadata"], !(meta is NSNull) {
                guard let meta = meta as? [String: Any],
                    let urlText = meta["url"] as? String, let hashHex = meta["hash"] as? String
                else {
                    throw CardanoChainError.valueError("Yaci genesis pool metadata is not a url and hash: \(meta)")
                }
                metadata = try PoolMetadata(
                    url: LedgerValues.url(urlText, "Yaci genesis pool metadata URL"),
                    poolMetadataHash: PoolMetadataHash(
                        payload: LedgerValues.hash32(hex: hashHex, "Yaci genesis pool metadata hash")))
            }

            result[id] = PoolParams(
                poolOperator: poolKeyHash,
                vrfKeyHash: try LedgerValues.hash(
                    hex: LedgerValues.required(pool["vrf"] as? String, "Yaci genesis pool vrf"), as: VrfKeyHash.self,
                    "Yaci genesis pool vrf"),
                pledge: try LedgerValues.required(
                    LedgerValues.integer(json: pool["pledge"], "Yaci genesis pool pledge"), "Yaci genesis pool pledge"),
                cost: try LedgerValues.required(
                    LedgerValues.integer(json: pool["cost"], "Yaci genesis pool cost"), "Yaci genesis pool cost"),
                // JSONSerialization reads the margin as a Double; its shortest
                // description is the decimal in the genesis file.
                margin: try LedgerValues.required(
                    LedgerValues.unitInterval(json: pool["margin"], "Yaci genesis pool margin"),
                    "Yaci genesis pool margin"),
                rewardAccount: try Self.genesisRewardAccount(pool["rewardAccount"]),
                poolOwners: .list(owners),
                relays: try LedgerValues.required(pool["relays"] as? [Any], "Yaci genesis pool \(id) relays")
                    .map { try Self.genesisRelay($0) },
                poolMetadata: metadata
            )
        }
        return result
    }

    /// The reward account of a genesis pool, which genesis writes as a credential plus a network
    /// rather than as the 29-byte on-chain form.
    static func genesisRewardAccount(_ any: Any?) throws -> RewardAccountHash {
        RewardAccountHash(payload: try LedgerValues.rewardAccount(json: any, "Yaci genesis pool reward account"))
    }

    /// One relay from a genesis pool, whose JSON tags the shape by key.
    ///
    /// An entry that is not one of the three shapes, an address that does not parse, a name
    /// missing from a named relay or longer than the ledger allows, all throw: a relay the ledger
    /// accepted always reads, so it means the genesis document is corrupt.
    static func genesisRelay(_ any: Any) throws -> SwiftCardanoCore.Relay {
        let what = "Yaci genesis pool relay"
        guard let entry = any as? [String: Any], entry.count == 1, let (kind, raw) = entry.first,
            let fields = raw as? [String: Any]
        else {
            throw CardanoChainError.valueError("\(what) \(any) is not a single tagged relay")
        }
        func text(_ keys: String...) throws -> String? {
            for key in keys {
                guard let value = fields[key], !(value is NSNull) else { continue }
                guard let text = value as? String else {
                    throw CardanoChainError.valueError("\(what) \(key) \(value) is not a string")
                }
                return text
            }
            return nil
        }

        let port: Int? = try LedgerValues.integer(json: fields["port"], "\(what) port")
        switch kind.lowercased().replacingOccurrences(of: " ", with: "") {
        case "singlehostaddr", "singlehostaddress":
            // Neither address is a relay the ledger allows, not one to drop.
            return .singleHostAddr(SingleHostAddr(
                port: port,
                ipv4: try text("IPv4", "ipv4").map { try LedgerValues.ipv4($0, "\(what) IPv4") },
                ipv6: try text("IPv6", "ipv6").map { try LedgerValues.ipv6($0, "\(what) IPv6") }))
        case "singlehostname":
            let dns = try LedgerValues.required(text("dnsName", "hostname"), "\(what) DNS name")
            return try LedgerValues.singleHostName(port: port, dnsName: dns, "\(what) DNS name")
        case "multihostname":
            let dns = try LedgerValues.required(text("dnsName", "hostname"), "\(what) DNS name")
            return try LedgerValues.multiHostName(dnsName: dns, "\(what) DNS name")
        default:
            throw CardanoChainError.valueError("\(what) has an unknown kind \(kind)")
        }
    }

    /// A retirement takes effect at the start of its retirement epoch, so the pool is still
    /// retiring for every epoch before that one.
    private static func poolStatus(
        retirement: Components.Schemas.PoolRetirement?, epoch: Int
    ) throws -> PoolStatus {
        guard let retirement else { return .registered }
        if let retiringEpoch = retirement.retirementEpoch, epoch < Int(retiringEpoch) {
            return .retiring(epoch: try retiringEpoch.checked("Yaci retirement_epoch"))
        }
        return .retired
    }

    /// Get every stake pool registered on the chain.
    ///
    /// Reconstructed from Yaci's pool certificate log, merged with the pools set up in the
    /// Shelley genesis, which never appear in that log. Pools whose retirement epoch has already
    /// passed are excluded, so this is the set of pools that are live or still winding down.
    public func stakePools() async throws -> [PoolOperator] {
        let epoch = try await epoch()
        let certificates = try await poolCertificates()
        // A DevKit whose admin API does not serve the genesis has no genesis pools to add; a
        // genesis it does serve must read.
        let genesisData = try? await genesisFile("shelley")
        let genesis = try genesisData.map { try Self.genesisPools(from: $0) } ?? [:]
        let retirements = try await poolRetirements()

        var ids = Set(certificates.keys)
        ids.formUnion(genesis.keys)

        return try ids.sorted().compactMap { poolId in
            // For a pool in the certificate log the folded retirement is authoritative, since a
            // later re-registration cancels an announced one. The raw retirement map is only for
            // genesis pools, which have no registration certificate to fold against.
            let retirement =
                certificates[poolId].map { $0.retirement } ?? retirements[poolId]
            if case .retired = try Self.poolStatus(retirement: retirement, epoch: epoch) {
                return nil
            }
            return PoolOperator(poolKeyHash: try LedgerValues.hash(hex: poolId, as: PoolKeyHash.self, "Yaci pool id"))
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
    /// Read from Yaci's per-epoch pool state where that is available, otherwise reconstructed
    /// from the pool certificate log, and failing that from the Shelley genesis, which is where
    /// a devnet's own block producer is set up. Yaci indexes certificates rather than ledger
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

        let details = try await poolDetails(poolOperator: poolOperator, epoch: currentEpoch)
        let certificate = try await poolCertificates()[poolIdHex]

        // Parameters come from the registration certificate where there is one. It carries the
        // margin as the exact numerator and denominator that were registered, where the
        // per-epoch view reports it as a rounded decimal, and a re-serialised pool parameter
        // set has to match the registered ratio byte for byte.
        let params: PoolParams
        if let certificate {
            params = try await Self.poolParams(from: certificate.registration, strict: strict)
        } else if let genesisParams = try await genesisPools()[poolIdHex] {
            // A pool set up in genesis has no registration certificate for the log to carry.
            params = genesisParams
        } else if let details {
            params = try await Self.poolParams(from: details, strict: strict)
        } else {
            throw CardanoChainError.valueError("Pool \(poolId) was not found.")
        }

        // Status comes from the per-epoch view where Yaci serves one, since that is the
        // ledger's own answer for the epoch rather than a fold of the certificate log.
        let status: PoolStatus
        if let details {
            status = try Self.poolStatus(from: details, epoch: currentEpoch)
        } else if let certificate {
            status = try Self.poolStatus(retirement: certificate.retirement, epoch: currentEpoch)
        } else {
            status = try Self.poolStatus(
                retirement: try await poolRetirements()[poolIdHex], epoch: currentEpoch)
        }

        return StakePoolInfo(poolParams: params, status: status)
    }

    /// Yaci's per-epoch view of a pool, or `nil` when the store has none for either form of the
    /// pool's ID (it answers with something other than 200, or with an empty record). A request
    /// that fails, or a 200 whose body does not decode, throws.
    private func poolDetails(
        poolOperator: PoolOperator, epoch: Int
    ) async throws -> Components.Schemas.PoolDetailsDto? {
        let ids = [try poolOperator.id(.bech32), poolOperator.poolKeyHash.payload.toHex]
        for id in ids {
            let output = try await api.client.getPoolDetails(
                path: .init(poolId: id, epoch: try epoch.checked("Yaci epoch")))
            guard case .ok(let ok) = output else { continue }
            let details = try ok.body.json
            guard details.poolId != nil || details.poolHash != nil else { continue }
            return details
        }
        return nil
    }

    private static func poolStatus(from details: Components.Schemas.PoolDetailsDto, epoch: Int)
        throws -> PoolStatus
    {
        switch details.status {
        case .retired:
            return .retired
        case .retiring:
            if let retiring = details.retireEpoch, epoch < Int(retiring) {
                return .retiring(epoch: try retiring.checked("Yaci retire_epoch"))
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
    ///
    /// An address that does not parse, or a DNS name longer than the ledger allows, throws:
    /// a relay that is on chain always passes, so it means Yaci sent something corrupt. A relay
    /// with no field set is a single-host-address relay with neither address, which the ledger
    /// allows.
    static func relay(from relay: Components.Schemas.Relay) throws -> SwiftCardanoCore.Relay {
        // Yaci reports a relay's absent port as 0 rather than null. Zero is not a usable TCP
        // port, so it is read as "no port" — and that distinction is what separates a
        // single-host DNS relay from a multi-host SRV record.
        let port = relay.port.flatMap { $0 > 0 ? Int($0) : nil }
        func present(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }
        let dns = present(relay.dnsName)
        return try LedgerValues.relay(
            port: port, ipv4: present(relay.ipv4), ipv6: present(relay.ipv6),
            dnsName: port == nil ? nil : dns, srvName: port == nil ? dns : nil, "Yaci pool relay")
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
        return try LedgerValues.hash(hex: owner, as: VerificationKeyHash.self, "Yaci pool owner")
    }

    /// The reward account as its 29-byte on-chain form, from either the bech32 stake address or
    /// the raw hex Yaci reports.
    private static func rewardAccount(bech32: String?, hex: String?) throws -> RewardAccountHash {
        if let bech32, bech32.hasPrefix("stake") {
            return RewardAccountHash(payload: try Address(from: .string(bech32)).toBytes())
        }
        guard let hex = hex ?? bech32, !hex.isEmpty else {
            throw CardanoChainError.valueError("Pool has no reward account")
        }
        let data = try LedgerValues.hexBytes(hex, "Yaci pool reward account")
        guard data.count == 29 else {
            throw CardanoChainError.valueError("Yaci pool reward account \(hex) is not 29 bytes")
        }
        return RewardAccountHash(payload: data)
    }

    private static func poolMetadata(url urlString: String?, hash hashString: String?, strict: Bool)
        async throws -> PoolMetadata?
    {
        func present(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }
        if present(urlString) == nil, present(hashString) == nil { return nil }

        let url = try LedgerValues.url(
            LedgerValues.required(urlString, "Yaci pool metadata URL"), "Yaci pool metadata URL")
        let hash = PoolMetadataHash(payload: try LedgerValues.hash32(
            hex: LedgerValues.required(hashString, "Yaci pool metadata hash"), "Yaci pool metadata hash"))
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
            let (n, d) = (try LedgerValues.integer(numerator, as: UInt64.self, "Yaci pool margin numerator"),
                          try LedgerValues.integer(denominator, as: UInt64.self, "Yaci pool margin denominator"))
            margin = try LedgerValues.unitInterval(text: "\(n)/\(d)", "Yaci pool margin")
        } else {
            margin = try LedgerValues.unitInterval(
                LedgerValues.required(registration.margin, "Yaci pool margin"), "Yaci pool margin")
        }

        return PoolParams(
            poolOperator: try LedgerValues.hash(
                hex: LedgerValues.required(registration.poolId, "Yaci pool id"), as: PoolKeyHash.self, "Yaci pool id"),
            vrfKeyHash: try LedgerValues.hash(
                hex: LedgerValues.required(registration.vrfKeyHash, "Yaci pool vrf key hash"), as: VrfKeyHash.self,
                "Yaci pool vrf key hash"),
            pledge: try LedgerValues.required(registration.pledge, "Yaci pool pledge").checked("Yaci pool pledge"),
            cost: try LedgerValues.required(registration.cost, "Yaci pool cost").checked("Yaci pool cost"),
            margin: margin,
            rewardAccount: try rewardAccount(
                bech32: registration.rewardAccount, hex: registration.rewardAccount
            ),
            poolOwners: .list(try (registration.poolOwners ?? []).map { try poolOwner($0) }),
            relays: try (registration.relays ?? []).map { try relay(from: $0) },
            poolMetadata: try await poolMetadata(
                url: registration.metadataUrl, hash: registration.metadataHash, strict: strict
            )
        )
    }

    private static func poolParams(
        from details: Components.Schemas.PoolDetailsDto, strict: Bool
    ) async throws -> PoolParams {
        return PoolParams(
            poolOperator: try LedgerValues.hash(
                hex: LedgerValues.required(details.poolHash, "Yaci pool hash"), as: PoolKeyHash.self, "Yaci pool hash"),
            vrfKeyHash: try LedgerValues.hash(
                hex: LedgerValues.required(details.vrfKeyHash, "Yaci pool vrf key hash"), as: VrfKeyHash.self,
                "Yaci pool vrf key hash"),
            pledge: try LedgerValues.integer(text: LedgerValues.required(details.pledge, "Yaci pool pledge"), "Yaci pool pledge"),
            cost: try LedgerValues.integer(text: LedgerValues.required(details.cost, "Yaci pool cost"), "Yaci pool cost"),
            // Yaci sends this margin as decimal text, read here exactly.
            margin: try LedgerValues.unitInterval(
                text: LedgerValues.required(details.margin, "Yaci pool margin"), "Yaci pool margin"),
            rewardAccount: try rewardAccount(bech32: details.rewardAccount, hex: details.rewardAccount),
            poolOwners: .list(try (details.poolOwners ?? []).map { try poolOwner($0) }),
            relays: try (details.relays ?? []).map { try relay(from: $0) },
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
                blocks = try await api.client.getBlocksBySlotLeaderEpoch(
                    path: .init(poolId: id), query: .init(epoch: try epoch.checked("Yaci epoch"))
                ).ok.body.json
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
        guard let counterText = block.opCertCounter else {
            throw CardanoChainError.yaciDevkitError(
                "Block \(number) carries no operational certificate counter"
            )
        }
        let counter: Int = try LedgerValues.integer(text: counterText, "Yaci op_cert_counter")

        if let opCert {
            return KESPeriodInfo(
                onChainOpCertCount: counter,
                onDiskOpCertCount: try opCert.sequenceNumber.checked("operational certificate sequence number"),
                nextChainOpCertCount: counter + 1,
                onDiskKESStart: try opCert.kesPeriod.checked("operational certificate KES period")
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
        let registration = certificates.reversed().first { $0._type == .regDrepCert }
        let deposit: Coin? = try registration?.deposit.map { try $0.checked("Yaci DRep deposit") }

        return DRepInfo(
            active: !retired,
            drep: drep,
            anchor: try Self.anchor(url: latest.anchorUrl, hash: latest.anchorHash),
            deposit: deposit,
            // A retired DRep holds no voting power; for a registered one, no
            // stake reading is not a stake of 0.
            stake: retired ? 0 : try await drepStake(hex: hex, drep: drep),
            expiry: nil,
            status: retired ? .retired : .registered
        )
    }

    /// A registered DRep's live voting power, read from DevKit's local-state endpoint.
    ///
    /// - Throws: ``CardanoChainError/notImplemented(_:)`` when the endpoint does not answer
    ///   with 200 — it is only served while the DevKit cluster runs, so this Yaci instance
    ///   cannot report DRep stake; ``CardanoChainError/valueError(_:)`` naming the DRep when
    ///   it answers without an amount; and when the request fails, the body does not decode,
    ///   or the amount is not a `Coin`.
    private func drepStake(hex: String, drep: DRep) async throws -> Coin {
        let name = (try? drep.id((.bech32, .cip129))).map { "\($0) (\(hex))" } ?? hex
        let output = try await api.client.getDRepStakeDistr(path: .init(dRepHash: hex))
        guard case .ok(let ok) = output else {
            throw CardanoChainError.notImplemented(
                "DRep stake is not supported by this Yaci instance: its live DRep stake endpoint "
                    + "answered \(output) for \(name). It is served only while the DevKit cluster runs.")
        }
        guard let amount = try ok.body.json.amount else {
            throw CardanoChainError.valueError("Yaci reports no stake for registered DRep \(name)")
        }
        return try amount.checked("Yaci DRep stake amount for \(name)")
    }

    /// Effective stake delegated to each DRep this epoch.
    ///
    /// Yaci has no distribution endpoint, so the registered DReps are enumerated from the
    /// certificate log and each one's live stake is read individually. A DRep whose stake
    /// cannot be read throws, naming it, and an instance that does not serve the live stake
    /// endpoint throws ``CardanoChainError/notImplemented(_:)``: never a partial distribution.
    public func drepStakeDistribution() async throws -> [SwiftCardanoNetwork.DRepStakeEntry] {
        var latestByHash: [String: Components.Schemas.DRepRegistration] = [:]
        for certificate in try await drepCertificates() {
            guard let hash = certificate.drepHash?.lowercased(), !hash.isEmpty else { continue }
            latestByHash[hash] = certificate
        }

        var entries: [SwiftCardanoNetwork.DRepStakeEntry] = []
        for hash in latestByHash.keys.sorted() {
            guard let certificate = latestByHash[hash], certificate._type != .unregDrepCert else { continue }
            let payload = try LedgerValues.hash28(hex: hash, "Yaci DRep certificate hash")
            let drep =
                certificate.credType == .scripthash
                ? DRep(credential: .scriptHash(ScriptHash(payload: payload)))
                : DRep(credential: .verificationKeyHash(VerificationKeyHash(payload: payload)))
            let stake = try await drepStake(hex: hash, drep: drep)
            entries.append(.init(drep: drep, stake: UInt64(stake)))
        }
        return entries
    }

    /// Build an anchor from the URL and hash Yaci reports beside a certificate: `nil` when
    /// both are missing or empty, an error when only one is there or either is invalid.
    static func anchor(url: String?, hash: String?) throws -> Anchor? {
        try LedgerValues.optionalAnchor(url: url, hash: hash, "Yaci anchor")
    }

    // MARK: - Governance actions

    /// The number of epochs a governance action stays open for voting.
    private func govActionLifetime() async throws -> UInt64? {
        let lifetime = try await perform("get protocol parameters") {
            try await api.client.getLatestProtocolParams().ok.body.json.govActionLifetime
        }
        return try lifetime.map { try LedgerValues.integer($0, as: UInt64.self, "Yaci gov_action_lifetime") }
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

    private static func govActionID(of proposal: Components.Schemas.GovActionProposal) throws -> GovActionID {
        guard let txHash = proposal.txHash, let index = proposal.index else {
            throw CardanoChainError.yaciDevkitError("Governance proposal without a transaction hash or index")
        }
        return GovActionID(
            transactionID: try LedgerValues.hash(hex: txHash, as: TransactionId.self, "Yaci TransactionId"),
            govActionIndex: try index.checked("Yaci proposal index")
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
        let proposedIn: UInt64? = try proposal.epoch.map { try $0.checked("Yaci proposal epoch") }
        return GovActionInfo(
            govActionId: govActionID,
            govAction: try Self.govAction(from: proposal, id: govActionID),
            proposedIn: proposedIn,
            expiresAfter: try Self.expiresAfter(proposedIn: proposedIn, lifetime: lifetime)
        )
    }

    private static func expiresAfter(proposedIn: UInt64?, lifetime: UInt64?) throws -> UInt64? {
        guard let proposedIn, let lifetime else { return nil }
        let (sum, overflow) = proposedIn.addingReportingOverflow(lifetime)
        guard !overflow else {
            throw CardanoChainError.yaciDevkitError("Proposal epoch \(proposedIn) + lifetime \(lifetime) overflows")
        }
        return sum
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
            let id = try Self.govActionID(of: proposal)
            results.append(try await govActionVotes(proposal: proposal, id: id, lifetime: lifetime))
        }
        return results
    }

    /// Lists the governance actions not yet past their expiry, without
    /// their votes.
    ///
    /// As with ``govActionInfo(govActionID:)``, Yaci keeps no governance
    /// state: an action ratified, enacted or dropped before its expiry is
    /// still listed, and the expiry is the proposal's epoch plus the current
    /// `govActionLifetime`.
    public func openGovActions() async throws -> [OpenGovAction] {
        let epoch = try LedgerValues.integer(try await self.epoch(), as: UInt64.self, "current epoch")
        let lifetime = try await govActionLifetime()
        let proposals = try await paginate("get the governance proposal list") { page, count in
            try await api.client.getGovActionProposalList(
                query: .init(page: page, count: count, order: .desc)
            ).ok.body.json
        }
        return try proposals.compactMap { proposal in
            let id = try Self.govActionID(of: proposal)
            let proposedIn: UInt64? = try proposal.epoch.map { try $0.checked("Yaci proposal epoch") }
            let expiresAfter = try Self.expiresAfter(proposedIn: proposedIn, lifetime: lifetime)
            guard OpenGovAction.isOpen(expiresAfter: expiresAfter, in: epoch) else { return nil }
            return OpenGovAction(
                govActionId: id,
                type: OpenGovAction.code(of: try Self.govAction(from: proposal, id: id)),
                deposit: try LedgerValues.required(proposal.deposit, "Yaci proposal deposit").checked("Yaci proposal deposit"),
                anchor: try Self.anchor(url: proposal.anchorUrl, hash: proposal.anchorHash),
                proposedIn: proposedIn,
                expiresAfter: expiresAfter
            )
        }
    }

    private func govActionVotes(
        proposal: Components.Schemas.GovActionProposal,
        id: GovActionID,
        lifetime: UInt64?
    ) async throws -> GovActionVotes {
        let (committee, dreps, pools) = try await votes(
            txHash: proposal.txHash ?? id.transactionID.payload.toHex,
            index: try (proposal.index ?? Int64(id.govActionIndex)).checked("Yaci proposal index")
        )
        let proposedIn: UInt64? = try proposal.epoch.map { try $0.checked("Yaci proposal epoch") }
        let returnAddress: Data = try {
            guard let address = proposal.returnAddress, !address.isEmpty else {
                throw CardanoChainError.yaciDevkitError("Governance proposal \(id) has no return address")
            }
            if let bytes = try? Address.fromBech32(address).toBytes() { return bytes }
            return try LedgerValues.hexBytes(address, "Yaci return address \(address) (neither bech32 nor hex)")
        }()

        return GovActionVotes(
            govActionId: id,
            govAction: try Self.govAction(from: proposal, id: id),
            committeeVotes: committee,
            dRepVotes: dreps,
            stakePoolVotes: pools,
            deposit: try LedgerValues.required(proposal.deposit, "Yaci proposal deposit").checked("Yaci proposal deposit"),
            depositReturnAddr: returnAddress,
            anchor: try Self.anchor(url: proposal.anchorUrl, hash: proposal.anchorHash),
            proposedIn: proposedIn,
            expiresAfter: try Self.expiresAfter(proposedIn: proposedIn, lifetime: lifetime)
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
        // Fetched by transaction and filtered here rather than through Yaci's
        // `/proposals/{txHash}/{indexInTx}/votes` endpoint: that one returns only the
        // delegate-representative votes and silently drops the stake-pool and committee ones.
        let rows = try await paginate("get votes for \(txHash)#\(index)") { page, count in
            try await api.client.getVotingProceduresByGovActionProposalTx(
                path: .init(txHash: txHash),
                query: .init(page: page, count: count, order: .asc)
            ).ok.body.json
        }.filter {
            $0.govActionIndex == index
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
            guard let row = latest[key] else { continue }
            let payload = try LedgerValues.hash28(
                hex: LedgerValues.required(row.voterHash, "Yaci vote voter_hash"), "Yaci vote voter_hash")
            guard let vote = GovernanceParsing.parseVote(row.vote?.rawValue) else {
                throw CardanoChainError.valueError("Yaci vote \(String(describing: row.vote)) is not a vote")
            }

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
                throw CardanoChainError.valueError("Yaci vote by \(payload.toHex) has no voter type")
            }
        }
        return (committee, dreps, pools)
    }

    // MARK: - Governance action parsing

    /// Map a Yaci proposal — its type plus the `details` document the store indexed — onto a
    /// `GovAction`. `details` is exact ledger JSON (numbers as `Decimal`); a payload that does not
    /// fit its action throws.
    static func govAction(from proposal: Components.Schemas.GovActionProposal, id: GovActionID)
        throws -> GovAction
    {
        let details = proposal.details.map(ChainJSON.init)?.object
        guard let type = proposal._type?.rawValue ?? details?["type"]?.string else {
            throw CardanoChainError.valueError("Yaci governance proposal \(id) has no type")
        }

        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = details?[key]?.string, !value.isEmpty { return value }
            }
            return nil
        }
        func object(_ keys: String...) -> [String: ChainJSON]? {
            for key in keys {
                if let value = details?[key]?.object { return value }
            }
            return nil
        }
        /// The action's previous action of the same purpose, Yaci's `govActionId`
        /// (`{transactionId, gov_action_index}`), or `nil` when it has none.
        func previous() throws -> GovActionID? {
            guard let raw = (details?["govActionId"] ?? details?["gov_action_id"]).nonNull else {
                return nil
            }
            guard let prev = raw.object,
                let txHash = (prev["transactionId"] ?? prev["transaction_id"])?.string
            else {
                throw CardanoChainError.valueError("Yaci previous governance action \(raw) is not an id")
            }
            return GovActionID(
                transactionID: try LedgerValues.hash(hex: txHash, as: TransactionId.self, "Yaci previous action"),
                govActionIndex: try LedgerValues.required(
                    LedgerValues.integer(
                        json: prev["gov_action_index"] ?? prev["govActionIndex"], "Yaci previous action index"),
                    "Yaci previous action index"))
        }
        func policyHash() throws -> ScriptHash? {
            guard let hex = string("policyHash", "policy_hash") else { return nil }
            return try LedgerValues.hash(hex: hex, as: ScriptHash.self, "Yaci ScriptHash")
        }

        switch type {
        case "INFO_ACTION":
            return .infoAction(InfoAction())

        case "NO_CONFIDENCE":
            return .noConfidence(NoConfidence(id: try previous()))

        case "HARD_FORK_INITIATION_ACTION":
            let version = try LedgerValues.required(
                object("protocolVersion", "protocol_version"), "Yaci hard fork protocol version")
            let major: Int = try LedgerValues.required(
                LedgerValues.integer(json: version["_1"] ?? version["major"], "Yaci hard fork major version"),
                "Yaci hard fork major version")
            let minor: Int = try LedgerValues.required(
                LedgerValues.integer(json: version["_2"] ?? version["minor"], "Yaci hard fork minor version"),
                "Yaci hard fork minor version")
            return .hardForkInitiationAction(
                HardForkInitiationAction(
                    id: try previous(), protocolVersion: ProtocolVersion(major: major, minor: minor)
                ))

        case "TREASURY_WITHDRAWALS_ACTION":
            var withdrawals: [RewardAccount: Coin] = [:]
            for (account, amount) in try LedgerValues.required(object("withdrawals"), "Yaci treasury withdrawals") {
                let lovelace = try LedgerValues.required(
                    LedgerValues.integer(json: amount, as: UInt64.self, "Yaci treasury withdrawal amount"), "Yaci treasury withdrawal amount")
                let bytes: Data
                if let decoded = try? Address.fromBech32(account).toBytes() {
                    bytes = decoded
                } else {
                    bytes = try LedgerValues.hexBytes(account, "Yaci treasury withdrawal account")
                    guard bytes.count == 29 else {
                        throw CardanoChainError.valueError("Yaci treasury withdrawal account \(account) is not 29 bytes")
                    }
                }
                withdrawals[bytes] = Coin(lovelace)
            }
            return .treasuryWithdrawalsAction(
                TreasuryWithdrawalsAction(withdrawals: withdrawals, policyHash: try policyHash())
            )

        case "NEW_CONSTITUTION":
            let constitution = try LedgerValues.required(object("constitution"), "Yaci new constitution")
            let anchor = try LedgerValues.required(
                LedgerValues.anchor(json: constitution["anchor"], "Yaci constitution anchor"),
                "Yaci constitution anchor")
            let scriptHash = try (constitution["scripthash"] ?? constitution["scriptHash"]
                ?? constitution["script"])?.string
                .flatMap { $0.isEmpty ? nil : $0 }
                .map { try LedgerValues.hash(hex: $0, as: ScriptHash.self, "Yaci constitution script hash") }
            return .newConstitution(
                NewConstitution(
                    id: try previous(), constitution: Constitution(anchor: anchor, scriptHash: scriptHash)
                ))

        case "UPDATE_COMMITTEE":
            // As the ledger holds it: `coldCredentials` is the members to remove,
            // `credentialEpochs` the members to add with their terms.
            var coldCredentials: Set<CommitteeColdCredential> = []
            var credentialEpochs: [CommitteeColdCredential: UInt64] = [:]

            guard let removals = (details?["membersForRemoval"] ?? details?["members_for_removal"])?.array else {
                throw CardanoChainError.valueError("Yaci committee update has no members to remove")
            }
            for entry in removals {
                coldCredentials.insert(try committeeColdCredential(from: entry))
            }
            guard let additions =
                (details?["newMembersAndTerms"] ?? details?["new_members_and_terms"])?.object
            else {
                throw CardanoChainError.valueError("Yaci committee update has no members to add")
            }
            for (key, epoch) in additions {
                let credential = try committeeColdCredential(fromKey: key)
                let epochValue: UInt64 = try LedgerValues.required(
                    LedgerValues.integer(json: epoch, "Yaci committee term epoch"), "Yaci committee term epoch")
                credentialEpochs[credential] = epochValue
            }
            // A committee update always carries its quorum; a missing one is not 0.
            let interval = try LedgerValues.required(
                LedgerValues.unitInterval(
                    json: details?["threshold"] ?? details?["quorumThreshold"] ?? details?["quorum"],
                    "Yaci committee update quorum"),
                "Yaci committee update quorum")

            return .updateCommittee(
                UpdateCommittee(
                    id: try previous(),
                    coldCredentials: coldCredentials,
                    credentialEpochs: credentialEpochs,
                    interval: interval
                ))

        case "PARAMETER_CHANGE_ACTION":
            let update = try LedgerValues.required(
                object("protocolParamUpdate", "protocol_param_update"), "Yaci parameter change update")
            return .parameterChangeAction(
                LedgerGovActionJSON.parameterChange(
                    prev: try previous(), update: try protocolParamUpdate(update), policyHash: try policyHash()
                ))

        default:
            throw CardanoChainError.valueError("Yaci governance proposal \(id) has an unknown type \(type)")
        }
    }

    /// A proposed parameter update as Yaci Store records it: the Jackson form of
    /// yaci's `ProtocolParamUpdate` (camelCase fields, ratios as `{numerator,
    /// denominator}`, each cost model as the hex of its CBOR parameter list,
    /// keyed by language number). A null field is not part of the update; a field
    /// this reader does not know, or one Conway cannot change, throws.
    static func protocolParamUpdate(_ d: [String: ChainJSON]) throws -> ProtocolParamUpdate {
        let what = "Yaci parameter update"
        func value(_ key: String) -> ChainJSON? {
            d[key].nonNull
        }
        func int<T: FixedWidthInteger>(_ key: String) throws -> T? {
            try LedgerValues.integer(json: value(key), "\(what) \(key)")
        }
        func unit(_ key: String, in object: [String: ChainJSON]? = nil) throws -> UnitInterval? {
            try LedgerValues.unitInterval(json: object.map { $0[key] } ?? value(key), "\(what) \(key)")
        }
        func nni(_ key: String) throws -> NonNegativeInterval? {
            try LedgerValues.nonNegativeInterval(json: value(key), "\(what) \(key)")
        }
        func object(_ key: String) throws -> [String: ChainJSON]? {
            guard let raw = value(key) else { return nil }
            guard let object = raw.object else {
                throw CardanoChainError.valueError("\(what) \(key): \(raw) is not an object")
            }
            return object
        }
        /// Both halves of a pair, or neither.
        func pair<A, B>(_ a: A?, _ b: B?, _ name: String) throws -> (A, B)? {
            switch (a, b) {
            case let (a?, b?): return (a, b)
            case (nil, nil): return nil
            default: throw CardanoChainError.valueError("\(what) has only half of \(name)")
            }
        }

        let known: Set<String> = [
            "minFeeA", "minFeeB", "maxBlockSize", "maxTxSize", "maxBlockHeaderSize", "keyDeposit",
            "poolDeposit", "maxEpoch", "nopt", "poolPledgeInfluence", "expansionRate", "treasuryGrowthRate",
            "decentralisationParam", "extraEntropy", "protocolMajorVer", "protocolMinorVer", "minUtxo",
            "minPoolCost", "adaPerUtxoByte", "costModels", "costModelsHash", "priceMem", "priceStep",
            "maxTxExMem", "maxTxExSteps", "maxBlockExMem", "maxBlockExSteps", "maxValSize",
            "collateralPercent", "maxCollateralInputs", "poolVotingThresholds", "drepVotingThresholds",
            "committeeMinSize", "committeeMaxTermLength", "govActionLifetime", "govActionDeposit",
            "drepDeposit", "drepActivity", "minFeeRefScriptCostPerByte",
        ]
        if let unknown = d.keys.filter({ !known.contains($0) }).sorted().first {
            throw CardanoChainError.valueError("\(what) has a field this library does not read: \(unknown)")
        }
        // Pre-Conway fields a Conway parameter change cannot carry.
        for key in ["extraEntropy", "minUtxo"] where value(key) != nil {
            throw CardanoChainError.notImplemented("\(what) changes \(key), which a Conway update cannot")
        }

        var u = ProtocolParamUpdate()
        u.minFeeA = try int("minFeeA")
        u.minFeeB = try int("minFeeB")
        u.maxBlockBodySize = try int("maxBlockSize")
        u.maxTransactionSize = try int("maxTxSize")
        u.maxBlockHeaderSize = try int("maxBlockHeaderSize")
        u.keyDeposit = try int("keyDeposit")
        u.poolDeposit = try int("poolDeposit")
        u.maximumEpoch = try int("maxEpoch")
        u.nOpt = try int("nopt")
        u.poolPledgeInfluence = try nni("poolPledgeInfluence")
        u.expansionRate = try unit("expansionRate")
        u.treasuryGrowthRate = try unit("treasuryGrowthRate")
        u.decentralizationConstant = try unit("decentralisationParam")
        if let (major, minor) = try pair(
            int("protocolMajorVer") as Int?, int("protocolMinorVer") as Int?, "the protocol version")
        {
            u.protocolVersion = ProtocolVersion(major: major, minor: minor)
        }
        u.minPoolCost = try int("minPoolCost")
        u.adaPerUtxoByte = try int("adaPerUtxoByte")
        if let models = try object("costModels") {
            u.costModels = try costModels(models, what)
        }
        if let (mem, step) = try pair(nni("priceMem"), nni("priceStep"), "the execution prices") {
            u.executionCosts = ExUnitPrices(memPrice: mem, stepPrice: step)
        }
        if let (mem, steps) = try pair(
            int("maxTxExMem") as UInt64?, int("maxTxExSteps") as UInt64?, "the transaction execution units")
        {
            u.maxTxExUnits = ExUnits(mem: mem, steps: steps)
        }
        if let (mem, steps) = try pair(
            int("maxBlockExMem") as UInt64?, int("maxBlockExSteps") as UInt64?, "the block execution units")
        {
            u.maxBlockExUnits = ExUnits(mem: mem, steps: steps)
        }
        u.maxValueSize = try int("maxValSize")
        u.collateralPercentage = try int("collateralPercent")
        u.maxCollateralInputs = try int("maxCollateralInputs")
        if let pvt = try object("poolVotingThresholds") {
            func t(_ key: String) throws -> UnitInterval {
                try LedgerValues.required(unit(key, in: pvt), "\(what) poolVotingThresholds \(key)")
            }
            u.poolVotingThresholds = PoolVotingThresholds(
                motionNoConfidence: try t("pvtMotionNoConfidence"),
                committeeNormal: try t("pvtCommitteeNormal"),
                committeeNoConfidence: try t("pvtCommitteeNoConfidence"),
                hardForkInitiation: try t("pvtHardForkInitiation"),
                ppSecurityGroup: try t("pvtPPSecurityGroup"))
        }
        if let dvt = try object("drepVotingThresholds") {
            func t(_ key: String) throws -> UnitInterval {
                try LedgerValues.required(unit(key, in: dvt), "\(what) drepVotingThresholds \(key)")
            }
            // CDDL order.
            u.drepVotingThresholds = try DrepVotingThresholds(thresholds: [
                t("dvtMotionNoConfidence"), t("dvtCommitteeNormal"), t("dvtCommitteeNoConfidence"),
                t("dvtUpdateToConstitution"), t("dvtHardForkInitiation"), t("dvtPPNetworkGroup"),
                t("dvtPPEconomicGroup"), t("dvtPPTechnicalGroup"), t("dvtPPGovGroup"), t("dvtTreasuryWithdrawal"),
            ])
        }
        u.minCommitteeSize = try int("committeeMinSize")
        u.committeeTermLimit = try int("committeeMaxTermLength")
        u.governanceActionValidityPeriod = try int("govActionLifetime")
        u.governanceActionDeposit = try int("govActionDeposit")
        u.drepDeposit = try int("drepDeposit")
        u.drepInactivityPeriod = try int("drepActivity")
        u.minFeeRefScriptCoinsPerByte = try nni("minFeeRefScriptCostPerByte")
        return u
    }

    /// `{"<language number>": "<hex of the CBOR parameter list>"}`, read through
    /// core's CBOR decoder as the ledger's cost-model map.
    private static func costModels(_ models: [String: ChainJSON], _ what: String) throws -> CostModels {
        guard models.count <= 23 else {
            throw CardanoChainError.valueError("\(what) costModels has \(models.count) languages")
        }
        var cbor = Data([0xA0 | UInt8(models.count)])
        for (key, value) in models.sorted(by: { $0.key < $1.key }) {
            guard let language = UInt8(key), language <= 2 else {
                throw CardanoChainError.valueError("\(what) costModels: unknown language \(key)")
            }
            guard let hex = value.string, !hex.isEmpty else {
                throw CardanoChainError.valueError("\(what) costModels \(key): \(value) is not CBOR hex")
            }
            cbor.append(language)
            cbor.append(try LedgerValues.hexBytes(hex, "\(what) costModels \(key)"))
        }
        do {
            return try CostModels.fromCBOR(data: cbor)
        } catch {
            throw CardanoChainError.valueError("\(what) costModels: \(error)")
        }
    }

    /// Yaci serialises a credential as `{"type": "ADDR_KEYHASH" | "SCRIPTHASH", "hash": hex}`.
    private static func committeeColdCredential(from json: ChainJSON) throws -> CommitteeColdCredential {
        if let key = json.string { return try committeeColdCredential(fromKey: key) }
        guard let dict = json.object, let hash = dict["hash"]?.string else {
            throw CardanoChainError.valueError("Yaci committee credential \(json) is not a credential")
        }
        let type = dict["type"]?.string ?? "ADDR_KEYHASH"
        return makeCommitteeColdCredential(
            payload: try LedgerValues.hash28(hex: hash, "Yaci committee credential"), isScript: type == "SCRIPTHASH")
    }

    /// Map keys arrive either in cardano-cli form (`keyHash-<hex>` / `scriptHash-<hex>`) or as
    /// Jackson's rendering of a credential (`Credential(type=ADDR_KEYHASH, hash=<hex>)`).
    private static func committeeColdCredential(fromKey key: String) throws -> CommitteeColdCredential {
        if key.hasPrefix("keyHash-") || key.hasPrefix("scriptHash-") {
            return CommitteeColdCredential(credential: try LedgerValues.credential(json: key, "Yaci committee member"))
        }
        if let range = key.range(of: "hash=") {
            let hex = key[range.upperBound...].prefix { $0 != ")" && $0 != "," }
            return makeCommitteeColdCredential(
                payload: try LedgerValues.hash28(hex: String(hex), "Yaci committee member"),
                isScript: key.contains("SCRIPTHASH"))
        }
        return makeCommitteeColdCredential(
            payload: try LedgerValues.hash28(hex: key, "Yaci committee member"), isScript: false)
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
        try? LedgerValues.unitInterval(json: any, "Yaci threshold")
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

        func hotCredential(for cold: CommitteeColdCredential) throws -> CommitteeHotCredential? {
            guard let hex = hotKeys[cold] else { return nil }
            let payload = try LedgerValues.hash28(hex: hex, "Yaci committee hot key")
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
                status = Int(expiration) >= currentEpoch ? .active : .expired
            } else {
                status = .active
            }
            members.append(
                CommitteeStateInfo.Member(
                    coldCredential: member.credential,
                    hotCredential: try hotCredential(for: member.credential),
                    expiration: try member.expiration.map { try $0.checked("Yaci committee member expiration") },
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
                    hotCredential: try hotCredential(for: cold),
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
    private func currentCommittee() async throws -> ([CommitteeMemberTerm], UnitInterval?) {
        if let output = try? await api.client.getCommitteeMembers(),
            case .ok(let ok) = output,
            let committee = try? ok.body.json,
            let rows = committee.members, !rows.isEmpty
        {
            let members = try rows.map { member -> CommitteeMemberTerm in
                let payload = try LedgerValues.hash28(
                    hex: LedgerValues.required(member.hash, "Yaci committee member hash"), "Yaci committee member hash")
                return CommitteeMemberTerm(
                    credential: Self.makeCommitteeColdCredential(
                        payload: payload, isScript: member.credType == .scripthash),
                    expiration: member.expiredEpoch
                )
            }
            let numerator: UInt64 = try LedgerValues.required(
                committee.thresholdNumerator, "Yaci committee threshold_numerator").checked("Yaci committee threshold_numerator")
            let denominator: UInt64 = try LedgerValues.required(
                committee.thresholdDenominator, "Yaci committee threshold_denominator")
                .checked("Yaci committee threshold_denominator")
            return (members, try LedgerValues.unitInterval(text: "\(numerator)/\(denominator)", "Yaci committee threshold"))
        }

        let live = try await perform("get the current committee") {
            try await api.client.getCommitteeInfo().ok.body.json
        }
        let members = try (live.members ?? []).map { member -> CommitteeMemberTerm in
            let payload = try LedgerValues.hash28(
                hex: LedgerValues.required(member.hash, "Yaci committee member hash"), "Yaci committee member hash")
            return CommitteeMemberTerm(
                credential: Self.makeCommitteeColdCredential(
                    payload: payload, isScript: member.credType == .scripthash),
                expiration: member.expiredEpoch
            )
        }
        // Yaci's client reads the threshold as the exact decimal Yaci sent.
        // None means no committee: nil.
        return (members, try live.threshold.map { try LedgerValues.unitInterval($0, "Yaci committee threshold") })
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
            let payload = try LedgerValues.hash28(
                hex: LedgerValues.required(row.coldKey, "Yaci committee registration cold_key"),
                "Yaci committee registration cold_key")
            let hot = try LedgerValues.required(row.hotKey, "Yaci committee registration hot_key")
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
            let payload = try LedgerValues.hash28(
                hex: LedgerValues.required(row.coldKey, "Yaci committee deregistration cold_key"),
                "Yaci committee deregistration cold_key")
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
