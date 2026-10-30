import BigInt
import Foundation
import SwiftCardanoCore
import SwiftCardanoNetwork
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
public actor OgmiosChainContext: ChainContext {

    // MARK: - Properties

    /// The name identifier for this chain context.
    nonisolated public var name: String { "Ogmios" }

    nonisolated public var type: ContextType { .online }

    /// The underlying Ogmios client used for all API calls.
    public let client: OgmiosClient

    private var _epoch: Int?
    private var _epochFetch: Task<Int, Error>?
    private var _genesisParameters: GenesisParameters?
    private var _genesisParametersFetch: Task<GenesisParameters, Error>?
    private var _protocolParameters: SwiftCardanoCore.ProtocolParameters?
    private var _protocolParametersEpoch: Int?
    private var _protocolParametersFetch: Task<SwiftCardanoCore.ProtocolParameters, Error>?
    private var lastEpochFetch: TimeInterval = 0
    private let _network: SwiftCardanoCore.Network

    /// The network identifier for this context.
    nonisolated public var networkId: NetworkId {
        self._network.networkId
    }

    /// Returns the current era based on the current epoch.
    ///
    /// The era is derived from the epoch number using `Era.fromEpoch()`.
    public func era() async throws -> SwiftCardanoCore.Era? {
        SwiftCardanoCore.Era.fromEpoch(epoch: try await self.epoch().checked("Ogmios epoch"))
    }

    /// Returns the current epoch number.
    ///
    /// The epoch is cached and refreshed periodically to avoid unnecessary API calls.
    public func epoch() async throws -> Int {
        // Refresh epoch if cache is stale (older than 60 seconds)
        if let cached = _epoch,
            (Date().timeIntervalSince1970 - lastEpochFetch) <= 60
        {
            return cached
        }
        if let inFlight = _epochFetch { return try await inFlight.value }

        // Cache writes happen inside the Task body so that the result lands in
        // the cache even if the launching caller is cancelled mid-flight.
        let task = Task<Int, Error> {
            do {
                let value = try await self.fetchEpochFromOgmios()
                self._epoch = value
                self.lastEpochFetch = Date().timeIntervalSince1970
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

    private func fetchEpochFromOgmios() async throws -> Int {
        let response = try await self.client.ledgerStateQuery.epoch.result()
        return try response.checked("Ogmios epoch")
    }

    /// Returns the slot number of the most recent block.
    ///
    /// Queries the current tip of the ledger to get the latest slot.
    public func lastBlockSlot() async throws -> Int {
        let response = try await self.client.ledgerStateQuery.tip.result()

        switch response {
        case .origin:
            return 0
        case .point(let point):
            return try point.slot.checked("Ogmios tip slot")
        }
    }

    /// Returns the genesis parameters for the network.
    ///
    /// Genesis parameters are cached after the first fetch since they never change
    /// during the lifetime of the network.
    public func genesisParameters() async throws -> GenesisParameters {
        if let cached = _genesisParameters { return cached }
        if let inFlight = _genesisParametersFetch { return try await inFlight.value }

        let task = Task<GenesisParameters, Error> {
            do {
                let value = try await self.fetchGenesisFromOgmios()
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

    private func fetchGenesisFromOgmios() async throws -> GenesisParameters {
        let genesisParams = QueryNetworkGenesisConfiguration.Params(era: .shelley)
        let response = try await self.client.networkQuery.genesisConfiguration.result(
            params: genesisParams
        )

        switch response {
        case .shelley(let genesis):
            // Ogmios sends the active slot coefficient as a fraction, e.g. "1/20".
            let activeSlots = try LedgerValues.unitInterval(
                text: genesis.activeSlotsCoefficient, "Ogmios genesis activeSlotsCoefficient")

            let systemStartDate = try Self.systemStart(genesis.startTime)

            return GenesisParameters(
                activeSlotsCoefficient: activeSlots,
                epochLength: genesis.epochLength,
                maxKesEvolutions: genesis.maxKesEvolutions,
                maxLovelaceSupply: genesis.maxLovelaceSupply,
                networkId: self._network.description,
                networkMagic: genesis.networkMagic,
                securityParam: genesis.securityParameter,
                // Seconds, exactly: a 200 ms slot is 0.2, not 0.
                slotLength: Decimal(genesis.slotLength.milliseconds) / 1000,
                slotsPerKesPeriod: genesis.slotsPerKesPeriod,
                systemStart: systemStartDate,
                updateQuorum: genesis.updateQuorum
            )
        default:
            throw CardanoChainError.operationError("Unexpected genesis configuration era")
        }
    }

    /// The genesis start time, which Ogmios sends in ISO 8601.
    ///
    /// - Throws: When it does not parse: the start time anchors every slot
    ///   and epoch computed from it, so "now" is no substitute.
    static func systemStart(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        throw CardanoChainError.valueError("Ogmios genesis startTime \(text) is not an ISO 8601 date")
    }

    /// Returns the current protocol parameters.
    ///
    /// Protocol parameters are cached per epoch and automatically refreshed
    /// when the epoch changes.
    public func protocolParameters() async throws -> SwiftCardanoCore.ProtocolParameters {
        // Refresh if epoch changed or not cached. Tracking the epoch the cached
        // params were *fetched for* (rather than comparing against `_epoch`,
        // which `epoch()` just updated) makes the invalidation actually fire.
        let currentEpoch = try await self.epoch()
        if let cached = _protocolParameters,
           _protocolParametersEpoch == currentEpoch {
            return cached
        }
        if let inFlight = _protocolParametersFetch { return try await inFlight.value }

        let task = Task<SwiftCardanoCore.ProtocolParameters, Error> {
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
            // Decoupled from SwiftCardanoUtils (a macOS/Linux CLI toolkit whose `Ogmios` type RUNS
            // an ogmios *server*). The client only needs an endpoint — default to a local ogmios.
            self.client = try await OgmiosClient(
                host: host ?? "localhost",
                port: port ?? 1337,
                path: path ?? "",
                secure: secure ?? false,
                httpOnly: httpOnly ?? false,
                rpcVersion: rpcVersion ?? "2.0"
            )
        }
    }

    // MARK: - Public Methods

    /// Queries the current chain tip.
    ///
    /// Combines the canonical `ledgerStateQuery/tip` (slot + hash) with the server's
    /// `/health` endpoint to fill in `era`, `block` (height), `epoch`, `slotInEpoch`,
    /// and `syncProgress`. If the health probe fails the tip portion is still returned
    /// with the remaining fields left `nil`.
    ///
    /// - Returns: A `ChainTip` object containing block height, slot, epoch, and other tip information.
    /// - Throws: `CardanoChainError.operationError` if the tip query fails.
    public func chainTip() async throws -> ChainTip {
        let tipResponse = try await client.ledgerStateQuery.tip.result()

        let health = try? await client.getServerHealth()

        let syncProgress = health.map { String(format: "%.2f", $0.networkSynchronization * 100) }

        switch tipResponse {
        case .origin:
            return ChainTip(
                block: 0,
                // At the origin no block exists yet, so the epoch is 0 when
                // the health probe does not say otherwise.
                epoch: try (health?.currentEpoch ?? 0).checked("Ogmios health currentEpoch"),
                era: health?.currentEra,
                hash: nil,
                slot: 0,
                slotInEpoch: try (health?.slotInEpoch).map { try $0.checked("Ogmios health slotInEpoch") },
                slotsToEpochEnd: nil,
                syncProgress: syncProgress
            )
        case .point(let point):
            let resolvedEpoch: Int
            if let healthEpoch = health?.currentEpoch {
                resolvedEpoch = healthEpoch
            } else {
                resolvedEpoch = try await epoch()
            }
            return ChainTip(
                block: try (health?.lastKnownTip.height).map { try $0.checked("Ogmios health height") },
                epoch: try resolvedEpoch.checked("Ogmios epoch"),
                era: health?.currentEra,
                hash: point.id.description,
                slot: try point.slot.checked("Ogmios tip slot"),
                slotInEpoch: try (health?.slotInEpoch).map { try $0.checked("Ogmios health slotInEpoch") },
                slotsToEpochEnd: nil,
                syncProgress: syncProgress
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

    /// Get the UTxO for a specific transaction input.
    ///
    /// - Parameter input: A transaction input identifying the UTxO by transaction hash and output index.
    /// - Returns: The UTxO if it exists and is unspent, or `nil` if it has been spent or does not exist.
    ///   Ogmios only queries the live UTxO set, so spent UTxOs are indistinguishable from non-existent ones.
    /// - Throws: `CardanoChainError` if the query fails.
    public func utxo(input: TransactionInput) async throws -> (UTxO, isSpent: Bool)? {
        let outputRef = SwiftOgmios.TransactionOutputReference(
            transaction: .init(id: input.transactionId.description),
            index: UInt64(input.index)
        )

        let entries = try await client.ledgerStateQuery.utxo.result(
            outputReferences: [outputRef]
        )

        guard let entry = entries.first else {
            return nil
        }

        return (try convertUtxoEntry(entry), false)
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
                mem: try evalResult.budget.memory.checked("Ogmios evaluation \(key) memory"),
                steps: try evalResult.budget.cpu.checked("Ogmios evaluation \(key) cpu")
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
                rewardAccountBalance: Int64(summary.rewards.ada.lovelace),
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
    public func stakePools() async throws -> [PoolOperator] {
        let response = try await client.ledgerStateQuery.stakePools.result()
        return try response.keys.map { try PoolOperator(from: $0.value) }
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

        let opCertCounter: Int = try matchingPool.value.checked("Ogmios operational certificate counter")

        let onChainOpCertCount = opCertCounter
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

    // MARK: - Private Helper Methods

    /// Converts a SwiftOgmios UtxoEntry to a SwiftCardanoCore UTxO.
    private func convertUtxoEntry(_ entry: SwiftOgmios.UtxoEntry) throws -> SwiftCardanoCore.UTxO {
        let txIn = TransactionInput(
            transactionId: try LedgerValues.hash(hex: entry.transaction.id, as: TransactionId.self, "Ogmios TransactionId"),
            index: try LedgerValues.integer(entry.index, "Ogmios output index")
        )

        // Convert value
        // SwiftOgmios reads an output's lovelace as UInt64, so it cannot be negative.
        let lovelaceAmount = entry.value.ada.lovelace
        var multiAssets = MultiAsset([:])

        if let assets = entry.value.assets {
            for (policyIdHex, assetMap) in assets {
                let policyId = try LedgerValues.hash(hex: policyIdHex, as: ScriptHash.self, "Ogmios ScriptHash")
                var asset = Asset([:])

                for (assetNameHex, quantity) in assetMap {
                    let assetName = try LedgerValues.assetName(hex: assetNameHex, "Ogmios asset name")
                    asset[assetName] = BigInt(quantity)
                }

                multiAssets[policyId] = asset
            }
        }

        let amount = Value(
            coin: BigInt(lovelaceAmount),
            multiAsset: multiAssets
        )

        // Convert datum
        var datumHash: DatumHash? = nil
        var datumOption: DatumOption? = nil

        if let hash = entry.datumHash, entry.datum == nil {
            datumHash = try LedgerValues.hash(hex: hash, as: DatumHash.self, "Ogmios DatumHash")
        }

        if let datumHex = entry.datum {
            let datumData = try LedgerValues.hexBytes(datumHex, "Ogmios inline datum")
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
            let data = try LedgerValues.hexBytes(plutusScript.cbor, "Ogmios script cbor")
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
        // Every field core holds is required: Ogmios leaves out only what the
        // node's era does not have, and a Conway parameter set has them all. A
        // missing one is an error, never a default (a missing cost model would
        // silently change the script data hash).
        func required<T>(_ value: T?, _ what: String) throws -> T {
            try LedgerValues.required(value, "Ogmios protocol parameter \(what)")
        }

        let plutusCostModels = try required(params.plutusCostModels, "plutusCostModels")
        let costModels = ProtocolParametersCostModels(
            PlutusV1: try required(plutusCostModels.plutusV1, "plutusCostModels plutus:v1").map { Int64($0) },
            PlutusV2: try required(plutusCostModels.plutusV2, "plutusCostModels plutus:v2").map { Int64($0) },
            PlutusV3: try required(plutusCostModels.plutusV3, "plutusCostModels plutus:v3").map { Int64($0) }
        )

        let prices = try required(params.scriptExecutionPrices, "scriptExecutionPrices")
        let executionPrices = ExecutionUnitPrices(
            priceMemory: try nonNegativeInterval(prices.memory, "scriptExecutionPrices.memory"),
            priceSteps: try nonNegativeInterval(prices.cpu, "scriptExecutionPrices.cpu")
        )

        let dRepVotingThresholds: DRepVotingThresholds
        do {
            let thresholds = try required(
                params.delegateRepresentativeVotingThresholds, "delegateRepresentativeVotingThresholds")
            dRepVotingThresholds = DRepVotingThresholds(
                committeeNoConfidence: try unitInterval(
                    thresholds.constitutionalCommittee.stateOfNoConfidence,
                    "delegateRepresentativeVotingThresholds.constitutionalCommittee.stateOfNoConfidence"),
                committeeNormal: try unitInterval(
                    thresholds.constitutionalCommittee.default,
                    "delegateRepresentativeVotingThresholds.constitutionalCommittee.default"),
                hardForkInitiation: try unitInterval(
                    thresholds.hardForkInitiation, "delegateRepresentativeVotingThresholds.hardForkInitiation"),
                motionNoConfidence: try unitInterval(
                    thresholds.noConfidence, "delegateRepresentativeVotingThresholds.noConfidence"),
                ppEconomicGroup: try unitInterval(
                    thresholds.protocolParametersUpdate.economic,
                    "delegateRepresentativeVotingThresholds.protocolParametersUpdate.economic"),
                ppGovGroup: try unitInterval(
                    thresholds.protocolParametersUpdate.governance,
                    "delegateRepresentativeVotingThresholds.protocolParametersUpdate.governance"),
                ppNetworkGroup: try unitInterval(
                    thresholds.protocolParametersUpdate.network,
                    "delegateRepresentativeVotingThresholds.protocolParametersUpdate.network"),
                ppTechnicalGroup: try unitInterval(
                    thresholds.protocolParametersUpdate.technical,
                    "delegateRepresentativeVotingThresholds.protocolParametersUpdate.technical"),
                treasuryWithdrawal: try unitInterval(
                    thresholds.treasuryWithdrawals, "delegateRepresentativeVotingThresholds.treasuryWithdrawals"),
                updateToConstitution: try unitInterval(
                    thresholds.constitution, "delegateRepresentativeVotingThresholds.constitution")
            )
        }

        let poolVotingThresholds: ProtocolParametersPoolVotingThresholds
        do {
            let thresholds = try required(params.stakePoolVotingThresholds, "stakePoolVotingThresholds")
            poolVotingThresholds = ProtocolParametersPoolVotingThresholds(
                committeeNoConfidence: try unitInterval(
                    thresholds.constitutionalCommittee.stateOfNoConfidence,
                    "stakePoolVotingThresholds.constitutionalCommittee.stateOfNoConfidence"),
                committeeNormal: try unitInterval(
                    thresholds.constitutionalCommittee.default,
                    "stakePoolVotingThresholds.constitutionalCommittee.default"),
                hardForkInitiation: try unitInterval(
                    thresholds.hardForkInitiation, "stakePoolVotingThresholds.hardForkInitiation"),
                motionNoConfidence: try unitInterval(
                    thresholds.noConfidence, "stakePoolVotingThresholds.noConfidence"),
                ppSecurityGroup: try unitInterval(
                    thresholds.protocolParametersUpdate.security,
                    "stakePoolVotingThresholds.protocolParametersUpdate.security")
            )
        }

        let blockUnits = try required(params.maxExecutionUnitsPerBlock, "maxExecutionUnitsPerBlock")
        let maxBlockExUnits = ProtocolParametersExecutionUnits(memory: blockUnits.memory, steps: blockUnits.cpu)
        let txUnits = try required(params.maxExecutionUnitsPerTransaction, "maxExecutionUnitsPerTransaction")
        let maxTxExUnits = ProtocolParametersExecutionUnits(memory: txUnits.memory, steps: txUnits.cpu)

        // The reference-script fee: `base` lovelace per byte, multiplied by
        // `multiplier` for every further `range` bytes. SwiftOgmios reads
        // `base` and `multiplier` as the exact decimals Ogmios sent.
        let referenceScripts = try params.minFeeReferenceScripts.map { fee -> MinReferenceScriptsSize in
            let multiplier = try LedgerValues.nonNegativeInterval(fee.multiplier, "Ogmios minFeeReferenceScripts.multiplier")
            // The ledger's multiplier is a PositiveInterval and its range a NonZero Word32.
            guard multiplier.numerator > 0 else {
                throw CardanoChainError.valueError("Ogmios minFeeReferenceScripts.multiplier must be positive")
            }
            guard fee.range > 0 else {
                throw CardanoChainError.valueError("Ogmios minFeeReferenceScripts.range must not be zero")
            }
            return MinReferenceScriptsSize(
                base: try LedgerValues.nonNegativeInterval(fee.base, "Ogmios minFeeReferenceScripts.base"),
                multiplier: multiplier,
                range: fee.range
            )
        }
        let minFeeRefScriptCostPerByte = referenceScripts?.base
        let maxReferenceScriptsSize: Int64? = try params.maxReferenceScriptsSize.map {
            try $0.bytes.checked("Ogmios maxReferenceScriptsSize")
        }

        func integer<T: FixedWidthInteger, S: BinaryInteger>(_ value: S, _ what: String) throws -> T {
            try LedgerValues.integer(value, as: T.self, "Ogmios \(what)")
        }
        func lovelace(_ value: ValueAdaOnly, _ what: String) throws -> Coin {
            try integer(value.ada.lovelace, what)
        }

        return SwiftCardanoCore.ProtocolParameters(
            collateralPercentage: try integer(required(params.collateralPercentage, "collateralPercentage"),
                                              "collateralPercentage"),
            committeeMaxTermLength: try integer(
                required(params.constitutionalCommitteeMaxTermLength, "constitutionalCommitteeMaxTermLength"),
                "constitutionalCommitteeMaxTermLength"),
            committeeMinSize: try integer(
                required(params.constitutionalCommitteeMinSize, "constitutionalCommitteeMinSize"),
                "constitutionalCommitteeMinSize"),
            costModels: costModels,
            dRepActivity: try integer(
                required(params.delegateRepresentativeMaxIdleTime, "delegateRepresentativeMaxIdleTime"),
                "delegateRepresentativeMaxIdleTime"),
            dRepDeposit: try lovelace(
                required(params.delegateRepresentativeDeposit, "delegateRepresentativeDeposit"),
                "delegateRepresentativeDeposit"),
            dRepVotingThresholds: dRepVotingThresholds,
            executionUnitPrices: executionPrices,
            govActionDeposit: try lovelace(
                required(params.governanceActionDeposit, "governanceActionDeposit"), "governanceActionDeposit"),
            govActionLifetime: try integer(
                required(params.governanceActionLifetime, "governanceActionLifetime"), "governanceActionLifetime"),
            maxBlockBodySize: try integer(params.maxBlockBodySize.bytes, "maxBlockBodySize"),
            maxBlockExecutionUnits: maxBlockExUnits,
            maxBlockHeaderSize: try integer(params.maxBlockHeaderSize.bytes, "maxBlockHeaderSize"),
            maxCollateralInputs: try integer(required(params.maxCollateralInputs, "maxCollateralInputs"),
                                             "maxCollateralInputs"),
            maxTxExecutionUnits: maxTxExUnits,
            maxTxSize: try integer(required(params.maxTransactionSize, "maxTransactionSize").bytes, "maxTransactionSize"),
            maxValueSize: try integer(required(params.maxValueSize, "maxValueSize").bytes, "maxValueSize"),
            maxReferenceScriptsSize: maxReferenceScriptsSize,
            minFeeReferenceScripts: referenceScripts,
            minFeeRefScriptCostPerByte: minFeeRefScriptCostPerByte,
            minPoolCost: try lovelace(params.minStakePoolCost, "minStakePoolCost"),
            monetaryExpansion: try unitInterval(params.monetaryExpansion, "monetaryExpansion"),
            poolPledgeInfluence: try nonNegativeInterval(params.stakePoolPledgeInfluence, "stakePoolPledgeInfluence"),
            poolRetireMaxEpoch: try integer(params.stakePoolRetirementEpochBound, "stakePoolRetirementEpochBound"),
            poolVotingThresholds: poolVotingThresholds,
            protocolVersion: ProtocolParametersProtocolVersion(
                major: params.version.major,
                minor: params.version.minor
            ),
            stakeAddressDeposit: try lovelace(params.stakeCredentialDeposit, "stakeCredentialDeposit"),
            stakePoolDeposit: try lovelace(params.stakePoolDeposit, "stakePoolDeposit"),
            stakePoolTargetNum: try integer(params.desiredNumberOfStakePools, "desiredNumberOfStakePools"),
            treasuryCut: try unitInterval(params.treasuryExpansion, "treasuryExpansion"),
            txFeeFixed: try lovelace(params.minFeeConstant, "minFeeConstant"),
            txFeePerByte: params.minFeeCoefficient,
            utxoCostPerByte: params.minUtxoDepositCoefficient
        )
    }

    /// An Ogmios ratio, sent as `"numerator/denominator"`, as an exact unit interval.
    private func unitInterval(_ ratio: SwiftOgmios.Ratio, _ what: String) throws -> UnitInterval {
        try LedgerValues.unitInterval(text: ratio.value, "Ogmios \(what)")
    }

    /// An Ogmios ratio, sent as `"numerator/denominator"`, as an exact non-negative interval.
    private func nonNegativeInterval(_ ratio: SwiftOgmios.Ratio, _ what: String) throws -> NonNegativeInterval {
        try LedgerValues.nonNegativeInterval(text: ratio.value, "Ogmios \(what)")
    }

    /// Get the stake pool information.
    /// - Parameter poolId: The pool ID (Bech32).
    /// - Returns: `StakePoolInfo` object.
    /// - Throws: `CardanoChainError.operationError` if the pool info cannot be fetched.
    public func stakePoolInfo(poolId: String) async throws -> StakePoolInfo {
        // Fetch all stake pools and find the matching one
        // Note: Ideally we should use query filtering if SwiftOgmios supports it.
        let response = try await client.ledgerStateQuery.stakePools.result(
            params: .init(
                includeStake: false,
                stakePools: [
                    StakePoolId(poolId)
                ]
            )
        )

        guard let entry = response.first(where: { $0.key.value == poolId }) else {
            throw CardanoChainError.operationError("Pool not found: \(poolId)")
        }

        let ogmiosParams = entry.value

        // Map Relays
        let relays: [SwiftCardanoCore.Relay] = try ogmiosParams.relays.map { relay in
            switch relay {
            case .singleHostAddr(let ip):
                let ipv4 = try ip.ipv4.map { try LedgerValues.ipv4($0, "Ogmios relay IPv4") }
                let ipv6 = try ip.ipv6.map { try LedgerValues.ipv6($0, "Ogmios relay IPv6") }
                return .singleHostAddr(
                    SingleHostAddr(port: ip.port.map { Int($0) }, ipv4: ipv4, ipv6: ipv6)
                )
            case .singleHostName(let name):
                return try LedgerValues.singleHostName(
                    port: name.port.map { Int($0) }, dnsName: name.hostname, "Ogmios relay DNS name")
            case .multiHostName(let name):
                return try LedgerValues.multiHostName(dnsName: name.hostname, "Ogmios relay SRV name")
            }
        }

        // Convert margin (Ratio) to UnitInterval
        let margin = try unitInterval(ogmiosParams.margin, "stake pool margin")

        let poolOperator = try PoolOperator(from: poolId)
        let vrfKeyHash = try LedgerValues.hash(
            hex: ogmiosParams.vrfVerificationKeyHash.description, as: VrfKeyHash.self, "Ogmios pool vrf")
        let rewardAddress = try Address(from: .string(ogmiosParams.rewardAccount.description))
        let rewardAccountHash = RewardAccountHash(payload: rewardAddress.toBytes())
        let poolOwnersList: [VerificationKeyHash] = try ogmiosParams.owners.map { owner in
            try LedgerValues.hash(hex: owner.description, as: VerificationKeyHash.self, "Ogmios VerificationKeyHash")
        }
        let poolOwners = ListOrOrderedSet<VerificationKeyHash>.list(poolOwnersList)

        var poolMetadata: PoolMetadata? = nil
        if let metadataUrl = ogmiosParams.metadata?.url,
            let metadataHash = ogmiosParams.metadata?.hash
        {
            let hashData = try LedgerValues.hash32(hex: metadataHash.description, "Ogmios pool metadata hash")
            let url = try LedgerValues.url(metadataUrl, "Ogmios pool metadata URL")
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

        let params = PoolParams(
            poolOperator: poolOperator.poolKeyHash,
            vrfKeyHash: vrfKeyHash,
            pledge: try LedgerValues.integer(ogmiosParams.pledge.ada.lovelace, "Ogmios stake pool pledge"),
            cost: try LedgerValues.integer(ogmiosParams.cost.ada.lovelace, "Ogmios stake pool cost"),
            margin: margin,
            rewardAccount: rewardAccountHash,
            poolOwners: poolOwners,
            relays: relays,
            poolMetadata: poolMetadata
        )

        // The opcert counter, from the operationalCertificates query. `nil` when
        // the server does not answer that query or the pool has issued no
        // certificate yet; a certificate it does report must be valid.
        var opcertCounter: UInt? = nil
        if let opCerts = try await Self.optionalLedgerQuery({
                try await client.ledgerStateQuery.operationalCertificates.result()
            }),
            let matchingPool = opCerts.value.first(where: { $0.key.value == poolId })
        {
            opcertCounter = try matchingPool.value.checked("Ogmios operational certificate counter")
        }

        // Live stake, its share, and the owners' stake, from stakePoolsPerformances.
        // `nil` when the server does not answer that query or does not list the pool.
        var liveStake: UInt? = nil
        var liveSize: Decimal? = nil
        var ownerStake: UInt? = nil
        if let performances = try await Self.optionalLedgerQuery({
                try await client.ledgerStateQuery.stakePoolsPerformances.result()
            }),
            let poolSummary = performances.stakePools.first(where: { $0.key.value == poolId })?
                .value
        {
            let poolStakeLovelace = poolSummary.stake.ada.lovelace
            let totalActiveStakeLovelace = performances.activeStakeInEpoch.ada.lovelace
            liveStake = try poolStakeLovelace.checked("Ogmios pool stake")
            if totalActiveStakeLovelace > 0 {
                liveSize = Decimal(poolStakeLovelace) / Decimal(totalActiveStakeLovelace)
            }
            ownerStake = try poolSummary.ownerStake.ada.lovelace.checked("Ogmios pool owner stake")
        }

        // Ogmios StakePool type does not expose retirement/retiring-epoch information.
        // If the pool was found in the stakePools query above it is currently registered.
        // Retired pools would not be returned by the query and the guard above would have
        // thrown an error, so we can safely mark any found pool as registered.
        return StakePoolInfo(
            poolParams: params,
            livePledge: ownerStake,
            liveStake: liveStake,
            liveSize: liveSize,
            opcertCounter: opcertCounter,
            status: .registered
        )
    }

    /// The result of a ledger-state query the server may not answer, or `nil`
    /// when it does not: Ogmios answers with a JSON-RPC error (the query is
    /// unknown to this server or unavailable in the current era), or its HTTP
    /// endpoint refuses the request as not found or not implemented. Any other
    /// failure — the server cannot be reached, or a successful response does
    /// not decode — throws.
    static func optionalLedgerQuery<T>(
        isolation: isolated (any Actor)? = #isolation, _ query: () async throws -> T
    ) async throws -> T? {
        do {
            return try await query()
        } catch OgmiosError.responseError {
            return nil
        } catch OgmiosError.connectionError(let message?)
            where ["HTTP Error: 404,", "HTTP Error: 501,"].contains(where: message.hasPrefix)
        {
            return nil
        }
    }

    /// Get the treasury balance.
    /// - Returns: The current balance of the treasury as a `Coin` object.
    /// - Throws: An error if the treasury balance cannot be retrieved.
    public func treasury() async throws -> Coin {
        let response =
            try await client
            .ledgerStateQuery
            .treasuryAndReserves
            .result()

        return try response.treasury.ada.lovelace.checked("Ogmios treasury")
    }

    /// Get the DRep information.
    /// - Parameter drep: The `DRep` object.
    /// - Returns: The `DRepInfo` object containing information about the DRep.
    public func drepInfo(drep: DRep) async throws -> DRepInfo {

        func ogmosisDRepInfoFromRegistered(
            drep: DRep,
            reg: DelegateRepresentativeSummary.Registered
        ) throws -> DRepInfo {
            let stake: Coin = try reg.stake.ada.lovelace.checked("Ogmios DRep stake")
            let deposit: Coin? = try reg.deposit.map { try $0.ada.lovelace.checked("Ogmios DRep deposit") }
            let expiry = reg.mandate.map { $0.epoch }

            let anchor = try reg.metadata.map { ogmiosAnchor in
                try LedgerValues.anchor(
                    url: ogmiosAnchor.url, hash: ogmiosAnchor.hash, "Ogmios DRep anchor")
            }

            return DRepInfo(
                active: true,
                drep: drep,
                anchor: anchor,
                deposit: deposit,
                stake: stake,
                expiry: expiry,
                status: .registered
            )
        }

        switch drep.credential {
        case .alwaysAbstain, .alwaysNoConfidence:

            let delegates =
                try await client
                .ledgerStateQuery
                .delegateRepresentatives
                .result()

            // SwiftOgmios decodes `{"type": "abstain", ...}` as `.noConfidence`
            // (its decoder tries NoConfidence first and ignores `type`), so
            // each summary is matched by its `type` field, not its case.
            func summaryStake(_ type: String) throws -> Coin {
                for delegate in delegates {
                    switch delegate {
                    case .abstain(let a) where a.type == type:
                        return try a.stake.ada.lovelace.checked("Ogmios \(type) stake")
                    case .noConfidence(let nc) where nc.type == type:
                        return try nc.stake.ada.lovelace.checked("Ogmios \(type) stake")
                    default:
                        continue
                    }
                }
                // Ogmios always reports both predefined DReps; a missing one is not 0.
                throw CardanoChainError.valueError("Ogmios reported no \(type) DRep summary")
            }

            let stake: Coin
            switch drep.credential {
            case .alwaysAbstain:
                stake = try summaryStake("abstain")
            case .alwaysNoConfidence:
                stake = try summaryStake("noConfidence")
            default:
                throw CardanoChainError.valueError("Unexpected DRep credential \(drep.credential)")
            }
            return DRepInfo(
                active: true,
                drep: drep,
                anchor: nil,
                deposit: nil,
                stake: stake,
                expiry: nil,
                status: .registered
            )

        case .verificationKeyHash(let hash):
            let hexHash = hash.payload.toHex
            let credential = try EncodingBase16(hexHash)
            let params = QueryLedgerStateDelegateRepresentatives.Params(
                keys: [.base16(credential)]
            )
            let delegates =
                try await client
                .ledgerStateQuery
                .delegateRepresentatives
                .result(params: params)

            guard let delegate = delegates.first, case .registered(let reg) = delegate else {
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
            return try ogmosisDRepInfoFromRegistered(drep: drep, reg: reg)

        case .scriptHash(let hash):
            let hexHash = hash.payload.toHex
            let credential = try EncodingBase16(hexHash)
            let params = QueryLedgerStateDelegateRepresentatives.Params(
                scripts: [.base16(credential)],
            )
            let delegates =
                try await client
                .ledgerStateQuery
                .delegateRepresentatives
                .result(params: params)
            guard let delegate = delegates.first, case .registered(let reg) = delegate else {
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
            return try ogmosisDRepInfoFromRegistered(drep: drep, reg: reg)
        }
    }

    /// Get the governance action information for a given governance action ID.
    /// - Parameter govActionID: The identifier of the governance action.
    /// - Returns: The `GovActionInfo` object containing information about the governance action.
    public func govActionInfo(govActionID: GovActionID) async throws -> GovActionInfo {
        let proposals = try await client.ledgerStateQuery.governanceProposals.result()

        guard
            let entry = proposals.first(where: {
                $0.proposal.transaction.id == govActionID.transactionID.payload.toHex
                    && $0.proposal.index == UInt32(govActionID.govActionIndex)
            })
        else {
            throw CardanoChainError.valueError("Governance action not found: \(govActionID)")
        }

        let govAction = try Self.mapOgmiosGovernanceAction(entry.action)

        return GovActionInfo(
            govActionId: govActionID,
            govAction: govAction,
            proposedIn: entry.since.epoch,
            expiresAfter: entry.until.epoch
        )
    }

    /// Get the committee member information for a given committee member credential.
    /// - Parameter cold: The `CommitteeColdCredential` object representing the committee member.
    /// - Returns: The `CommitteeMemberInfo` object containing information about the committee member.
    public func committeeMemberInfo(cold: CommitteeColdCredential) async throws
        -> CommitteeMemberInfo
    {
        let constitutionalCommittee = try await client.ledgerStateQuery.constitutionalCommittee
            .result()

        let coldCredentialHex = cold.credential.payload.toHex.lowercased()
        let member = constitutionalCommittee.members.first { member in
            guard member.id.description.lowercased() == coldCredentialHex else {
                return false
            }

            switch (cold.credential, member.from) {
            case (.scriptHash, .script), (.verificationKeyHash, .verificationKey):
                return true
            default:
                return false
            }
        }

        guard let member else {
            throw CardanoChainError.valueError(
                "Committee member not found for credential: \(cold)"
            )
        }

        guard let expirationEpoch: Int = try member.mandate.map({ try $0.epoch.checked("Ogmios committee mandate epoch") }) else {
            throw CardanoChainError.valueError(
                "Missing expiration epoch for committee member: \(cold)"
            )
        }

        let hotCredential: CommitteeHotCredential?
        switch member.delegate {
            case .authorized(let delegate):
                switch delegate.from {
                    case .script:
                        hotCredential = CommitteeHotCredential(
                            credential: .scriptHash(try LedgerValues.hash(hex: delegate.id.description, as: ScriptHash.self, "Ogmios ScriptHash"))
                        )
                    case .verificationKey:
                        hotCredential = CommitteeHotCredential(
                            credential: .verificationKeyHash(
                                try LedgerValues.hash(hex: delegate.id.description, as: VerificationKeyHash.self, "Ogmios VerificationKeyHash")
                            )
                        )
                    }
            case .resigned, .none:
                hotCredential = nil
        }

        let status: CommitteeMemberStatus
        switch member.status {
            case .active:
                status = .active
            case .expired:
                status = .expired
            case .unrecognized:
                status = .unrecognized
        }

        return CommitteeMemberInfo(
            coldCredential: cold,
            hotCredential: hotCredential,
            expiration: EpochNumber(expirationEpoch),
            status: status
        )
    }

    /// Get the committee member information identified by an authorized hot credential.
    /// - Parameter hot: The `CommitteeHotCredential` the member has authorized.
    /// - Returns: The `CommitteeMemberInfo` object containing information about the committee member.
    public func committeeMemberInfo(hot: CommitteeHotCredential) async throws
        -> CommitteeMemberInfo
    {
        let constitutionalCommittee = try await client.ledgerStateQuery.constitutionalCommittee
            .result()

        let hotHexLower = hot.credential.payload.toHex.lowercased()

        let member = constitutionalCommittee.members.first { member in
            guard case .authorized(let delegate) = member.delegate else { return false }
            guard delegate.id.description.lowercased() == hotHexLower else { return false }
            switch (hot.credential, delegate.from) {
            case (.scriptHash, .script), (.verificationKeyHash, .verificationKey):
                return true
            default:
                return false
            }
        }

        guard let member else {
            throw CardanoChainError.valueError(
                "Committee member not found for hot credential: \(hot)"
            )
        }

        let coldCredential: CommitteeColdCredential
        switch member.from {
        case .script:
            coldCredential = CommitteeColdCredential(
                credential: .scriptHash(try LedgerValues.hash(hex: member.id.description, as: ScriptHash.self, "Ogmios ScriptHash"))
            )
        case .verificationKey:
            coldCredential = CommitteeColdCredential(
                credential: .verificationKeyHash(
                    try LedgerValues.hash(hex: member.id.description, as: VerificationKeyHash.self, "Ogmios VerificationKeyHash")
                )
            )
        }

        guard let expirationEpoch: Int = try member.mandate.map({ try $0.epoch.checked("Ogmios committee mandate epoch") }) else {
            throw CardanoChainError.valueError(
                "Missing expiration epoch for committee member: \(coldCredential)"
            )
        }

        let status: CommitteeMemberStatus
        switch member.status {
            case .active:
                status = .active
            case .expired:
                status = .expired
            case .unrecognized:
                status = .unrecognized
        }

        return CommitteeMemberInfo(
            coldCredential: coldCredential,
            hotCredential: hot,
            expiration: EpochNumber(expirationEpoch),
            status: status
        )
    }

    // MARK: - Votes / Governance State

    public func govActionVotes(govActionID: GovActionID) async throws -> GovActionVotes {
        let proposals = try await client.ledgerStateQuery.governanceProposals.result()

        guard let entry = proposals.first(where: {
            $0.proposal.transaction.id == govActionID.transactionID.payload.toHex
                && $0.proposal.index == UInt32(govActionID.govActionIndex)
        }) else {
            throw CardanoChainError.valueError("Governance action not found: \(govActionID)")
        }

        return try Self.mapProposalState(entry, proposalID: govActionID)
    }

    public func govActionsAll() async throws -> [GovActionVotes] {
        let proposals = try await client.ledgerStateQuery.governanceProposals.result()
        return try proposals.map { state in
            let id = GovActionID(
                transactionID: try LedgerValues.hash(hex: state.proposal.transaction.id, as: TransactionId.self, "Ogmios TransactionId"),
                govActionIndex: try state.proposal.index.checked("Ogmios proposal index")
            )
            return try Self.mapProposalState(state, proposalID: id)
        }
    }

    public func committeeState() async throws -> CommitteeStateInfo {
        let constitutionalCommittee = try await client.ledgerStateQuery.constitutionalCommittee.result()

        let members: [CommitteeStateInfo.Member] = try constitutionalCommittee.members.map { m in
            let cold: CommitteeColdCredential = try {
                switch m.from {
                case .script:
                    return CommitteeColdCredential(
                        credential: .scriptHash(try LedgerValues.hash(hex: m.id.description, as: ScriptHash.self, "Ogmios ScriptHash"))
                    )
                case .verificationKey:
                    return CommitteeColdCredential(
                        credential: .verificationKeyHash(
                            try LedgerValues.hash(hex: m.id.description, as: VerificationKeyHash.self, "Ogmios VerificationKeyHash")
                        )
                    )
                }
            }()

            let hot: CommitteeHotCredential?
            switch m.delegate {
            case .authorized(let d):
                switch d.from {
                case .script:
                    hot = CommitteeHotCredential(
                        credential: .scriptHash(try LedgerValues.hash(hex: d.id.description, as: ScriptHash.self, "Ogmios ScriptHash"))
                    )
                case .verificationKey:
                    hot = CommitteeHotCredential(
                        credential: .verificationKeyHash(
                            try LedgerValues.hash(hex: d.id.description, as: VerificationKeyHash.self, "Ogmios VerificationKeyHash")
                        )
                    )
                }
            case .resigned, .none:
                hot = nil
            }

            let status: CommitteeMemberStatus
            switch m.status {
            case .active:        status = .active
            case .expired:       status = .expired
            case .unrecognized:  status = .unrecognized
            }

            return CommitteeStateInfo.Member(
                coldCredential: cold,
                hotCredential: hot,
                expiration: m.mandate.map { $0.epoch },
                status: status
            )
        }

        // The committee's quorum is an Ogmios `Ratio` ("num/den"); with no
        // committee (a state of no confidence) there is none, and it is nil.
        let threshold = try Self.quorumThreshold(constitutionalCommittee.quorum?.value)

        return CommitteeStateInfo(members: members, threshold: threshold)
    }

    /// The committee quorum, an Ogmios `"n/d"` ratio, exactly; `nil` when
    /// there is none, as with no committee.
    ///
    /// - Throws: When it is present but not a unit interval.
    static func quorumThreshold(_ raw: String?) throws -> UnitInterval? {
        try raw.map { try LedgerValues.unitInterval(text: $0, "Ogmios committee quorum") }
    }

    // MARK: - Helpers

    /// The parameters a proposal changes; a field Ogmios leaves out is unchanged.
    ///
    /// A field a Conway update cannot carry (extra entropy, the minimum UTxO
    /// constant, the reference-scripts size limit) throws rather than being
    /// dropped from the update.
    static func proposedUpdate(_ p: ProposedProtocolParameters) throws -> ProtocolParamUpdate {
        func what(_ field: String) -> String { "Ogmios proposed \(field)" }
        func ratio(_ r: SwiftOgmios.Ratio?, _ field: String) throws -> UnitInterval? {
            try r.map { try LedgerValues.unitInterval(text: $0.value, what(field)) }
        }
        func nni(_ r: SwiftOgmios.Ratio?, _ field: String) throws -> NonNegativeInterval? {
            try r.map { try LedgerValues.nonNegativeInterval(text: $0.value, what(field)) }
        }
        func coin(_ v: ValueAdaOnly?, _ field: String) throws -> Coin? {
            try v.map { try $0.ada.lovelace.checked(what(field)) }
        }
        func int<T: FixedWidthInteger, S: BinaryInteger>(_ v: S?, _ field: String) throws -> T? {
            try v.map { try LedgerValues.integer($0, as: T.self, what(field)) }
        }
        func required(_ r: SwiftOgmios.Ratio, _ field: String) throws -> UnitInterval {
            try LedgerValues.unitInterval(text: r.value, what(field))
        }

        if p.extraEntropy != nil { throw CardanoChainError.notImplemented("\(what("extraEntropy")) is not a Conway parameter") }
        if p.minUtxoDepositConstant != nil {
            throw CardanoChainError.notImplemented("\(what("minUtxoDepositConstant")) is not a Conway parameter")
        }
        if p.maxReferenceScriptsSize != nil {
            throw CardanoChainError.notImplemented("\(what("maxReferenceScriptsSize")) is not an updatable parameter")
        }

        var u = ProtocolParamUpdate()
        u.minFeeA = try int(p.minFeeCoefficient, "minFeeCoefficient")
        u.minFeeB = try coin(p.minFeeConstant, "minFeeConstant")
        u.minFeeRefScriptCoinsPerByte = try p.minFeeReferenceScripts.map {
            try LedgerValues.nonNegativeInterval($0.base, what("minFeeReferenceScripts.base"))
        }
        u.adaPerUtxoByte = try int(p.minUtxoDepositCoefficient, "minUtxoDepositCoefficient")
        u.maxBlockBodySize = try int(p.maxBlockBodySize?.bytes, "maxBlockBodySize")
        u.maxBlockHeaderSize = try int(p.maxBlockHeaderSize?.bytes, "maxBlockHeaderSize")
        u.maxTransactionSize = try int(p.maxTransactionSize?.bytes, "maxTransactionSize")
        u.maxValueSize = try int(p.maxValueSize?.bytes, "maxValueSize")
        u.keyDeposit = try coin(p.stakeCredentialDeposit, "stakeCredentialDeposit")
        u.poolDeposit = try coin(p.stakePoolDeposit, "stakePoolDeposit")
        u.maximumEpoch = try int(p.stakePoolRetirementEpochBound, "stakePoolRetirementEpochBound")
        u.poolPledgeInfluence = try nni(p.stakePoolPledgeInfluence, "stakePoolPledgeInfluence")
        u.minPoolCost = try coin(p.minStakePoolCost, "minStakePoolCost")
        u.nOpt = try int(p.desiredNumberOfStakePools, "desiredNumberOfStakePools")
        u.decentralizationConstant = try ratio(p.federatedBlockProductionRatio, "federatedBlockProductionRatio")
        u.expansionRate = try ratio(p.monetaryExpansion, "monetaryExpansion")
        u.treasuryGrowthRate = try ratio(p.treasuryExpansion, "treasuryExpansion")
        u.collateralPercentage = try int(p.collateralPercentage, "collateralPercentage")
        u.maxCollateralInputs = try int(p.maxCollateralInputs, "maxCollateralInputs")
        if let models = p.plutusCostModels {
            var byLanguage: [Int: [Int64]] = [:]
            for (language, values) in models.costModels {
                let id: Int
                switch language {
                case "plutus:v1": id = 0
                case "plutus:v2": id = 1
                case "plutus:v3": id = 2
                default:
                    throw CardanoChainError.valueError("\(what("plutusCostModels")): unknown language \(language)")
                }
                guard !values.isEmpty else {
                    throw CardanoChainError.valueError("\(what("plutusCostModels")) \(language) is empty")
                }
                byLanguage[id] = values
            }
            u.costModels = try CostModels(byLanguage)
        }
        u.executionCosts = try p.scriptExecutionPrices.map {
            ExUnitPrices(
                memPrice: try LedgerValues.nonNegativeInterval(text: $0.memory.value, what("scriptExecutionPrices.memory")),
                stepPrice: try LedgerValues.nonNegativeInterval(text: $0.cpu.value, what("scriptExecutionPrices.cpu")))
        }
        u.maxTxExUnits = p.maxExecutionUnitsPerTransaction.map { ExUnits(mem: $0.memory, steps: $0.cpu) }
        u.maxBlockExUnits = p.maxExecutionUnitsPerBlock.map { ExUnits(mem: $0.memory, steps: $0.cpu) }
        u.poolVotingThresholds = try p.stakePoolVotingThresholds.map { t in
            PoolVotingThresholds(
                motionNoConfidence: try required(t.noConfidence, "stakePoolVotingThresholds.noConfidence"),
                committeeNormal: try required(
                    t.constitutionalCommittee.default, "stakePoolVotingThresholds.constitutionalCommittee.default"),
                committeeNoConfidence: try required(
                    t.constitutionalCommittee.stateOfNoConfidence,
                    "stakePoolVotingThresholds.constitutionalCommittee.stateOfNoConfidence"),
                hardForkInitiation: try required(t.hardForkInitiation, "stakePoolVotingThresholds.hardForkInitiation"),
                ppSecurityGroup: try required(
                    t.protocolParametersUpdate.security, "stakePoolVotingThresholds.protocolParametersUpdate.security"))
        }
        u.drepVotingThresholds = try p.delegateRepresentativeVotingThresholds.map { t in
            // CDDL order.
            try DrepVotingThresholds(thresholds: [
                required(t.noConfidence, "dRepVotingThresholds.noConfidence"),
                required(t.constitutionalCommittee.default, "dRepVotingThresholds.constitutionalCommittee.default"),
                required(
                    t.constitutionalCommittee.stateOfNoConfidence,
                    "dRepVotingThresholds.constitutionalCommittee.stateOfNoConfidence"),
                required(t.constitution, "dRepVotingThresholds.constitution"),
                required(t.hardForkInitiation, "dRepVotingThresholds.hardForkInitiation"),
                required(t.protocolParametersUpdate.network, "dRepVotingThresholds.protocolParametersUpdate.network"),
                required(t.protocolParametersUpdate.economic, "dRepVotingThresholds.protocolParametersUpdate.economic"),
                required(t.protocolParametersUpdate.technical, "dRepVotingThresholds.protocolParametersUpdate.technical"),
                required(t.protocolParametersUpdate.governance, "dRepVotingThresholds.protocolParametersUpdate.governance"),
                required(t.treasuryWithdrawals, "dRepVotingThresholds.treasuryWithdrawals"),
            ])
        }
        u.minCommitteeSize = try int(p.constitutionalCommitteeMinSize, "constitutionalCommitteeMinSize")
        u.committeeTermLimit = try int(p.constitutionalCommitteeMaxTermLength, "constitutionalCommitteeMaxTermLength")
        u.governanceActionValidityPeriod = try int(p.governanceActionLifetime, "governanceActionLifetime")
        u.governanceActionDeposit = try coin(p.governanceActionDeposit, "governanceActionDeposit")
        u.drepDeposit = try coin(p.delegateRepresentativeDeposit, "delegateRepresentativeDeposit")
        u.drepInactivityPeriod = try int(p.delegateRepresentativeMaxIdleTime, "delegateRepresentativeMaxIdleTime")
        u.protocolVersion = try p.version.map {
            ProtocolVersion(major: try LedgerValues.integer($0.major, as: Int.self, what("version.major")),
                            minor: try LedgerValues.integer($0.minor, as: Int.self, what("version.minor")))
        }
        return u
    }

    /// Map an Ogmios `GovernanceAction` into the SwiftCardanoCore `GovAction`
    /// as the ledger holds it: each action's `id` is its `ancestor` (or `nil`),
    /// guardrails become the policy or constitution script hash, and nothing is
    /// filled in that Ogmios did not report.
    private static func mapOgmiosGovernanceAction(
        _ action: SwiftOgmios.GovernanceAction
    ) throws -> GovAction {
        /// An action's `ancestor`: the previous action of its purpose, or `nil` for none.
        func previous(_ ancestor: GovernanceProposalReference?) throws -> GovActionID? {
            try ancestor.map {
                GovActionID(
                    transactionID: try LedgerValues.hash(
                        hex: $0.transaction.id, as: TransactionId.self, "Ogmios ancestor transaction"),
                    govActionIndex: try $0.index.checked("Ogmios ancestor index"))
            }
        }
        /// An action's `guardrails`: the constitution's guardrails script hash, or `nil`.
        func guardrails(_ guardrails: Guardrails?) throws -> ScriptHash? {
            try guardrails.map {
                try LedgerValues.hash(hex: $0.hash.value, as: ScriptHash.self, "Ogmios guardrails script hash")
            }
        }
        switch action {
        case .protocolParametersUpdate(let update):
            return .parameterChangeAction(LedgerGovActionJSON.parameterChange(
                prev: try previous(update.ancestor),
                update: try proposedUpdate(update.parameters),
                policyHash: try guardrails(update.guardrails)
            ))

        case .hardForkInitiation(let hf):
            return .hardForkInitiationAction(HardForkInitiationAction(
                id: try previous(hf.ancestor),
                protocolVersion: ProtocolVersion(
                    major: Int(hf.version.major),
                    minor: Int(hf.version.minor)
                )
            ))

        case .treasuryTransfer:
            // A pre-Conway transfer between the reserves and the treasury, which
            // Conway has no governance action for. Reporting it as any Conway
            // action would misrepresent it.
            throw CardanoChainError.notImplemented("Ogmios reported a treasury transfer, which is not a Conway governance action")

        case .treasuryWithdrawals(let tw):
            var withdrawals: [SwiftCardanoCore.RewardAccount: Coin] = [:]
            for (stakeAddressBech32, delta) in tw.withdrawals.value {
                let address = try Address.fromBech32(stakeAddressBech32)
                withdrawals[SwiftCardanoCore.RewardAccount(address.toBytes())] =
                    try delta.ada.lovelace.checked("Ogmios treasury withdrawal amount")
            }
            return .treasuryWithdrawalsAction(TreasuryWithdrawalsAction(
                withdrawals: withdrawals,
                policyHash: try guardrails(tw.guardrails)
            ))

        case .constitutionalCommittee(let cc):
            // `coldCredentials` holds the members to remove; the members to add
            // go in `credentialEpochs` with their terms.
            let coldCredentials: Set<CommitteeColdCredential> = Set(try (cc.members.removed ?? []).map {
                try makeCommitteeColdCredential(idHex: $0.id.value, from: $0.from)
            })
            var credentialEpochs: [CommitteeColdCredential: UInt64] = [:]
            for member in cc.members.added ?? [] {
                let cred = try makeCommitteeColdCredential(
                    idHex: member.id.value,
                    from: member.from
                )
                credentialEpochs[cred] = try LedgerValues.required(
                    member.mandate, "Ogmios committee member to add \(member.id.value) term").epoch
            }
            // Ogmios's schema requires the quorum; a missing one is not 0.
            let interval = try LedgerValues.unitInterval(
                text: LedgerValues.required(cc.quorum?.value, "Ogmios committee update quorum"),
                "Ogmios committee update quorum")
            return .updateCommittee(UpdateCommittee(
                id: try previous(cc.ancestor),
                coldCredentials: coldCredentials,
                credentialEpochs: credentialEpochs,
                interval: interval
            ))

        case .constitution(let c):
            let anchor = try LedgerValues.anchor(
                url: c.metadata.url, hash: c.metadata.hash, "Ogmios constitution anchor")
            return .newConstitution(NewConstitution(
                id: try previous(c.ancestor),
                constitution: Constitution(anchor: anchor, scriptHash: try guardrails(c.guardrails))
            ))

        case .noConfidence(let nc):
            return .noConfidence(NoConfidence(id: try previous(nc.ancestor)))

        case .information:
            return .infoAction(InfoAction())
        }
    }

    /// Build a `CommitteeColdCredential` from an Ogmios member-summary id +
    /// credential origin (script vs verificationKey).
    private static func makeCommitteeColdCredential(
        idHex: String,
        from origin: SwiftOgmios.CredentialOrigin
    ) throws -> CommitteeColdCredential {
        CommitteeColdCredential(
            credential: try LedgerValues.credential(
                isScript: origin == .script, hex: idHex, "Ogmios committee member id"))
    }

    private static func mapProposalState(
        _ state: SwiftOgmios.GovernanceProposalState,
        proposalID: GovActionID
    ) throws -> GovActionVotes {
        var committeeVotes: [SwiftCardanoNetwork.CommitteeVote] = []
        var dRepVotes: [SwiftCardanoNetwork.DRepVote] = []
        var stakePoolVotes: [SwiftCardanoNetwork.StakePoolVote] = []

        for v in state.votes {
            let vote: Vote
            switch v.vote {
            case .yes: vote = .yes
            case .no: vote = .no
            case .abstain: vote = .abstain
            }

            switch v.issuer {
            case .constitutionalCommittee(let cc):
                let cred: CommitteeHotCredential
                switch cc.from {
                case .script:
                    cred = CommitteeHotCredential(
                        credential: .scriptHash(try LedgerValues.hash(hex: cc.id.description, as: ScriptHash.self, "Ogmios ScriptHash"))
                    )
                case .verificationKey:
                    cred = CommitteeHotCredential(
                        credential: .verificationKeyHash(
                            try LedgerValues.hash(hex: cc.id.description, as: VerificationKeyHash.self, "Ogmios VerificationKeyHash")
                        )
                    )
                }
                committeeVotes.append(.init(credential: cred, vote: vote))
            case .delegateRepresentative(let dr):
                let cred: DRepCredential
                switch dr.from {
                case .script:
                    cred = DRepCredential(
                        credential: .scriptHash(try LedgerValues.hash(hex: dr.id.description, as: ScriptHash.self, "Ogmios ScriptHash"))
                    )
                case .verificationKey:
                    cred = DRepCredential(
                        credential: .verificationKeyHash(
                            try LedgerValues.hash(hex: dr.id.description, as: VerificationKeyHash.self, "Ogmios VerificationKeyHash")
                        )
                    )
                }
                dRepVotes.append(.init(credential: cred, vote: vote))
            case .stakePoolOperator(let spo):
                stakePoolVotes.append(.init(poolOperator: try PoolOperator(from: .string(spo.id.value)), vote: vote))
            case .genesisDelegate:
                // Genesis delegates are a pre-Conway construct — ignored for current vote tally.
                break
            }
        }

        // Convert deposit / returnAccount / metadata into core types.
        let deposit: Coin = try state.deposit.ada.lovelace.checked("Ogmios proposal deposit")
        let returnAddrData = try Address.fromBech32(state.returnAccount.value).toBytes()
        let anchor: SwiftCardanoCore.Anchor? = try LedgerValues.anchor(
            url: state.metadata.url, hash: state.metadata.hash.description,
            "Ogmios proposal anchor")

        let govAction = try mapOgmiosGovernanceAction(state.action)

        return GovActionVotes(
            govActionId: proposalID,
            govAction: govAction,
            committeeVotes: committeeVotes,
            dRepVotes: dRepVotes,
            stakePoolVotes: stakePoolVotes,
            deposit: deposit,
            depositReturnAddr: returnAddrData,
            anchor: anchor,
            proposedIn: state.since.epoch,
            expiresAfter: state.until.epoch,
            ratifiedEpoch: nil,
            enactedEpoch: nil,
            droppedEpoch: nil,
            expiredEpoch: nil
        )
    }
}
