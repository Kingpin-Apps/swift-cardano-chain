import BigInt
import Foundation
import OpenAPIRuntime
import SwiftBlockfrostAPI
import SwiftCardanoCore
import SwiftCardanoNetwork

/// A chain context implementation backed by the [BlockFrost](https://blockfrost.io) cloud API.
///
/// `BlockFrostChainContext` is the easiest way to interact with Cardano without running a local
/// node. It forwards all chain queries to the BlockFrost REST API and requires no local
/// infrastructure beyond a project ID.
///
/// ## Creating a Context
///
/// ```swift
/// // From an environment variable (recommended for CI/production)
/// let context = try await BlockFrostChainContext(
///     network: .mainnet,
///     environmentVariable: "BLOCKFROST_API_KEY"
/// )
///
/// // Or with a project ID directly
/// let context = try await BlockFrostChainContext(
///     projectId: "mainnetXXXXXXXXXXXXXXXXXXXX",
///     network: .mainnet
/// )
/// ```
///
/// ## Supported Networks
///
/// `.mainnet`, `.preprod`, `.preview`
///
/// ## Topics
///
/// ### Creating a Context
/// - ``init(projectId:network:basePath:environmentVariable:client:)``
///
/// ### Querying Chain State
/// - ``utxos(address:)``
/// - ``stakeAddressInfo(address:)``
/// - ``stakePools()``
/// - ``stakePoolInfo(poolId:)``
///
/// ### Transaction Operations
/// - ``submitTxCBOR(cbor:)``
/// - ``evaluateTxCBOR(cbor:)``
public actor BlockFrostChainContext: ChainContext {

    // MARK: - Properties
    nonisolated public var name: String { "Blockfrost" }
    nonisolated public var type: ContextType { .online }

    public let api: Blockfrost
    private var epochInfo: Components.Schemas.EpochContent?
    private var _epochInfoFetch: Task<Components.Schemas.EpochContent, Error>?
    private var _genesisParameters: GenesisParameters?
    private var _genesisParametersFetch: Task<GenesisParameters, Error>?
    private var _protocolParameters: ProtocolParameters?
    private var _protocolParametersEpoch: Int?
    private var _protocolParametersFetch: Task<ProtocolParameters, Error>?
    private let _network: SwiftCardanoCore.Network

    nonisolated public var networkId: NetworkId {
        _network.networkId
    }

    public func era() async throws -> Era? {
        Era.fromEpoch(epoch: try await epoch().checked("Blockfrost epoch"))
    }

    public func epoch() async throws -> Int {
        try await currentEpochInfo().epoch
    }

    /// Master cache for the latest Blockfrost epoch metadata.
    ///
    /// `endTime` is the wall-clock instant the current epoch ends. While that's in the
    /// future the cache is fresh; otherwise we refresh, deduplicating concurrent callers
    /// through `_epochInfoFetch` so the network round-trip happens at most once at a time.
    /// Cache writes happen inside the Task body so the result lands in the cache even if
    /// the launching caller is cancelled mid-flight.
    private func currentEpochInfo() async throws -> Components.Schemas.EpochContent {
        if let cached = epochInfo,
           Int(Date().timeIntervalSince1970) < cached.endTime {
            return cached
        }
        if let inFlight = _epochInfoFetch { return try await inFlight.value }

        let task = Task<Components.Schemas.EpochContent, Error> {
            do {
                let value = try await self.fetchEpochInfoFromAPI()
                self.epochInfo = value
                self._epochInfoFetch = nil
                return value
            } catch {
                self._epochInfoFetch = nil
                throw error
            }
        }
        _epochInfoFetch = task
        return try await task.value
    }

    private func fetchEpochInfoFromAPI() async throws -> Components.Schemas.EpochContent {
        let response = try await api.client.getEpochsLatest()
        do {
            return try response.ok.body.json
        } catch {
            throw CardanoChainError.blockfrostError("Failed to get epoch info: \(response)")
        }
    }

    public func lastBlockSlot() async throws -> Int {
        let response = try await api.client.getBlocksLatest()
        do {
            return try LedgerValues.required(response.ok.body.json.slot, "Blockfrost latest block slot")
        } catch {
            throw CardanoChainError.blockfrostError("Failed to get blocksLatest: \(response)")
        }
    }

    public func genesisParameters() async throws -> GenesisParameters {
        if let cached = _genesisParameters { return cached }
        if let inFlight = _genesisParametersFetch { return try await inFlight.value }

        let task = Task<GenesisParameters, Error> {
            do {
                let value = try await self.fetchGenesisFromAPI()
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

    private func fetchGenesisFromAPI() async throws -> GenesisParameters {
        let response = try await api.client.getGenesis()
        do {
            let genesis = try response.ok.body.json
            func int<T: FixedWidthInteger>(_ value: Int, _ field: String) throws -> T {
                try LedgerValues.integer(value, as: T.self, "Blockfrost genesis \(field)")
            }
            return GenesisParameters(
                activeSlotsCoefficient: try LedgerValues.unitInterval(
                    genesis.activeSlotsCoefficient, "Blockfrost genesis active_slots_coefficient"),
                epochLength: try int(genesis.epochLength, "epoch_length"),
                maxKesEvolutions: try int(genesis.maxKesEvolutions, "max_kes_evolutions"),
                maxLovelaceSupply: try LedgerValues.integer(
                    text: genesis.maxLovelaceSupply, "Blockfrost genesis max_lovelace_supply"),
                networkId: _network.description,
                networkMagic: try int(genesis.networkMagic, "network_magic"),
                securityParam: try int(genesis.securityParam, "security_param"),
                // Blockfrost sends the slot length in whole seconds.
                slotLength: Decimal(genesis.slotLength),
                slotsPerKesPeriod: try int(genesis.slotsPerKesPeriod, "slots_per_kes_period"),
                systemStart: Date(timeIntervalSince1970: TimeInterval(genesis.systemStart)),
                updateQuorum: try int(genesis.updateQuorum, "update_quorum")
            )
        } catch {
            throw CardanoChainError.blockfrostError("Failed to get getGenesis: \(response)")
        }
    }

    public func protocolParameters() async throws -> ProtocolParameters {
        let currentEpoch = try await epoch()
        if let cached = _protocolParameters,
           _protocolParametersEpoch == currentEpoch {
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

    // MARK: - Initialization

    public init(
        projectId: String? = nil,
        network: SwiftCardanoCore.Network? = .mainnet,
        basePath: String? = nil,
        environmentVariable: String? = nil,
        client: Client? = nil,
    ) async throws {
        self._network = network ?? .mainnet

        let blockfrostNetwork: SwiftBlockfrostAPI.Network
        switch network {
        case .mainnet:
            blockfrostNetwork = .mainnet
        case .preprod:
            blockfrostNetwork = .preprod
        case .preview:
            blockfrostNetwork = .preview
        default:
            throw CardanoChainError.unsupportedNetwork(
                "Unsupported network: \(String(describing: network))"
            )
        }

        self.api = try Blockfrost(
            network: blockfrostNetwork,
            projectId: projectId,
            basePath: basePath,
            environmentVariable: environmentVariable,
            client: client
        )

        // Initialize epoch info
        do {
            let response = try await api.client.getEpochsLatest()
            self.epochInfo = try response.ok.body.json
        } catch {
            throw
                CardanoChainError
                .blockfrostError(
                    "Failed to get epoch info: \(error.localizedDescription)"
                )
        }
    }

    // MARK: - Public Methods

    /// Query the chain tip
    ///
    /// - Returns: The chain tip as a dictionary
    /// - Throws: CardanoChainError if the query fails
    public func chainTip() async throws -> ChainTip {
        do {
            let response = try await api.client.getBlocksLatest()
            let json = try response.ok.body.json

            return ChainTip(
                block: try json.height.map { try $0.checked("Blockfrost tip height") },
                epoch: try json.epoch.map { try $0.checked("Blockfrost tip epoch") },
                era: nil,
                hash: json.hash,
                slot: try json.slot.map { try $0.checked("Blockfrost tip slot") },
                slotInEpoch: try json.epochSlot.map { try $0.checked("Blockfrost tip epoch_slot") },
                slotsToEpochEnd: nil,
                syncProgress: nil
            )
        } catch {
            throw CardanoChainError.blockfrostError("Failed to get blocksLatest: \(error)")
        }
    }

    /// Query the current protocol parameters
    ///
    /// - Returns: The protocol parameters as a dictionary
    /// - Throws: CardanoChainError if the query fails
    public func queryCurrentProtocolParams() async throws -> ProtocolParameters {
        do {
            let response = try await api.client.getEpochsLatestParameters()
            let protocolParams = try response.ok.body.json

            // Read from `cost_models_raw` rather than the deprecated `cost_models` map. The raw
            // form is the ledger-ordered list, and that ordering is load-bearing: the script
            // data hash covers the costs in ledger order, which for Plutus V3 is not
            // alphabetical, so costs taken from the name-keyed map and sorted would have the
            // transaction refused with PPViewHashesDontMatch.
            let rawCostModels = protocolParams.costModelsRaw?.additionalProperties.value ?? [:]
            // A missing or malformed cost model is an error, not an empty one.
            func costModel(_ language: String) throws -> [Int64] {
                guard let value = rawCostModels[language].flatMap({ $0 }),
                    let list = value as? [Any]
                else {
                    throw CardanoChainError.blockfrostError("cost_models_raw has no \(language) list")
                }
                return try list.map {
                    try LedgerValues.required(
                        LedgerValues.integer(json: $0, as: Int64.self, "Blockfrost \(language) cost"),
                        "Blockfrost \(language) cost")
                }
            }

            let p = protocolParams
            // Blockfrost's client reads each ratio as a Double; its shortest
            // description is the decimal Blockfrost sent, read here exactly.
            func unit(_ value: Double?, _ field: String) throws -> UnitInterval {
                try LedgerValues.unitInterval(LedgerValues.required(value, "Blockfrost \(field)"), "Blockfrost \(field)")
            }
            func nonNegative(_ value: Double?, _ field: String) throws -> NonNegativeInterval {
                try LedgerValues.nonNegativeInterval(
                    LedgerValues.required(value, "Blockfrost \(field)"), "Blockfrost \(field)")
            }
            func int<T: FixedWidthInteger>(_ value: Int?, _ field: String) throws -> T {
                try LedgerValues.integer(LedgerValues.required(value, "Blockfrost \(field)"), as: T.self, "Blockfrost \(field)")
            }
            func int<T: FixedWidthInteger>(_ text: String?, _ field: String) throws -> T {
                try LedgerValues.integer(
                    text: LedgerValues.required(text, "Blockfrost \(field)"), as: T.self, "Blockfrost \(field)")
            }

            return ProtocolParameters(
                collateralPercentage: try int(p.collateralPercent, "collateral_percent"),
                committeeMaxTermLength: try int(p.committeeMaxTermLength, "committee_max_term_length"),
                committeeMinSize: try int(p.committeeMinSize, "committee_min_size"),
                costModels: ProtocolParametersCostModels(
                    PlutusV1: try costModel("PlutusV1"),
                    PlutusV2: try costModel("PlutusV2"),
                    PlutusV3: try costModel("PlutusV3")
                ),
                dRepActivity: try int(p.drepActivity, "drep_activity"),
                dRepDeposit: try int(p.drepDeposit, "drep_deposit"),
                dRepVotingThresholds: DRepVotingThresholds(
                    committeeNoConfidence: try unit(p.dvtCommitteeNoConfidence, "dvt_committee_no_confidence"),
                    committeeNormal: try unit(p.dvtCommitteeNormal, "dvt_committee_normal"),
                    hardForkInitiation: try unit(p.dvtHardForkInitiation, "dvt_hard_fork_initiation"),
                    motionNoConfidence: try unit(p.dvtMotionNoConfidence, "dvt_motion_no_confidence"),
                    ppEconomicGroup: try unit(p.dvtPPEconomicGroup, "dvt_p_p_economic_group"),
                    ppGovGroup: try unit(p.dvtPPGovGroup, "dvt_p_p_gov_group"),
                    ppNetworkGroup: try unit(p.dvtPPNetworkGroup, "dvt_p_p_network_group"),
                    ppTechnicalGroup: try unit(p.dvtPPTechnicalGroup, "dvt_p_p_technical_group"),
                    treasuryWithdrawal: try unit(p.dvtTreasuryWithdrawal, "dvt_treasury_withdrawal"),
                    updateToConstitution: try unit(p.dvtUpdateToConstitution, "dvt_update_to_constitution")
                ),
                executionUnitPrices: ExecutionUnitPrices(
                    priceMemory: try nonNegative(p.priceMem, "price_mem"),
                    priceSteps: try nonNegative(p.priceStep, "price_step")
                ),
                govActionDeposit: try int(p.govActionDeposit, "gov_action_deposit"),
                govActionLifetime: try int(p.govActionLifetime, "gov_action_lifetime"),
                maxBlockBodySize: try int(p.maxBlockSize, "max_block_size"),
                maxBlockExecutionUnits: ProtocolParametersExecutionUnits(
                    memory: try int(p.maxBlockExMem, "max_block_ex_mem"),
                    steps: try int(p.maxBlockExSteps, "max_block_ex_steps")
                ),
                maxBlockHeaderSize: try int(p.maxBlockHeaderSize, "max_block_header_size"),
                maxCollateralInputs: try int(p.maxCollateralInputs, "max_collateral_inputs"),
                maxTxExecutionUnits: ProtocolParametersExecutionUnits(
                    memory: try int(p.maxTxExMem, "max_tx_ex_mem"),
                    steps: try int(p.maxTxExSteps, "max_tx_ex_steps")
                ),
                maxTxSize: try int(p.maxTxSize, "max_tx_size"),
                maxValueSize: try int(p.maxValSize, "max_val_size"),
                minFeeRefScriptCostPerByte: try nonNegative(
                    p.minFeeRefScriptCostPerByte, "min_fee_ref_script_cost_per_byte"),
                minPoolCost: try int(p.minPoolCost, "min_pool_cost"),
                monetaryExpansion: try unit(p.rho, "rho"),
                poolPledgeInfluence: try nonNegative(p.a0, "a0"),
                poolRetireMaxEpoch: try int(p.eMax, "e_max"),
                poolVotingThresholds: ProtocolParametersPoolVotingThresholds(
                    committeeNoConfidence: try unit(p.pvtCommitteeNoConfidence, "pvt_committee_no_confidence"),
                    committeeNormal: try unit(p.pvtCommitteeNormal, "pvt_committee_normal"),
                    hardForkInitiation: try unit(p.pvtHardForkInitiation, "pvt_hard_fork_initiation"),
                    motionNoConfidence: try unit(p.pvtMotionNoConfidence, "pvt_motion_no_confidence"),
                    ppSecurityGroup: try unit(p.pvtPPSecurityGroup, "pvt_p_p_security_group")
                ),
                protocolVersion: ProtocolParametersProtocolVersion(
                    major: try int(p.protocolMajorVer, "protocol_major_ver"),
                    minor: try int(p.protocolMinorVer, "protocol_minor_ver")
                ),
                stakeAddressDeposit: try int(p.keyDeposit, "key_deposit"),
                stakePoolDeposit: try int(p.poolDeposit, "pool_deposit"),
                stakePoolTargetNum: try int(p.nOpt, "n_opt"),
                treasuryCut: try unit(p.tau, "tau"),
                txFeeFixed: try int(p.minFeeB, "min_fee_b"),
                txFeePerByte: try int(p.minFeeA, "min_fee_a"),
                utxoCostPerByte: try int(p.coinsPerUtxoSize, "coins_per_utxo_size")
            )

        } catch {
            throw CardanoChainError.blockfrostError(
                "Failed to get getEpochsLatestParameters: \(error)")
        }
    }

    // MARK: - Private Methods

    /// A helper function to try to fix script hash issues
    ///
    /// - Parameters:
    ///   - hash: The script hash string
    ///   - script: The script object
    /// - Returns: The fixed script object
    /// - Throws: ValueError if the script cannot be recovered from hash
    public func tryFixScript(
        hash: String,
        script: PlutusScript
    ) throws -> PlutusScript {

        let _scriptHash = try scriptHash(script: script.toScriptType)
        if _scriptHash.payload.toHex == hash {
            return script
        }

        let newScript: PlutusScript
        switch script {
        case .plutusV1Script(let script):
            newScript =
                .plutusV1Script(script)
        case .plutusV2Script(let script):
            newScript =
                .plutusV2Script(script)
        case .plutusV3Script(let script):
            newScript =
                .plutusV3Script(script)
        }

        let newScriptHash = try scriptHash(script: newScript.toScriptType)
        if newScriptHash.payload.toHex == hash {
            return newScript
        } else {
            throw CardanoChainError.valueError(
                "Cannot recover script: \(script) from hash: \(hash).")
        }
    }

    private func getScript(scriptHash: String) async throws -> ScriptType {
        do {
            let scriptInfo = try await api.client.getScriptsScriptHash(
                Operations.GetScriptsScriptHash
                    .Input(
                        path: Operations.GetScriptsScriptHash.Input
                            .Path(scriptHash: scriptHash)
                    )
            )

            let scriptType: Components.Schemas.Script._TypePayload
            do {
                let script = try scriptInfo.ok.body.json
                scriptType = script._type
            } catch {
                throw CardanoChainError.blockfrostError(
                    "Failed to get scriptInfo info: \(scriptInfo)")
            }

            switch scriptType {
            case .plutusV1:
                let scriptCBOR = try await api.client.getScriptsScriptHashCbor(
                    Operations.GetScriptsScriptHashCbor
                        .Input(
                            path: Operations.GetScriptsScriptHashCbor.Input
                                .Path(scriptHash: scriptHash)
                        )
                )
                do {
                    let cbor = try LedgerValues.required(scriptCBOR.ok.body.json.cbor, "Blockfrost script cbor")
                    let v1script = PlutusV1Script(data: try LedgerValues.hexBytes(cbor, "Blockfrost script cbor"))
                    return try tryFixScript(
                        hash: scriptHash,
                        script: .plutusV1Script(v1script)
                    ).toScriptType
                } catch {
                    throw CardanoChainError.blockfrostError(
                        "Failed to get scriptCBOR: \(scriptCBOR)")
                }
            case .plutusV2:
                let scriptCBOR = try await api.client.getScriptsScriptHashCbor(
                    Operations.GetScriptsScriptHashCbor
                        .Input(
                            path: Operations.GetScriptsScriptHashCbor.Input
                                .Path(scriptHash: scriptHash)
                        )
                )
                do {
                    let cbor = try LedgerValues.required(scriptCBOR.ok.body.json.cbor, "Blockfrost script cbor")
                    let v1script = PlutusV2Script(data: try LedgerValues.hexBytes(cbor, "Blockfrost script cbor"))
                    return try tryFixScript(
                        hash: scriptHash,
                        script: .plutusV2Script(v1script)
                    ).toScriptType
                } catch {
                    throw CardanoChainError.blockfrostError(
                        "Failed to get scriptCBOR: \(scriptCBOR)")
                }
            case .plutusV3:
                let scriptCBOR = try await api.client.getScriptsScriptHashCbor(
                    Operations.GetScriptsScriptHashCbor
                        .Input(
                            path: Operations.GetScriptsScriptHashCbor.Input
                                .Path(scriptHash: scriptHash)
                        )
                )
                do {
                    let cbor = try LedgerValues.required(scriptCBOR.ok.body.json.cbor, "Blockfrost script cbor")
                    let v1script = PlutusV3Script(data: try LedgerValues.hexBytes(cbor, "Blockfrost script cbor"))
                    return try tryFixScript(
                        hash: scriptHash,
                        script: .plutusV3Script(v1script)
                    ).toScriptType
                } catch {
                    throw CardanoChainError.blockfrostError(
                        "Failed to get scriptCBOR: \(scriptCBOR)")
                }
            case .timelock:
                let scriptJSON = try await api.client.getScriptsScriptHashJson(
                    Operations.GetScriptsScriptHashJson
                        .Input(
                            path: Operations.GetScriptsScriptHashJson.Input
                                .Path(scriptHash: scriptHash)
                        )
                )
                do {
                    let json = try scriptJSON.ok.body.json.json
                    let jsonData = try JSONEncoder().encode(json)
                    guard let text = String(data: jsonData, encoding: .utf8) else {
                        throw CardanoChainError.blockfrostError(
                            "Script JSON is not valid UTF-8")
                    }
                    // `NativeScript.fromJSON` is the entry point that understands the
                    // `{"type": "sig", …}` shape; decoding the type directly goes through its
                    // CBOR representation instead.
                    return .nativeScript(try NativeScript.fromJSON(text))
                } catch {
                    throw CardanoChainError.blockfrostError(
                        "Failed to get scriptJSON: \(scriptJSON)")
                }
            }
        } catch {
            throw CardanoChainError.invalidArgument(
                "Failed to get script: \(error.localizedDescription)")
        }
    }

    // MARK: - Public Methods

    /// Gets the UTxOs for a given address.
    /// - Parameter address: The address to get the `UTxO`s for.
    /// - Returns: A list of `UTxO`s.
    public func utxos(address: Address) async throws -> [UTxO] {
        let addressUtxos = try await api.client.getAddressesAddressUtxos(
            Operations.GetAddressesAddressUtxos.Input(
                path: Operations.GetAddressesAddressUtxos.Input
                    .Path(address: address.toBech32())
            )
        )

        do {
            let results = try addressUtxos.ok.body.json
            var utxos: [UTxO] = []

            for result in results {
                let txIn = TransactionInput(
                    transactionId: try LedgerValues.hash(hex: result.txHash, as: TransactionId.self, "Blockfrost TransactionId"),
                    index: try LedgerValues.integer(result.outputIndex, "Blockfrost output index")
                )

                var lovelaceAmount: UInt64? = nil
                var multiAssets = MultiAsset([:])

                for item in result.amount {
                    if item.unit == "lovelace" {
                        lovelaceAmount = try LedgerValues.integer(text: item.quantity, "Blockfrost lovelace quantity")
                    } else {
                        // The utxo contains Multi-asset
                        let (policyId, assetName) = try LedgerValues.asset(unit: item.unit, "Blockfrost asset unit")

                        if multiAssets[policyId] == nil {
                            multiAssets[policyId] = Asset([:])
                        }
                        multiAssets[policyId]?[assetName] = try LedgerValues.bigInt(text: item.quantity, "Blockfrost asset quantity")
                    }
                }

                let amount = Value(
                    coin: BigInt(try LedgerValues.required(lovelaceAmount, "Blockfrost UTxO lovelace")),
                    multiAsset: multiAssets
                )

                var datumHash: DatumHash? = nil
                var datumOption: DatumOption? = nil
                var script: ScriptType? = nil

                if result.dataHash != nil && result.inlineDatum == nil {
                    datumHash = try LedgerValues.hash(hex: result.dataHash!, as: DatumHash.self, "Blockfrost DatumHash")
                }

                if let inlineDatum = result.inlineDatum {
                    let datumData = try LedgerValues.hexBytes(inlineDatum, "Blockfrost inline datum")
                    // Parse as PlutusData first, then wrap in DatumOption
                    let plutusData = try PlutusData.fromCBOR(data: datumData)
                    datumOption = DatumOption(datum: plutusData)
                }
                //                else if let inlineDatum = result.inlineDatum as? [AnyHashable: Any] {
                //                    let plutusData = try PlutusData.fromDict(inlineDatum)
                //                    datumOption = DatumOption(datum: plutusData)
                //                }

                if let referenceScriptHash = result.referenceScriptHash {
                    script =
                        try? await self
                        .getScript(scriptHash: referenceScriptHash)
                }

                let address = try Address(from: .string(result.address))
                let txOut = TransactionOutput(
                    address: address,
                    amount: amount,
                    datumHash: datumHash,
                    datumOption: datumOption,
                    script: script
                )

                utxos.append(UTxO(input: txIn, output: txOut))
            }

            return utxos
        } catch {
            throw CardanoChainError.blockfrostError("Failed to get UTxOs: \(error)")
        }
    }

    /// Get the UTxO for a specific transaction input.
    ///
    /// - Parameter input: A transaction input identifying the UTxO by transaction hash and output index.
    /// - Returns: A tuple of the UTxO and a boolean indicating whether it has been spent,
    ///   or `nil` if the output index does not exist in that transaction.
    ///   Blockfrost returns all outputs regardless of spent status, so `isSpent` is accurate.
    /// - Throws: `CardanoChainError.blockfrostError` if the query fails.
    public func utxo(input: TransactionInput) async throws -> (UTxO, isSpent: Bool)? {
        let txHash = input.transactionId.description
        let outputIndex = Int(input.index)

        let response = try await api.client.getTxsHashUtxos(
            Operations.GetTxsHashUtxos.Input(
                path: Operations.GetTxsHashUtxos.Input.Path(hash: txHash)
            )
        )

        do {
            let txUtxos = try response.ok.body.json

            guard let result = txUtxos.outputs.first(where: { $0.outputIndex == outputIndex }) else {
                return nil
            }

            let isSpent = result.consumedByTx != nil

            let txIn = TransactionInput(
                transactionId: try LedgerValues.hash(hex: txHash, as: TransactionId.self, "Blockfrost TransactionId"),
                index: try LedgerValues.integer(outputIndex, "Blockfrost output index")
            )

            var lovelaceAmount: UInt64? = nil
            var multiAssets = MultiAsset([:])

            for item in result.amount {
                if item.unit == "lovelace" {
                    lovelaceAmount = try LedgerValues.integer(text: item.quantity, "Blockfrost lovelace quantity")
                } else {
                    let (policyId, assetName) = try LedgerValues.asset(unit: item.unit, "Blockfrost asset unit")
                    if multiAssets[policyId] == nil {
                        multiAssets[policyId] = Asset([:])
                    }
                    multiAssets[policyId]?[assetName] = try LedgerValues.bigInt(text: item.quantity, "Blockfrost asset quantity")
                }
            }

            let amount = Value(
                coin: BigInt(try LedgerValues.required(lovelaceAmount, "Blockfrost UTxO lovelace")),
                multiAsset: multiAssets
            )

            var datumHash: DatumHash? = nil
            var datumOption: DatumOption? = nil
            var script: ScriptType? = nil

            if result.dataHash != nil && result.inlineDatum == nil {
                datumHash = try LedgerValues.hash(hex: result.dataHash!, as: DatumHash.self, "Blockfrost DatumHash")
            }

            if let inlineDatum = result.inlineDatum {
                let datumData = try LedgerValues.hexBytes(inlineDatum, "Blockfrost inline datum")
                let plutusData = try PlutusData.fromCBOR(data: datumData)
                datumOption = DatumOption(datum: plutusData)
            }

            if let referenceScriptHash = result.referenceScriptHash {
                script = try await self.getScript(scriptHash: referenceScriptHash)
            }

            let address = try Address(from: .string(result.address))
            let txOut = TransactionOutput(
                address: address,
                amount: amount,
                datumHash: datumHash,
                datumOption: datumOption,
                script: script
            )

            return (UTxO(input: txIn, output: txOut), isSpent)
        } catch let error as CardanoChainError {
            throw error
        } catch {
            throw CardanoChainError.blockfrostError("Failed to get UTxO: \(error)")
        }
    }

    /// Submit a transaction to the blockchain.
    /// - Parameter cbor: The serialized transaction to be submitted.
    /// - Returns: The transaction hash.
    /// - Throws: `CardanoChainError.blockfrostError` if the transaction cannot be submitted.
    public func submitTxCBOR(cbor: Data) async throws -> String {
        let response = try await api.client.postTxSubmit(
            Operations.PostTxSubmit
                .Input(
                    body: Operations.PostTxSubmit.Input.Body
                        .applicationCbor(HTTPBody(cbor))
                )
        )

        do {
            let result = try response.ok.body.json
            return result
        } catch {
            throw CardanoChainError.transactionFailed("Failed to submit transaction: \(response)")
        }
    }

    /// Evaluate execution units of a transaction.
    /// - Parameter cbor: The serialized transaction to be evaluated.
    /// - Returns: A dictionary mapping redeemer strings to execution units.
    /// - Throws: `CardanoChainError.blockfrostError` if the evaluation fails.
    public func evaluateTxCBOR(cbor: Data) async throws -> [String: ExecutionUnits] {
        let result = try await api.client.postUtilsTxsEvaluate(
            Operations.PostUtilsTxsEvaluate.Input(
                body: Operations.PostUtilsTxsEvaluate.Input.Body
                    .applicationCbor(HTTPBody(cbor))
            )
        )

        var returnVal: [String: ExecutionUnits] = [:]

        do {
            let evaluationResult = try result.ok.body.json.additionalProperties.value

            if let evaluationResult = evaluationResult["EvaluationResult"]
                as? [String: [String: Int]]
            {
                for (key, value) in evaluationResult {
                    returnVal[key] = ExecutionUnits(
                        mem: try LedgerValues.required(value["memory"], "Blockfrost evaluation \(key) memory")
                            .checked("Blockfrost evaluation \(key) memory"),
                        steps: try LedgerValues.required(value["steps"], "Blockfrost evaluation \(key) steps")
                            .checked("Blockfrost evaluation \(key) steps")
                    )
                }
            }
        } catch let error as CardanoChainError {
            throw error
        } catch {
            throw CardanoChainError.blockfrostError("Failed to evaluate TxCBOR: \(result)")
        }
        return returnVal
    }

    /// Get the stake address information.
    /// - Parameter address: The stake address.
    /// - Returns: A list of `StakeAddressInfo` object.
    /// - Throws: `CardanoChainError.blockfrostError` if the stake address info cannot be fetched.
    public func stakeAddressInfo(address: Address) async throws -> [StakeAddressInfo] {
        let rewardsState = try await api.client.getAccountsStakeAddress(
            Operations.GetAccountsStakeAddress.Input(
                path: Operations.GetAccountsStakeAddress.Input
                    .Path(stakeAddress: address.toBech32())
            )
        )

        do {
            let stakeInfo = try rewardsState.ok.body.json
            return [
                StakeAddressInfo(
                    active: stakeInfo.active,
                    activeEpoch: try stakeInfo.activeEpoch.map { try $0.checked("Blockfrost active_epoch") },
                    address: stakeInfo.stakeAddress,
                    rewardAccountBalance: try LedgerValues.integer(
                        text: stakeInfo.withdrawableAmount, "Blockfrost withdrawable_amount"),
                    stakeDelegation: stakeInfo.poolId != nil
                        ? try PoolOperator(
                            from: stakeInfo.poolId!
                        ) : nil,
                    voteDelegation: stakeInfo.drepId != nil
                        ? try DRep(
                            from: stakeInfo.drepId!
                        ) : nil,
                )
            ]
        } catch {
            throw CardanoChainError.blockfrostError(
                "Failed to get getAccountsStakeAddressRewards: \(rewardsState)")
        }
    }

    /// Get the list of stake pools
    ///
    /// - Returns: List of stake pool IDs
    public func stakePools() async throws -> [PoolOperator] {
        // Fetch all stake pools (paginated)
        var allStakePools: [PoolOperator] = []
        var page = 1
        var hasMorePages = true

        while hasMorePages {
            let response = try await api.client.getPools(
                Operations.GetPools.Input(
                    query: Operations.GetPools.Input.Query(
                        count: 100,
                        page: page,
                        order: .asc
                    )
                )
            )

            do {
                let stakePools = try response.ok.body.json

                allStakePools.append(contentsOf: try stakePools.map {
                    try PoolOperator(from: $0)
                })

                if stakePools.isEmpty || stakePools.count < 100 {
                    hasMorePages = false
                } else {
                    page += 1
                }
            } catch {
                throw CardanoChainError.blockfrostError("Failed to get stake pools: \(response)")
            }
        }
        return allStakePools
    }

    /// Get the KES period information for a stake pool.
    ///
    /// Retrieves operational certificate counter information from the pool's most recently minted block.
    /// This is useful for stake pool operators to determine when to rotate their operational certificates.
    ///
    /// - Parameters:
    ///   - pool: The pool operator identifier. **Required** for Blockfrost backend.
    ///   - opCert: The local operational certificate file. If provided, includes on-disk certificate details.
    /// - Returns: A `KESPeriodInfo` containing certificate counter information.
    /// - Throws: `CardanoChainError.invalidArgument` if pool is not provided.
    /// - Throws: `CardanoChainError.blockfrostError` if the pool has never minted a block or API call fails.
    ///
    /// ## Example
    /// ```swift
    /// let pool = try PoolOperator(from: "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy")
    /// let kesInfo = try await chainContext.kesPeriodInfo(pool: pool, opCert: nil)
    /// print("On-chain cert counter: \(kesInfo.onChainOpCertCount ?? -1)")
    /// ```
    public func kesPeriodInfo(pool: PoolOperator?, opCert: OperationalCertificate? = nil)
        async throws -> KESPeriodInfo
    {
        guard let pool = pool else {
            throw CardanoChainError.invalidArgument("Pool operator must be provided")
        }

        let latestMintedBlockResponse = try await api.client.getPoolsPoolIdBlocks(
            Operations.GetPoolsPoolIdBlocks.Input(
                path: Operations.GetPoolsPoolIdBlocks.Input.Path(poolId: pool.id(.bech32)),
                query: Operations.GetPoolsPoolIdBlocks.Input.Query(
                    count: 1,
                    order: .desc
                )
            )
        )

        let latestMintedBlock = try latestMintedBlockResponse.ok.body.json[0]

        let blockInfoResponse = try await api.client.getBlocksHashOrNumber(
            Operations.GetBlocksHashOrNumber.Input(
                path: Operations.GetBlocksHashOrNumber.Input.Path(
                    hashOrNumber: latestMintedBlock
                )
            )
        )

        let blockInfo = try blockInfoResponse.ok.body.json

        guard let opCertCounter = blockInfo.opCertCounter else {
            throw CardanoChainError.blockfrostError(
                "Failed to get opCertCounter from block info: \(blockInfo)")
        }

        let onChainOpCertCount: Int = try LedgerValues.integer(text: opCertCounter, "Blockfrost op_cert_counter")
        let nextChainOpCertCount = onChainOpCertCount + 1

        if let opCert = opCert {
            let onDiskOpCertCount: Int = try opCert.sequenceNumber.checked("operational certificate sequence number")
            let onDiskKESStart: Int = try opCert.kesPeriod.checked("operational certificate KES period")

            return KESPeriodInfo(
                onChainOpCertCount: onChainOpCertCount,
                onDiskOpCertCount: onDiskOpCertCount,
                nextChainOpCertCount: nextChainOpCertCount,
                onDiskKESStart: onDiskKESStart
            )
        }

        return KESPeriodInfo(
            onChainOpCertCount: onChainOpCertCount,
            nextChainOpCertCount: nextChainOpCertCount,
        )
    }

    /// Get the stake pool information.
    /// - Parameter poolId: The pool ID (Bech32).
    /// - Returns: `StakePoolInfo` object.
    /// - Throws: `CardanoChainError.blockfrostError` if the pool info cannot be fetched.
    public func stakePoolInfo(poolId: String) async throws -> StakePoolInfo {
        // 1. Get basic pool info
        let poolResponse = try await api.client.getPoolsPoolId(
            Operations.GetPoolsPoolId.Input(
                path: Operations.GetPoolsPoolId.Input.Path(poolId: poolId)
            )
        )
        let pool = try poolResponse.ok.body.json

        // 2. Get pool relays
        let relaysResponse = try await api.client.getPoolsPoolIdRelays(
            Operations.GetPoolsPoolIdRelays.Input(
                path: Operations.GetPoolsPoolIdRelays.Input.Path(poolId: poolId)
            )
        )
        let relaysData = try relaysResponse.ok.body.json

        // 3. Get pool metadata
        var poolMetadata: PoolMetadata? = nil

        // A separate call: when it fails (a pool with no metadata is a 404),
        // the pool simply has none. A URL or hash it does return must be valid.
        if case .ok(let metadataOK)? = try? await api.client.getPoolsPoolIdMetadata(
            Operations.GetPoolsPoolIdMetadata.Input(
                path: Operations.GetPoolsPoolIdMetadata.Input.Path(poolId: poolId)
            )
        ) {
            let metadata = try metadataOK.body.json
            let urlString = metadata.value1?.url
            let hashString = metadata.value1?.hash
            if urlString != nil || hashString != nil {
                let url = try LedgerValues.url(
                    LedgerValues.required(urlString, "Blockfrost pool metadata URL"), "Blockfrost pool metadata URL")
                let hash = PoolMetadataHash(payload: try LedgerValues.hash32(
                    hex: LedgerValues.required(hashString, "Blockfrost pool metadata hash"),
                    "Blockfrost pool metadata hash"))
                do {
                    poolMetadata = try await PoolMetadata.fetch(
                        url: url,
                        poolMetadataHash: hash
                    )
                } catch {
                    poolMetadata = try PoolMetadata(
                        url: url,
                        poolMetadataHash: hash
                    )
                }
            }
        }

        // 4. Get latest block minted by pool for opcert counter
        var opcertCounter: UInt? = nil
        var opcertCounterText: String? = nil
        do {
            let latestBlockResponse = try await api.client.getPoolsPoolIdBlocks(
                Operations.GetPoolsPoolIdBlocks.Input(
                    path: Operations.GetPoolsPoolIdBlocks.Input.Path(poolId: poolId),
                    query: Operations.GetPoolsPoolIdBlocks.Input.Query(
                        count: 1,
                        order: .desc
                    )
                )
            )
            let blocks = try latestBlockResponse.ok.body.json
            if let latestBlock = blocks.first {
                let blockInfoResponse = try await api.client.getBlocksHashOrNumber(
                    Operations.GetBlocksHashOrNumber.Input(
                        path: Operations.GetBlocksHashOrNumber.Input.Path(
                            hashOrNumber: latestBlock
                        )
                    )
                )
                let blockInfo = try blockInfoResponse.ok.body.json
                opcertCounterText = blockInfo.opCertCounter
            }
        } catch {
            // Pool may not have minted any blocks yet
        }
        // A counter that is there but does not parse is an error, not "no counter".
        if let opcertCounterText {
            opcertCounter = try LedgerValues.integer(text: opcertCounterText, "Blockfrost op_cert_counter")
        }

        // Map relays
        let relays: [SwiftCardanoCore.Relay] = try relaysData.map { relay in
            try LedgerValues.relay(
                port: relay.port, ipv4: relay.ipv4, ipv6: relay.ipv6,
                dnsName: relay.dns, srvName: relay.dnsSrv, "Blockfrost pool relay")
        }

        // Blockfrost's client reads the margin as a Double; its shortest
        // description is the decimal Blockfrost sent, read here exactly.
        let margin = try LedgerValues.unitInterval(pool.marginCost, "Blockfrost pool margin_cost")

        let poolOperator = try PoolOperator(from: poolId)
        let vrfKeyHash = try LedgerValues.hash(hex: pool.vrfKey, as: VrfKeyHash.self, "Blockfrost VrfKeyHash")
        let rewardAccount = try Address(from: .string(pool.rewardAccount))
        let rewardAccountHash = RewardAccountHash(payload: rewardAccount.toBytes())
        let poolOwnersList: [VerificationKeyHash] = try pool.owners.map { ownerBech32 in
            let ownerAddr = try Address(from: .string(ownerBech32))
            switch ownerAddr.stakingPart {
            case .verificationKeyHash(let vkh):
                return VerificationKeyHash(payload: vkh.payload)
            default:
                switch ownerAddr.paymentPart {
                case .verificationKeyHash(let vkh):
                    return VerificationKeyHash(payload: vkh.payload)
                case .scriptHash(let sh):
                    return VerificationKeyHash(payload: sh.payload)
                case nil:
                    return VerificationKeyHash(payload: Data())
                }
            }
        }
        let poolOwners = ListOrOrderedSet<VerificationKeyHash>.list(poolOwnersList)

        let params = PoolParams(
            poolOperator: poolOperator.poolKeyHash,
            vrfKeyHash: vrfKeyHash,
            pledge: try LedgerValues.integer(text: pool.declaredPledge, "Blockfrost pool declared_pledge"),
            cost: try LedgerValues.integer(text: pool.fixedCost, "Blockfrost pool fixed_cost"),
            margin: margin,
            rewardAccount: rewardAccountHash,
            poolOwners: poolOwners,
            relays: relays,
            poolMetadata: poolMetadata
        )

        let livePledge: UInt? = try LedgerValues.integer(text: pool.livePledge, "Blockfrost pool live_pledge")
        let liveStake: UInt? = try LedgerValues.integer(text: pool.liveStake, "Blockfrost pool live_stake")
        let activeStake: UInt? = try LedgerValues.integer(text: pool.activeStake, "Blockfrost pool active_stake")
        let activeSize: Decimal? = Decimal(pool.activeSize)

        // 5. Determine pool status from retirement field
        var status: PoolStatus? = nil
        if pool.retirement.isEmpty {
            status = .registered
        } else if let lastRetirementTxHash = pool.retirement.last {
            // Fetch the retirement certificate to get the retiring epoch
            do {
                let retireResponse = try await api.client.getTxsHashPoolRetires(
                    Operations.GetTxsHashPoolRetires.Input(
                        path: .init(hash: lastRetirementTxHash)
                    )
                )
                let retireInfo = try retireResponse.ok.body.json
                if let retire = retireInfo.first(where: { $0.poolId == poolId }) {
                    let retiringEpoch = retire.retiringEpoch
                    let currentEpoch = try await self.epoch()
                    if currentEpoch >= retiringEpoch {
                        status = .retired
                    } else {
                        status = .retiring(epoch: try retiringEpoch.checked("Blockfrost retiring_epoch"))
                    }
                }
            } catch let error as CardanoChainError {
                throw error
            } catch {
                // The retirement could not be fetched, so the status is not
                // known: leave it nil rather than invent a retiring epoch of 0.
                status = nil
            }
        }

        return StakePoolInfo(
            poolParams: params,
            livePledge: livePledge,
            liveStake: liveStake,
            activeStake: activeStake,
            activeSize: activeSize,
            opcertCounter: opcertCounter,
            status: status
        )
    }
    
    /// Get the treasury balance.
    /// - Returns: The current balance of the treasury as a `Coin` object.
    /// - Throws: An error if the treasury balance cannot be retrieved.
    public func treasury() async throws -> Coin {
        let networkResponse = try await api.client.getNetwork(
            Operations.GetNetwork.Input()
        )
        let networkData = try networkResponse.ok.body.json

        return try LedgerValues.integer(text: networkData.supply.treasury, "Blockfrost treasury")
    }

    /// Get the DRep information.
    /// - Parameter drep: The `DRep` object.
    /// - Returns: The `DRepInfo` object containing information about the DRep.
    public func drepInfo(drep: DRep) async throws -> DRepInfo {
        let drepId = try drep.id((.bech32, .cip129))
        let response = try await api.client.getGovernanceDrepsDrepId(
            .init(path: .init(drepId: drepId))
        )
        let drepData = try response.ok.body.json
        
        guard let stakeInt = UInt64(drepData.amount) else {
            throw CardanoChainError.valueError("Failed to parse DRep stake amount")
        }
        
        // A separate call: when it fails (a DRep with no anchor is a 404), the
        // DRep has no anchor. An anchor it does return must be valid.
        var anchor: Anchor? = nil
        if case .ok(let metadataOK)? = try? await api.client.getGovernanceDrepsDrepIdMetadata(
            .init(path: .init(drepId: drepId))
        ) {
            let metaData = try metadataOK.body.json
            anchor = try LedgerValues.optionalAnchor(
                url: metaData.url, hash: metaData.hash, "Blockfrost DRep anchor")
        }
        
        let status: DRepStatus = drepData.retired ? .retired : .registered
        let active = !drepData.retired && !drepData.expired
        
        return DRepInfo(
            active: active,
            drep: drep,
            anchor: anchor,
            stake: Coin(stakeInt),
            status: status
        )
    }
    
    /// Get the governance action information for a given governance action ID.
    /// - Parameter govActionID: The identifier of the governance action.
    /// - Returns: The `GovActionInfo` object containing information about the governance action.
    public func govActionInfo(govActionID: GovActionID) async throws -> GovActionInfo {
        let response = try await api.client.getGovernanceProposalsTxHashCertIndex(
            .init(
                path: .init(
                    txHash: govActionID.transactionID.payload.toHex,
                    certIndex: Int(govActionID.govActionIndex)
                )
            )
        )
        let govActionData = try response.ok.body.json
        
        var govAction: GovAction = .infoAction(.init())
        
        switch govActionData.governanceType {
        case .infoAction:
            govAction = .infoAction(.init())
        case .hardForkInitiation:
            let paramsResponse = try await api.client.getGovernanceProposalsTxHashCertIndexParameters(
                .init(path: .init(
                    txHash: govActionID.transactionID.payload.toHex,
                    certIndex: Int(govActionID.govActionIndex)
                ))
            )
            let params = try paramsResponse.ok.body.json.parameters
            govAction = .hardForkInitiationAction(.init(
                id: nil,
                protocolVersion: ProtocolVersion(
                    major: try LedgerValues.required(params.protocolMajorVer, "Blockfrost protocol_major_ver"),
                    minor: try LedgerValues.required(params.protocolMinorVer, "Blockfrost protocol_minor_ver")
                )
            ))
        case .parameterChange:
            let paramsResponse = try await api.client.getGovernanceProposalsTxHashCertIndexParameters(
                .init(path: .init(
                    txHash: govActionID.transactionID.payload.toHex,
                    certIndex: Int(govActionID.govActionIndex)
                ))
            )
            let params = try paramsResponse.ok.body.json.parameters
            
            // Construct ProtocolParamUpdate from Blockfrost params. Blockfrost's
            // client reads each ratio as a Double; its shortest description is
            // the decimal Blockfrost sent, read here exactly.
            func int<T: FixedWidthInteger>(_ value: Int?, _ field: String) throws -> T? {
                try value.map { try LedgerValues.integer($0, as: T.self, "Blockfrost proposal \(field)") }
            }
            func int<T: FixedWidthInteger>(_ text: String?, _ field: String) throws -> T? {
                try text.map { try LedgerValues.integer(text: $0, as: T.self, "Blockfrost proposal \(field)") }
            }
            func unit(_ value: Double?, _ field: String) throws -> UnitInterval? {
                try value.map { try LedgerValues.unitInterval($0, "Blockfrost proposal \(field)") }
            }
            func nonNegative(_ value: Double?, _ field: String) throws -> NonNegativeInterval? {
                try value.map { try LedgerValues.nonNegativeInterval($0, "Blockfrost proposal \(field)") }
            }
            func exUnits(_ mem: String?, _ steps: String?, _ field: String) throws -> ExUnits? {
                guard let mem: UInt64 = try int(mem, "\(field)_mem"),
                      let steps: UInt64 = try int(steps, "\(field)_steps") else { return nil }
                return ExUnits(mem: mem, steps: steps)
            }
            // Blockfrost sends extra_entropy as the nonce's hash in hex, or null
            // for the neutral nonce.
            let extraEntropy = try params.extraEntropy.map { hex -> Nonce in
                try Nonce(hash: LedgerValues.hexBytes(hex, "Blockfrost proposal extra_entropy"))
            }
            let executionCosts: ExUnitPrices?
            if let memPrice = try nonNegative(params.priceMem, "price_mem"),
               let stepPrice = try nonNegative(params.priceStep, "price_step") {
                executionCosts = ExUnitPrices(memPrice: memPrice, stepPrice: stepPrice)
            } else {
                executionCosts = nil
            }

            let update = ProtocolParamUpdate(
                minFeeA: try int(params.minFeeA, "min_fee_a"),
                minFeeB: try int(params.minFeeB, "min_fee_b"),
                maxBlockBodySize: try int(params.maxBlockSize, "max_block_size"),
                maxTransactionSize: try int(params.maxTxSize, "max_tx_size"),
                maxBlockHeaderSize: try int(params.maxBlockHeaderSize, "max_block_header_size"),
                keyDeposit: try int(params.keyDeposit, "key_deposit"),
                poolDeposit: try int(params.poolDeposit, "pool_deposit"),
                maximumEpoch: try int(params.eMax, "e_max"),
                nOpt: try int(params.nOpt, "n_opt"),
                poolPledgeInfluence: try nonNegative(params.a0, "a0"),
                expansionRate: try unit(params.rho, "rho"),
                treasuryGrowthRate: try unit(params.tau, "tau"),
                decentralizationConstant: try unit(params.decentralisationParam, "decentralisation_param"),
                extraEntropy: extraEntropy,
                protocolVersion: (params.protocolMajorVer != nil && params.protocolMinorVer != nil) ? ProtocolVersion(major: params.protocolMajorVer!, minor: params.protocolMinorVer!) : nil,
                minPoolCost: try int(params.minPoolCost, "min_pool_cost"),
                adaPerUtxoByte: try int(params.coinsPerUtxoSize, "coins_per_utxo_size"),
                costModels: nil, // Mapping cost models is complex due to different versions
                executionCosts: executionCosts,
                maxTxExUnits: try exUnits(params.maxTxExMem, params.maxTxExSteps, "max_tx_ex"),
                maxBlockExUnits: try exUnits(params.maxBlockExMem, params.maxBlockExSteps, "max_block_ex"),
                maxValueSize: try int(params.maxValSize, "max_val_size"),
                collateralPercentage: try int(params.collateralPercent, "collateral_percent"),
                maxCollateralInputs: try int(params.maxCollateralInputs, "max_collateral_inputs")
            )
            govAction = .parameterChangeAction(ParameterChangeAction(id: govActionID, protocolParamUpdate: update, policyHash: nil))
        case .noConfidence:
            govAction = .noConfidence(.init(id: govActionID)) // Using same ID as placeholder
        case .newCommittee:
            // Blockfrost's `/governance/proposals/{tx_hash}/{cert_index}`
            // payload does not expose the proposed cold-credential add/remove
            // sets or the new quorum threshold (only `governance_description`
            // as an untyped opaque container). Surface the variant tag
            // correctly, but use an honest "unknown" interval (0/1) and
            // empty credential collections rather than a plausible-looking
            // fake. Switch to Koios, Ogmios, or cardano-cli for the real
            // proposed values.
            govAction = .updateCommittee(.init(
                id: govActionID,
                coldCredentials: [],
                credentialEpochs: [:],
                interval: UnitInterval(numerator: 0, denominator: 1)
            ))
        case .newConstitution:
            // The constitution's anchor is in `governance_description`, the
            // action as db-sync records it:
            // `{"tag": "NewConstitution", "contents": [prevId, {"anchor": {url, dataHash}, "script": …}]}`.
            // (The proposal's metadata endpoint is the proposal's own anchor,
            // not the constitution's.)
            let description = govActionData.governanceDescription?.additionalProperties.value
            let contents = description?["contents"] as? [Any] ?? []
            let constitution = contents.last as? [String: Any]
            let anchor = try LedgerValues.required(
                LedgerValues.anchor(json: constitution?["anchor"], "Blockfrost constitution anchor"),
                "Blockfrost constitution anchor")
            let scriptHash: ScriptHash? = try {
                guard let script = constitution?["script"], !(script is NSNull) else { return nil }
                guard let hex = script as? String else {
                    throw CardanoChainError.valueError("Blockfrost constitution script \(script) is not a hash")
                }
                return try LedgerValues.hash(hex: hex, as: ScriptHash.self, "Blockfrost ScriptHash")
            }()
            govAction = .newConstitution(.init(
                id: govActionID, constitution: .init(anchor: anchor, scriptHash: scriptHash)))
        case .treasuryWithdrawals:
            let withdrawalsResponse = try await api.client.getGovernanceProposalsTxHashCertIndexWithdrawals(
                .init(path: .init(
                    txHash: govActionID.transactionID.payload.toHex,
                    certIndex: Int(govActionID.govActionIndex)
                ))
            )
            let withdrawalsData = try withdrawalsResponse.ok.body.json
            var withdrawals: [RewardAccount: Coin] = [:]
            for item in withdrawalsData {
                // Blockfrost names the account by its bech32 stake address.
                let account = try Address.fromBech32(item.stakeAddress).toBytes()
                withdrawals[account] = try LedgerValues.integer(
                    text: item.amount, "Blockfrost proposal withdrawal amount")
            }
            govAction = .treasuryWithdrawalsAction(.init(withdrawals: withdrawals, policyHash: nil))
        @unknown default:
            govAction = .infoAction(.init())
        }
        
        return GovActionInfo(
            govActionId: govActionID,
            govAction: govAction,
            proposedIn: nil,
            expiresAfter: try govActionData.expiration.checked("Blockfrost proposal expiration"),
            ratifiedEpoch: try govActionData.ratifiedEpoch.map { try $0.checked("Blockfrost proposal ratified_epoch") },
            enactedEpoch: try govActionData.enactedEpoch.map { try $0.checked("Blockfrost proposal enacted_epoch") },
            droppedEpoch: try govActionData.droppedEpoch.map { try $0.checked("Blockfrost proposal dropped_epoch") },
            expiredEpoch: try govActionData.expiredEpoch.map { try $0.checked("Blockfrost proposal expired_epoch") }
        )
    }
    
    /// Get the committee member information for a given committee member credential.
    /// - Parameter cold: The `CommitteeColdCredential` object representing the committee member.
    /// - Returns: The `CommitteeMemberInfo` object containing information about the committee member.
    public func committeeMemberInfo(cold: CommitteeColdCredential) async throws -> CommitteeMemberInfo {
        let coldHex = cold.credential.payload.toHex.lowercased()
        let coldIsScript: Bool
        switch cold.credential {
        case .scriptHash:          coldIsScript = true
        case .verificationKeyHash: coldIsScript = false
        }

        let members = try await fetchGovernanceCommitteeMembers()
        guard let member = members.first(where: {
            $0.ccColdHex.lowercased() == coldHex && $0.ccColdHasScript == coldIsScript
        }) else {
            throw CardanoChainError.valueError(
                "Committee member not found for credential: \(cold)"
            )
        }

        return try await buildCommitteeMemberInfo(
            from: member,
            preferredCold: cold,
            preferredHot: nil
        )
    }

    /// Get the committee member information identified by an authorized hot credential.
    /// - Parameter hot: The `CommitteeHotCredential` the member has authorized.
    /// - Returns: The `CommitteeMemberInfo` object containing information about the committee member.
    public func committeeMemberInfo(hot: CommitteeHotCredential) async throws -> CommitteeMemberInfo {
        let hotHex = hot.credential.payload.toHex.lowercased()
        let hotIsScript: Bool
        switch hot.credential {
        case .scriptHash:          hotIsScript = true
        case .verificationKeyHash: hotIsScript = false
        }

        let members = try await fetchGovernanceCommitteeMembers()
        guard let member = members.first(where: {
            $0.ccHotHex?.lowercased() == hotHex
                && ($0.ccHotHasScript ?? false) == hotIsScript
        }) else {
            throw CardanoChainError.valueError(
                "Committee member not found for hot credential: \(hot)"
            )
        }

        return try await buildCommitteeMemberInfo(
            from: member,
            preferredCold: nil,
            preferredHot: hot
        )
    }

    // MARK: - Internal helpers

    private typealias GeneratedCommitteeMember =
        Components.Schemas.Committee.MembersPayloadPayload

    /// Fetch all committee members via the generated `/governance/committee` operation.
    private func fetchGovernanceCommitteeMembers() async throws -> [GeneratedCommitteeMember] {
        do {
            let response = try await api.client.getGovernanceCommittee()
            return try response.ok.body.json.members
        } catch let error as CardanoChainError {
            throw error
        } catch {
            throw CardanoChainError.blockfrostError(
                "Failed to fetch committee state: \(error)"
            )
        }
    }

    /// Build a `CommitteeMemberInfo` from a generated committee-member row.
    ///
    /// `preferredCold` / `preferredHot` let the caller pass through the original credential
    /// (preserves byte-for-byte identity) when the lookup originated from one side; either
    /// can be `nil` and we'll reconstruct from the row's hex fields.
    private func buildCommitteeMemberInfo(
        from member: GeneratedCommitteeMember,
        preferredCold: CommitteeColdCredential?,
        preferredHot: CommitteeHotCredential?
    ) async throws -> CommitteeMemberInfo {
        let coldCredential: CommitteeColdCredential
        if let preferredCold = preferredCold {
            coldCredential = preferredCold
        } else if member.ccColdHasScript {
            coldCredential = CommitteeColdCredential(
                credential: .scriptHash(
                    try LedgerValues.hash(hex: member.ccColdHex, as: ScriptHash.self, "Blockfrost ScriptHash"))
            )
        } else {
            coldCredential = CommitteeColdCredential(
                credential: .verificationKeyHash(
                    try LedgerValues.hash(hex: member.ccColdHex, as: VerificationKeyHash.self, "Blockfrost VerificationKeyHash"))
            )
        }

        let hotCredential: CommitteeHotCredential?
        if let preferredHot = preferredHot {
            hotCredential = preferredHot
        } else if let hotHex = member.ccHotHex {
            if member.ccHotHasScript ?? false {
                hotCredential = CommitteeHotCredential(
                    credential: .scriptHash(try LedgerValues.hash(hex: hotHex, as: ScriptHash.self, "Blockfrost ScriptHash"))
                )
            } else {
                hotCredential = CommitteeHotCredential(
                    credential: .verificationKeyHash(
                        try LedgerValues.hash(hex: hotHex, as: VerificationKeyHash.self, "Blockfrost VerificationKeyHash"))
                )
            }
        } else {
            hotCredential = nil
        }

        let currentEpoch = try await epoch()
        let status: CommitteeMemberStatus
        switch member.status {
        case .authorized:
            status = member.expirationEpoch >= currentEpoch ? .active : .expired
        case .notAuthorized, .resigned:
            status = .expired
        }

        return CommitteeMemberInfo(
            coldCredential: coldCredential,
            hotCredential: hotCredential,
            expiration: try member.expirationEpoch.checked("Blockfrost committee member expiration_epoch"),
            status: status
        )
    }

    // MARK: - Votes / Governance State

    public func govActionVotes(govActionID: GovActionID) async throws -> GovActionVotes {
        let info = try await self.govActionInfo(govActionID: govActionID)

        // Pull deposit + return-address from the proposal record itself. The proposal
        // endpoint already runs inside govActionInfo above; we re-query rather than
        // refactor it to return the raw payload, accepting one extra HTTP call to keep
        // the existing govActionInfo signature untouched.
        let proposalResponse = try await api.client.getGovernanceProposalsTxHashCertIndex(
            .init(path: .init(
                txHash: govActionID.transactionID.payload.toHex,
                certIndex: Int(govActionID.govActionIndex)
            ))
        )
        let proposal = try proposalResponse.ok.body.json

        let deposit: Coin = try LedgerValues.integer(text: proposal.deposit, "Blockfrost proposal deposit")
        let returnAddrData = try Address.fromBech32(proposal.returnAddress).toBytes()

        // Anchor metadata via a separate endpoint, which answers 404 until
        // Blockfrost has indexed the off-chain document; when the call fails the
        // anchor is left out. An anchor it does return must be valid.
        var anchor: SwiftCardanoCore.Anchor? = nil
        if case .ok(let metadataOK)? = try? await api.client.getGovernanceProposalsTxHashCertIndexMetadata(
            .init(path: .init(
                txHash: govActionID.transactionID.payload.toHex,
                certIndex: Int(govActionID.govActionIndex)
            ))
        ) {
            let meta = try metadataOK.body.json
            anchor = try LedgerValues.optionalAnchor(url: meta.url, hash: meta.hash, "Blockfrost proposal anchor")
        }

        let votesResponse = try await api.client.getGovernanceProposalsTxHashCertIndexVotes(
            .init(path: .init(
                txHash: govActionID.transactionID.payload.toHex,
                certIndex: Int(govActionID.govActionIndex)
            ))
        )
        let voteRows = try votesResponse.ok.body.json

        var committeeVotes: [SwiftCardanoNetwork.CommitteeVote] = []
        var dRepVotes: [SwiftCardanoNetwork.DRepVote] = []
        var stakePoolVotes: [SwiftCardanoNetwork.StakePoolVote] = []

        for row in voteRows {
            let vote: Vote
            switch row.vote {
            case .yes: vote = .yes
            case .no: vote = .no
            case .abstain: vote = .abstain
            }

            switch row.voterRole {
            case .constitutionalCommittee:
                if let cred = try? CommitteeHotCredential(from: row.voter) {
                    committeeVotes.append(.init(credential: cred, vote: vote))
                }
            case .drep:
                if let drep = try? DRep(from: row.voter) {
                    let cred: DRepCredential
                    switch drep.credential {
                    case .verificationKeyHash(let h):
                        cred = DRepCredential(credential: .verificationKeyHash(h))
                    case .scriptHash(let h):
                        cred = DRepCredential(credential: .scriptHash(h))
                    case .alwaysAbstain, .alwaysNoConfidence:
                        continue
                    }
                    dRepVotes.append(.init(credential: cred, vote: vote))
                }
            case .spo:
                stakePoolVotes.append(.init(poolOperator: try PoolOperator(from: .string(row.voter)), vote: vote))
            }
        }

        return GovActionVotes(
            govActionId: govActionID,
            govAction: info.govAction,
            committeeVotes: committeeVotes,
            dRepVotes: dRepVotes,
            stakePoolVotes: stakePoolVotes,
            deposit: deposit,
            depositReturnAddr: returnAddrData,
            anchor: anchor,
            proposedIn: info.proposedIn,
            expiresAfter: info.expiresAfter,
            ratifiedEpoch: info.ratifiedEpoch,
            enactedEpoch: info.enactedEpoch,
            droppedEpoch: info.droppedEpoch,
            expiredEpoch: info.expiredEpoch
        )
    }

    public func govActionsAll() async throws -> [GovActionVotes] {
        let response = try await api.client.getGovernanceProposals()
        let proposals = try response.ok.body.json

        var results: [GovActionVotes] = []
        for proposal in proposals {
            let govActionID = GovActionID(
                transactionID: try LedgerValues.hash(hex: proposal.txHash, as: TransactionId.self, "Blockfrost TransactionId"),
                govActionIndex: try proposal.certIndex.checked("Blockfrost proposal cert_index")
            )
            if let votes = try? await govActionVotes(govActionID: govActionID) {
                results.append(votes)
            }
        }
        return results
    }

    /// Lists the open governance actions without their votes.
    ///
    /// Blockfrost's proposal list carries no status, so each proposal's
    /// detail is fetched to tell whether it is open. The list is read newest
    /// first and the scan stops at the first proposal past its expiry: every
    /// older one has expired too, since an action's expiry is the epoch it
    /// was proposed in plus the governance action lifetime. That costs one
    /// request per open action, plus the list and the epoch, instead of
    /// three per proposal ever made.
    public func openGovActions() async throws -> [OpenGovAction] {
        let epoch = try LedgerValues.integer(try await self.epoch(), as: UInt64.self, "current epoch")
        let pageSize = 100
        var open: [OpenGovAction] = []
        var page = 1
        scan: while true {
            let response = try await api.client.getGovernanceProposals(
                Operations.GetGovernanceProposals.Input(query: .init(count: pageSize, page: page, order: .desc))
            )
            let proposals = try response.ok.body.json
            // A few at a time: enough to be quick, few enough for the rate limit.
            for start in stride(from: 0, to: proposals.count, by: 5) {
                let batch = Array(proposals[start..<min(start + 5, proposals.count)])
                let details = try await withThrowingTaskGroup(of: (Int, Components.Schemas.Proposal).self) { group in
                    for (position, proposal) in batch.enumerated() {
                        group.addTask {
                            let detail = try await self.api.client.getGovernanceProposalsTxHashCertIndex(
                                .init(path: .init(txHash: proposal.txHash, certIndex: proposal.certIndex))
                            )
                            return (position, try detail.ok.body.json)
                        }
                    }
                    var found: [(Int, Components.Schemas.Proposal)] = []
                    for try await result in group { found.append(result) }
                    return found.sorted { $0.0 < $1.0 }.map(\.1)
                }
                for detail in details {
                    let expiresAfter: UInt64 = try detail.expiration.checked("Blockfrost proposal expiration")
                    guard OpenGovAction.isOpen(expiresAfter: expiresAfter, in: epoch) else { break scan }
                    let concluded = detail.ratifiedEpoch != nil || detail.enactedEpoch != nil
                        || detail.droppedEpoch != nil || detail.expiredEpoch != nil
                    guard !concluded else { continue }
                    open.append(OpenGovAction(
                        govActionId: GovActionID(
                            transactionID: try LedgerValues.hash(hex: detail.txHash, as: TransactionId.self, "Blockfrost TransactionId"),
                            govActionIndex: try detail.certIndex.checked("Blockfrost proposal cert_index")
                        ),
                        type: Self.govActionCode(detail.governanceType),
                        deposit: try LedgerValues.integer(text: detail.deposit, "Blockfrost proposal deposit"),
                        expiresAfter: expiresAfter
                    ))
                }
            }
            guard proposals.count == pageSize else { break }
            page += 1
        }
        return open
    }

    private static func govActionCode(_ type: Components.Schemas.Proposal.GovernanceTypePayload) -> GovActionCode {
        switch type {
        case .parameterChange: .parameterChangeAction
        case .hardForkInitiation: .hardForkInitiationAction
        case .treasuryWithdrawals: .treasuryWithdrawalsAction
        case .noConfidence: .noConfidence
        case .newCommittee: .updateCommittee
        case .newConstitution: .newConstitution
        case .infoAction: .infoAction
        @unknown default: .infoAction
        }
    }

    public func committeeState() async throws -> CommitteeStateInfo {
        let response = try await api.client.getGovernanceCommittee()
        let committee = try response.ok.body.json

        let currentEpoch = try await epoch()

        let members: [CommitteeStateInfo.Member] = try committee.members.map { m in
            let cold: CommitteeColdCredential = m.ccColdHasScript
                ? CommitteeColdCredential(credential: .scriptHash(try LedgerValues.hash(hex: m.ccColdHex, as: ScriptHash.self, "Blockfrost ScriptHash")))
                : CommitteeColdCredential(credential: .verificationKeyHash(try LedgerValues.hash(hex: m.ccColdHex, as: VerificationKeyHash.self, "Blockfrost VerificationKeyHash")))

            let hot: CommitteeHotCredential? = try {
                guard let hotHex = m.ccHotHex else { return nil }
                let isScript = m.ccHotHasScript ?? false
                return isScript
                    ? CommitteeHotCredential(credential: .scriptHash(try LedgerValues.hash(hex: hotHex, as: ScriptHash.self, "Blockfrost ScriptHash")))
                    : CommitteeHotCredential(credential: .verificationKeyHash(try LedgerValues.hash(hex: hotHex, as: VerificationKeyHash.self, "Blockfrost VerificationKeyHash")))
            }()

            let status: CommitteeMemberStatus = {
                switch m.status {
                case .authorized:
                    return m.expirationEpoch >= currentEpoch ? .active : .expired
                case .notAuthorized, .resigned:
                    return .expired
                }
            }()

            return CommitteeStateInfo.Member(
                coldCredential: cold,
                hotCredential: hot,
                expiration: try m.expirationEpoch.checked("Blockfrost committee member expiration_epoch"),
                status: status
            )
        }

        let threshold = try LedgerValues.unitInterval(
            text: "\(committee.quorum.numerator)/\(committee.quorum.denominator)", "Blockfrost committee quorum")

        return CommitteeStateInfo(members: members, threshold: threshold)
    }
}

// MARK: - Transactions by hash

extension BlockFrostChainContext {
    /// The bytes of a transaction on chain, from `/txs/{hash}/cbor`.
    public func transactionCBOR(hash: TransactionId) async throws -> Data {
        let response = try await api.client.getTxsHashCbor(
            Operations.GetTxsHashCbor.Input(path: .init(hash: hash.payload.toHex))
        )
        guard case .ok(let ok) = response else {
            throw CardanoChainError.blockfrostError("Transaction \(hash) not found: \(response)")
        }
        let cbor = try ok.body.json.cbor
        return try LedgerValues.hexBytes(cbor, "Blockfrost transaction \(hash) CBOR")
    }
}
