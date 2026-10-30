#if CLIBACKENDS
import Foundation
import SwiftCardanoCore
import SwiftCardanoNetwork
import SwiftCardanoUtils
import SystemPackage

/// A chain context implementation that shells out to the `cardano-cli` binary.
///
/// `CardanoCliChainContext` wraps a local `cardano-cli` installation and requires access to a
/// running `cardano-node` socket. It is the right choice when you control the server
/// environment and need full local-node fidelity without running Ogmios or the NtC socket
/// directly.
///
/// Protocol parameters, UTxO sets, and the chain tip are cached to avoid redundant CLI
/// invocations. Cache lifetimes and sizes are configurable at initialisation time.
///
/// ## Creating a Context
///
/// ```swift
/// // Minimal — reads node config, binary and socket from ~/.cardano-cli/config
/// let context = try await CardanoCliChainContext(network: .mainnet)
///
/// // Explicit paths
/// let context = try await CardanoCliChainContext(
///     nodeConfig: FilePath("/opt/cardano/mainnet/config.json"),
///     binary: FilePath("/usr/local/bin/cardano-cli"),
///     socket: FilePath("/ipc/node.socket"),
///     network: .mainnet
/// )
///
/// // Tuned caching
/// let context = try await CardanoCliChainContext(
///     nodeConfig: FilePath("/opt/cardano/preview/config.json"),
///     binary: FilePath("/usr/local/bin/cardano-cli"),
///     socket: FilePath("/ipc/node.socket"),
///     network: .preview,
///     refetchChainTipInterval: 30,
///     utxoCacheSize: 5_000,
///     datumCacheSize: 1_000
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
/// - ``init(nodeConfig:binary:socket:network:era:ttlBuffer:refetchChainTipInterval:utxoCacheSize:datumCacheSize:cli:)``
///
/// ### Querying Chain State
/// - ``utxos(address:)``
/// - ``stakeAddressInfo(address:)``
/// - ``stakePools()``
///
/// ### Transaction Operations
/// - ``submitTxCBOR(cbor:)``
/// - ``evaluateTxCBOR(cbor:)``
public actor CardanoCliChainContext: ChainContext {
    // MARK: - Properties

    nonisolated public var name: String { "Cardano-CLI" }
    nonisolated public var type: ContextType { .online }

    public let cli: CardanoCLI
    private var lastKnownBlockSlot: Int = 0
    private var lastChainTipFetch: TimeInterval = 0
    private var refetchChainTipInterval: TimeInterval
    private var utxoCache: [String: ([UTxO], TimeInterval)]
    private var datumCache: [String: Any]
    private let cache = Cache<String, Int>()
    private let cacheTTL: TimeInterval = 1.0  // 1 second TTL
    private let _network: Network
    private var _epochFetch: Task<Int, Error>?
    private var _lastBlockSlotFetch: Task<Int, Error>?
    private var _genesisParameters: GenesisParameters?
    private var _genesisParametersFetch: Task<GenesisParameters, Error>?
    private var _protocolParameters: ProtocolParameters?
    private var _protocolParametersFetch: Task<ProtocolParameters, Error>?

    // MARK: - ChainContext Protocol Properties

    nonisolated public var networkId: NetworkId {
        self._network.networkId
    }

    public func era() async throws -> Era? {
        return try await cli.getEra()
    }

    public func epoch() async throws -> Int {
        if let inFlight = _epochFetch { return try await inFlight.value }

        // CLI calls fork a subprocess. Dedup concurrent callers via an in-flight
        // Task so we don't fork multiple `cardano-cli` processes for the same query.
        // No long-lived cache here — each fresh call invokes the CLI again.
        let task = Task<Int, Error> {
            do {
                let value: Int = try await self.cli.getEpoch().checked("cardano-cli epoch")
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

    public func lastBlockSlot() async throws -> Int {
        let cacheKey = "lastBlockSlot"

        if let cachedValue = self.cache.value(forKey: cacheKey) {
            return cachedValue
        }
        if let inFlight = _lastBlockSlotFetch { return try await inFlight.value }

        let task = Task<Int, Error> {
            do {
                let value: Int = try await self.cli.getTip().checked("cardano-cli tip slot")
                self.cache.insert(value, forKey: cacheKey)
                self._lastBlockSlotFetch = nil
                return value
            } catch {
                self._lastBlockSlotFetch = nil
                throw error
            }
        }
        _lastBlockSlotFetch = task
        return try await task.value
    }

    public func genesisParameters() async throws -> GenesisParameters {
        if let cached = _genesisParameters { return cached }
        if let inFlight = _genesisParametersFetch { return try await inFlight.value }

        let task = Task<GenesisParameters, Error> {
            do {
                let value = try await self.fetchGenesisParametersFromCLI()
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

    private func fetchGenesisParametersFromCLI() async throws -> GenesisParameters {
        guard let nodeConfig = self.cli.cardanoConfig.config else {
            throw CardanoChainError.valueError("Cardano node config is nil")
        }

        let genesis = try GenesisParameters(
            nodeConfigFilePath: nodeConfig.string
        )

        // Set the refetch chain tip interval if not provided
        if self.refetchChainTipInterval == 0 {
            // slotLength / f, with f = n/d: slotLength × d / n.
            guard let slotLength = genesis.slotLength,
                  let f = genesis.activeSlotsCoefficient, f.numerator > 0 else {
                throw CardanoChainError.valueError("Genesis has no slot length or active slot coefficient")
            }
            self.refetchChainTipInterval = NSDecimalNumber(
                decimal: slotLength * Decimal(f.denominator) / Decimal(f.numerator)
            ).doubleValue
        }

        return genesis
    }

    public func protocolParameters() async throws -> ProtocolParameters {
        let chainTipUpdated = try await self.isChainTipUpdated()
        if !chainTipUpdated, let cached = _protocolParameters { return cached }
        if let inFlight = _protocolParametersFetch { return try await inFlight.value }

        let task = Task<ProtocolParameters, Error> {
            do {
                let value = try await self.queryCurrentProtocolParams()
                self._protocolParameters = value
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

    /// Initialize a new CardanoCliChainContext
    ///
    /// - Parameters:
    ///   - nodeConfig: Path to the cardano-node config file
    ///   - binary: Path to the cardano-cli binary
    ///   - socket: Path to the cardano-node socket
    ///   - network: Network to use
    ///   - era: Era to use
    ///   - ttlBuffer: The time to live buffer
    ///   - refetchChainTipInterval: Interval in seconds to refetch the chain tip
    ///   - utxoCacheSize: Size of the UTxO cache
    ///   - datumCacheSize: Size of the datum cache
    ///   - cli: An instance of a CLIClient. If nil, a default CardanoCLIClient will be created.
    public init(
        nodeConfig: FilePath? = nil,
        binary: FilePath? = nil,
        socket: FilePath? = nil,
        network: Network = .mainnet,
        era: Era = .conway,
        ttlBuffer: Int = 3600,
        refetchChainTipInterval: TimeInterval? = nil,
        utxoCacheSize: Int = 10000,
        datumCacheSize: Int = 10000,
        cli: CardanoCLI? = nil
    ) async throws {
        self.refetchChainTipInterval = refetchChainTipInterval ?? 1000
        self.utxoCache = [:]
        self.datumCache = [:]
        self._network = network

        if let cli = cli {
            self.cli = cli
        } else if let nodeConfig = nodeConfig,
            let binary = binary,
            let socket = socket
        {
            self.cli = try await CardanoCLI(
                configuration: Config(
                    cardano: CardanoConfig(
                        cli: binary,
                        socket: socket,
                        config: nodeConfig,
                        network: self._network,
                        era: era,
                        ttlBuffer: 3600
                    )
                )
            )
        } else {
            self.cli = try await CardanoCLI(configuration: Config.default())
        }
    }

    public init(cardanoConfig: CardanoConfig) async throws {
        self.refetchChainTipInterval = 1000
        self.utxoCache = [:]
        self.datumCache = [:]
        self._network = cardanoConfig.network

        self.cli = try await CardanoCLI(
            configuration: Config(cardano: cardanoConfig)
        )
    }

    // MARK: - Public Methods

    /// Query the chain tip
    ///
    /// - Returns: The chain tip as a dictionary
    /// - Throws: CardanoChainError if the query fails
    public func chainTip() async throws -> ChainTip {
        let result = try await cli.query.tip()

        self.lastChainTipFetch = Date().timeIntervalSince1970

        return result
    }

    /// Query the current protocol parameters
    ///
    /// - Returns: The protocol parameters as a dictionary
    /// - Throws: CardanoChainError if the query fails
    public func queryCurrentProtocolParams() async throws -> ProtocolParameters {
        let result = try await cli.query.protocolParameters()
        guard let data = result.data(using: .utf8) else {
            throw CardanoChainError.valueError("Failed to parse protocol parameters JSON")
        }

        let json = try JSONDecoder().decode(ProtocolParameters.self, from: data)

        return json
    }

    /// Check if the chain tip has been updated
    ///
    /// - Returns: True if the chain tip has been updated, false otherwise
    /// - Throws: CardanoChainError if the query fails
    public func isChainTipUpdated() async throws -> Bool {
        // Fetch at almost every refetchChainTipInterval seconds
        if Date().timeIntervalSince1970 - lastChainTipFetch < refetchChainTipInterval {
            return false
        }

        let syncProgress = try await cli.getSyncProgress()

        return syncProgress != 100.0
    }

    // MARK: - Private Methods

    /// Get a script object from a reference script dictionary
    ///
    /// - Parameter referenceScript: The reference script dictionary
    /// - Returns: A script object
    /// - Throws: CardanoChainError if the script type is not supported
    private func getScript(from referenceScript: [String: Any]) async throws -> ScriptType {
        guard let script = referenceScript["script"] as? [String: Any],
            let scriptType = script["type"] as? String
        else {
            throw CardanoChainError.valueError("Invalid reference script")
        }

        if scriptType == "PlutusScriptV1" {
            guard let cborHex = script["cborHex"] as? String else {
                throw CardanoChainError.valueError("Invalid PlutusScriptV1 CBOR")
            }
            let cborData = try LedgerValues.hexBytes(cborHex, "cardano-cli PlutusScriptV1 cborHex")

            // Create PlutusV1Script from CBOR
            let v1script = PlutusV1Script(data: cborData)
            return .plutusV1Script(v1script)
        } else if scriptType == "PlutusScriptV2" {
            guard let cborHex = script["cborHex"] as? String else {
                throw CardanoChainError.valueError("Invalid PlutusScriptV2 CBOR")
            }
            let cborData = try LedgerValues.hexBytes(cborHex, "cardano-cli PlutusScriptV2 cborHex")

            // Create PlutusV2Script from CBOR
            let v2script = PlutusV2Script(data: cborData)
            return .plutusV2Script(v2script)
        } else if scriptType == "PlutusScriptV3" {
            guard let cborHex = script["cborHex"] as? String else {
                throw CardanoChainError.valueError("Invalid PlutusScriptV3 CBOR")
            }
            let cborData = try LedgerValues.hexBytes(cborHex, "cardano-cli PlutusScriptV3 cborHex")

            // Create PlutusV3Script from CBOR
            let v3script = PlutusV3Script(data: cborData)
            return .plutusV3Script(v3script)
        } else {
            // Create NativeScript from dictionary
            // Convert the dictionary to JSON data
            guard let jsonData = try? JSONSerialization.data(withJSONObject: script, options: [])
            else {
                throw CardanoChainError.valueError("Failed to serialize NativeScript JSON")
            }

            // Decode the JSON data to a NativeScript object
            let nativeScript = try JSONDecoder().decode(NativeScript.self, from: jsonData)
            return .nativeScript(nativeScript)
        }
    }

    // MARK: - ChainContext Protocol Methods

    /// Get all UTxOs associated with an address
    ///
    /// - Parameter address: An address encoded with bech32
    /// - Returns: A list of UTxOs
    /// - Throws: CardanoChainError if the query fails
    public func utxos(address: Address) async throws -> [UTxO] {
        // Check if the UTxOs are in the cache
        let currentSlot = try await lastBlockSlot()
        let cacheKey = "\(currentSlot):\(try address.toBech32())"

        if let (cachedUtxos, _) = utxoCache[cacheKey] {
            return cachedUtxos
        }

        // Query the UTxOs
        let utxos = try await cli.utxos(address: address)

        // Cache the UTxOs
        utxoCache[cacheKey] = (utxos, Date().timeIntervalSince1970)

        return utxos
    }

    /// Get the UTxO for a specific transaction input.
    ///
    /// - Parameter input: A transaction input identifying the UTxO by transaction hash and output index.
    /// - Returns: A tuple of the UTxO and a boolean indicating whether it has been spent,
    ///   or `nil` if the UTxO cannot be found. CardanoCLI only queries the live UTxO set,
    ///   so `isSpent` is always `false` when a result is returned.
    /// - Throws: CardanoChainError if the query fails.
    public func utxo(input: TransactionInput) async throws -> (UTxO, isSpent: Bool)? {
        let txInStr = input.description  // "<txhash>#<index>"
        let result = try await cli.query.utxo(arguments: [
            "--tx-in", txInStr, "--output-json", "--out-file", "/dev/stdout",
        ])

        guard let data = result.data(using: .utf8),
            let rawUtxos = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [String: [String: Any]]
        else {
            throw CardanoChainError.valueError("Failed to parse UTxO JSON")
        }

        guard let utxoEntry = rawUtxos[txInStr] else {
            return nil  // Not in UTXO set: either spent or never existed
        }

        guard let utxoValue = utxoEntry["value"] as? [String: Any] else {
            return nil
        }

        var value = Value(coin: 0)
        var multiAsset = MultiAsset([:])

        for (asset, amount) in utxoValue {
            if asset == "lovelace" {
                if let lovelace = try LedgerValues.bigInt(json: amount, "cardano-cli lovelace") {
                    value.coin = lovelace
                }
            } else {
                let policyId = asset
                guard let assets = amount as? [String: Any] else { continue }
                for (assetHexName, assetAmount) in assets {
                    let policy = try LedgerValues.hash(hex: policyId, as: ScriptHash.self, "cardano-cli ScriptHash")
                    let assetName = AssetName(from: assetHexName)
                    if multiAsset[policy] == nil {
                        multiAsset[policy] = Asset([:])
                    }
                    multiAsset[policy]?[assetName] = try LedgerValues.bigInt(
                        json: assetAmount, "cardano-cli asset quantity")
                }
            }
        }

        value.multiAsset = multiAsset

        var datumHash: DatumHash? = nil
        if let datumHashStr = utxoEntry["datumhash"] as? String {
            datumHash = try LedgerValues.hash(hex: datumHashStr, as: DatumHash.self, "cardano-cli DatumHash")
        }

        var datumOption: DatumOption? = nil
        if let datumStr = utxoEntry["datum"] as? String {
            let datumData = try LedgerValues.hexBytes(datumStr, "cardano-cli UTxO datum")
            datumOption = try DatumOption.fromCBOR(data: datumData)
        } else if let inlineDatum = utxoEntry["inlineDatum"] as? [AnyHashable: Any] {
            let primitiveDict = try Primitive.fromAny(inlineDatum)
            let plutusData = try PlutusData(from: primitiveDict)
            datumOption = DatumOption(datum: plutusData)
        }

        var script: ScriptType? = nil
        if let referenceScript = utxoEntry["referenceScript"] as? [String: Any] {
            script = try await getScript(from: referenceScript)
        }

        guard let addressText = utxoEntry["address"] as? String else {
            throw CardanoChainError.valueError("cardano-cli UTxO \(txInStr) has no address")
        }
        let address = try Address(from: .string(addressText))
        let txOut = TransactionOutput(
            address: address,
            amount: value,
            datumHash: datumHash,
            datumOption: datumOption,
            script: script
        )

        return (UTxO(input: input, output: txOut), false)
    }

    /// Submit a transaction to the blockchain
    ///
    /// - Parameter cbor: The transaction to be submitted
    /// - Returns: The transaction hash
    /// - Throws: CardanoChainError if the submission fails
    public func submitTxCBOR(cbor: Data) async throws -> String {
        let cborHex = cbor.hexEncodedString()

        // Create a temporary file for the transaction
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)

        let era = try await self.era() ?? .conway

        // Write the transaction to the temporary file
        let txJson: [String: Any] = [
            "type": "Tx \(era.rawValue.capitalized)Era",
            "description": "Generated by SwiftCardanoChain",
            "cborHex": cborHex,
        ]

        guard let txData = try? JSONSerialization.data(withJSONObject: txJson, options: []),
            (try? txData.write(to: tempFile)) != nil
        else {
            throw CardanoChainError.valueError("Failed to write transaction to temporary file")
        }

        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        // Submit the transaction
        do {
            let _ = try await cli.transaction.submit(arguments: ["--tx-file", tempFile.path])
        } catch {
            throw CardanoChainError.transactionFailed(
                "Failed to submit transaction: \(error)")
        }

        // Get the transaction ID
        var txid: String
        do {
            txid = try await cli.transaction.txId(arguments: ["--tx-file", tempFile.path])
        } catch {
            throw CardanoChainError.valueError(
                "Unable to get transaction id for \(tempFile.path): \(error)")
        }

        return txid
    }

    /// Get the stake address information
    ///
    /// - Parameter address: The stake address
    /// - Returns: List of StakeAddressInfo objects
    /// - Throws: CardanoChainError if the query fails
    public func stakeAddressInfo(address: Address) async throws -> [StakeAddressInfo] {
        return try await cli.stakeAddressInfo(address: address)
    }

    /// Get the list of stake pools
    ///
    /// - Returns: List of stake pool IDs
    public func stakePools() async throws -> [PoolOperator] {
        return try await cli.query.stakePools()
    }

    /// Get the cardano-cli version
    ///
    /// - Returns: The cardano-cli version
    /// - Throws: CardanoChainError if the query fails
    public func version() async throws -> String {
        return try await cli.version()
    }

    /// Evaluate execution units of a transaction by running every Plutus script
    /// through the local CEK machine (via `swift-cardano-uplc`).
    ///
    /// Resolves all transaction inputs (regular and reference) via `cardano-cli` and
    /// fetches the current protocol parameters, then delegates to the shared
    /// `evaluateTx(tx:resolvedInputs:protocolParameters:)` helper for the actual
    /// PhaseTwo evaluation.
    ///
    /// - Parameter cbor: The serialized transaction to be evaluated.
    /// - Returns: A dictionary mapping redeemer strings to execution units.
    /// - Throws: `CardanoChainError.invalidArgument` if the CBOR cannot be decoded.
    /// - Throws: `CardanoChainError.valueError` if any input cannot be resolved.
    public func evaluateTxCBOR(cbor: Data) async throws -> [String: ExecutionUnits] {
        let tx: Transaction
        do {
            tx = try Transaction.fromCBOR(data: cbor)
        } catch {
            throw CardanoChainError.invalidArgument(
                "Failed to decode transaction CBOR: \(error)")
        }

        let regularInputs = tx.transactionBody.inputs.asArray
        let referenceInputs = tx.transactionBody.referenceInputs?.asList ?? []
        let allInputs = regularInputs + referenceInputs

        var resolved: [UTxO] = []
        for input in allInputs {
            guard let (utxo, _) = try await self.utxo(input: input) else {
                throw CardanoChainError.valueError(
                    "Cannot evaluate transaction: input \(input) not found in live UTxO set"
                )
            }
            resolved.append(utxo)
        }

        let pp = try await self.protocolParameters()

        // A validity interval needs the chain's slot timeline; without one the
        // script cannot be given its time range and evaluation refuses it.
        let timeline = (try? await self.slotTimeline()) ?? nil

        return try await evaluateTx(
            tx: tx,
            resolvedInputs: resolved,
            protocolParameters: pp,
            slotTimeline: timeline
        )
    }

    /// Get the KES period information for a stake pool using cardano-cli.
    ///
    /// Queries the local node for KES period information using `cardano-cli query kes-period-info`.
    /// This provides detailed information about the operational certificate including the current
    /// KES period and remaining periods before expiration.
    ///
    /// - Parameters:
    ///   - pool: The pool operator identifier. Not used for CardanoCLI backend.
    ///   - opCert: The local operational certificate file. **Required** for CardanoCLI backend.
    /// - Returns: A `KESPeriodInfo` containing detailed certificate information from the node.
    /// - Throws: `CardanoChainError.valueError` if opCert is not provided or query fails.
    ///
    /// ## Example
    /// ```swift
    /// let opCert = try OperationalCertificate.load(from: "/path/to/node.opcert")
    /// let kesInfo = try await chainContext.kesPeriodInfo(pool: nil, opCert: opCert)
    /// print("KES start period: \(kesInfo.onDiskKESStart ?? 0)")
    /// ```
    public func kesPeriodInfo(pool: PoolOperator? = nil, opCert: OperationalCertificate?)
        async throws -> KESPeriodInfo
    {
        guard let opCert = opCert else {
            throw CardanoChainError.valueError(
                "Operational certificate is required for KES period info")
        }

        // Create a temporary file for the opCert
        let tempDir = FileManager.default.temporaryDirectory
        let tempOpCertFile = tempDir.appendingPathComponent(UUID().uuidString)
        let tempQueryFile = tempDir.appendingPathComponent(UUID().uuidString)

        try opCert.save(to: tempOpCertFile.path)

        defer {
            try? FileManager.default.removeItem(at: tempOpCertFile)
            try? FileManager.default.removeItem(at: tempQueryFile)
        }

        let _ = try await cli.query.kesPeriodInfo(
            arguments: [
                "--op-cert-file",
                tempOpCertFile.path,
                "--out-file",
                tempQueryFile.path,
            ]
        )

        let data = try Data(contentsOf: URL(fileURLWithPath: tempQueryFile.path))
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw CardanoChainError.valueError("Top-level JSON is not a dictionary")
        }

        // null until the pool has minted a block: -1, as the node-socket backend reports it.
        let onChainOpCertCount: Int = try LedgerValues.integer(
            json: dict["qKesNodeStateOperationalCertificateNumber"], "cardano-cli on-chain op cert counter") ?? -1
        // These come from the certificate file passed in, so they are always there.
        let onDiskOpCertCount: Int = try LedgerValues.required(
            LedgerValues.integer(json: dict["qKesOnDiskOperationalCertificateNumber"], "cardano-cli on-disk op cert counter"),
            "cardano-cli on-disk op cert counter")
        let onDiskKESStart: Int = try LedgerValues.required(
            LedgerValues.integer(json: dict["qKesStartKesInterval"], "cardano-cli KES start interval"),
            "cardano-cli KES start interval")

        return KESPeriodInfo(
            onChainOpCertCount: onChainOpCertCount,
            onDiskOpCertCount: onDiskOpCertCount,
            nextChainOpCertCount: onChainOpCertCount + 1,
            onDiskKESStart: onDiskKESStart
        )
    }

    /// Get the stake pool information.
    /// - Parameter poolId: The pool ID (Bech32).
    /// - Returns: `StakePoolInfo` object.
    /// - Throws: `CardanoChainError.cardanoCLIError` if the query fails or parsing fails.
    ///
    /// Off-chain metadata problems (unreachable URL / hash mismatch) are tolerated.
    /// Use ``stakePoolInfo(poolId:strict:)`` with `strict: true` to require successful
    /// metadata download + hash verification.
    public func stakePoolInfo(poolId: String) async throws -> StakePoolInfo {
        try await stakePoolInfo(poolId: poolId, strict: false)
    }

    /// Get the stake pool information.
    /// - Parameters:
    ///   - poolId: The pool ID (Bech32).
    ///   - strict: When `true`, the off-chain metadata is downloaded and its hash
    ///     verified; any failure is fatal. When `false`, metadata problems are
    ///     tolerated and the on-chain parameters are still returned.
    /// - Returns: `StakePoolInfo` object.
    /// - Throws: `CardanoChainError.cardanoCLIError` if the query fails or parsing fails.
    public func stakePoolInfo(poolId: String, strict: Bool) async throws -> StakePoolInfo {
        let poolOperator = try PoolOperator(from: poolId)

        let poolState = try await cli.query.poolState(
            pool: poolOperator
        )

        guard let poolEntry = poolState.pools.first(where: { $0.key == poolOperator }) else {
            throw CardanoChainError.cardanoCLIError("Pool not found or has no poolParams")
        }

        let poolParams = try await poolEntry.value.poolParams.toPoolParams(
            poolOperator: poolOperator,
            strict: strict
        )

        let stakeSnapshot = try await cli.query.stakeSnapshot(
            pool: poolOperator
        )

        let protocolState = try await cli.query.protocolState()

        let opCertInfo = protocolState.oCertCounters.first(where: { $0.key == poolOperator })

        var activeStake: UInt64? = nil
        var activeSize: Decimal? = nil

        if let poolStakeInfo = stakeSnapshot.pools.first(
            where: { $0.key == poolOperator }
        ) {
            activeStake = poolStakeInfo.value.stakeSet
            let totalStakeSet = stakeSnapshot.total.stakeSet
            if totalStakeSet > 0 {
                activeSize = Decimal(poolStakeInfo.value.stakeSet) / Decimal(totalStakeSet)
            }
        }

        // Determine pool status from the retiring field in pool state
        let status: PoolStatus
        if let retiringEpoch = poolEntry.value.retiring {
            status = .retiring(epoch: UInt(retiringEpoch))
        } else {
            status = .registered
        }

        return StakePoolInfo(
            poolParams: poolParams,
            livePledge: nil,
            liveStake: nil,
            activeStake: activeStake != nil ? UInt(activeStake!) : nil,
            activeSize: activeSize,
            opcertCounter: opCertInfo != nil ? UInt(opCertInfo!.value) : nil,
            status: status
        )
    }

    /// Get the treasury balance.
    /// - Returns: The current balance of the treasury as a `Coin` object.
    /// - Throws: An error if the treasury balance cannot be retrieved.
    public func treasury() async throws -> Coin {
        let currentTreasuryValue = try await cli.query.treasury(arguments: [])

        guard let treasuryInt = UInt64(currentTreasuryValue) else {
            throw CardanoChainError.valueError("Failed to parse treasury balance")
        }

        return Coin(treasuryInt)
    }

    /// Get the DRep information.
    /// - Parameter drep: The `DRep` object.
    /// - Returns: The `DRepInfo` object containing information about the DRep.
    public func drepInfo(drep: DRep) async throws -> DRepInfo {

        func parseDRepStateResult(_ result: String, drep: DRep) throws -> DRepInfo {
            guard let data = result.data(using: .utf8),
                let entries = try? JSONSerialization.jsonObject(with: data) as? [[Any]]
            else {
                throw CardanoChainError.valueError("cardano-cli drep-state output is not a JSON list")
            }
            // An empty list is a DRep the ledger does not know: not registered.
            guard let firstEntry = entries.first else {
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

            guard firstEntry.count == 2, let stateDict = firstEntry[1] as? [String: Any] else {
                throw CardanoChainError.valueError("cardano-cli drep-state entry is not [drep, state]")
            }

            let deposit: Coin? = try LedgerValues.integer(json: stateDict["deposit"], "cardano-cli DRep deposit")
            let expiry: UInt64? = try LedgerValues.integer(json: stateDict["expiry"], "cardano-cli DRep expiry")
            // Asked for with --include-stake, so it must be there.
            let stake: Coin = try LedgerValues.required(
                LedgerValues.integer(json: stateDict["stake"], "cardano-cli DRep stake"), "cardano-cli DRep stake")

            let anchor = try LedgerValues.anchor(json: stateDict["anchor"], "cardano-cli DRep anchor")

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
            let distKey =
                drep.credential == .alwaysAbstain
                ? "drep-alwaysAbstain"
                : "drep-alwaysNoConfidence"

            let distResult =
                try await cli
                .query
                .drepStakeDistribution(arguments: [
                    "--all-dreps",
                    "--output-json",
                ])

            guard let distData = distResult.data(using: .utf8),
                let distDict = try? JSONSerialization.jsonObject(with: distData) as? [String: Any]
            else {
                throw CardanoChainError.valueError("cardano-cli drep-stake-distribution output is not a JSON object")
            }
            // Absent from the distribution means no stake is delegated to it.
            let stake: Coin = try LedgerValues.integer(json: distDict[distKey], "cardano-cli \(distKey) stake") ?? 0

            return DRepInfo(
                active: true,
                drep: drep,
                stake: stake,
                status: .registered
            )

        case .verificationKeyHash(let hash):
            let result = try await cli.query.drepState(arguments: [
                "--drep-key-hash", hash.payload.toHex,
                "--include-stake",
                "--output-json",
            ])
            return try parseDRepStateResult(result, drep: drep)

        case .scriptHash(let hash):
            let result = try await cli.query.drepState(arguments: [
                "--drep-script-hash", hash.payload.toHex,
                "--include-stake",
                "--output-json",
            ])
            return try parseDRepStateResult(result, drep: drep)
        }
    }

    /// Get the governance action information for a given governance action ID.
    /// - Parameter govActionID: The identifier of the governance action.
    /// - Returns: The `GovActionInfo` object containing information about the governance action.
    public func govActionInfo(govActionID: GovActionID) async throws -> GovActionInfo {
        let result = try await cli.query.govState(arguments: ["--output-json"])

        guard let data = result.data(using: .utf8),
            let govState = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let proposals = govState["proposals"] as? [[String: Any]]
        else {
            throw CardanoChainError.valueError(
                "Failed to parse gov-state JSON or missing proposals")
        }

        let txHash = govActionID.transactionID.payload.toHex.lowercased()
        let index = govActionID.govActionIndex

        let nextRatifyState = govState["nextRatifyState"] as? [String: Any]
        let enactedGovActions = nextRatifyState?["enactedGovActions"] as? [[String: Any]] ?? []
        let expiredGovActions = nextRatifyState?["expiredGovActions"] as? [[String: Any]] ?? []
        let currentEpoch: UInt64 = try await self.epoch().checked("cardano-cli epoch")

        func actionIdMatches(_ actionId: [String: Any]) -> Bool {
            guard let pTxId = actionId["txId"] as? String else {
                return false
            }

            let pIndex: Int
            if let idx = actionId["govActionIx"] as? Int {
                pIndex = idx
            } else if let idx = actionId["govActionIx"] as? NSNumber {
                pIndex = idx.intValue
            } else {
                return false
            }

            return pTxId.lowercased() == txHash && pIndex == index
        }

        func actionExists(in entries: [[String: Any]]) -> Bool {
            entries.contains { entry in
                if let nestedActionId = entry["actionId"] as? [String: Any] {
                    return actionIdMatches(nestedActionId)
                }
                return actionIdMatches(entry)
            }
        }

        let proposal = proposals.first(where: {
            guard let actionId = $0["actionId"] as? [String: Any] else {
                return false
            }
            return actionIdMatches(actionId)
        })

        func extractGovAction(_ proposal: [String: Any]) throws -> GovAction {
            guard let proposalProcedure = proposal["proposalProcedure"] as? [String: Any]
            else {
                throw CardanoChainError.valueError("Missing proposalProcedure in proposal")
            }
            return try parseGovAction(actionDict: proposalProcedure["govAction"])
        }

        let inEnactedSet = actionExists(in: enactedGovActions)
        let inExpiredSet = actionExists(in: expiredGovActions)
        let proposalsEmpty = proposals.isEmpty

        let proposedIn: UInt64? = try LedgerValues.integer(json: proposal?["proposedIn"], "cardano-cli proposedIn")
        let expiresAfter: UInt64? = try LedgerValues.integer(json: proposal?["expiresAfter"], "cardano-cli expiresAfter")
        let expiredByEpoch = expiresAfter.map { currentEpoch > $0 } ?? false
        let missingFromProposals = proposal == nil

        // User-defined status rules:
        // 1) Ratified: in proposals and in nextRatifyState.enactedGovActions
        // 2) Dropped: proposals are empty
        // 3) Expired: in expiredGovActions, or missing from proposals, or currentEpoch > expiresAfter
        let ratifiedEpoch: UInt64? = (proposal != nil && inEnactedSet) ? currentEpoch : nil
        let droppedEpoch: UInt64? = (ratifiedEpoch == nil && proposalsEmpty) ? currentEpoch : nil
        let expiredEpoch: UInt64? =
            (ratifiedEpoch == nil && droppedEpoch == nil
                && (inExpiredSet || missingFromProposals || expiredByEpoch))
            ? currentEpoch : nil

        let parsedGovAction: GovAction
        if let proposal {
            parsedGovAction = try extractGovAction(proposal)
        } else {
            // When the proposal is no longer present, return a neutral placeholder action.
            parsedGovAction = .infoAction(InfoAction())
        }

        return GovActionInfo(
            govActionId: govActionID,
            govAction: parsedGovAction,
            proposedIn: proposedIn,
            expiresAfter: expiresAfter,
            ratifiedEpoch: ratifiedEpoch,
            enactedEpoch: nil,
            droppedEpoch: droppedEpoch,
            expiredEpoch: expiredEpoch
        )
    }

    /// Get the committee member information for a given committee member credential.
    /// - Parameter cold: The `CommitteeColdCredential` object representing the committee member.
    /// - Returns: The `CommitteeMemberInfo` object containing information about the committee member.
    public func committeeMemberInfo(cold: CommitteeColdCredential) async throws
        -> CommitteeMemberInfo
    {
        // Branch on the credential type: a script-hash committee member must be
        // queried with --cold-script-hash and is keyed as "scriptHash-<hex>" in the
        // committee-state JSON (key-hash members use --cold-verification-key-hash /
        // "keyHash-<hex>"). Treating every cold credential as a key hash makes
        // script-based members — e.g. preview's entire committee — unfindable.
        let coldHashFlag: String
        let coldKeyPrefix: String
        switch cold.credential {
        case .verificationKeyHash:
            coldHashFlag = "--cold-verification-key-hash"
            coldKeyPrefix = "keyHash-"
        case .scriptHash:
            coldHashFlag = "--cold-script-hash"
            coldKeyPrefix = "scriptHash-"
        }

        let result = try await cli.query.committeeState(
            arguments: [
                coldHashFlag,
                cold.credential.payload.toHex,
                "--output-json",
            ]
        )

        guard let data = result.data(using: .utf8),
            let committeeState = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let committee = committeeState["committee"] as? [String: Any]
        else {
            throw CardanoChainError.valueError("Failed to parse committee state JSON")
        }

        // Find the committee member entry for the given cold credential.
        let coldKeyHexPrefix = cold.credential.payload.toHex
        let memberKey = "\(coldKeyPrefix)\(coldKeyHexPrefix)"

        guard let memberEntry = committee[memberKey] as? [String: Any] else {
            throw CardanoChainError.valueError(
                "Committee member not found for cold credential: \(memberKey)")
        }

        // Extract expiration epoch
        guard let expiration = memberEntry["expiration"] as? Int else {
            throw CardanoChainError.valueError("Missing expiration in committee member entry")
        }

        // Parse status
        let statusStr = memberEntry["status"] as? String ?? "Unknown"
        let status: CommitteeMemberStatus
        switch statusStr.lowercased() {
        case "active":
            status = .active
        case "expired":
            status = .expired
        default:
            status = .unrecognized
        }

        // Extract hot credential from hotCredsAuthStatus. The authorized hot
        // credential may be a key hash or a script hash — use whichever field is
        // present and build the matching credential type (the entry previously
        // always read "keyHash" yet labelled it a scriptHash).
        var hotCredential: CommitteeHotCredential?
        if let hotCredsAuthStatus = memberEntry["hotCredsAuthStatus"] as? [String: Any],
            let tag = hotCredsAuthStatus["tag"] as? String,
            tag == "MemberAuthorized",
            let contents = hotCredsAuthStatus["contents"] as? [String: Any]
        {
            if let hotKeyHash = contents["keyHash"] as? String {
                hotCredential = CommitteeHotCredential(
                    credential: .verificationKeyHash(
                        try LedgerValues.hash(hex: hotKeyHash, as: VerificationKeyHash.self, "cardano-cli VerificationKeyHash")))
            } else if let hotScriptHash = contents["scriptHash"] as? String {
                hotCredential = CommitteeHotCredential(
                    credential: .scriptHash(try LedgerValues.hash(hex: hotScriptHash, as: ScriptHash.self, "cardano-cli ScriptHash")))
            }
        }

        guard let hotCred = hotCredential else {
            throw CardanoChainError.valueError(
                "Failed to parse hot credential from committee member entry")
        }

        return CommitteeMemberInfo(
            coldCredential: cold,
            hotCredential: hotCred,
            expiration: try expiration.checked("cardano-cli committee member expiration"),
            status: status
        )
    }

    /// Get the committee member information identified by an authorized hot credential.
    /// - Parameter hot: The `CommitteeHotCredential` the member has authorized.
    /// - Returns: The `CommitteeMemberInfo` object containing information about the committee member.
    public func committeeMemberInfo(hot: CommitteeHotCredential) async throws
        -> CommitteeMemberInfo
    {
        let hotHashFlag: String
        switch hot.credential {
        case .verificationKeyHash:
            hotHashFlag = "--hot-key-hash"
        case .scriptHash:
            hotHashFlag = "--hot-script-hash"
        }

        let result = try await cli.query.committeeState(
            arguments: [
                hotHashFlag,
                hot.credential.payload.toHex,
                "--output-json",
            ]
        )

        guard let data = result.data(using: .utf8),
            let committeeState = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let committee = committeeState["committee"] as? [String: Any]
        else {
            throw CardanoChainError.valueError("Failed to parse committee state JSON")
        }

        // cardano-cli returns the matching committee entries keyed by the cold credential
        // ("keyHash-<hex>" or "scriptHash-<hex>"). Pick the first (or only) entry.
        guard let (coldKey, anyEntry) = committee.first,
            let memberEntry = anyEntry as? [String: Any]
        else {
            throw CardanoChainError.valueError(
                "Committee member not found for hot credential: \(hot.credential.payload.toHex)")
        }

        // Parse the cold credential from the entry key ("keyHash-<hex>" / "scriptHash-<hex>").
        let coldCredential: CommitteeColdCredential
        if coldKey.hasPrefix("keyHash-") {
            let hex = String(coldKey.dropFirst("keyHash-".count))
            coldCredential = CommitteeColdCredential(
                credential: .verificationKeyHash(
                    try LedgerValues.hash(hex: hex, as: VerificationKeyHash.self, "cardano-cli VerificationKeyHash"))
            )
        } else if coldKey.hasPrefix("scriptHash-") {
            let hex = String(coldKey.dropFirst("scriptHash-".count))
            coldCredential = CommitteeColdCredential(
                credential: .scriptHash(try LedgerValues.hash(hex: hex, as: ScriptHash.self, "cardano-cli ScriptHash"))
            )
        } else {
            throw CardanoChainError.valueError(
                "Unexpected committee entry key format: \(coldKey)")
        }

        guard let expiration = memberEntry["expiration"] as? Int else {
            throw CardanoChainError.valueError("Missing expiration in committee member entry")
        }

        let statusStr = memberEntry["status"] as? String ?? "Unknown"
        let status: CommitteeMemberStatus
        switch statusStr.lowercased() {
        case "active":
            status = .active
        case "expired":
            status = .expired
        default:
            status = .unrecognized
        }

        return CommitteeMemberInfo(
            coldCredential: coldCredential,
            hotCredential: hot,
            expiration: try expiration.checked("cardano-cli committee member expiration"),
            status: status
        )
    }

    // MARK: - Votes / Governance State

    public func govActionVotes(govActionID: GovActionID) async throws -> GovActionVotes {
        let proposals = try await fetchProposalsFromGovState()
        let currentEpoch: UInt64 = try await self.epoch().checked("cardano-cli epoch")

        let txHash = govActionID.transactionID.payload.toHex.lowercased()
        let index = Int(govActionID.govActionIndex)

        guard let proposal = proposals.first(where: { proposalMatchesActionId($0, txHash: txHash, index: index) }) else {
            throw CardanoChainError.valueError(
                "Governance action not found in gov-state: \(txHash)#\(index)")
        }

        return try buildGovActionVotes(
            proposal: proposal,
            actionID: govActionID,
            currentEpoch: currentEpoch
        )
    }

    public func govActionsAll() async throws -> [GovActionVotes] {
        let proposals = try await fetchProposalsFromGovState()
        let currentEpoch: UInt64 = try await self.epoch().checked("cardano-cli epoch")

        return try proposals.map { proposal in
            try buildGovActionVotes(
                proposal: proposal,
                actionID: try parseActionId(from: proposal),
                currentEpoch: currentEpoch
            )
        }
    }

    public func drepStakeDistribution() async throws -> [SwiftCardanoNetwork.DRepStakeEntry] {
        let result = try await cli.query.drepStakeDistribution(
            arguments: ["--all-dreps", "--output-json"]
        )

        guard let data = result.data(using: .utf8) else {
            throw CardanoChainError.valueError("Failed to parse drep-stake-distribution as UTF-8")
        }

        // cardano-cli returns either a JSON array of pairs [[drepKey, lovelace], ...] or
        // a JSON object keyed by drepKey. Handle both shapes.
        let json = try? JSONSerialization.jsonObject(with: data)
        var entries: [SwiftCardanoNetwork.DRepStakeEntry] = []

        if let pairs = json as? [[Any]] {
            for pair in pairs {
                guard pair.count == 2 else {
                    throw CardanoChainError.valueError("cardano-cli stake distribution entry \(pair) is not [key, stake]")
                }
                let drep = try parseDRepKey(pair[0])
                // The ledger keeps a stake for every entry; a null one is not 0.
                let stake = try LedgerValues.required(parseLovelaceUInt(pair[1]), "cardano-cli stake distribution stake")
                entries.append(SwiftCardanoNetwork.DRepStakeEntry(drep: drep, stake: stake))
            }
        } else if let dict = json as? [String: Any] {
            for (key, value) in dict {
                let drep = try parseDRepKey(key)
                // The ledger keeps a stake for every entry; a null one is not 0.
                let stake = try LedgerValues.required(parseLovelaceUInt(value), "cardano-cli stake distribution stake")
                entries.append(SwiftCardanoNetwork.DRepStakeEntry(drep: drep, stake: stake))
            }
        } else {
            throw CardanoChainError.valueError(
                "Unexpected drep-stake-distribution JSON shape")
        }

        return entries
    }

    public func spoStakeDistribution() async throws -> [SwiftCardanoNetwork.SPOStakeEntry] {
        let result = try await cli.query.spoStakeDistribution(
            arguments: ["--all-spos", "--output-json"]
        )

        guard let data = result.data(using: .utf8) else {
            throw CardanoChainError.valueError("Failed to parse spo-stake-distribution as UTF-8")
        }

        let json = try? JSONSerialization.jsonObject(with: data)
        var entries: [SwiftCardanoNetwork.SPOStakeEntry] = []

        if let pairs = json as? [[Any]] {
            for pair in pairs {
                guard pair.count == 2 else {
                    throw CardanoChainError.valueError("cardano-cli stake distribution entry \(pair) is not [key, stake]")
                }
                let pool = try parsePoolKey(pair[0])
                // The ledger keeps a stake for every entry; a null one is not 0.
                let stake = try LedgerValues.required(parseLovelaceUInt(pair[1]), "cardano-cli stake distribution stake")
                entries.append(SwiftCardanoNetwork.SPOStakeEntry(poolOperator: pool, stake: stake))
            }
        } else if let dict = json as? [String: Any] {
            for (key, value) in dict {
                let pool = try parsePoolKey(key)
                // The ledger keeps a stake for every entry; a null one is not 0.
                let stake = try LedgerValues.required(parseLovelaceUInt(value), "cardano-cli stake distribution stake")
                entries.append(SwiftCardanoNetwork.SPOStakeEntry(poolOperator: pool, stake: stake))
            }
        } else {
            throw CardanoChainError.valueError(
                "Unexpected spo-stake-distribution JSON shape")
        }

        return entries
    }

    public func committeeState() async throws -> CommitteeStateInfo {
        let result = try await cli.query.committeeState(arguments: ["--output-json"])

        guard let data = result.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CardanoChainError.valueError("Failed to parse committee-state JSON")
        }

        let committeeDict = root["committee"] as? [String: Any] ?? [:]
        var members: [CommitteeStateInfo.Member] = []

        for (coldKey, anyEntry) in committeeDict {
            guard let entry = anyEntry as? [String: Any] else { continue }
            let cold = try parseCommitteeColdKey(coldKey)

            var hot: CommitteeHotCredential? = nil
            if let hotKey = entry["hotCredsAuthStatus"] as? [String: Any] {
                if let memberAuthorizedHotCredential = hotKey["contents"] as? [String: Any] {
                    if let hexStr = memberAuthorizedHotCredential["keyHash"] as? String {
                        hot = CommitteeHotCredential(
                            credential: .verificationKeyHash(
                                try LedgerValues.hash(hex: hexStr, as: VerificationKeyHash.self, "cardano-cli VerificationKeyHash")
                            )
                        )
                    } else if let hexStr = memberAuthorizedHotCredential["scriptHash"] as? String {
                        hot = CommitteeHotCredential(
                            credential: .scriptHash(
                                try LedgerValues.hash(hex: hexStr, as: ScriptHash.self, "cardano-cli ScriptHash")
                            )
                        )
                    }
                }
            }

            let expiration: EpochNumber? = try LedgerValues.integer(json: entry["expiration"], "cardano-cli committee member expiration")

            let statusStr = entry["status"] as? String ?? ""
            let status: CommitteeMemberStatus? = {
                switch statusStr.lowercased() {
                case "active": return .active
                case "expired": return .expired
                default: return nil
                }
            }()

            members.append(CommitteeStateInfo.Member(
                coldCredential: cold,
                hotCredential: hot,
                expiration: expiration,
                status: status
            ))
        }

        let threshold = try GovernanceParsing.parseThreshold(root["threshold"])
        return CommitteeStateInfo(members: members, threshold: threshold)
    }

    private func parseLovelaceUInt(_ any: Any) throws -> UInt64? {
        try GovernanceParsing.parseLovelace(any)
    }

    // MARK: - Vote-query helpers (private)

    private func fetchProposalsFromGovState() async throws -> [[String: Any]] {
        let result = try await cli.query.govState(arguments: ["--output-json"])
        guard let data = result.data(using: .utf8),
              let govState = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proposals = govState["proposals"] as? [[String: Any]]
        else {
            throw CardanoChainError.valueError(
                "Failed to parse gov-state JSON or missing proposals")
        }
        return proposals
    }

    private func proposalMatchesActionId(
        _ proposal: [String: Any],
        txHash: String,
        index: Int
    ) -> Bool {
        guard let actionId = proposal["actionId"] as? [String: Any],
              let pTxId = actionId["txId"] as? String else { return false }
        let pIndex: Int
        if let i = actionId["govActionIx"] as? Int {
            pIndex = i
        } else if let n = actionId["govActionIx"] as? NSNumber {
            pIndex = n.intValue
        } else {
            return false
        }
        return pTxId.lowercased() == txHash && pIndex == index
    }

    /// A proposal's own id, which every proposal in the gov state carries.
    private func parseActionId(from proposal: [String: Any]) throws -> GovActionID {
        guard let actionId = proposal["actionId"] as? [String: Any],
              let txId = actionId["txId"] as? String
        else {
            throw CardanoChainError.valueError("cardano-cli proposal has no actionId: \(proposal)")
        }
        return GovActionID(
            transactionID: try LedgerValues.hash(hex: txId, as: TransactionId.self, "cardano-cli TransactionId"),
            govActionIndex: try LedgerValues.required(
                LedgerValues.integer(json: actionId["govActionIx"], "cardano-cli govActionIx"), "cardano-cli govActionIx")
        )
    }

    private func buildGovActionVotes(
        proposal: [String: Any],
        actionID: GovActionID,
        currentEpoch: UInt64
    ) throws -> GovActionVotes {
        let proposalProcedure = proposal["proposalProcedure"] as? [String: Any] ?? [:]

        // Parse govAction fully from the proposal procedure.
        let govAction = try parseGovAction(actionDict: proposalProcedure["govAction"])

        // Parse deposit + return address.
        let deposit: Coin = try LedgerValues.required(
            LedgerValues.integer(json: proposalProcedure["deposit"], "cardano-cli proposal deposit"),
            "cardano-cli proposal deposit")

        // Every proposal names the account its deposit is returned to.
        let returnAddr: RewardAccount = try LedgerValues.required(
            parseRewardAccount(proposalProcedure["returnAddr"]), "cardano-cli proposal returnAddr")

        // Parse anchor (optional).
        let anchor = try parseAnchor(proposalProcedure["anchor"])

        // Parse vote arrays.
        let committeeVotes = try parseCommitteeVotes(proposal["committeeVotes"])
        let dRepVotes = try parseDRepVotes(proposal["dRepVotes"])
        let stakePoolVotes = try parseStakePoolVotes(proposal["stakePoolVotes"])

        // Epochs.
        let proposedIn = (proposal["proposedIn"] as? NSNumber)?.uint64Value
            ?? (proposal["proposedIn"] as? Int).map(UInt64.init)
        let expiresAfter = (proposal["expiresAfter"] as? NSNumber)?.uint64Value
            ?? (proposal["expiresAfter"] as? Int).map(UInt64.init)
        let expiredByEpoch = expiresAfter.map { currentEpoch > $0 } ?? false
        let expiredEpoch: UInt64? = expiredByEpoch ? currentEpoch : nil

        return GovActionVotes(
            govActionId: actionID,
            govAction: govAction,
            committeeVotes: committeeVotes,
            dRepVotes: dRepVotes,
            stakePoolVotes: stakePoolVotes,
            deposit: deposit,
            depositReturnAddr: returnAddr,
            anchor: anchor,
            proposedIn: proposedIn,
            expiresAfter: expiresAfter,
            ratifiedEpoch: nil,
            enactedEpoch: nil,
            droppedEpoch: nil,
            expiredEpoch: expiredEpoch
        )
    }

    /// Parse a cardano-cli `proposalProcedure.govAction` dict into a real
    /// `GovAction`. Unlike a tag-only stub, this walks the `contents` array
    /// and extracts the on-chain payload for each variant. When a particular
    /// field cannot be parsed (e.g. malformed JSON for that variant) the
    /// fallback is to surface the variant tag with empty contents rather
    /// than fabricated data — and where the tag itself is missing, we
    /// return `.infoAction` so consumers can detect "unparseable" via the
    /// variant tag.
    private func parseGovAction(actionDict any: Any?) throws -> GovAction {
        try LedgerGovActionJSON.govAction(any, "cardano-cli governance action") {
            try LedgerGovActionJSON.protocolParamUpdate($0, "cardano-cli")
        }
    }

    /// A reward account: the ledger's `{network, credential}` object, or its
    /// 29 bytes in hex.
    private func parseRewardAccount(_ any: Any?) throws -> RewardAccount? {
        guard let any, !(any is NSNull) else { return nil }
        if let hex = any as? String {
            let bytes = try LedgerValues.hexBytes(hex, "cardano-cli reward account")
            guard bytes.count == 29 else {
                throw CardanoChainError.valueError("cardano-cli reward account \(hex) is not 29 bytes")
            }
            return bytes
        }
        return try LedgerValues.rewardAccount(json: any, "cardano-cli reward account")
    }

    private func parseAnchor(_ any: Any?) throws -> Anchor? {
        try LedgerValues.anchor(json: any, "cardano-cli proposal anchor")
    }

    /// A DRep as cardano-cli writes one: a `keyHash-<hex>` / `scriptHash-<hex>`
    /// key (with or without a `drep-` prefix), `alwaysAbstain` /
    /// `alwaysNoConfidence`, or a `{keyHash | scriptHash}` object.
    private func parseDRepKey(_ any: Any) throws -> DRep {
        if let s = any as? String {
            // `cardano-cli query drep-stake-distribution` emits keys with a
            // `drep-` prefix (`drep-keyHash-...`, `drep-alwaysAbstain`, etc).
            let stripped = s.hasPrefix("drep-") ? String(s.dropFirst("drep-".count)) : s
            switch stripped {
            case "alwaysAbstain", "AlwaysAbstain": return DRep(credential: .alwaysAbstain)
            case "alwaysNoConfidence", "AlwaysNoConfidence": return DRep(credential: .alwaysNoConfidence)
            default:
                return try drep(LedgerValues.credential(json: stripped, "cardano-cli DRep"))
            }
        }
        return try drep(LedgerValues.credential(json: any, "cardano-cli DRep"))
    }

    private func drep(_ credential: CredentialType) -> DRep {
        switch credential {
        case .verificationKeyHash(let hash): DRep(credential: .verificationKeyHash(hash))
        case .scriptHash(let hash): DRep(credential: .scriptHash(hash))
        }
    }

    /// A stake pool: bech32 `pool…` (the gov-state proposal body), or the pool
    /// key hash in hex, bare or as `keyHash-<hex>` (the stake distribution).
    private func parsePoolKey(_ any: Any) throws -> PoolOperator {
        let text: String
        if let s = any as? String {
            text = s.hasPrefix("keyHash-") ? String(s.dropFirst("keyHash-".count)) : s
        } else if let dict = any as? [String: Any], dict.count == 1, let hex = dict["keyHash"] as? String {
            text = hex
        } else {
            throw CardanoChainError.valueError("cardano-cli stake pool \(any) is not a pool id")
        }
        if text.hasPrefix("pool") {
            return try PoolOperator(from: .string(text))
        }
        return PoolOperator(poolKeyHash: try LedgerValues.hash(hex: text, as: PoolKeyHash.self, "cardano-cli pool key hash"))
    }

    private func parseCommitteeColdKey(_ key: String) throws -> CommitteeColdCredential {
        CommitteeColdCredential(credential: try LedgerValues.credential(json: key, "cardano-cli committee cold key"))
    }

    private func parseCommitteeHotKey(_ key: String) throws -> CommitteeHotCredential {
        CommitteeHotCredential(credential: try LedgerValues.credential(json: key, "cardano-cli committee hot key"))
    }

    private func parseLovelace(_ any: Any) throws -> Coin? {
        try GovernanceParsing.parseLovelace(any)
    }

    private func parseVoteValue(_ any: Any) throws -> Vote {
        guard let vote = GovernanceParsing.parseVote(any) else {
            throw CardanoChainError.valueError("cardano-cli vote \(any) is not a vote")
        }
        return vote
    }

    private func parseCommitteeVotes(_ any: Any?) throws -> [CommitteeVote] {
        guard let dict = any as? [String: Any] else { return [] }
        return try dict.map { (k, v) in
            CommitteeVote(credential: try parseCommitteeHotKey(k), vote: try parseVoteValue(v))
        }
    }

    private func parseDRepVotes(_ any: Any?) throws -> [DRepVote] {
        guard let dict = any as? [String: Any] else { return [] }
        return try dict.map { (k, v) in
            DRepVote(
                credential: DRepCredential(credential: try LedgerValues.credential(json: k, "cardano-cli DRep voter")),
                vote: try parseVoteValue(v))
        }
    }

    private func parseStakePoolVotes(_ any: Any?) throws -> [StakePoolVote] {
        guard let dict = any as? [String: Any] else { return [] }
        return try dict.map { (k, v) in
            StakePoolVote(poolOperator: try parsePoolKey(k), vote: try parseVoteValue(v))
        }
    }
}

#endif
