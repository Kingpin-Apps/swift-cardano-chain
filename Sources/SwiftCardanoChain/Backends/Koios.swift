import Foundation
import OpenAPIRuntime
import PotentCBOR
import SwiftCardanoCore
import SwiftKoios

/// A `Koios <https://www.koios.rest/>`_ API wrapper for the client code to interact with.
///
/// - Parameters:
///   - apiKey: A Koios API Key obtained from https://www.koios.rest.
///   - network: Network to use.
///   - baseUrl: Base URL for the Koios API. Defaults to the mainnet url.
public class KoiosChainContext: ChainContext {

    // MARK: - Properties

    public var name: String { "Koios" }
    public var type: ContextType { .online }

    public var api: Koios
    private var epochInfo: Components.Schemas.EpochInfoPayload?
    private var _epoch: Int?
    private var _genesisParameters: GenesisParameters?
    private var _protocolParameters: ProtocolParameters?
    private let _network: SwiftCardanoCore.Network

    public var networkId: NetworkId {
        self._network.networkId
    }

    public lazy var era: () async throws -> Era? = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }

        return Era.fromEpoch(epoch: EpochNumber(try await self.epoch()))
    }

    public lazy var epoch: () async throws -> Int = { [weak self] in
        guard let self = self else {
            throw CardanoChainError.koiosError("Self is nil")
        }

        if try await self.checkEpochAndUpdate() || self._epoch == nil {
            do {
                let response = try await api.client.epochInfo()
                self.epochInfo = try response.ok.body.json.first
                self._epoch = Int(self.epochInfo?.epochNo ?? 0)
            } catch {
                throw CardanoChainError.koiosError("Failed to get epoch info: \(error)")
            }
        }
        return self._epoch ?? 0
    }

    public lazy var lastBlockSlot: () async throws -> Int = { [weak self] in
        guard let self = self else {
            throw CardanoChainError.koiosError("Self is nil")
        }

        do {
            let response = try await api.client.tip()
            return try response.ok.body.json.first?.absSlot?.value as? Int ?? 0
        } catch {
            throw CardanoChainError.koiosError("Failed to get tip: \(error)")
        }
    }

    public lazy var genesisParameters: () async throws -> GenesisParameters = { [weak self] in
        guard let self = self else {
            throw CardanoChainError.koiosError("Self is nil")
        }

        if try await self.checkEpochAndUpdate() || self._genesisParameters == nil {
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

                self._genesisParameters = GenesisParameters(
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
        return self._genesisParameters!
    }

    public lazy var protocolParameters: () async throws -> ProtocolParameters = { [weak self] in
        guard let self = self else {
            throw CardanoChainError.koiosError("Self is nil")
        }

        if try await self.checkEpochAndUpdate() || self._protocolParameters == nil {
            self._protocolParameters = try await self.queryCurrentProtocolParams()
        }

        return self._protocolParameters!
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
    public func queryChainTip() async throws -> ChainTip {
        do {
            let response = try await api.client.tip()
            let json = try response.ok.body.json

            guard let tip = json.first else {
                throw CardanoChainError.koiosError("Tip response was empty")
            }

            return ChainTip(
                block: Int(tip.blockNo ?? 0),
                epoch: tip.epochNo?.value as? Int,
                era: nil,
                hash: tip.hash?.value as? String,
                slot: tip.absSlot?.value as? Int,
                slotInEpoch: tip.epochSlot?.value as? Int,
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

    private func checkEpochAndUpdate() async throws -> Bool {
        if let epochTime = self.epochInfo?.endTime, Date().timeIntervalSince1970 < epochTime {
            return false
        }

        do {
            let response = try await api.client.epochInfo()
            self.epochInfo = try response.ok.body.json.first
        } catch {
            throw
                CardanoChainError
                .koiosError("Failed to get epoch info: \(error)")
        }
        return true
    }

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
                                multiAssets[policyId]?[assetName] = Int(quantity) ?? 0
                            }
                        }
                    }
                }

                let amount = Value(
                    coin: Int(lovelaceAmount),
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
                                mem: memory,
                                steps: cpu
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
                let info = StakeAddressInfo(
                    active: stakeInfo.status == .registered,
                    address: (stakeInfo.stakeAddress?.value as? String) ?? "",
                    rewardAccountBalance: Int(stakeInfo.rewardsAvailable ?? "0") ?? 0,
                    stakeDelegation: try PoolOperator(
                        from: stakeInfo.delegatedPool ?? ""
                    ),
                    voteDelegation: try DRep(
                        from: stakeInfo.delegatedDrep ?? ""
                    )
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
    public func stakePools() async throws -> [String] {
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
            let poolIds = poolList.compactMap {
                $0.poolIdBech32?.value as? String
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
    /// - Returns: `PoolParams` object.
    /// - Throws: `CardanoChainError.koiosError` if the pool info cannot be fetched.
    public func stakePoolInfo(poolId: String) async throws -> PoolParams {
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
            poolMetadata = try PoolMetadata(
                url: try Url(urlString),
                poolMetadataHash: PoolMetadataHash(payload: hashData)
            )
        }

        return PoolParams(
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
    }
}
