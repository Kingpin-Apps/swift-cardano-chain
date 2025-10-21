import Foundation
import SwiftCardanoCore
import SwiftBlockfrostAPI
import PotentCBOR
import OpenAPIRuntime

/// A `BlockFrost <https://blockfrost.io/>`_ API wrapper for the client code to interact with.
///
/// - Parameters:
///   - projectId: A BlockFrost project ID obtained from https://blockfrost.io.
///   - network: Network to use.
///   - baseUrl: Base URL for the BlockFrost API. Defaults to the mainnet url.
public class BlockFrostChainContext: ChainContext {
    
    // MARK: - Properties

    public var api: Blockfrost
    private var epochInfo: Components.Schemas.EpochContent?
    private var _epoch: Int?
    private var _genesisParam: GenesisParameters?
    private var _protocolParam: ProtocolParameters?
    private let _network: SwiftCardanoCore.Network
    
    public var networkId: NetworkId {
        self._network.networkId
    }
    
    public lazy var epoch: () async throws -> Int = { [weak self] in
        guard let self = self else {
            throw CardanoChainError.blockfrostError("Self is nil")
        }
        
        if try await self.checkEpochAndUpdate() || self._epoch == nil {
            let response = try await api.client.getEpochsLatest()
            do {
                self.epochInfo = try response.ok.body.json
                self._epoch = self.epochInfo?.epoch
            } catch {
                throw CardanoChainError.blockfrostError("Failed to get epoch info: \(response)")
            }
        }
        return self._epoch ?? 0
    }
    
    public lazy var lastBlockSlot: () async throws -> Int = { [weak self] in
        guard let self = self else {
            throw CardanoChainError.blockfrostError("Self is nil")
        }
        let response = try await api.client.getBlocksLatest()
        do {
            return try response.ok.body.json.slot!
        } catch {
            throw CardanoChainError.blockfrostError("Failed to get blocksLatest: \(response)")
        }
    }
    
    public lazy var genesisParameters: () async throws -> GenesisParameters  = { [weak self] in
        guard let self = self else {
            throw CardanoChainError.blockfrostError("Self is nil")
        }
        
        if try await self.checkEpochAndUpdate() || self._genesisParam == nil {
            let response = try await api.client.getGenesis()
            do {
                let genesis = try response.ok.body.json
                self._genesisParam = GenesisParameters(
                    activeSlotsCoefficient: genesis.activeSlotsCoefficient,
                    epochLength: genesis.epochLength,
                    maxKesEvolutions: genesis.maxKesEvolutions,
                    maxLovelaceSupply: Int(genesis.maxLovelaceSupply)!,
                    networkId: self._network.description,
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
        return self._genesisParam!
    }

    public lazy var protocolParameters: () async throws -> ProtocolParameters  = { [weak self] in
        guard let self = self else {
            throw CardanoChainError.blockfrostError("Self is nil")
        }
        
        if try await self.checkEpochAndUpdate() || self._protocolParam == nil {
            let response = try await api.client.getEpochsLatestParameters()
            do {
                let protocolParams = try response.ok.body.json
                
                let costModels = protocolParams.costModels.unsafelyUnwrapped.additionalProperties.value
                
                self._protocolParam = ProtocolParameters(
                    collateralPercentage: protocolParams.collateralPercent!,
                    committeeMaxTermLength: Int(protocolParams.committeeMaxTermLength!)!,
                    committeeMinSize: Int(protocolParams.committeeMinSize!)!,
                    costModels: ProtocolParametersCostModels(
                        PlutusV1: (costModels["PlutusV1"] as! [String: Int]).map { key, value in
                                return value
                            },
                        PlutusV2: (costModels["PlutusV2"] as! [String: Int]).map { key, value in
                                return value
                            },
                        PlutusV3: (costModels["PlutusV3"] as! [String: Int]).map { key, value in
                                return value
                            }
                    ),
                    dRepActivity: Int(protocolParams.drepActivity!)!,
                    dRepDeposit: Int(protocolParams.drepDeposit!)!,
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
                    govActionDeposit: Int(protocolParams.govActionDeposit!)!,
                    govActionLifetime: Int(protocolParams.govActionLifetime!)!,
                    maxBlockBodySize: Int(
                        exactly: protocolParams.maxBlockSize
                    )!,
                    maxBlockExecutionUnits: ProtocolParametersExecutionUnits(
                        memory: Int(protocolParams.maxBlockExMem!)!,
                        steps: Int64(protocolParams.maxBlockExSteps!)!
                    ),
                    maxBlockHeaderSize: Int(protocolParams.maxBlockHeaderSize),
                    maxCollateralInputs: protocolParams.maxCollateralInputs!,
                    maxTxExecutionUnits: ProtocolParametersExecutionUnits(
                        memory: Int(protocolParams.maxTxExMem!)!,
                        steps: Int64(protocolParams.maxTxExSteps!)!
                    ),
                    maxTxSize: protocolParams.maxTxSize,
                    maxValueSize: Int(protocolParams.maxValSize!)!,
                    minFeeRefScriptCostPerByte: Int(
                        protocolParams.minFeeRefScriptCostPerByte!
                    ),
                    minPoolCost: Int(protocolParams.minPoolCost)!,
                    monetaryExpansion: protocolParams.rho,
                    poolPledgeInfluence: protocolParams.a0,
                    poolRetireMaxEpoch: protocolParams.eMax,
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
                    stakeAddressDeposit: Int(protocolParams.keyDeposit)!,
                    stakePoolDeposit: Int(protocolParams.poolDeposit)!,
                    stakePoolTargetNum: protocolParams.nOpt,
                    treasuryCut: protocolParams.tau,
                    txFeeFixed: protocolParams.minFeeB,
                    txFeePerByte: protocolParams.minFeeA,
                    utxoCostPerByte: Int(protocolParams.coinsPerUtxoSize!)!
                )
                                                         
            } catch {
                throw CardanoChainError.blockfrostError("Failed to get getEpochsLatestParameters: \(response)")
            }
        }
        return self._protocolParam!
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
            throw CardanoChainError
                .blockfrostError(
                    "Failed to get epoch info: \(error.localizedDescription)"
                )
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
            throw CardanoChainError.valueError("Cannot recover script: \(script) from hash: \(hash).")
        }
    }

    private func checkEpochAndUpdate() async throws -> Bool {
        if let epochTime = self.epochInfo?.endTime, Int(Date().timeIntervalSince1970) < epochTime {
            return false
        }
        
        let epochInfo = try await api.client.getEpochsLatest()
        do {
            self.epochInfo = try epochInfo.ok.body.json
        } catch {
            throw CardanoChainError.blockfrostError("Failed to get epoch info: \(epochInfo)")
        }
        return true
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
                throw CardanoChainError.blockfrostError("Failed to get scriptInfo info: \(scriptInfo)")
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
                        throw CardanoChainError.blockfrostError("Failed to get scriptCBOR: \(scriptCBOR)")
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
                        throw CardanoChainError.blockfrostError("Failed to get scriptCBOR: \(scriptCBOR)")
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
                        throw CardanoChainError.blockfrostError("Failed to get scriptJSON: \(scriptJSON)")
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
                        multiAssets[policyId]?[assetName] = Int(item.quantity)
                    }
                }

                let amount = Value(
                    coin: Int(lovelaceAmount),
                    multiAsset: multiAssets
                )
                
                var datumHash: DatumHash? = nil
                var datumOption: DatumOption? = nil
                var script: ScriptType? = nil
                
                if result.dataHash != nil && result.inlineDatum == nil {
                    datumHash = try DatumHash(from: .string(result.dataHash!))
                }
                
                if let inlineDatum = result.inlineDatum,
                    let datumData = Data(hexString: inlineDatum) {
                    datumOption = try DatumOption.fromCBOR(data: datumData)
                }
//                else if let inlineDatum = result.inlineDatum as? [AnyHashable: Any] {
//                    let plutusData = try PlutusData.fromDict(inlineDatum)
//                    datumOption = DatumOption(datum: plutusData)
//                }

                if let referenceScriptHash = result.referenceScriptHash {
                    script = try? await self
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
            throw CardanoChainError.transactionFailed("Failed to get UTxOs: \(addressUtxos)")
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
            let evaluationResult  = try result.ok.body.json.additionalProperties.value
            
            if let evaluationResult = evaluationResult["EvaluationResult"] as? [String: [String: Int]]
            {
                for (key, value) in evaluationResult {
                    returnVal[key] = ExecutionUnits(
                        mem: Int(value["memory"] ?? 0),
                        steps: Int(value["steps"] ?? 0)
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
            let stakeInfo  = try rewardsState.ok.body.json
            return [
                StakeAddressInfo(
                    address: stakeInfo.stakeAddress,
                    rewardAccountBalance: Int(
                        stakeInfo.withdrawableAmount
                    )!,
                    stakeDelegation: stakeInfo.poolId != nil ? try PoolOperator(
                        from: stakeInfo.poolId!
                    ) : nil,
                    voteDelegation: stakeInfo.drepId != nil ? try DRep(
                        from: stakeInfo.drepId!
                    ) : nil,
                )
            ]
        } catch {
            throw CardanoChainError.blockfrostError("Failed to get getAccountsStakeAddressRewards: \(rewardsState)")
        }
    }
}
