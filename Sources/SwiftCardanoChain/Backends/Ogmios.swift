import Foundation
import PotentCBOR
import SwiftCardanoCore
import SwiftCardanoUtils
import SwiftOgmios
import SystemPackage

/// A chain context implementation using the Ogmios WebSocket/HTTP API.
///
/// `OgmiosChainContext` provides a full implementation of the `ChainContext` protocol
/// using the [Ogmios](https://ogmios.dev) server as the data source. Ogmios is a lightweight
/// bridge interface for Cardano that exposes the Ouroboros mini-protocols through a WebSocket
/// and HTTP API.
///
/// ## Overview
///
/// This context supports all chain interaction operations including:
/// - Querying UTxOs, protocol parameters, and genesis parameters
/// - Submitting and evaluating transactions
/// - Querying stake address information and stake pools
///
/// ## Creating a Context
///
/// ```swift
/// // Connect to a local Ogmios instance
/// let context = try await OgmiosChainContext(
///     host: "localhost",
///     port: 1337,
///     network: .mainnet
/// )
///
/// // Or inject an existing client
/// let existingClient = try await OgmiosClient(host: "localhost", port: 1337)
/// let context = try await OgmiosChainContext(
///     network: .mainnet,
///     client: existingClient
/// )
/// ```
///
/// ## Topics
///
/// ### Creating a Context
/// - ``init(host:port:path:secure:httpOnly:rpcVersion:network:client:)``
///
/// ### Querying Chain State
/// - ``utxos(address:)``
/// - ``stakeAddressInfo(address:)``
/// - ``stakePools()``
///
/// ### Transaction Operations
/// - ``submitTxCBOR(cbor:)``
/// - ``evaluateTxCBOR(cbor:)``
public class OgmiosChainContext: ChainContext {

    // MARK: - Properties

    /// The name identifier for this chain context.
    public var name: String { "Ogmios" }

    public var type: ContextType { .online }

    /// The underlying Ogmios client used for all API calls.
    public var client: OgmiosClient

    private var _epoch: Int?
    private var _genesisParameters: GenesisParameters?
    private var _protocolParameters: SwiftCardanoCore.ProtocolParameters?
    private var lastEpochFetch: TimeInterval = 0
    private let _network: SwiftCardanoCore.Network

    /// The network identifier for this context.
    public var networkId: NetworkId {
        self._network.networkId
    }

    /// Returns the current era based on the current epoch.
    ///
    /// The era is derived from the epoch number using `Era.fromEpoch()`.
    public lazy var era: () async throws -> SwiftCardanoCore.Era? = { [weak self] in
        guard let self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }

        return SwiftCardanoCore.Era.fromEpoch(epoch: EpochNumber(try await self.epoch()))
    }

    /// Returns the current epoch number.
    ///
    /// The epoch is cached and refreshed periodically to avoid unnecessary API calls.
    public lazy var epoch: () async throws -> Int = { [weak self] in
        guard let self = self else {
            throw CardanoChainError.operationError("Self is nil")
        }

        // Refresh epoch if cache is stale (older than 60 seconds)
        if self._epoch == nil || (Date().timeIntervalSince1970 - self.lastEpochFetch) > 60 {
            let response = try await self.client.ledgerStateQuery.epoch.result()
            self._epoch = Int(response)
            self.lastEpochFetch = Date().timeIntervalSince1970
        }

        return self._epoch ?? 0
    }

    /// Returns the slot number of the most recent block.
    ///
    /// Queries the current tip of the ledger to get the latest slot.
    public lazy var lastBlockSlot: () async throws -> Int = { [weak self] in
        guard let self = self else {
            throw CardanoChainError.operationError("Self is nil")
        }

        let response = try await self.client.ledgerStateQuery.tip.result()

        switch response {
        case .origin:
            return 0
        case .point(let point):
            return Int(point.slot)
        }
    }

    /// Returns the genesis parameters for the network.
    ///
    /// Genesis parameters are cached after the first fetch since they never change
    /// during the lifetime of the network.
    public lazy var genesisParameters: () async throws -> GenesisParameters = { [weak self] in
        guard let self = self else {
            throw CardanoChainError.operationError("Self is nil")
        }

        if self._genesisParameters == nil {
            let genesisParams = QueryNetworkGenesisConfiguration.Params(era: .shelley)
            let response = try await self.client.networkQuery.genesisConfiguration.result(
                params: genesisParams
            )

            switch response {
            case .shelley(let genesis):
                // Parse activeSlotsCoefficient string (e.g., "1/20") to Double
                let activeSlots = self.parseRatioString(genesis.activeSlotsCoefficient) ?? 0.05

                // Parse startTime string to Date
                let formatter = ISO8601DateFormatter()
                let systemStartDate = formatter.date(from: genesis.startTime) ?? Date()

                self._genesisParameters = GenesisParameters(
                    activeSlotsCoefficient: activeSlots,
                    epochLength: Int(genesis.epochLength),
                    maxKesEvolutions: Int(genesis.maxKesEvolutions),
                    maxLovelaceSupply: Int(genesis.maxLovelaceSupply),
                    networkId: self._network.description,
                    networkMagic: Int(genesis.networkMagic),
                    securityParam: Int(genesis.securityParameter),
                    slotLength: Int(genesis.slotLength.milliseconds / 1000),
                    slotsPerKesPeriod: Int(genesis.slotsPerKesPeriod),
                    systemStart: systemStartDate,
                    updateQuorum: Int(genesis.updateQuorum)
                )
            default:
                throw CardanoChainError.operationError("Unexpected genesis configuration era")
            }
        }

        return self._genesisParameters!
    }

    /// Returns the current protocol parameters.
    ///
    /// Protocol parameters are cached per epoch and automatically refreshed
    /// when the epoch changes.
    public lazy var protocolParameters: () async throws -> SwiftCardanoCore.ProtocolParameters = {
        [weak self] in
        guard let self = self else {
            throw CardanoChainError.operationError("Self is nil")
        }

        // Refresh if epoch changed or not cached
        let currentEpoch = try await self.epoch()
        if self._protocolParameters == nil || self._epoch != currentEpoch {
            self._protocolParameters = try await self.queryCurrentProtocolParams()
        }

        return self._protocolParameters!
    }

    // MARK: - Initialization

    /// Creates a new Ogmios chain context.
    ///
    /// - Parameters:
    ///   - host: The hostname of the Ogmios server. Defaults to configuration or "localhost".
    ///   - port: The port number of the Ogmios server. Defaults to configuration or 1337.
    ///   - path: Additional path component for the server URL. Defaults to empty string.
    ///   - secure: Whether to use TLS encryption (WSS/HTTPS). Defaults to false.
    ///   - httpOnly: Whether to use HTTP transport only (no WebSocket). Defaults to false.
    ///   - rpcVersion: JSON-RPC version to use. Defaults to "2.0".
    ///   - network: The Cardano network to connect to. Defaults to `.mainnet`.
    ///   - client: An existing `OgmiosClient` to use. If provided, other connection parameters are ignored.
    ///
    /// - Throws: `CardanoChainError.operationError` if the connection fails.
    ///
    /// ## Example
    /// ```swift
    /// // Connect to local Ogmios
    /// let context = try await OgmiosChainContext(
    ///     host: "localhost",
    ///     port: 1337,
    ///     network: .preview
    /// )
    ///
    /// // Connect to remote Ogmios with TLS
    /// let secureContext = try await OgmiosChainContext(
    ///     host: "ogmios.example.com",
    ///     port: 443,
    ///     secure: true,
    ///     network: .mainnet
    /// )
    /// ```
    public init(
        host: String? = nil,
        port: Int? = nil,
        path: String? = nil,
        secure: Bool? = nil,
        httpOnly: Bool? = nil,
        rpcVersion: String? = nil,
        network: SwiftCardanoCore.Network = .mainnet,
        client: OgmiosClient? = nil
    ) async throws {
        self._network = network

        if let client = client {
            self.client = client
        } else if let host = host, let port = port {
            self.client = try await OgmiosClient(
                host: host,
                port: port,
                path: path ?? "",
                secure: secure ?? false,
                httpOnly: httpOnly ?? false,
                rpcVersion: rpcVersion ?? "2.0"
            )
        } else {
            let ogmiosConfig = try Config.default().ogmios!
            self.client = try await OgmiosClient(
                host: ogmiosConfig.host ?? "localhost",
                port: ogmiosConfig.port ?? 1337
            )
        }
    }

    // MARK: - Public Methods

    /// Queries the current chain tip.
    ///
    /// - Returns: A `ChainTip` object containing block height, slot, epoch, and other tip information.
    /// - Throws: `CardanoChainError.operationError` if the query fails.
    public func queryChainTip() async throws -> ChainTip {
        let response = try await client.ledgerStateQuery.tip.result()

        switch response {
        case .origin:
            return ChainTip(
                block: 0,
                epoch: 0,
                era: nil,
                hash: nil,
                slot: 0,
                slotInEpoch: nil,
                slotsToEpochEnd: nil,
                syncProgress: nil
            )
        case .point(let point):
            let currentEpoch = try await epoch()
            return ChainTip(
                block: nil,
                epoch: currentEpoch,
                era: nil,
                hash: point.id.description,
                slot: Int(point.slot),
                slotInEpoch: nil,
                slotsToEpochEnd: nil,
                syncProgress: nil
            )
        }
    }

    /// Queries the current protocol parameters from Ogmios.
    ///
    /// - Returns: A `ProtocolParameters` object containing all current protocol parameters.
    /// - Throws: `CardanoChainError.operationError` if the query fails.
    public func queryCurrentProtocolParams() async throws -> SwiftCardanoCore.ProtocolParameters {
        let params = try await client.ledgerStateQuery.protocolParameters.result()

        // Convert SwiftOgmios.ProtocolParameters to SwiftCardanoCore.ProtocolParameters
        return try convertProtocolParameters(params)
    }

    // MARK: - ChainContext Protocol Methods

    /// Gets all UTxOs for a given address.
    ///
    /// - Parameter address: The Cardano address to query UTxOs for.
    /// - Returns: An array of `UTxO` objects associated with the address.
    /// - Throws: `CardanoChainError.operationError` if the query fails.
    ///
    /// ## Example
    /// ```swift
    /// let address = try Address(from: .string("addr_test1..."))
    /// let utxos = try await context.utxos(address: address)
    ///
    /// for utxo in utxos {
    ///     print("UTxO: \(utxo.input.transactionId.payload.toHex)#\(utxo.input.index)")
    ///     print("Value: \(utxo.output.amount.coin) lovelace")
    /// }
    /// ```
    public func utxos(address: SwiftCardanoCore.Address) async throws -> [SwiftCardanoCore.UTxO] {
        let ogmiosAddress = SwiftOgmios.Address(try address.toBech32())
        let response = try await client.ledgerStateQuery.utxo.result(
            addresses: [ogmiosAddress]
        )

        return try response.map { entry in
            try convertUtxoEntry(entry)
        }
    }

    /// Submits a serialized transaction to the blockchain.
    ///
    /// - Parameter cbor: The CBOR-encoded transaction data.
    /// - Returns: The transaction ID (hash) of the submitted transaction.
    /// - Throws: `CardanoChainError.transactionFailed` if the submission fails.
    ///
    /// ## Example
    /// ```swift
    /// let txCbor = signedTransaction.toCBORData()
    /// let txId = try await context.submitTxCBOR(cbor: txCbor)
    /// print("Transaction submitted: \(txId)")
    /// ```
    public func submitTxCBOR(cbor: Data) async throws -> String {
        let cborHex = cbor.toHex
        let transaction = SubmitTransaction.Params.Transaction(cbor: cborHex)
        let submitParams = SubmitTransaction.Params(transaction: transaction)

        let response = try await client.transactionSubmission.submitTransaction.result(
            params: submitParams
        )

        return response.transaction.id
    }

    /// Evaluates execution units for a transaction.
    ///
    /// - Parameter cbor: The CBOR-encoded transaction data.
    /// - Returns: A dictionary mapping redeemer pointers to their execution units.
    /// - Throws: `CardanoChainError.operationError` if evaluation fails.
    ///
    /// ## Example
    /// ```swift
    /// let executionUnits = try await context.evaluateTxCBOR(cbor: txCbor)
    /// for (redeemer, units) in executionUnits {
    ///     print("\(redeemer): \(units.mem) mem, \(units.steps) steps")
    /// }
    /// ```
    public func evaluateTxCBOR(cbor: Data) async throws -> [String: SwiftCardanoCore.ExecutionUnits]
    {
        let cborHex = cbor.toHex
        let txCbor = TransactionCBOR(cbor: cborHex)
        let evalParams = EvaluateTransaction.Params(transaction: txCbor)

        let response = try await client.transactionSubmission.evaluateTransaction.result(
            params: evalParams
        )

        var result: [String: SwiftCardanoCore.ExecutionUnits] = [:]

        for evalResult in response {
            let key = "\(evalResult.validator.purpose.rawValue):\(evalResult.validator.index)"
            result[key] = SwiftCardanoCore.ExecutionUnits(
                mem: Int(evalResult.budget.memory),
                steps: Int(evalResult.budget.cpu)
            )
        }

        return result
    }

    /// Gets stake address information for a given address.
    ///
    /// - Parameter address: The stake address to query.
    /// - Returns: An array of `StakeAddressInfo` objects.
    /// - Throws: `CardanoChainError.operationError` if the query fails.
    ///
    /// ## Example
    /// ```swift
    /// let stakeAddr = try Address(from: .string("stake_test1..."))
    /// let info = try await context.stakeAddressInfo(address: stakeAddr)
    ///
    /// for stakeInfo in info {
    ///     print("Rewards: \(stakeInfo.rewardAccountBalance) lovelace")
    ///     if let pool = stakeInfo.stakeDelegation {
    ///         print("Delegated to: \(try pool.id())")
    ///     }
    /// }
    /// ```
    public func stakeAddressInfo(address: SwiftCardanoCore.Address) async throws
        -> [StakeAddressInfo]
    {
        // Extract the stake credential from the address
        guard let stakePart = address.stakingPart else {
            throw CardanoChainError.invalidArgument("Address does not have a staking part")
        }

        let credentialHex: String
        switch stakePart {
        case .verificationKeyHash(let hash):
            credentialHex = hash.payload.toHex
        case .scriptHash(let hash):
            credentialHex = hash.payload.toHex
        case .pointerAddress:
            throw CardanoChainError.invalidArgument(
                "Pointer addresses not supported for stake info")
        }

        let credential = try EncodingBase16(credentialHex)
        let rewardParams = QueryLedgerStateRewardAccountSummaries.Params(keys: [.base16(credential)]
        )
        let response = try await client.ledgerStateQuery.rewardAccountSummaries.result(
            params: rewardParams
        )

        return try response.map { summary in
            var stakeDelegation: PoolOperator? = nil
            if let stakePool = summary.stakePool {
                stakeDelegation = try PoolOperator(from: stakePool.id.description)
            }

            var voteDelegation: DRep? = nil
            if let dRep = summary.delegateRepresentative {
                switch dRep {
                case .registered(let registered):
                    voteDelegation = try DRep(from: registered.id.description)
                case .noConfidence:
                    voteDelegation = DRep(credential: .alwaysNoConfidence)
                case .abstain:
                    voteDelegation = DRep(credential: .alwaysAbstain)
                }
            }

            return StakeAddressInfo(
                active: true,  // If we get a summary, the account is active
                address: try address.toBech32(),
                rewardAccountBalance: Int(summary.rewards.ada.lovelace),
                stakeDelegation: stakeDelegation,
                voteDelegation: voteDelegation
            )
        }
    }

    /// Gets the list of all registered stake pools.
    ///
    /// - Returns: An array of stake pool IDs in Bech32 format.
    /// - Throws: `CardanoChainError.operationError` if the query fails.
    ///
    /// ## Example
    /// ```swift
    /// let pools = try await context.stakePools()
    /// print("Found \(pools.count) stake pools")
    /// for poolId in pools.prefix(5) {
    ///     print("Pool: \(poolId)")
    /// }
    /// ```
    public func stakePools() async throws -> [String] {
        let response = try await client.ledgerStateQuery.stakePools.result()
        return response.keys.map { $0.value }
    }

    /// Get the KES period information for a stake pool via Ogmios.
    ///
    /// Queries the Ogmios server's ledger state for operational certificate counters.
    /// This uses the `ledgerStateQuery.operationalCertificates` endpoint to retrieve
    /// the on-chain certificate counter for the specified pool.
    ///
    /// - Parameters:
    ///   - pool: The pool operator identifier. **Required** for Ogmios backend.
    ///   - opCert: The local operational certificate file. If provided, includes on-disk certificate details.
    /// - Returns: A `KESPeriodInfo` containing certificate counter information.
    /// - Throws: `CardanoChainError.invalidArgument` if pool is not provided or not found.
    ///
    /// ## Example
    /// ```swift
    /// let pool = try PoolOperator(from: "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy")
    /// let kesInfo = try await chainContext.kesPeriodInfo(pool: pool, opCert: myOpCert)
    /// if let onDisk = kesInfo.onDiskOpCertCount,
    ///    let nextChain = kesInfo.nextChainOpCertCount {
    ///     print("Certificate is \(onDisk >= nextChain ? "ready" : "not ready") for rotation")
    /// }
    /// ```
    public func kesPeriodInfo(
        pool: PoolOperator?, opCert: SwiftCardanoCore.OperationalCertificate? = nil
    ) async throws -> KESPeriodInfo {
        guard let pool = pool else {
            throw CardanoChainError.invalidArgument("Pool operator must be provided")
        }

        let poolId = try pool.id(.bech32)

        let opCerts = try await client.ledgerStateQuery.operationalCertificates.result()

        guard
            let matchingPool = opCerts.value.first(where: { (key, value) in
                key.value == poolId
            })
        else {
            throw CardanoChainError.invalidArgument(
                "Operational certificate not found for pool \(poolId)")
        }

        let opCertCounter: Int = matchingPool.value

        let onChainOpCertCount = opCertCounter
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

    // MARK: - Private Helper Methods

    /// Converts a SwiftOgmios UtxoEntry to a SwiftCardanoCore UTxO.
    private func convertUtxoEntry(_ entry: SwiftOgmios.UtxoEntry) throws -> SwiftCardanoCore.UTxO {
        let txIn = TransactionInput(
            transactionId: try TransactionId(from: .string(entry.transaction.id)),
            index: UInt16(entry.index)
        )

        // Convert value
        let lovelaceAmount = entry.value.ada.lovelace
        var multiAssets = MultiAsset([:])

        if let assets = entry.value.assets {
            for (policyIdHex, assetMap) in assets {
                let policyId = ScriptHash(payload: Data(hex: policyIdHex))
                var asset = Asset([:])

                for (assetNameHex, quantity) in assetMap {
                    let assetName = try AssetName(payload: Data(hex: assetNameHex))
                    asset[assetName] = Int(quantity)
                }

                multiAssets[policyId] = asset
            }
        }

        let amount = Value(
            coin: Int(lovelaceAmount),
            multiAsset: multiAssets
        )

        // Convert datum
        var datumHash: DatumHash? = nil
        var datumOption: DatumOption? = nil

        if let hash = entry.datumHash, entry.datum == nil {
            datumHash = try DatumHash(from: .string(hash))
        }

        if let datumHex = entry.datum,
            let datumData = Data(hexString: datumHex)
        {
            datumOption = try DatumOption.fromCBOR(data: datumData)
        }

        // Convert script
        var script: ScriptType? = nil
        if let ogmiosScript = entry.script {
            script = try convertScript(ogmiosScript)
        }

        let address = try SwiftCardanoCore.Address(from: .string(entry.address.value))
        let txOut = TransactionOutput(
            address: address,
            amount: amount,
            datumHash: datumHash,
            datumOption: datumOption,
            script: script
        )

        return SwiftCardanoCore.UTxO(input: txIn, output: txOut)
    }

    /// Converts a SwiftOgmios Script to a SwiftCardanoCore ScriptType.
    private func convertScript(_ script: SwiftOgmios.Script) throws -> ScriptType {
        switch script {
        case .native(let nativeScript):
            let jsonData = nativeScript.json.data(using: .utf8)!
            let native = try JSONDecoder().decode(NativeScript.self, from: jsonData)
            return .nativeScript(native)

        case .plutus(let plutusScript):
            let data = Data(hex: plutusScript.cbor)
            switch plutusScript.language {
            case "plutus:v1":
                return .plutusV1Script(PlutusV1Script(data: data))
            case "plutus:v2":
                return .plutusV2Script(PlutusV2Script(data: data))
            case "plutus:v3":
                return .plutusV3Script(PlutusV3Script(data: data))
            default:
                throw CardanoChainError.valueError(
                    "Unknown Plutus version: \(plutusScript.language)")
            }
        }
    }

    /// Converts SwiftOgmios ProtocolParameters to SwiftCardanoCore ProtocolParameters.
    private func convertProtocolParameters(
        _ params: SwiftOgmios.ProtocolParameters
    ) throws -> SwiftCardanoCore.ProtocolParameters {
        // Convert cost models - provide empty arrays as defaults
        let costModels: ProtocolParametersCostModels
        if let plutusCostModels = params.plutusCostModels {
            costModels = ProtocolParametersCostModels(
                PlutusV1: plutusCostModels.plutusV1?.compactMap { Int($0) } ?? [],
                PlutusV2: plutusCostModels.plutusV2?.compactMap { Int($0) } ?? [],
                PlutusV3: plutusCostModels.plutusV3?.compactMap { Int($0) } ?? []
            )
        } else {
            costModels = ProtocolParametersCostModels(PlutusV1: [], PlutusV2: [], PlutusV3: [])
        }

        // Convert execution unit prices - provide default values
        let executionPrices: ExecutionUnitPrices
        if let prices = params.scriptExecutionPrices {
            executionPrices = ExecutionUnitPrices(
                priceMemory: parseRatio(prices.memory) ?? 0,
                priceSteps: parseRatio(prices.cpu) ?? 0
            )
        } else {
            executionPrices = ExecutionUnitPrices(priceMemory: 0, priceSteps: 0)
        }

        // Convert DRep voting thresholds - provide default values
        let dRepVotingThresholds: DRepVotingThresholds
        if let thresholds = params.delegateRepresentativeVotingThresholds {
            dRepVotingThresholds = DRepVotingThresholds(
                committeeNoConfidence: parseRatio(thresholds.noConfidence) ?? 0,
                committeeNormal: parseRatio(thresholds.constitutionalCommittee.default) ?? 0,
                hardForkInitiation: parseRatio(thresholds.hardForkInitiation) ?? 0,
                motionNoConfidence: parseRatio(thresholds.noConfidence) ?? 0,
                ppEconomicGroup: parseRatio(thresholds.protocolParametersUpdate.economic) ?? 0,
                ppGovGroup: parseRatio(thresholds.protocolParametersUpdate.governance) ?? 0,
                ppNetworkGroup: parseRatio(thresholds.protocolParametersUpdate.network) ?? 0,
                ppTechnicalGroup: parseRatio(thresholds.protocolParametersUpdate.technical) ?? 0,
                treasuryWithdrawal: parseRatio(thresholds.treasuryWithdrawals) ?? 0,
                updateToConstitution: parseRatio(thresholds.constitution) ?? 0
            )
        } else {
            dRepVotingThresholds = DRepVotingThresholds(
                committeeNoConfidence: 0, committeeNormal: 0, hardForkInitiation: 0,
                motionNoConfidence: 0, ppEconomicGroup: 0, ppGovGroup: 0,
                ppNetworkGroup: 0, ppTechnicalGroup: 0, treasuryWithdrawal: 0,
                updateToConstitution: 0
            )
        }

        // Convert pool voting thresholds - provide default values
        let poolVotingThresholds: ProtocolParametersPoolVotingThresholds
        if let thresholds = params.stakePoolVotingThresholds {
            poolVotingThresholds = ProtocolParametersPoolVotingThresholds(
                committeeNoConfidence: parseRatio(thresholds.noConfidence) ?? 0,
                committeeNormal: parseRatio(thresholds.constitutionalCommittee.default) ?? 0,
                hardForkInitiation: parseRatio(thresholds.hardForkInitiation) ?? 0,
                motionNoConfidence: parseRatio(thresholds.noConfidence) ?? 0,
                ppSecurityGroup: parseRatio(thresholds.protocolParametersUpdate.security) ?? 0
            )
        } else {
            poolVotingThresholds = ProtocolParametersPoolVotingThresholds(
                committeeNoConfidence: 0, committeeNormal: 0, hardForkInitiation: 0,
                motionNoConfidence: 0, ppSecurityGroup: 0
            )
        }

        // Convert execution units - provide default values
        let maxBlockExUnits: ProtocolParametersExecutionUnits
        if let units = params.maxExecutionUnitsPerBlock {
            maxBlockExUnits = ProtocolParametersExecutionUnits(
                memory: Int(units.memory),
                steps: Int64(units.cpu)
            )
        } else {
            maxBlockExUnits = ProtocolParametersExecutionUnits(memory: 0, steps: 0)
        }

        let maxTxExUnits: ProtocolParametersExecutionUnits
        if let units = params.maxExecutionUnitsPerTransaction {
            maxTxExUnits = ProtocolParametersExecutionUnits(
                memory: Int(units.memory),
                steps: Int64(units.cpu)
            )
        } else {
            maxTxExUnits = ProtocolParametersExecutionUnits(memory: 0, steps: 0)
        }

        return SwiftCardanoCore.ProtocolParameters(
            collateralPercentage: params.collateralPercentage != nil
                ? Int(params.collateralPercentage!) : 150,
            committeeMaxTermLength: params.constitutionalCommitteeMaxTermLength != nil
                ? Int(params.constitutionalCommitteeMaxTermLength!) : 0,
            committeeMinSize: params.constitutionalCommitteeMinSize != nil
                ? Int(params.constitutionalCommitteeMinSize!) : 0,
            costModels: costModels,
            dRepActivity: params.delegateRepresentativeMaxIdleTime != nil
                ? Int(params.delegateRepresentativeMaxIdleTime!) : 0,
            dRepDeposit: params.delegateRepresentativeDeposit != nil
                ? Int(params.delegateRepresentativeDeposit!.ada.lovelace) : 0,
            dRepVotingThresholds: dRepVotingThresholds,
            executionUnitPrices: executionPrices,
            govActionDeposit: params.governanceActionDeposit != nil
                ? Int(params.governanceActionDeposit!.ada.lovelace) : 0,
            govActionLifetime: params.governanceActionLifetime != nil
                ? Int(params.governanceActionLifetime!) : 0,
            maxBlockBodySize: Int(params.maxBlockBodySize.bytes),
            maxBlockExecutionUnits: maxBlockExUnits,
            maxBlockHeaderSize: Int(params.maxBlockHeaderSize.bytes),
            maxCollateralInputs: params.maxCollateralInputs != nil
                ? Int(params.maxCollateralInputs!) : 3,
            maxTxExecutionUnits: maxTxExUnits,
            maxTxSize: params.maxTransactionSize != nil
                ? Int(params.maxTransactionSize!.bytes) : 16384,
            maxValueSize: params.maxValueSize != nil ? Int(params.maxValueSize!.bytes) : 5000,
            minFeeRefScriptCostPerByte: params.minFeeReferenceScripts != nil
                ? Int(params.minFeeReferenceScripts!.base) : nil,
            minPoolCost: Int(params.minStakePoolCost.ada.lovelace),
            monetaryExpansion: parseRatio(params.monetaryExpansion) ?? 0,
            poolPledgeInfluence: parseRatio(params.stakePoolPledgeInfluence) ?? 0,
            poolRetireMaxEpoch: Int(params.stakePoolRetirementEpochBound),
            poolVotingThresholds: poolVotingThresholds,
            protocolVersion: ProtocolParametersProtocolVersion(
                major: Int(params.version.major),
                minor: Int(params.version.minor)
            ),
            stakeAddressDeposit: Int(params.stakeCredentialDeposit.ada.lovelace),
            stakePoolDeposit: Int(params.stakePoolDeposit.ada.lovelace),
            stakePoolTargetNum: Int(params.desiredNumberOfStakePools),
            treasuryCut: parseRatio(params.treasuryExpansion) ?? 0,
            txFeeFixed: Int(params.minFeeConstant.ada.lovelace),
            txFeePerByte: Int(params.minFeeCoefficient),
            utxoCostPerByte: Int(params.minUtxoDepositCoefficient)
        )
    }

    /// Parses a Ratio type (which stores value as "numerator/denominator" string) to Double.
    private func parseRatio(_ ratio: SwiftOgmios.Ratio) -> Double? {
        return parseRatioString(ratio.value)
    }

    /// Parses a ratio string like "1/20" to a Double.
    private func parseRatioString(_ ratioString: String) -> Double? {
        let parts = ratioString.split(separator: "/")
        guard parts.count == 2,
            let numerator = Double(parts[0]),
            let denominator = Double(parts[1]),
            denominator != 0
        else {
            return nil
        }
        return numerator / denominator
    }

    /// Get the stake pool information.
    /// - Parameter poolId: The pool ID (Bech32).
    /// - Returns: `PoolParams` object.
    /// - Throws: `CardanoChainError.operationError` if the pool info cannot be fetched.
    public func stakePoolInfo(poolId: String) async throws -> PoolParams {
        // Fetch all stake pools and find the matching one
        // Note: Ideally we should use query filtering if SwiftOgmios supports it.
        let response = try await client.ledgerStateQuery.stakePools.result()

        guard let entry = response.first(where: { $0.key.value == poolId }) else {
            throw CardanoChainError.operationError("Pool not found: \(poolId)")
        }

        let ogmiosParams = entry.value

        // Map Relays
        let relays: [SwiftCardanoCore.Relay] = ogmiosParams.relays.compactMap { relay in
            switch relay {
            case .singleHostAddr(let ip):
                let ipv4 = ip.ipv4.flatMap { IPv4Address($0) }
                let ipv6 = ip.ipv6.flatMap { IPv6Address($0) }
                return .singleHostAddr(
                    SingleHostAddr(port: ip.port.map { Int($0) }, ipv4: ipv4, ipv6: ipv6)
                )
            case .singleHostName(let name):
                return .singleHostName(
                    SingleHostName(port: name.port.map { Int($0) }, dnsName: name.hostname)
                )
            case .multiHostName(let name):
                return .multiHostName(MultiHostName(dnsName: name.hostname))
            }
        }

        // Convert margin (Ratio) to UnitInterval
        let marginDouble = parseRatio(ogmiosParams.margin) ?? 0.0
        let marginDenom: UInt64 = 100_000_000
        let marginNum = UInt64((marginDouble * Double(marginDenom)).rounded())
        let margin = UnitInterval(numerator: marginNum, denominator: marginDenom)

        let poolOperator = try PoolOperator(from: poolId)
        let vrfKeyHash = VrfKeyHash(payload: Data(hex: ogmiosParams.vrfVerificationKeyHash.description))
        let rewardAddress = try Address(from: .string(ogmiosParams.rewardAccount.description))
        let rewardAccountHash = RewardAccountHash(payload: rewardAddress.toBytes())
        let poolOwnersList: [VerificationKeyHash] = ogmiosParams.owners.map { owner in
            VerificationKeyHash(payload: Data(hex: owner.description))
        }
        let poolOwners = ListOrOrderedSet<VerificationKeyHash>.list(poolOwnersList)

        var poolMetadata: PoolMetadata? = nil
        if let metadataUrl = ogmiosParams.metadata?.url,
           let metadataHash = ogmiosParams.metadata?.hash
        {
            let hashData = Data(hex: metadataHash.description)
            poolMetadata = try PoolMetadata(
                url: try Url(metadataUrl.absoluteString),
                poolMetadataHash: PoolMetadataHash(payload: hashData)
            )
        }

        return PoolParams(
            poolOperator: poolOperator.poolKeyHash,
            vrfKeyHash: vrfKeyHash,
            pledge: Int(ogmiosParams.pledge.ada.lovelace),
            cost: Int(ogmiosParams.cost.ada.lovelace),
            margin: margin,
            rewardAccount: rewardAccountHash,
            poolOwners: poolOwners,
            relays: relays,
            poolMetadata: poolMetadata
        )
    }
}
