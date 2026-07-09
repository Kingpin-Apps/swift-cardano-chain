import Foundation
import OpenAPIRuntime
import SwiftCardanoCore
import SwiftCardanoNetwork
import SwiftKoios

/// A chain context implementation backed by the [Koios](https://www.koios.rest) distributed API.
///
/// `KoiosChainContext` queries the Koios elastic query layer, a community-run, elastic API
/// for Cardano. Unlike BlockFrost, Koios is decentralised — multiple community nodes serve the
/// same REST interface, so there is no single point of failure.
///
/// An API key is optional for low-volume usage; create one at https://www.koios.rest for
/// higher rate limits.
///
/// ## Creating a Context
///
/// ```swift
/// // Without an API key (rate-limited)
/// let context = try await KoiosChainContext(network: .mainnet)
///
/// // From an environment variable
/// let context = try await KoiosChainContext(
///     network: .mainnet,
///     environmentVariable: "KOIOS_API_KEY"
/// )
///
/// // With an API key directly
/// let context = try await KoiosChainContext(
///     apiKey: "your-koios-api-key",
///     network: .preprod
/// )
/// ```
///
/// ## Supported Networks
///
/// `.mainnet`, `.preprod`, `.preview`, `.guildnet`, `.sanchonet`
///
/// ## Topics
///
/// ### Creating a Context
/// - ``init(apiKey:network:basePath:environmentVariable:client:)``
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
public actor KoiosChainContext: ChainContext {

    // MARK: - Properties

    nonisolated public var name: String { "Koios" }
    nonisolated public var type: ContextType { .online }

    public let api: Koios
    private var epochInfo: Components.Schemas.EpochInfoPayload?
    private var _epochInfoFetch: Task<Components.Schemas.EpochInfoPayload, Error>?
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
        let info = try await currentEpochInfo()
        return Int(info.epochNo ?? 0)
    }

    /// Master cache for the latest Koios epoch metadata.
    ///
    /// `endTime` is the wall-clock instant the current epoch ends. While that's in the
    /// future the cache is fresh; otherwise we refresh, deduplicating concurrent callers
    /// through `_epochInfoFetch` so the network round-trip happens at most once at a time.
    /// Cache writes happen inside the Task body so the result lands in the cache even if
    /// the launching caller is cancelled mid-flight.
    private func currentEpochInfo() async throws -> Components.Schemas.EpochInfoPayload {
        if let cached = epochInfo,
           let endTime = cached.endTime,
           Date().timeIntervalSince1970 < endTime {
            return cached
        }
        if let inFlight = _epochInfoFetch { return try await inFlight.value }

        let task = Task<Components.Schemas.EpochInfoPayload, Error> {
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

    private func fetchEpochInfoFromAPI() async throws -> Components.Schemas.EpochInfoPayload {
        do {
            let response = try await api.client.epochInfo()
            guard let info = try response.ok.body.json.first else {
                throw CardanoChainError.koiosError("Empty epoch info response")
            }
            return info
        } catch let error as CardanoChainError {
            throw error
        } catch {
            throw CardanoChainError.koiosError("Failed to get epoch info: \(error)")
        }
    }

    public func lastBlockSlot() async throws -> Int {
        do {
            let response = try await api.client.tip()
            return try response.ok.body.json.first?.absSlot?.value as? Int ?? 0
        } catch {
            throw CardanoChainError.koiosError("Failed to get tip: \(error)")
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
        let response = try await api.client.genesis()
        do {
            let payloads = try response.ok.body.json
            guard let genesis = payloads.first else {
                throw CardanoChainError.koiosError("Genesis response was empty")
            }

            // Safely convert and unwrap expected fields. Many Koios fields are strings.
            // Provide meaningful errors if any required field is missing.
            func requireDouble(_ value: String?, name: String) throws -> Double {
                guard let s = value, let d = Double(s) else {
                    throw CardanoChainError.koiosError("Missing/invalid Double for \(name)")
                }
                return d
            }
            func requireInt(_ value: String?, name: String) throws -> Int {
                guard let s = value, let i = Int(s) else {
                    throw CardanoChainError.koiosError("Missing/invalid Int for \(name)")
                }
                return i
            }
            func requireUInt64(_ value: String?, name: String) throws -> UInt64 {
                guard let s = value, let i = UInt64(s) else {
                    throw CardanoChainError.koiosError("Missing/invalid UInt64 for \(name)")
                }
                return i
            }

            let activeSlotsCoefficient = try requireDouble(
                genesis.activeslotcoeff, name: "activeslotcoeff")
            let epochLength = try requireInt(genesis.epochlength, name: "epochlength")
            let maxKesEvolutions = try requireInt(
                genesis.maxkesrevolutions, name: "maxkesrevolutions")
            let maxLovelaceSupply = try requireInt(
                genesis.maxlovelacesupply, name: "maxlovelacesupply")
            let networkMagic = try requireInt(genesis.networkmagic, name: "networkmagic")
            let securityParam = try requireInt(genesis.securityparam, name: "securityparam")
            let slotLength = try requireInt(genesis.slotlength, name: "slotlength")
            let slotsPerKesPeriod = try requireInt(
                genesis.slotsperkesperiod, name: "slotsperkesperiod")
            let updateQuorum = try requireInt(genesis.updatequorum, name: "updatequorum")

            return GenesisParameters(
                activeSlotsCoefficient: activeSlotsCoefficient,
                epochLength: epochLength,
                maxKesEvolutions: maxKesEvolutions,
                maxLovelaceSupply: maxLovelaceSupply,
                networkId: genesis.networkid!,
                networkMagic: networkMagic,
                securityParam: securityParam,
                slotLength: slotLength,
                slotsPerKesPeriod: slotsPerKesPeriod,
                systemStart: Date(timeIntervalSince1970: TimeInterval(genesis.systemstart!)),
                updateQuorum: updateQuorum
            )
        } catch {
            throw CardanoChainError.koiosError("Failed to decode Genesis parameters: \(error)")
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

    // MARK: - Initializers
    public init(
        apiKey: String? = nil,
        network: SwiftCardanoCore.Network? = .mainnet,
        basePath: String? = nil,
        environmentVariable: String? = nil,
        client: Client? = nil,
    ) async throws {
        self._network = network ?? .mainnet

        let koiosNetwork: SwiftKoios.Network
        switch network {
        case .mainnet:
            koiosNetwork = .mainnet
        case .guildnet:
            koiosNetwork = .guild
        case .preview:
            koiosNetwork = .preview
        case .preprod:
            koiosNetwork = .preprod
        case .sanchonet:
            koiosNetwork = .sancho
        default:
            throw CardanoChainError.unsupportedNetwork(
                "Unsupported network: \(String(describing: network))"
            )
        }

        self.api = try Koios(
            network: koiosNetwork,
            apiKey: apiKey,
            basePath: basePath,
            environmentVariable: environmentVariable,
            client: client
        )

        // Initialize epoch info
        do {
            let response = try await api.client.epochInfo()
            self.epochInfo = try response.ok.body.json.first
        } catch {
            throw
                CardanoChainError
                .koiosError("Failed to get epoch info: \(error)")
        }
    }

    // MARK: - Public Methods

    /// Query the chain tip
    ///
    /// - Returns: The chain tip as a dictionary
    /// - Throws: CardanoChainError if the query fails
    public func chainTip() async throws -> ChainTip {
        do {
            let response = try await api.client.tip()
            let json = try response.ok.body.json

            guard let tip = json.first else {
                throw CardanoChainError.koiosError("Tip response was empty")
            }

            return ChainTip(
                block: BlockNumber(exactly: tip.blockNo ?? 0),
                epoch: (tip.epochNo?.value as? Int).map { EpochNumber($0) },
                era: nil,
                hash: tip.hash?.value as? String,
                slot: (tip.absSlot?.value as? Int).map { SlotNumber($0) },
                slotInEpoch: (tip.epochSlot?.value as? Int).map { SlotNumber($0) },
                slotsToEpochEnd: nil,
                syncProgress: nil
            )
        } catch {
            throw CardanoChainError.koiosError("Failed to get tip: \(error)")
        }
    }

    /// Query the current protocol parameters
    ///
    /// - Returns: The protocol parameters as a dictionary
    /// - Throws: CardanoChainError if the query fails
    public func queryCurrentProtocolParams() async throws -> ProtocolParameters {
        do {
            let response = try await api.client.cliProtocolParams()
            let protocolParams = try response.ok.body.json
            let jsonData =
                try JSONSerialization
                .data(
                    withJSONObject: protocolParams,
                    options: [
                        .prettyPrinted,
                        .sortedKeys,
                        .withoutEscapingSlashes,
                    ]
                )

            return try JSONDecoder().decode(ProtocolParameters.self, from: jsonData)

        } catch {
            throw CardanoChainError.koiosError("Failed to get protocol parameters: \(error)")
        }
    }

    // MARK: - Private methods

    // MARK: - Private Helper Methods

    /// Parse a script from a dictionary (typically from reference_script field)
    /// - Parameter scriptDict: Dictionary containing script type and data
    /// - Returns: A ScriptType object
    private func getScript(from scriptDict: [String: Any]) throws -> ScriptType {
        guard let scriptType = scriptDict["type"] as? String else {
            throw CardanoChainError.koiosError("Missing script type")
        }

        switch scriptType {
        case "plutusV1":
            guard let bytes = scriptDict["bytes"] as? String else {
                throw CardanoChainError.koiosError("Missing script bytes")
            }
            let script = PlutusV1Script(data: Data(hex: bytes))
            return .plutusV1Script(script)

        case "plutusV2":
            guard let bytes = scriptDict["bytes"] as? String else {
                throw CardanoChainError.koiosError("Missing script bytes")
            }
            let script = PlutusV2Script(data: Data(hex: bytes))
            return .plutusV2Script(script)

        case "plutusV3":
            guard let bytes = scriptDict["bytes"] as? String else {
                throw CardanoChainError.koiosError("Missing script bytes")
            }
            let script = PlutusV3Script(data: Data(hex: bytes))
            return .plutusV3Script(script)

        default:
            // For native scripts, expect a 'value' field with the script JSON
            guard let value = scriptDict["value"] else {
                throw CardanoChainError.koiosError("Missing script value for native script")
            }
            let jsonData = try JSONSerialization.data(withJSONObject: value)
            let nativeScript = try JSONDecoder().decode(NativeScript.self, from: jsonData)
            return .nativeScript(nativeScript)
        }
    }

    // MARK: - ChainContext methods

    /// Gets the UTxOs for a given address.
    ///
    /// This implementation follows the Python reference implementation from pycardano_chain_contexts.
    /// See: /Users/hadderley/Projects/pycardano_chain_contexts/pycardano_chain_contexts/pccontext/backend/koios.py
    ///
    /// - Parameter address: The address to get the `UTxO`s for.
    /// - Returns: A list of `UTxO`s.
    public func utxos(address: SwiftCardanoCore.Address) async throws -> [UTxO] {
        let addressUtxos = try await api.client.addressUtxos(
            Operations.AddressUtxos.Input(
                body: Components.RequestBodies.PaymentAddressesWithExtended
                    .json(.init(_addresses: [address.toBech32()]))
            )
        )

        do {
            let results = try addressUtxos.ok.body.json
            var utxos: [UTxO] = []

            for result in results {
                let txIn = TransactionInput(
                    transactionId: try TransactionId(
                        from: .string(result.txHash!)
                    ),
                    index: UInt16(result.txIndex!)
                )

                var lovelaceAmount: UInt64 = 0
                var multiAssets = MultiAsset([:])

                // Parse the value from OpenAPIValueContainer
                if let valueContainer = result.value,
                    let valueArray = valueContainer.value as? [[String: Any]]
                {
                    for item in valueArray {
                        if let unit = item["unit"] as? String,
                            let quantity = item["quantity"] as? String
                        {
                            if unit == "lovelace" {
                                lovelaceAmount = UInt64(quantity) ?? 0
                            } else {
                                // The utxo contains Multi-asset
                                let data = Data(hex: unit)
                                let policyId = ScriptHash(
                                    payload: data.prefix(SCRIPT_HASH_SIZE)
                                )
                                let assetName = try AssetName(
                                    payload: data.suffix(from: SCRIPT_HASH_SIZE)
                                )

                                if multiAssets[policyId] == nil {
                                    multiAssets[policyId] = Asset([:])
                                }
                                multiAssets[policyId]?[assetName] = Int64(quantity) ?? 0
                            }
                        }
                    }
                }

                let amount = Value(
                    coin: Int64(lovelaceAmount),
                    multiAsset: multiAssets
                )

                var datumHash: DatumHash? = nil
                var datumOption: DatumOption? = nil
                var script: ScriptType? = nil

                if let datumHashValue = result.datumHash?.value as? String,
                    result.inlineDatum == nil
                {
                    datumHash = try DatumHash(from: .string(datumHashValue))
                }

                if let inlineDatum = result.inlineDatum?.value as? String,
                    let datumData = Data(hexString: inlineDatum)
                {
                    // Parse as PlutusData first, then wrap in DatumOption
                    let plutusData = try PlutusData.fromCBOR(data: datumData)
                    datumOption = DatumOption(datum: plutusData)
                }

                if let referenceScriptValue = result.referenceScript?.value {
                    // For reference scripts, we need to parse the script object
                    // This is a simplified implementation - may need adjustment based on actual data structure
                    if let scriptDict = referenceScriptValue as? [String: Any] {
                        script = try? getScript(from: scriptDict)
                    }
                }

                let address = try Address(from: .string(result.address!))
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
            throw CardanoChainError.koiosError("Failed to get UTxOs: \(error)")
        }
    }

    /// Get the UTxO for a specific transaction input.
    ///
    /// - Parameter input: A transaction input identifying the UTxO by transaction hash and output index.
    /// - Returns: A tuple of the UTxO and a boolean indicating whether it has been spent,
    ///   or `nil` if the UTxO cannot be found. Koios returns UTxOs regardless of spent status,
    ///   so `isSpent` is accurate when a result is returned.
    /// - Throws: `CardanoChainError.koiosError` if the query fails.
    public func utxo(input: TransactionInput) async throws -> (UTxO, isSpent: Bool)? {
        let txRef = input.description  // "<txhash>#<index>"

        let response = try await api.client.utxoInfo(
            Operations.UtxoInfo.Input(
                body: Components.RequestBodies.UtxoRefsWithExtended.json(
                    .init(_utxoRefs: [txRef])
                )
            )
        )

        do {
            let results = try response.ok.body.json

            guard let result = results.first else {
                return nil
            }

            let isSpent = result.isSpent ?? false

            guard let txHashStr = result.txHash,
                let txIndexDouble = result.txIndex,
                let addressStr = result.address
            else {
                return nil
            }

            let txIn = TransactionInput(
                transactionId: try TransactionId(from: .string(txHashStr)),
                index: UInt16(txIndexDouble)
            )

            var lovelaceAmount: UInt64 = 0
            var multiAssets = MultiAsset([:])

            // Parse lovelace from value field
            if let valueContainer = result.value,
                let valueStr = valueContainer.value as? String
            {
                lovelaceAmount = UInt64(valueStr) ?? 0
            }

            // Parse multi-assets from asset_list
            if let assetList = result.assetList {
                for asset in assetList {
                    guard let policyIdStr = asset.policyId?.value as? String,
                        let assetNameStr = asset.assetName?.value as? String,
                        let quantityStr = asset.quantity
                    else { continue }

                    let policyId = try ScriptHash(from: .string(policyIdStr))
                    let assetName = try AssetName(payload: Data(hex: assetNameStr))

                    if multiAssets[policyId] == nil {
                        multiAssets[policyId] = Asset([:])
                    }
                    multiAssets[policyId]?[assetName] = Int64(quantityStr) ?? 0
                }
            }

            let amount = Value(
                coin: Int64(lovelaceAmount),
                multiAsset: multiAssets
            )

            var datumHash: DatumHash? = nil
            var datumOption: DatumOption? = nil
            var script: ScriptType? = nil

            if let datumHashValue = result.datumHash?.value as? String,
                result.inlineDatum == nil
            {
                datumHash = try DatumHash(from: .string(datumHashValue))
            }

            if let inlineDatum = result.inlineDatum?.value as? String,
                let datumData = Data(hexString: inlineDatum)
            {
                let plutusData = try PlutusData.fromCBOR(data: datumData)
                datumOption = DatumOption(datum: plutusData)
            }

            if let referenceScriptValue = result.referenceScript?.value {
                if let scriptDict = referenceScriptValue as? [String: Any] {
                    script = try? getScript(from: scriptDict)
                }
            }

            let address = try Address(from: .string(addressStr))
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
            throw CardanoChainError.koiosError("Failed to get UTxO: \(error)")
        }
    }

    /// Submit a transaction to the blockchain.
    /// - Parameter cbor: The serialized transaction to be submitted.
    /// - Returns: The transaction hash.
    /// - Throws: `CardanoChainError.koiosError` if the transaction cannot be submitted.
    public func submitTxCBOR(cbor: Data) async throws -> String {
        let response = try await api.client.submittx(
            Operations.Submittx
                .Input(
                    body: Components.RequestBodies.Txbin.applicationCbor(HTTPBody(cbor))
                )
        )

        switch response {
        case .accepted(let acceptedResponse):
            do {
                let result = try acceptedResponse.body.json
                return result
            } catch {
                throw CardanoChainError.koiosError("Failed to parse submit response: \(error)")
            }
        default:
            throw CardanoChainError.transactionFailed("Failed to submit transaction: \(response)")
        }
    }

    /// Evaluate execution units of a transaction.
    /// - Parameter cbor: The serialized transaction to be evaluated.
    /// - Returns: A dictionary mapping redeemer strings to execution units.
    /// - Throws: `CardanoChainError.koiosError` if the evaluation fails.
    public func evaluateTxCBOR(cbor: Data) async throws -> [String: ExecutionUnits] {
        let result = try await api.client.ogmios(
            Operations.Ogmios.Input(
                body: Components.RequestBodies.Ogmios.json(
                    .init(
                        jsonrpc: "2.0",
                        method: .evaluateTransaction,
                        params: .init(unvalidatedValue: [
                            "transaction": [
                                "cbor": cbor.toHex
                            ]
                        ])
                    ))
            )
        )

        var returnVal: [String: ExecutionUnits] = [:]

        switch result {
        case .ok(let okResponse):
            do {
                let evaluationResultsJSON = try okResponse.body.json

                if let evaluationResults = evaluationResultsJSON.value["result"] as? [[String: Any]]
                {
                    for evaluationResult in evaluationResults {
                        if let validator = evaluationResult["validator"] as? [String: Any],
                            let purpose = validator["purpose"] as? String,
                            let index = validator["index"] as? Int,
                            let budget = evaluationResult["budget"] as? [String: Any],
                            let memory = budget["memory"] as? Int,
                            let cpu = budget["cpu"] as? Int
                        {

                            // Handle purpose rename as in Python version
                            let normalizedPurpose = purpose == "withdraw" ? "withdrawal" : purpose
                            let key = "\(normalizedPurpose):\(index)"

                            returnVal[key] = ExecutionUnits(
                                mem: Int64(memory),
                                steps: Int64(cpu)
                            )
                        }
                    }
                }
            } catch {
                throw CardanoChainError.koiosError("Failed to parse evaluation response: \(error)")
            }
        default:
            throw CardanoChainError.koiosError("Failed to evaluate TxCBOR: \(result)")
        }
        return returnVal
    }

    /// Get the stake address information.
    /// - Parameter address: The stake address.
    /// - Returns: A list of `StakeAddressInfo` object.
    /// - Throws: `CardanoChainError.koiosError` if the stake address info cannot be fetched.
    public func stakeAddressInfo(address: Address) async throws -> [StakeAddressInfo] {
        let response = try await api.client.accountInfo(
            Operations.AccountInfo.Input(
                body: Components.RequestBodies.StakeAddresses
                    .json(.init(_stakeAddresses: [address.toBech32()]))
            )
        )

        do {
            let stakeInfoArray = try response.ok.body.json
            var result: [StakeAddressInfo] = []

            for stakeInfo in stakeInfoArray {
                // An account can be registered but not delegated to a pool and/or DRep, in which
                // case Koios returns null/empty for those fields. Parse only when present —
                // `PoolOperator(from: "")` / `DRep(from: "")` would otherwise throw and fail the
                // whole read for every un-delegated account.
                let delegatedPool = stakeInfo.delegatedPool.flatMap { $0.isEmpty ? nil : $0 }
                let delegatedDrep = stakeInfo.delegatedDrep.flatMap { $0.isEmpty ? nil : $0 }
                let info = StakeAddressInfo(
                    active: stakeInfo.status == .registered,
                    address: (stakeInfo.stakeAddress?.value as? String) ?? "",
                    rewardAccountBalance: Int64(stakeInfo.rewardsAvailable ?? "0") ?? 0,
                    stakeDelegation: try delegatedPool.map { try PoolOperator(from: $0) },
                    voteDelegation: try delegatedDrep.map { try DRep(from: $0) }
                )
                result.append(info)
            }

            return result
        } catch {
            throw CardanoChainError.koiosError("Failed to get accountInfo: \(error)")
        }
    }

    /// Get the list of stake pools
    ///
    /// - Returns: List of stake pool IDs
    public func stakePools() async throws -> [PoolOperator] {
        let response = try await api.client.poolList(
            Operations.PoolList.Input(
                query: .init(
                    select: [
                        "pool_bech32_id"
                    ]
                )
            )
        )

        do {
            let poolList = try response.ok.body.json
            let poolIds = try poolList.compactMap {
                try PoolOperator(from: ($0.poolIdBech32?.value as? String)!)
            }
            return poolIds
        } catch {
            throw CardanoChainError.koiosError("Failed to get stake pools: \(error)")
        }
    }

    /// Get all addresses holding a specific asset.
    /// - Parameters:
    ///   - assetPolicy: The asset policy ID.
    ///   - assetName: The asset name (optional).
    /// - Returns: An `AssetAddresses` object containing the addresses holding the asset.
    /// - Throws: `CardanoChainError.koiosError` if the asset addresses cannot be fetched.
    public func assetAddresses(assetPolicy: String, assetName: String? = nil) async throws
        -> Components.Schemas.AssetAddresses
    {
        let response = try await api.client.assetAddresses(
            Operations.AssetAddresses.Input(
                query: .init(
                    _assetPolicy: assetPolicy,
                    _assetName: assetName,
                )
            )
        )

        do {
            let assetAddresses = try response.ok.body.json
            return assetAddresses
        } catch {
            throw CardanoChainError.koiosError("Failed to get asset addresses: \(error)")
        }
    }

    public func poolInfo(poolIds: [String]) async throws -> Components.Schemas.PoolInfo {
        let response = try await api.client.poolInfo(
            Operations.PoolInfo.Input(
                body: .json(
                    .init(
                        _poolBech32Ids: poolIds
                    ))
            )
        )

        do {
            let poolInfos = try response.ok.body.json
            return poolInfos
        } catch {
            throw CardanoChainError.koiosError("Failed to get pool info: \(error)")
        }
    }

    /// Get the KES period information for a stake pool.
    ///
    /// Retrieves operational certificate counter information from Koios pool info endpoint.
    /// This is useful for stake pool operators to determine when to rotate their operational certificates.
    ///
    /// - Parameters:
    ///   - pool: The pool operator identifier. **Required** for Koios backend.
    ///   - opCert: The local operational certificate file. If provided, includes on-disk certificate details.
    /// - Returns: A `KESPeriodInfo` containing certificate counter information.
    /// - Throws: `CardanoChainError.invalidArgument` if pool is not provided.
    /// - Throws: `CardanoChainError.koiosError` if pool info cannot be retrieved.
    ///
    /// ## Example
    /// ```swift
    /// let pool = try PoolOperator(from: "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy")
    /// let kesInfo = try await chainContext.kesPeriodInfo(pool: pool, opCert: nil)
    /// print("Next cert counter should be: \(kesInfo.nextChainOpCertCount ?? 0)")
    /// ```
    public func kesPeriodInfo(pool: PoolOperator?, opCert: OperationalCertificate? = nil)
        async throws -> KESPeriodInfo
    {
        guard let pool = pool else {
            throw CardanoChainError.invalidArgument("Pool operator must be provided")
        }

        let poolInfoResponse = try await api.client.poolInfo(
            Operations.PoolInfo.Input(
                body: .json(
                    .init(
                        _poolBech32Ids: [pool.id(.bech32)]
                    ))
            )
        )

        let poolInfo = try poolInfoResponse.ok.body.json.first

        guard let opCertCounter = poolInfo?.opCertCounter else {
            throw CardanoChainError.koiosError(
                "Failed to get opCertCounter from pool info: \(String(describing: poolInfo))"
            )
        }

        let onChainOpCertCount = Int(opCertCounter)
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
    /// - Throws: `CardanoChainError.koiosError` if the pool info cannot be fetched.
    public func stakePoolInfo(poolId: String) async throws -> StakePoolInfo {
        let poolInfoResponse = try await api.client.poolInfo(
            Operations.PoolInfo.Input(
                body: .json(
                    .init(
                        _poolBech32Ids: [poolId]
                    ))
            )
        )

        guard let pool = try poolInfoResponse.ok.body.json.first else {
            throw CardanoChainError.koiosError("Pool not found")
        }

        // Map relays (Koios relay schema has no port field)
        let relays: [SwiftCardanoCore.Relay] =
            pool.relays?.compactMap { relay in
                if let ipv4String = relay.ipv4, let ipv4 = IPv4Address(ipv4String) {
                    return .singleHostAddr(SingleHostAddr(port: nil, ipv4: ipv4, ipv6: nil))
                } else if let ipv6String = relay.ipv6, let ipv6 = IPv6Address(ipv6String) {
                    return .singleHostAddr(SingleHostAddr(port: nil, ipv4: nil, ipv6: ipv6))
                } else if let dns = relay.dns {
                    return .singleHostName(SingleHostName(port: nil, dnsName: dns))
                } else if let srv = relay.srv {
                    return .multiHostName(MultiHostName(dnsName: srv))
                }
                return nil
            } ?? []

        // Convert margin (Double) to UnitInterval using 10^8 denominator for precision
        let marginDenom: UInt64 = 100_000_000
        let marginDouble = pool.margin ?? 0.0
        let marginNum = UInt64((marginDouble * Double(marginDenom)).rounded())
        let margin = UnitInterval(numerator: marginNum, denominator: marginDenom)

        let poolOperator = try PoolOperator(from: poolId)
        let vrfKeyHash = VrfKeyHash(payload: Data(hex: pool.vrfKeyHash ?? ""))
        let rewardAddr = pool.rewardAddr ?? ""
        let rewardAddress = try Address(from: .string(rewardAddr))
        let rewardAccount = RewardAccountHash(payload: rewardAddress.toBytes())
        let poolOwnersList: [VerificationKeyHash] = try (pool.owners ?? []).map { ownerBech32 in
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

        var poolMetadata: PoolMetadata? = nil
        if let urlString = pool.metaUrl, let hashString = pool.metaHash,
            let hashData = Data(hexString: hashString)
        {
            poolMetadata = try await PoolMetadata.fetch(
                url: try Url(urlString),
                poolMetadataHash: PoolMetadataHash(payload: hashData)
            )
        }

        let params = PoolParams(
            poolOperator: poolOperator.poolKeyHash,
            vrfKeyHash: vrfKeyHash,
            pledge: Int(UInt64(pool.pledge ?? "0") ?? 0),
            cost: Int(UInt64(pool.fixedCost ?? "0") ?? 0),
            margin: margin,
            rewardAccount: rewardAccount,
            poolOwners: poolOwners,
            relays: relays,
            poolMetadata: poolMetadata
        )

        let livePledge: UInt? = pool.livePledge.flatMap { UInt($0) }
        let liveStake: UInt? = pool.liveStake.flatMap { UInt($0) }
        let activeStake: UInt? = pool.activeStake.flatMap { UInt($0) }
        let activeSize: Decimal? = pool.sigma.map { Decimal($0) }
        let opcertCounter: UInt? = pool.opCertCounter.map { UInt($0) }

        // Map pool status from Koios pool_status field
        let status: PoolStatus?
        switch pool.poolStatus {
        case .registered:
            status = .registered
        case .retiring:
            if let epoch = pool.retiringEpoch {
                status = .retiring(epoch: UInt(epoch))
            } else {
                status = .registered
            }
        case .retired:
            status = .retired
        case nil:
            status = nil
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
        let totalsResponse = try await api.client.totals(
            .init(
                query: .init(
                    _epochNo: String(self.epoch())
                )
            )
        )

        let totalsPayload = try totalsResponse.ok.body.json

        guard totalsPayload.count == 1 else {
            throw CardanoChainError.koiosError(
                "Unexpected response format for totals endpoint: expected 1 item, got \(totalsPayload.count)"
            )
        }

        guard let treasuryStr = totalsPayload[0].treasury else {
            throw CardanoChainError.koiosError("Treasury balance is missing in totals response")
        }

        guard let treasuryInt = UInt64(treasuryStr) else {
            throw CardanoChainError.valueError("Failed to parse treasury balance")
        }

        return Coin(treasuryInt)
    }

    /// Get the DRep information.
    /// - Parameter drep: The `DRep` object.
    /// - Returns: The `DRepInfo` object containing information about the DRep.
    public func drepInfo(drep: DRep) async throws -> DRepInfo {
        let drepId = try drep.id((.bech32, .cip129))
        let response = try await api.client.drepInfo(
            body: .json(.init(_drepIds: [drepId]))
        )
        let payload = try response.ok.body.json

        guard let info = payload.first else {
            return DRepInfo(
                active: false,
                drep: drep,
                anchor: nil,
                deposit: nil,
                stake: Coin(0),
                expiry: nil,
                status: .notRegistered
            )
        }

        let active = info.active ?? false
        let status: DRepStatus?

        switch info.drepStatus {
            case .registered:
                status = .registered
            case .deregistered:
                status = .retired
            case .notRegistered:
                status = .notRegistered
            default:
                status = nil
        }

        let stake: Coin
        if let amountStr = info.amount, let amountInt = UInt64(amountStr) {
            stake = Coin(amountInt)
        } else {
            stake = Coin(0)
        }

        let deposit: Coin?
        if let depositStr = info.deposit, let depositInt = UInt64(depositStr) {
            deposit = Coin(depositInt)
        } else {
            deposit = nil
        }

        let expiry: UInt64? = info.expiresEpochNo.map { UInt64($0) }

        var anchor: Anchor? = nil
        if let urlStr = info.metaUrl, let hashStr = info.metaHash,
            !urlStr.isEmpty, !hashStr.isEmpty,
            let hashData = Data(hexString: hashStr)
        {
            anchor = try? Anchor(
                anchorUrl: Url(urlStr),
                anchorDataHash: AnchorDataHash(payload: hashData)
            )
        }

        return DRepInfo(
            active: active,
            drep: drep,
            anchor: anchor,
            deposit: deposit,
            stake: stake,
            expiry: expiry,
            status: status
        )
    }

    /// Get the governance action information for a given governance action ID.
    /// - Parameter govActionID: The identifier of the governance action.
    /// - Returns: The `GovActionInfo` object containing information about the governance action.
    public func govActionInfo(govActionID: GovActionID) async throws -> GovActionInfo {
        do {
            let proposalRef = try govActionID.id()
            let response = try await api.client.proposalList()
            let proposals = try response.ok.body.json
            let txHash = govActionID.transactionID.payload.toHex.lowercased()
            let proposalIndex = Int(govActionID.govActionIndex)

            guard
                let proposal = proposals.first(where: {
                    if $0.proposalId == proposalRef {
                        return true
                    }

                    let proposalTxHash = ($0.proposalTxHash?.value as? String)?.lowercased()
                    let idx = $0.proposalIndex.map(Int.init)

                    return proposalTxHash == txHash && idx == proposalIndex
                })
            else {
                throw CardanoChainError.valueError("Governance action not found: \(govActionID)")
            }

            let govAction = parseKoiosGovAction(proposal.proposalDescription, id: govActionID)

            return GovActionInfo(
                govActionId: govActionID,
                govAction: govAction,
                proposedIn: proposal.proposedEpoch.map { UInt64($0) },
                expiresAfter: proposal.expiration.map { UInt64($0) },
                ratifiedEpoch: proposal.ratifiedEpoch.map { UInt64($0) },
                enactedEpoch: proposal.enactedEpoch.map { UInt64($0) },
                droppedEpoch: proposal.droppedEpoch.map { UInt64($0) },
                expiredEpoch: proposal.expiredEpoch.map { UInt64($0) }
            )
        } catch {
            throw CardanoChainError.koiosError("Failed to get proposal info: \(error)")
        }
    }

    /// Get the committee member information for a given committee member credential.
    /// - Parameter cold: The `CommitteeColdCredential` object representing the committee member.
    /// - Returns: The `CommitteeMemberInfo` object containing information about the committee member.
    public func committeeMemberInfo(cold: CommitteeColdCredential) async throws
        -> CommitteeMemberInfo
    {
        do {
            let response = try await api.client.committeeInfo()
            let committeeInfo = try response.ok.body.json

            let coldCredentialHex = cold.credential.payload.toHex.lowercased()
            let coldCredentialIsScript: Bool
            switch cold.credential {
            case .scriptHash:
                coldCredentialIsScript = true
            case .verificationKeyHash:
                coldCredentialIsScript = false
            }

            guard
                let member = committeeInfo.members?.first(where: {
                    $0.ccColdHex?.lowercased() == coldCredentialHex
                        && ($0.ccColdHasScript ?? false) == coldCredentialIsScript
                })
            else {
                throw CardanoChainError.valueError(
                    "Committee member not found for credential: \(cold)"
                )
            }

            guard let expirationEpoch = member.expirationEpoch.map(Int.init) else {
                throw CardanoChainError.valueError(
                    "Missing expiration epoch for committee member: \(cold)"
                )
            }

            guard let hotHex = member.ccHotHex, let hotHasScript = member.ccHotHasScript else {
                throw CardanoChainError.valueError(
                    "Committee member does not have an authorized hot credential: \(cold)"
                )
            }

            let hotCredential: CommitteeHotCredential
            if hotHasScript {
                hotCredential = CommitteeHotCredential(
                    credential: .scriptHash(ScriptHash(payload: Data(hex: hotHex)))
                )
            } else {
                hotCredential = CommitteeHotCredential(
                    credential: .verificationKeyHash(
                        VerificationKeyHash(payload: Data(hex: hotHex))
                    )
                )
            }

            let currentEpoch = try await epoch()
            let status: CommitteeMemberStatus
            switch member.status {
                case .authorized:
                    status = expirationEpoch >= currentEpoch ? .active : .expired
                case .notAuthorized, .resigned:
                    status = .expired
                case nil:
                    status = expirationEpoch >= currentEpoch ? .unrecognized : .expired
            }

            return CommitteeMemberInfo(
                coldCredential: cold,
                hotCredential: hotCredential,
                expiration: EpochNumber(expirationEpoch),
                status: status
            )
        } catch let error as CardanoChainError {
            throw error
        } catch {
            throw CardanoChainError.koiosError("Failed to get committee member info: \(error)")
        }
    }

    /// Get the committee member information identified by an authorized hot credential.
    /// - Parameter hot: The `CommitteeHotCredential` the member has authorized.
    /// - Returns: The `CommitteeMemberInfo` object containing information about the committee member.
    public func committeeMemberInfo(hot: CommitteeHotCredential) async throws
        -> CommitteeMemberInfo
    {
        do {
            let response = try await api.client.committeeInfo()
            let committeeInfo = try response.ok.body.json

            let hotHexLower = hot.credential.payload.toHex.lowercased()
            let hotIsScript: Bool
            switch hot.credential {
            case .scriptHash:
                hotIsScript = true
            case .verificationKeyHash:
                hotIsScript = false
            }

            guard
                let member = committeeInfo.members?.first(where: {
                    $0.ccHotHex?.lowercased() == hotHexLower
                        && ($0.ccHotHasScript ?? false) == hotIsScript
                })
            else {
                throw CardanoChainError.valueError(
                    "Committee member not found for hot credential: \(hot)"
                )
            }

            guard let coldHex = member.ccColdHex else {
                throw CardanoChainError.valueError(
                    "Committee entry is missing cold credential hex for hot: \(hot)"
                )
            }
            let coldIsScript = member.ccColdHasScript ?? false
            let coldCredential: CommitteeColdCredential
            if coldIsScript {
                coldCredential = CommitteeColdCredential(
                    credential: .scriptHash(ScriptHash(payload: Data(hex: coldHex)))
                )
            } else {
                coldCredential = CommitteeColdCredential(
                    credential: .verificationKeyHash(
                        VerificationKeyHash(payload: Data(hex: coldHex))
                    )
                )
            }

            guard let expirationEpoch = member.expirationEpoch.map(Int.init) else {
                throw CardanoChainError.valueError(
                    "Missing expiration epoch for committee member: \(coldCredential)"
                )
            }

            let currentEpoch = try await epoch()
            let status: CommitteeMemberStatus
            switch member.status {
                case .authorized:
                    status = expirationEpoch >= currentEpoch ? .active : .expired
                case .notAuthorized, .resigned:
                    status = .expired
                case nil:
                    status = expirationEpoch >= currentEpoch ? .unrecognized : .expired
            }

            return CommitteeMemberInfo(
                coldCredential: coldCredential,
                hotCredential: hot,
                expiration: EpochNumber(expirationEpoch),
                status: status
            )
        } catch let error as CardanoChainError {
            throw error
        } catch {
            throw CardanoChainError.koiosError(
                "Failed to get committee member info by hot credential: \(error)")
        }
    }

    // MARK: - Votes / Governance State

    public func govActionVotes(govActionID: GovActionID) async throws -> GovActionVotes {
        let proposalIdBech32 = try govActionID.id()
        let proposalResponse = try await api.client.proposalList()
        let proposals = try proposalResponse.ok.body.json

        let txHashLower = govActionID.transactionID.payload.toHex.lowercased()
        let idx = Int(govActionID.govActionIndex)

        guard let proposal = proposals.first(where: { p in
            if p.proposalId == proposalIdBech32 { return true }
            let pTx = (p.proposalTxHash?.value as? String)?.lowercased()
            let pIdx = p.proposalIndex.map(Int.init)
            return pTx == txHashLower && pIdx == idx
        }) else {
            throw CardanoChainError.valueError("Governance action not found: \(govActionID)")
        }

        return try await buildKoiosGovActionVotes(
            govActionID: govActionID,
            proposal: proposal,
            proposalIdBech32: proposalIdBech32
        )
    }

    public func govActionsAll() async throws -> [GovActionVotes] {
        let response = try await api.client.proposalList()
        let proposals = try response.ok.body.json

        var results: [GovActionVotes] = []
        for proposal in proposals {
            guard let txHashRaw = proposal.proposalTxHash?.value as? String else { continue }
            let idx: Int = proposal.proposalIndex.map(Int.init) ?? 0
            let govActionID = GovActionID(
                transactionID: TransactionId(payload: Data(hex: txHashRaw)),
                govActionIndex: UInt16(idx)
            )
            let proposalIdBech32 = proposal.proposalId ?? (try? govActionID.id()) ?? ""
            if let votes = try? await buildKoiosGovActionVotes(
                govActionID: govActionID,
                proposal: proposal,
                proposalIdBech32: proposalIdBech32
            ) {
                results.append(votes)
            }
        }
        return results
    }

    /// Shared mapping logic: given an already-fetched Koios proposal row, fetch its votes
    /// and assemble a `GovActionVotes`. Reused by both `govActionVotes(govActionID:)` and
    /// `govActionsAll()` to avoid the N+1 of refetching `proposalList()` per action.
    private func buildKoiosGovActionVotes(
        govActionID: GovActionID,
        proposal: Components.Schemas.ProposalListPayload,
        proposalIdBech32: String
    ) async throws -> GovActionVotes {
        let govAction = parseKoiosGovAction(proposal.proposalDescription, id: govActionID)

        // deposit / returnAddress / anchor straight from the proposal row.
        let deposit = Coin(GovernanceParsing.parseLovelace(proposal.deposit?.value) ?? 0)
        let returnAddrData: Data = {
            guard let s = proposal.returnAddress else { return Data() }
            return (try? Address.fromBech32(s).toBytes()) ?? Data()
        }()
        let anchor: SwiftCardanoCore.Anchor? = {
            guard let urlStr = proposal.metaUrl?.value as? String,
                  let hashStr = proposal.metaHash?.value as? String,
                  let url = try? Url(urlStr)
            else { return nil }
            return SwiftCardanoCore.Anchor(
                anchorUrl: url,
                anchorDataHash: AnchorDataHash(payload: Data(hex: hashStr))
            )
        }()

        // Vote list for this proposal.
        let votesResponse = try await api.client.proposalVotes(
            .init(query: .init(_proposalId: proposalIdBech32))
        )
        let voteRows = try votesResponse.ok.body.json

        var committeeVotes: [SwiftCardanoNetwork.CommitteeVote] = []
        var dRepVotes: [SwiftCardanoNetwork.DRepVote] = []
        var stakePoolVotes: [SwiftCardanoNetwork.StakePoolVote] = []

        for row in voteRows {
            guard let role = row.voterRole,
                  let hotOrPoolHex = row.voterHex,
                  let voteRaw = row.vote?.value as? String,
                  let vote = GovernanceParsing.parseVote(voteRaw) else { continue }

            let isScript = (row.voterHasScript?.value as? Bool) ?? false

            switch role {
            case .constitutionalCommittee:
                let cred: CommitteeHotCredential = isScript
                    ? CommitteeHotCredential(credential: .scriptHash(ScriptHash(payload: Data(hex: hotOrPoolHex))))
                    : CommitteeHotCredential(credential: .verificationKeyHash(VerificationKeyHash(payload: Data(hex: hotOrPoolHex))))
                committeeVotes.append(.init(credential: cred, vote: vote))
            case .dRep:
                let cred: DRepCredential = isScript
                    ? DRepCredential(credential: .scriptHash(ScriptHash(payload: Data(hex: hotOrPoolHex))))
                    : DRepCredential(credential: .verificationKeyHash(VerificationKeyHash(payload: Data(hex: hotOrPoolHex))))
                dRepVotes.append(.init(credential: cred, vote: vote))
            case .spo:
                if let poolBech32 = row.voterId,
                   let pool = try? PoolOperator(from: .string(poolBech32)) {
                    stakePoolVotes.append(.init(poolOperator: pool, vote: vote))
                }
            }
        }

        return GovActionVotes(
            govActionId: govActionID,
            govAction: govAction,
            committeeVotes: committeeVotes,
            dRepVotes: dRepVotes,
            stakePoolVotes: stakePoolVotes,
            deposit: deposit,
            depositReturnAddr: returnAddrData,
            anchor: anchor,
            proposedIn: proposal.proposedEpoch.map { UInt64($0) },
            expiresAfter: proposal.expiration.map { UInt64($0) },
            ratifiedEpoch: proposal.ratifiedEpoch.map { UInt64($0) },
            enactedEpoch: proposal.enactedEpoch.map { UInt64($0) },
            droppedEpoch: proposal.droppedEpoch.map { UInt64($0) },
            expiredEpoch: proposal.expiredEpoch.map { UInt64($0) }
        )
    }

    public func committeeState() async throws -> CommitteeStateInfo {
        let response = try await api.client.committeeInfo()
        let committeeInfo = try response.ok.body.json

        let currentEpoch = try await epoch()

        let members: [CommitteeStateInfo.Member] = (committeeInfo.members ?? []).compactMap { m in
            guard let coldHex = m.ccColdHex else { return nil }
            let coldIsScript = m.ccColdHasScript ?? false

            let cold: CommitteeColdCredential = coldIsScript
                ? CommitteeColdCredential(credential: .scriptHash(ScriptHash(payload: Data(hex: coldHex))))
                : CommitteeColdCredential(credential: .verificationKeyHash(VerificationKeyHash(payload: Data(hex: coldHex))))

            let hot: CommitteeHotCredential? = {
                guard let hotHex = m.ccHotHex else { return nil }
                let isScript = m.ccHotHasScript ?? false
                return isScript
                    ? CommitteeHotCredential(credential: .scriptHash(ScriptHash(payload: Data(hex: hotHex))))
                    : CommitteeHotCredential(credential: .verificationKeyHash(VerificationKeyHash(payload: Data(hex: hotHex))))
            }()

            let expirationEpoch = m.expirationEpoch.map { Int($0) }
            let status: CommitteeMemberStatus = {
                switch m.status {
                case .authorized:
                    return (expirationEpoch ?? -1) >= currentEpoch ? .active : .expired
                case .notAuthorized, .resigned:
                    return .expired
                case nil:
                    return (expirationEpoch ?? -1) >= currentEpoch ? .unrecognized : .expired
                }
            }()

            return CommitteeStateInfo.Member(
                coldCredential: cold,
                hotCredential: hot,
                expiration: expirationEpoch.map { EpochNumber($0) },
                status: status
            )
        }

        let threshold: Double = {
            guard let num = committeeInfo.quorumNumerator,
                  let den = committeeInfo.quorumDenominator,
                  den != 0 else { return 0.0 }
            return num / den
        }()

        return CommitteeStateInfo(members: members, threshold: threshold)
    }

    // MARK: - GovAction parsing

    /// Parse a Koios `proposal_description` (an OpenAPI generic JSON object)
    /// into a real `GovAction`. The shape matches cardano-cli's
    /// `proposalProcedure.govAction` (tag + contents) — Koios indexes the
    /// ledger-state output. When the description is missing or unparseable
    /// we surface the variant as `.infoAction` so callers can detect the
    /// gap via the variant tag rather than via fabricated inner data.
    private func parseKoiosGovAction(
        _ description: OpenAPIRuntime.OpenAPIObjectContainer?,
        id: GovActionID
    ) -> GovAction {
        guard let value = description?.value as? [String: Any],
              let tag = value["tag"] as? String
        else { return .infoAction(InfoAction()) }

        let contents = value["contents"] as? [Any] ?? []

        switch tag {
        case "ParameterChange":
            // TODO: walk contents[1] and map ProposedProtocolParameters → ProtocolParamUpdate.
            return .parameterChangeAction(ParameterChangeAction(
                id: id,
                protocolParamUpdate: ProtocolParamUpdate(),
                policyHash: nil
            ))

        case "HardForkInitiation":
            guard contents.count >= 2,
                  let versionDict = contents[1] as? [String: Any],
                  let major = versionDict["major"] as? Int,
                  let minor = versionDict["minor"] as? Int
            else { return .infoAction(InfoAction()) }
            return .hardForkInitiationAction(HardForkInitiationAction(
                id: nil,
                protocolVersion: ProtocolVersion(major: major, minor: minor)
            ))

        case "TreasuryWithdrawals":
            // contents = [[[{network, credential}, lovelace], ...], policyHash]
            var withdrawals: [RewardAccount: Coin] = [:]
            if let pairs = contents.first as? [[Any]] {
                for entry in pairs where entry.count >= 2 {
                    guard let wrapper = entry[0] as? [String: Any],
                          let lovelace = GovernanceParsing.parseLovelace(entry[1]),
                          let returnAddr = buildKoiosRewardAccount(wrapper)
                    else { continue }
                    withdrawals[returnAddr] = Coin(lovelace)
                }
            }
            let policyHash: ScriptHash? = {
                guard contents.count > 1,
                      let hex = contents[1] as? String,
                      !hex.isEmpty
                else { return nil }
                return try? ScriptHash(from: .string(hex))
            }()
            return .treasuryWithdrawalsAction(TreasuryWithdrawalsAction(
                withdrawals: withdrawals,
                policyHash: policyHash
            ))

        case "NoConfidence":
            return .noConfidence(NoConfidence(id: id))

        case "UpdateCommittee":
            // contents = [prevGovActionId, [removed], {added}, quorum]
            var coldCredentials: Set<CommitteeColdCredential> = []
            var credentialEpochs: [CommitteeColdCredential: UInt64] = [:]
            if contents.count >= 2, let removed = contents[1] as? [Any] {
                for entry in removed {
                    if let cred = parseKoiosColdCredential(entry) {
                        coldCredentials.insert(cred)
                    }
                }
            }
            if contents.count >= 3, let added = contents[2] as? [String: Any] {
                for (key, value) in added {
                    guard let cred = parseKoiosColdCredentialKey(key),
                          let epoch = (value as? NSNumber)?.uint64Value
                              ?? (value as? Int).map(UInt64.init)
                    else { continue }
                    coldCredentials.insert(cred)
                    credentialEpochs[cred] = epoch
                }
            }
            let interval: UnitInterval = {
                guard contents.count >= 4 else {
                    return UnitInterval(numerator: 0, denominator: 1)
                }
                if let dict = contents[3] as? [String: Any],
                   let num = (dict["numerator"] as? NSNumber)?.uint64Value
                       ?? (dict["numerator"] as? Int).map(UInt64.init),
                   let den = (dict["denominator"] as? NSNumber)?.uint64Value
                       ?? (dict["denominator"] as? Int).map(UInt64.init),
                   den != 0 {
                    return UnitInterval(numerator: num, denominator: den)
                }
                if let arr = contents[3] as? [Any], arr.count == 2,
                   let num = (arr[0] as? NSNumber)?.uint64Value
                       ?? (arr[0] as? Int).map(UInt64.init),
                   let den = (arr[1] as? NSNumber)?.uint64Value
                       ?? (arr[1] as? Int).map(UInt64.init),
                   den != 0 {
                    return UnitInterval(numerator: num, denominator: den)
                }
                return UnitInterval(numerator: 0, denominator: 1)
            }()
            return .updateCommittee(UpdateCommittee(
                id: id,
                coldCredentials: coldCredentials,
                credentialEpochs: credentialEpochs,
                interval: interval
            ))

        case "NewConstitution":
            guard contents.count >= 2,
                  let constitution = contents[1] as? [String: Any],
                  let anchorDict = constitution["anchor"] as? [String: Any],
                  let urlString = anchorDict["url"] as? String,
                  let url = try? Url(urlString)
            else { return .infoAction(InfoAction()) }
            let dataHashHex = (anchorDict["dataHash"] as? String)
                ?? (anchorDict["anchorDataHash"] as? String)
                ?? ""
            let anchor = Anchor(
                anchorUrl: url,
                anchorDataHash: AnchorDataHash(payload: dataHashHex.hexStringToData)
            )
            let scriptHash: ScriptHash? = {
                guard let hex = constitution["script"] as? String, !hex.isEmpty
                else { return nil }
                return try? ScriptHash(from: .string(hex))
            }()
            return .newConstitution(NewConstitution(
                id: id,
                constitution: Constitution(anchor: anchor, scriptHash: scriptHash)
            ))

        case "InfoAction":
            return .infoAction(InfoAction())

        default:
            return .infoAction(InfoAction())
        }
    }

    /// Koios's TreasuryWithdrawals credential wrapper is
    /// `{network: "Mainnet" | "Testnet", credential: {keyHash | scriptHash}}`.
    private func buildKoiosRewardAccount(_ wrapper: [String: Any]) -> RewardAccount? {
        guard let credential = wrapper["credential"] as? [String: Any] else { return nil }
        let isTestnet = (wrapper["network"] as? String)?.lowercased() == "testnet"
        if let hex = credential["keyHash"] as? String {
            // 0xE0 = mainnet+keyHash, 0xE2 = testnet+keyHash header byte.
            var data = Data([isTestnet ? 0xE0 : 0xE0])
            data.append(hex.hexStringToData)
            return RewardAccount(data)
        }
        if let hex = credential["scriptHash"] as? String {
            // 0xE1 = mainnet+scriptHash, 0xE3 = testnet+scriptHash header byte.
            var data = Data([isTestnet ? 0xE1 : 0xE1])
            data.append(hex.hexStringToData)
            return RewardAccount(data)
        }
        return nil
    }

    /// Koios cold credentials can be either a bare `{keyHash | scriptHash}` dict
    /// or a stringified `keyHash-<hex>` / `scriptHash-<hex>` form.
    private func parseKoiosColdCredential(_ any: Any) -> CommitteeColdCredential? {
        if let key = any as? String { return parseKoiosColdCredentialKey(key) }
        guard let dict = any as? [String: Any] else { return nil }
        if let hex = dict["keyHash"] as? String {
            return CommitteeColdCredential(
                credential: .verificationKeyHash(VerificationKeyHash(payload: hex.hexStringToData))
            )
        }
        if let hex = dict["scriptHash"] as? String {
            return CommitteeColdCredential(
                credential: .scriptHash(ScriptHash(payload: hex.hexStringToData))
            )
        }
        return nil
    }

    private func parseKoiosColdCredentialKey(_ key: String) -> CommitteeColdCredential? {
        if key.hasPrefix("keyHash-") {
            let hex = String(key.dropFirst("keyHash-".count))
            return CommitteeColdCredential(
                credential: .verificationKeyHash(VerificationKeyHash(payload: hex.hexStringToData))
            )
        }
        if key.hasPrefix("scriptHash-") {
            let hex = String(key.dropFirst("scriptHash-".count))
            return CommitteeColdCredential(
                credential: .scriptHash(ScriptHash(payload: hex.hexStringToData))
            )
        }
        return nil
    }
}
