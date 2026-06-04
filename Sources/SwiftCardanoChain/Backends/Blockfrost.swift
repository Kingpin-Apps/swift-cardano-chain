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
        Era.fromEpoch(epoch: EpochNumber(try await epoch()))
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
            return try response.ok.body.json.slot!
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
            return GenesisParameters(
                activeSlotsCoefficient: genesis.activeSlotsCoefficient,
                epochLength: genesis.epochLength,
                maxKesEvolutions: genesis.maxKesEvolutions,
                maxLovelaceSupply: Int(genesis.maxLovelaceSupply)!,
                networkId: _network.description,
                networkMagic: genesis.networkMagic,
                securityParam: genesis.securityParam,
                slotLength: genesis.slotLength,
                slotsPerKesPeriod: genesis.slotsPerKesPeriod,
                systemStart: Date(timeIntervalSince1970: TimeInterval(genesis.systemStart)),
                updateQuorum: genesis.updateQuorum
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
                block: json.height.map { BlockNumber($0) },
                epoch: json.epoch.map { EpochNumber($0) },
                era: nil,
                hash: json.hash,
                slot: json.slot.map { SlotNumber($0) },
                slotInEpoch: json.epochSlot.map { SlotNumber($0) },
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

            let costModels = protocolParams.costModels.unsafelyUnwrapped.additionalProperties.value

            return ProtocolParameters(
                collateralPercentage: Int64(protocolParams.collateralPercent!),
                committeeMaxTermLength: Int64(protocolParams.committeeMaxTermLength!)!,
                committeeMinSize: Int64(protocolParams.committeeMinSize!)!,
                costModels: ProtocolParametersCostModels(
                    PlutusV1: (costModels["PlutusV1"] as! [String: Int])
                        .sorted { $0.key < $1.key }.map { Int64($0.value) },
                    PlutusV2: (costModels["PlutusV2"] as! [String: Int])
                        .sorted { $0.key < $1.key }.map { Int64($0.value) },
                    PlutusV3: (costModels["PlutusV3"] as! [String: Int])
                        .sorted { $0.key < $1.key }.map { Int64($0.value) }
                ),
                dRepActivity: Int64(protocolParams.drepActivity!)!,
                dRepDeposit: Int64(protocolParams.drepDeposit!)!,
                dRepVotingThresholds: DRepVotingThresholds(
                    committeeNoConfidence: protocolParams.dvtCommitteeNoConfidence!,
                    committeeNormal: protocolParams.dvtCommitteeNormal!,
                    hardForkInitiation: protocolParams.dvtHardForkInitiation!,
                    motionNoConfidence: protocolParams.dvtMotionNoConfidence!,
                    ppEconomicGroup: protocolParams.dvtPPEconomicGroup!,
                    ppGovGroup: protocolParams.dvtPPGovGroup!,
                    ppNetworkGroup: protocolParams.dvtPPNetworkGroup!,
                    ppTechnicalGroup: protocolParams.dvtPPTechnicalGroup!,
                    treasuryWithdrawal: protocolParams.dvtTreasuryWithdrawal!,
                    updateToConstitution: protocolParams.dvtUpdateToConstitution!
                ),
                executionUnitPrices: ExecutionUnitPrices(
                    priceMemory: protocolParams.priceMem!,
                    priceSteps: protocolParams.priceStep!
                ),
                govActionDeposit: Int64(protocolParams.govActionDeposit!)!,
                govActionLifetime: Int64(protocolParams.govActionLifetime!)!,
                maxBlockBodySize: Int64(protocolParams.maxBlockSize),
                maxBlockExecutionUnits: ProtocolParametersExecutionUnits(
                    memory: Int64(protocolParams.maxBlockExMem!)!,
                    steps: Int64(protocolParams.maxBlockExSteps!)!
                ),
                maxBlockHeaderSize: Int64(protocolParams.maxBlockHeaderSize),
                maxCollateralInputs: Int64(protocolParams.maxCollateralInputs!),
                maxTxExecutionUnits: ProtocolParametersExecutionUnits(
                    memory: Int64(protocolParams.maxTxExMem!)!,
                    steps: Int64(protocolParams.maxTxExSteps!)!
                ),
                maxTxSize: Int64(protocolParams.maxTxSize),
                maxValueSize: Int64(protocolParams.maxValSize!)!,
                minFeeRefScriptCostPerByte: Int64(
                    protocolParams.minFeeRefScriptCostPerByte!
                ),
                minPoolCost: Int64(protocolParams.minPoolCost)!,
                monetaryExpansion: protocolParams.rho,
                poolPledgeInfluence: protocolParams.a0,
                poolRetireMaxEpoch: Int64(protocolParams.eMax),
                poolVotingThresholds: ProtocolParametersPoolVotingThresholds(
                    committeeNoConfidence: protocolParams.pvtMotionNoConfidence!,
                    committeeNormal: protocolParams.pvtCommitteeNormal!,
                    hardForkInitiation: protocolParams.pvtHardForkInitiation!,
                    motionNoConfidence: protocolParams.pvtMotionNoConfidence!,
                    ppSecurityGroup: protocolParams.pvtPPSecurityGroup!
                ),
                protocolVersion: ProtocolParametersProtocolVersion(
                    major: protocolParams.protocolMajorVer,
                    minor: protocolParams.protocolMinorVer
                ),
                stakeAddressDeposit: Int64(protocolParams.keyDeposit)!,
                stakePoolDeposit: Int64(protocolParams.poolDeposit)!,
                stakePoolTargetNum: Int64(protocolParams.nOpt),
                treasuryCut: protocolParams.tau,
                txFeeFixed: Int64(protocolParams.minFeeB),
                txFeePerByte: Int64(protocolParams.minFeeA),
                utxoCostPerByte: Int64(protocolParams.coinsPerUtxoSize!)!
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
                    let cbor = try scriptCBOR.ok.body.json.cbor!
                    let v1script = PlutusV1Script(data: Data(hex: cbor))
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
                    let cbor = try scriptCBOR.ok.body.json.cbor!
                    let v1script = PlutusV2Script(data: Data(hex: cbor))
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
                    let cbor = try scriptCBOR.ok.body.json.cbor!
                    let v1script = PlutusV3Script(data: Data(hex: cbor))
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

                    let nativeScript = try JSONDecoder()
                        .decode(
                            NativeScript.self,
                            from: jsonData
                        )
                    return .nativeScript(nativeScript)
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
                    transactionId: try TransactionId(from: .string(result.txHash)),
                    index: UInt16(result.outputIndex)
                )

                var lovelaceAmount: UInt64 = 0
                var multiAssets = MultiAsset([:])

                for item in result.amount {
                    if item.unit == "lovelace" {
                        lovelaceAmount = UInt64(item.quantity) ?? 0
                    } else {
                        // The utxo contains Multi-asset
                        let data = Data(hex: item.unit)
                        let policyId = ScriptHash(
                            payload: data.prefix(SCRIPT_HASH_SIZE)
                        )
                        let assetName = try AssetName(
                            payload: data.suffix(from: SCRIPT_HASH_SIZE)
                        )

                        if multiAssets[policyId] == nil {
                            multiAssets[policyId] = Asset([:])
                        }
                        multiAssets[policyId]?[assetName] = Int64(item.quantity) ?? 0
                    }
                }

                let amount = Value(
                    coin: Int64(lovelaceAmount),
                    multiAsset: multiAssets
                )

                var datumHash: DatumHash? = nil
                var datumOption: DatumOption? = nil
                var script: ScriptType? = nil

                if result.dataHash != nil && result.inlineDatum == nil {
                    datumHash = try DatumHash(from: .string(result.dataHash!))
                }

                if let inlineDatum = result.inlineDatum,
                    let datumData = Data(hexString: inlineDatum)
                {
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
                transactionId: try TransactionId(from: .string(txHash)),
                index: UInt16(outputIndex)
            )

            var lovelaceAmount: UInt64 = 0
            var multiAssets = MultiAsset([:])

            for item in result.amount {
                if item.unit == "lovelace" {
                    lovelaceAmount = UInt64(item.quantity) ?? 0
                } else {
                    let data = Data(hex: item.unit)
                    let policyId = ScriptHash(payload: data.prefix(SCRIPT_HASH_SIZE))
                    let assetName = try AssetName(payload: data.suffix(from: SCRIPT_HASH_SIZE))
                    if multiAssets[policyId] == nil {
                        multiAssets[policyId] = Asset([:])
                    }
                    multiAssets[policyId]?[assetName] = Int64(item.quantity) ?? 0
                }
            }

            let amount = Value(
                coin: Int64(lovelaceAmount),
                multiAsset: multiAssets
            )

            var datumHash: DatumHash? = nil
            var datumOption: DatumOption? = nil
            var script: ScriptType? = nil

            if result.dataHash != nil && result.inlineDatum == nil {
                datumHash = try DatumHash(from: .string(result.dataHash!))
            }

            if let inlineDatum = result.inlineDatum,
               let datumData = Data(hexString: inlineDatum)
            {
                let plutusData = try PlutusData.fromCBOR(data: datumData)
                datumOption = DatumOption(datum: plutusData)
            }

            if let referenceScriptHash = result.referenceScriptHash {
                script = try? await self.getScript(scriptHash: referenceScriptHash)
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
                        mem: Int64(value["memory"] ?? 0),
                        steps: Int64(value["steps"] ?? 0)
                    )
                }
            }
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
                    activeEpoch: stakeInfo.activeEpoch.map { EpochNumber($0) },
                    address: stakeInfo.stakeAddress,
                    rewardAccountBalance: Int64(
                        stakeInfo.withdrawableAmount
                    )!,
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

        let onChainOpCertCount = Int(opCertCounter)!
        let nextChainOpCertCount = onChainOpCertCount + 1

        if let opCert = opCert {
            let onDiskOpCertCount = Int(opCert.sequenceNumber)
            let onDiskKESStart = Int(opCert.kesPeriod)

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

        do {
            let metadataResponse = try await api.client.getPoolsPoolIdMetadata(
                Operations.GetPoolsPoolIdMetadata.Input(
                    path: Operations.GetPoolsPoolIdMetadata.Input.Path(poolId: poolId)
                )
            )
            let metadata = try metadataResponse.ok.body.json
            if let urlString = metadata.value1?.url, let hashString = metadata.value1?.hash,
               let hashData = Data(hexString: hashString)
            {
                let url = try Url(urlString)
                let hash = PoolMetadataHash(payload: hashData)
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
        } catch {
            // Metadata might not exist, ignore error
        }

        // 4. Get latest block minted by pool for opcert counter
        var opcertCounter: UInt? = nil
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
                if let counterStr = blockInfo.opCertCounter, let counter = UInt(counterStr) {
                    opcertCounter = counter
                }
            }
        } catch {
            // Pool may not have minted any blocks yet
        }

        // Map relays
        let relays: [SwiftCardanoCore.Relay] = relaysData.compactMap { relay in
            if let ipv4String = relay.ipv4, let ipv4 = IPv4Address(ipv4String) {
                return .singleHostAddr(SingleHostAddr(port: relay.port, ipv4: ipv4, ipv6: nil))
            } else if let ipv6String = relay.ipv6, let ipv6 = IPv6Address(ipv6String) {
                return .singleHostAddr(SingleHostAddr(port: relay.port, ipv4: nil, ipv6: ipv6))
            } else if let dns = relay.dns {
                return .singleHostName(SingleHostName(port: relay.port, dnsName: dns))
            } else if let dnsSrv = relay.dnsSrv {
                return .multiHostName(MultiHostName(dnsName: dnsSrv))
            }
            return nil
        }

        // Convert margin (Double) to UnitInterval using 10^8 denominator for precision
        let marginDenom: UInt64 = 100_000_000
        let marginNum = UInt64((pool.marginCost * Double(marginDenom)).rounded())
        let margin = UnitInterval(numerator: marginNum, denominator: marginDenom)

        let poolOperator = try PoolOperator(from: poolId)
        let vrfKeyHash = VrfKeyHash(payload: Data(hex: pool.vrfKey))
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
            pledge: Int(UInt64(pool.declaredPledge) ?? 0),
            cost: Int(UInt64(pool.fixedCost) ?? 0),
            margin: margin,
            rewardAccount: rewardAccountHash,
            poolOwners: poolOwners,
            relays: relays,
            poolMetadata: poolMetadata
        )

        let livePledge: UInt? = UInt(pool.livePledge)
        let liveStake: UInt? = UInt(pool.liveStake)
        let activeStake: UInt? = UInt(pool.activeStake)
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
                        status = .retiring(epoch: UInt(retiringEpoch))
                    }
                }
            } catch {
                // If we can't determine the exact epoch, fall back to retiring
                status = .retiring(epoch: 0)
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

        guard let treasuryInt = UInt64(networkData.supply.treasury) else {
            throw CardanoChainError.valueError("Failed to parse treasury balance")
        }

        return Coin(treasuryInt)
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
        
        var anchor: Anchor? = nil
        if let metadataResponse = try? await api.client.getGovernanceDrepsDrepIdMetadata(
            .init(path: .init(drepId: drepId))
        ), let metaData = try? metadataResponse.ok.body.json,
           !metaData.url.isEmpty, !metaData.hash.isEmpty,
           let hashData = Data(hexString: metaData.hash) {
            anchor = try? Anchor(
                anchorUrl: Url(metaData.url),
                anchorDataHash: AnchorDataHash(payload: hashData)
            )
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
                    major: params.protocolMajorVer ?? 0,
                    minor: params.protocolMinorVer ?? 0
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
            
            // Construct ProtocolParamUpdate from Blockfrost params
            let update = ProtocolParamUpdate(
                minFeeA: params.minFeeA != nil ? Coin(params.minFeeA!) : nil,
                minFeeB: params.minFeeB != nil ? Coin(params.minFeeB!) : nil,
                maxBlockBodySize: params.maxBlockSize != nil ? UInt32(params.maxBlockSize!) : nil,
                maxTransactionSize: params.maxTxSize != nil ? UInt32(params.maxTxSize!) : nil,
                maxBlockHeaderSize: params.maxBlockHeaderSize != nil ? UInt16(params.maxBlockHeaderSize!) : nil,
                keyDeposit: params.keyDeposit != nil ? Coin(Int(params.keyDeposit!)!) : nil,
                poolDeposit: params.poolDeposit != nil ? Coin(Int(params.poolDeposit!)!) : nil,
                maximumEpoch: params.eMax != nil ? EpochInterval(params.eMax!) : nil,
                nOpt: params.nOpt != nil ? UInt16(params.nOpt!) : nil,
                poolPledgeInfluence: params.a0.map { makeNonNegativeInterval($0) },
                expansionRate: params.rho.map { makeUnitInterval($0) },
                treasuryGrowthRate: params.tau.map { makeUnitInterval($0) },
                decentralizationConstant: params.decentralisationParam.map { makeUnitInterval($0) },
                extraEntropy: params.extraEntropy != nil ? 0 : nil, // Placeholder as extraEntropy in ProtocolParamUpdate is UInt32
                protocolVersion: (params.protocolMajorVer != nil && params.protocolMinorVer != nil) ? ProtocolVersion(major: params.protocolMajorVer!, minor: params.protocolMinorVer!) : nil,
                minPoolCost: params.minPoolCost != nil ? Coin(Int64(params.minPoolCost!)!) : nil,
                adaPerUtxoByte: params.coinsPerUtxoSize != nil ? Coin(Int64(params.coinsPerUtxoSize!)!) : nil,
                costModels: nil, // Mapping cost models is complex due to different versions
                executionCosts: (params.priceMem != nil && params.priceStep != nil) ? try? ExUnitPrices(from: .list([.float(params.priceMem!), .float(params.priceStep!)])) : nil,
                maxTxExUnits: (params.maxTxExMem != nil && params.maxTxExSteps != nil) ? try? ExUnits(from: .list([.uint(UInt64(params.maxTxExMem!)!), .uint(UInt64(params.maxTxExSteps!)!)])) : nil,
                maxBlockExUnits: (params.maxBlockExMem != nil && params.maxBlockExSteps != nil) ? try? ExUnits(from: .list([.uint(UInt64(params.maxBlockExMem!)!), .uint(UInt64(params.maxBlockExSteps!)!)])) : nil,
                maxValueSize: params.maxValSize != nil ? UInt32(params.maxValSize!) : nil,
                collateralPercentage: params.collateralPercent != nil ? UInt16(params.collateralPercent!) : nil,
                maxCollateralInputs: params.maxCollateralInputs != nil ? UInt16(params.maxCollateralInputs!) : nil
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
            // The proposal endpoint doesn't carry the constitution's anchor;
            // fetch it from the metadata endpoint. Fall back to a placeholder
            // URL if Blockfrost hasn't indexed the metadata yet so the call
            // still returns a valid `GovAction` instead of trapping.
            let realAnchor: Anchor? = try? await {
                let metadataResponse = try await api.client.getGovernanceProposalsTxHashCertIndexMetadata(
                    .init(path: .init(
                        txHash: govActionID.transactionID.payload.toHex,
                        certIndex: Int(govActionID.govActionIndex)
                    ))
                )
                let meta = try metadataResponse.ok.body.json
                guard let url = try? Url(meta.url) else { return nil as Anchor? }
                return Anchor(
                    anchorUrl: url,
                    anchorDataHash: AnchorDataHash(payload: Data(hex: meta.hash))
                )
            }()
            let anchor = realAnchor
                ?? Anchor(
                    anchorUrl: (try? Url("https://example.invalid"))!,
                    anchorDataHash: AnchorDataHash(payload: Data())
                )
            govAction = .newConstitution(.init(id: govActionID, constitution: .init(anchor: anchor, scriptHash: nil)))
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
                withdrawals[RewardAccount(Data(hexString: item.stakeAddress) ?? Data())] = Coin(Int(item.amount)!)
            }
            govAction = .treasuryWithdrawalsAction(.init(withdrawals: withdrawals, policyHash: nil))
        @unknown default:
            govAction = .infoAction(.init())
        }
        
        return GovActionInfo(
            govActionId: govActionID,
            govAction: govAction,
            proposedIn: nil,
            expiresAfter: UInt64(govActionData.expiration),
            ratifiedEpoch: govActionData.ratifiedEpoch != nil ? UInt64(govActionData.ratifiedEpoch!) : nil,
            enactedEpoch: govActionData.enactedEpoch != nil ? UInt64(govActionData.enactedEpoch!) : nil,
            droppedEpoch: govActionData.droppedEpoch != nil ? UInt64(govActionData.droppedEpoch!) : nil,
            expiredEpoch: govActionData.expiredEpoch != nil ? UInt64(govActionData.expiredEpoch!) : nil
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
                    ScriptHash(payload: Data(hex: member.ccColdHex)))
            )
        } else {
            coldCredential = CommitteeColdCredential(
                credential: .verificationKeyHash(
                    VerificationKeyHash(payload: Data(hex: member.ccColdHex)))
            )
        }

        let hotCredential: CommitteeHotCredential?
        if let preferredHot = preferredHot {
            hotCredential = preferredHot
        } else if let hotHex = member.ccHotHex {
            if member.ccHotHasScript ?? false {
                hotCredential = CommitteeHotCredential(
                    credential: .scriptHash(ScriptHash(payload: Data(hex: hotHex)))
                )
            } else {
                hotCredential = CommitteeHotCredential(
                    credential: .verificationKeyHash(
                        VerificationKeyHash(payload: Data(hex: hotHex)))
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
            expiration: EpochNumber(member.expirationEpoch),
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

        let deposit = Coin(UInt64(proposal.deposit) ?? 0)
        let returnAddrData: Data = (try? Address.fromBech32(proposal.returnAddress).toBytes()) ?? Data()

        // Anchor metadata via a separate endpoint. Best-effort — the proposal may have
        // no anchor (rare in practice), or Blockfrost may return 404 if the metadata
        // hasn't been indexed yet. Either way we just drop the anchor and continue.
        let anchor: SwiftCardanoCore.Anchor? = try? await {
            let metadataResponse = try await api.client.getGovernanceProposalsTxHashCertIndexMetadata(
                .init(path: .init(
                    txHash: govActionID.transactionID.payload.toHex,
                    certIndex: Int(govActionID.govActionIndex)
                ))
            )
            let meta = try metadataResponse.ok.body.json
            guard let url = try? Url(meta.url) else { return nil as SwiftCardanoCore.Anchor? }
            return SwiftCardanoCore.Anchor(
                anchorUrl: url,
                anchorDataHash: AnchorDataHash(payload: Data(hex: meta.hash))
            )
        }()

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
                if let pool = try? PoolOperator(from: .string(row.voter)) {
                    stakePoolVotes.append(.init(poolOperator: pool, vote: vote))
                }
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
                transactionID: TransactionId(payload: Data(hex: proposal.txHash)),
                govActionIndex: UInt16(proposal.certIndex)
            )
            if let votes = try? await govActionVotes(govActionID: govActionID) {
                results.append(votes)
            }
        }
        return results
    }

    public func committeeState() async throws -> CommitteeStateInfo {
        let response = try await api.client.getGovernanceCommittee()
        let committee = try response.ok.body.json

        let currentEpoch = try await epoch()

        let members: [CommitteeStateInfo.Member] = committee.members.map { m in
            let cold: CommitteeColdCredential = m.ccColdHasScript
                ? CommitteeColdCredential(credential: .scriptHash(ScriptHash(payload: Data(hex: m.ccColdHex))))
                : CommitteeColdCredential(credential: .verificationKeyHash(VerificationKeyHash(payload: Data(hex: m.ccColdHex))))

            let hot: CommitteeHotCredential? = {
                guard let hotHex = m.ccHotHex else { return nil }
                let isScript = m.ccHotHasScript ?? false
                return isScript
                    ? CommitteeHotCredential(credential: .scriptHash(ScriptHash(payload: Data(hex: hotHex))))
                    : CommitteeHotCredential(credential: .verificationKeyHash(VerificationKeyHash(payload: Data(hex: hotHex))))
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
                expiration: EpochNumber(m.expirationEpoch),
                status: status
            )
        }

        let threshold: Double = committee.quorum.denominator != 0
            ? Double(committee.quorum.numerator) / Double(committee.quorum.denominator)
            : 0.0

        return CommitteeStateInfo(members: members, threshold: threshold)
    }
}

// Blockfrost returns protocol-parameter ratios as JSON doubles, but
// `UnitInterval`/`NonNegativeInterval`'s primitive initializers reject
// `.float` — they want a CBOR-tagged or list-form pair of integers.
// Round to a fixed precision (6 decimal places by default, which covers
// the precision Cardano actually publishes for these parameters).

internal func makeUnitInterval(_ value: Double, precision: UInt64 = 1_000_000) -> UnitInterval {
    let bounded = max(0.0, min(1.0, value))
    let scaled = (bounded * Double(precision)).rounded()
    return UnitInterval(numerator: UInt64(scaled), denominator: precision)
}

internal func makeNonNegativeInterval(_ value: Double, precision: UInt64 = 1_000_000) -> NonNegativeInterval {
    let bounded = max(0.0, value)
    let scaled = (bounded * Double(precision)).rounded()
    return NonNegativeInterval(lowerBound: UInt64(scaled), upperBound: precision)
}
