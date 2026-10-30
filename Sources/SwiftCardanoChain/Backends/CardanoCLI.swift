#if CLIBACKENDS
import BigInt
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
    static func getScript(from referenceScript: ChainJSON) throws -> ScriptType {
        guard let script = referenceScript["script"], let scriptType = script["type"]?.string else {
            throw CardanoChainError.valueError("Invalid reference script")
        }
        func cbor(_ name: String) throws -> Data {
            guard let hex = script["cborHex"]?.string else {
                throw CardanoChainError.valueError("Invalid \(name) CBOR")
            }
            return try LedgerValues.hexBytes(hex, "cardano-cli \(name) cborHex")
        }
        switch scriptType {
        case "PlutusScriptV1": return .plutusV1Script(PlutusV1Script(data: try cbor("PlutusScriptV1")))
        case "PlutusScriptV2": return .plutusV2Script(PlutusV2Script(data: try cbor("PlutusScriptV2")))
        case "PlutusScriptV3": return .plutusV3Script(PlutusV3Script(data: try cbor("PlutusScriptV3")))
        default:
            // A native script in cardano-cli's JSON form.
            do {
                return .nativeScript(try JSONDecoder().decode(NativeScript.self, from: JSONEncoder().encode(script)))
            } catch {
                throw CardanoChainError.valueError("Invalid native reference script: \(error)")
            }
        }
    }

    // MARK: - ChainContext Protocol Methods

    /// The datum of a UTxO entry in `query utxo --output-json`, read from its
    /// CBOR: `datum` (a datum option) or `inlineDatumRaw` (the inline datum's
    /// Plutus data). `nil` when the output has neither.
    ///
    /// The JSON `inlineDatum` is never read: a datum integer is unbounded, and
    /// a JSON number (a `Decimal`'s 38 digits) does not hold it exactly. An
    /// entry with an inline datum but no CBOR for it throws.
    static func datumOption(_ entry: ChainJSON, _ what: String) throws -> DatumOption? {
        if let datum = entry["datum"]?.string {
            return try DatumOption.fromCBOR(data: LedgerValues.hexBytes(datum, "\(what) datum"))
        }
        if let raw = entry["inlineDatumRaw"]?.string {
            let data = try LedgerValues.hexBytes(raw, "\(what) inlineDatumRaw")
            do {
                return DatumOption(datum: try PlutusData.fromCBOR(data: data))
            } catch {
                throw CardanoChainError.valueError("\(what) inlineDatumRaw is not Plutus data: \(error)")
            }
        }
        if entry["inlineDatum"].nonNull != nil {
            throw CardanoChainError.valueError(
                "\(what) has an inline datum only as JSON (no inlineDatumRaw), whose integers cannot be read exactly")
        }
        return nil
    }

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
            let rawUtxos = try ChainJSON.decode(data, "cardano-cli UTxO JSON").object
        else {
            throw CardanoChainError.valueError("Failed to parse UTxO JSON")
        }

        guard let utxoEntry = rawUtxos[txInStr] else {
            return nil  // Not in UTXO set: either spent or never existed
        }

        guard let utxoValue = utxoEntry["value"]?.object else {
            throw CardanoChainError.valueError("cardano-cli UTxO \(txInStr) has no value")
        }
        let value = try Self.outputValue(utxoValue, "cardano-cli UTxO \(txInStr)")

        var datumHash: DatumHash? = nil
        if let datumHashStr = utxoEntry["datumhash"]?.string {
            datumHash = try LedgerValues.hash(hex: datumHashStr, as: DatumHash.self, "cardano-cli DatumHash")
        }

        let datumOption = try Self.datumOption(utxoEntry, "cardano-cli UTxO \(txInStr)")

        var script: ScriptType? = nil
        if let referenceScript = utxoEntry["referenceScript"].nonNull {
            script = try Self.getScript(from: referenceScript)
        }

        guard let addressText = utxoEntry["address"]?.string else {
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

    /// An output's value from cardano-cli's UTxO JSON. An output's lovelace
    /// and token quantities are a ledger Word64, so a larger number — or one
    /// longer than the 38 digits a `Decimal` keeps — throws.
    static func outputValue(_ utxoValue: [String: ChainJSON], _ what: String) throws -> Value {
        var value = Value(coin: 0)
        var multiAsset = MultiAsset([:])

        for (asset, amount) in utxoValue {
            if asset == "lovelace" {
                value.coin = BigInt(try LedgerValues.required(
                    LedgerValues.integer(json: amount, as: UInt64.self, "\(what) lovelace"), "\(what) lovelace"))
            } else {
                let policyId = asset
                guard let assets = amount.object else {
                    throw CardanoChainError.valueError("\(what) assets of \(policyId) are not an object")
                }
                for (assetHexName, assetAmount) in assets {
                    let policy = try LedgerValues.hash(hex: policyId, as: ScriptHash.self, "cardano-cli ScriptHash")
                    let assetName = AssetName(from: assetHexName)
                    if multiAsset[policy] == nil {
                        multiAsset[policy] = Asset([:])
                    }
                    multiAsset[policy]?[assetName] = BigInt(try LedgerValues.required(
                        LedgerValues.integer(json: assetAmount, as: UInt64.self, "\(what) asset quantity"),
                        "\(what) asset quantity"))
                }
            }
        }

        value.multiAsset = multiAsset
        return value
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
        // script cannot be given its time range and evaluation refuses it. The
        // timeline comes from the genesis parameters, and failing to read them is
        // an error — never a reason to evaluate without one.
        let timeline = try await self.slotTimeline()

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
        guard let dict = try ChainJSON.decode(data, "cardano-cli kes-period-info").object else {
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
                let entries = try ChainJSON.decode(data, "cardano-cli drep-state").array
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

            guard let pair = firstEntry.array, pair.count == 2, let stateDict = pair[1].object else {
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
                let distDict = try ChainJSON.decode(distData, "cardano-cli drep-stake-distribution").object
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

        guard let data = result.data(using: .utf8) else {
            throw CardanoChainError.valueError("Failed to parse gov-state JSON or missing proposals")
        }
        let govState = try ChainJSON.decode(data, "cardano-cli gov-state")
        guard let proposals = govState["proposals"]?.array else {
            throw CardanoChainError.valueError(
                "Failed to parse gov-state JSON or missing proposals")
        }

        let txHash = govActionID.transactionID.payload.toHex.lowercased()
        let index = govActionID.govActionIndex

        let nextRatifyState = govState["nextRatifyState"]
        let enactedGovActions = nextRatifyState?["enactedGovActions"]?.array ?? []
        let expiredGovActions = nextRatifyState?["expiredGovActions"]?.array ?? []
        let currentEpoch: UInt64 = try await self.epoch().checked("cardano-cli epoch")

        func actionIdMatches(_ actionId: ChainJSON) -> Bool {
            Self.actionIdMatches(actionId, txHash: txHash, index: index)
        }

        func actionExists(in entries: [ChainJSON]) -> Bool {
            entries.contains { entry in
                if let nestedActionId = entry["actionId"], nestedActionId.object != nil {
                    return actionIdMatches(nestedActionId)
                }
                return actionIdMatches(entry)
            }
        }

        let proposal = proposals.first(where: { $0["actionId"].map(actionIdMatches) ?? false })

        func extractGovAction(_ proposal: ChainJSON) throws -> GovAction {
            guard let procedure = proposal["proposalProcedure"], procedure.object != nil else {
                throw CardanoChainError.valueError("Missing proposalProcedure in proposal")
            }
            return try parseGovAction(procedure["govAction"])
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

        // A proposal no longer in the gov state has no body to read: report its
        // status without an action rather than standing in a different one.
        let parsedGovAction: GovAction? = try proposal.map(extractGovAction)

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

    /// Whether `actionId` (`{txId, govActionIx}`) names `txHash#index`.
    static func actionIdMatches(_ actionId: ChainJSON, txHash: String, index: some BinaryInteger) -> Bool {
        guard let pTxId = actionId["txId"]?.string,
              let pIndex = try? LedgerValues.integer(json: actionId["govActionIx"], as: UInt64.self, "govActionIx")
        else { return false }
        return pTxId.lowercased() == txHash && UInt64(exactly: index) == pIndex
    }

    /// The `committee` object of `query committee-state` output.
    static func committeeMembers(_ data: Data) throws -> (root: [String: ChainJSON], committee: [String: ChainJSON]) {
        guard let root = try ChainJSON.decode(data, "cardano-cli committee-state").object else {
            throw CardanoChainError.valueError("Failed to parse committee state JSON")
        }
        switch root["committee"].nonNull {
        case nil: return (root, [:])
        case let committee?:
            guard let members = committee.object else {
                throw CardanoChainError.valueError("cardano-cli committee-state committee is not an object")
            }
            return (root, members)
        }
    }

    /// A committee member's status: `Active`, `Expired`, or `nil` for anything else.
    static func committeeStatus(_ entry: [String: ChainJSON]) -> CommitteeMemberStatus? {
        switch entry["status"]?.string?.lowercased() {
        case "active": .active
        case "expired": .expired
        default: nil
        }
    }

    /// The hot credential a member has authorized (`hotCredsAuthStatus` tagged
    /// `MemberAuthorized`), or `nil` when it has none.
    static func authorizedHotCredential(_ entry: [String: ChainJSON]) throws -> CommitteeHotCredential? {
        guard let auth = entry["hotCredsAuthStatus"], auth["tag"]?.string == "MemberAuthorized",
              let contents = auth["contents"]
        else { return nil }
        return CommitteeHotCredential(credential: try LedgerValues.credential(json: contents, "cardano-cli hot credential"))
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
        // "keyHash-<hex>").
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

        guard let data = result.data(using: .utf8) else {
            throw CardanoChainError.valueError("Failed to parse committee state JSON")
        }
        let committee = try Self.committeeMembers(data).committee

        let memberKey = "\(coldKeyPrefix)\(cold.credential.payload.toHex)"
        guard let memberEntry = committee[memberKey]?.object else {
            throw CardanoChainError.valueError(
                "Committee member not found for cold credential: \(memberKey)")
        }

        let expiration: UInt64 = try LedgerValues.required(
            LedgerValues.integer(json: memberEntry["expiration"], "cardano-cli committee member expiration"),
            "cardano-cli committee member expiration")

        guard let hotCred = try Self.authorizedHotCredential(memberEntry) else {
            throw CardanoChainError.valueError(
                "Failed to parse hot credential from committee member entry")
        }

        return CommitteeMemberInfo(
            coldCredential: cold,
            hotCredential: hotCred,
            expiration: expiration,
            status: Self.committeeStatus(memberEntry) ?? .unrecognized
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

        guard let data = result.data(using: .utf8) else {
            throw CardanoChainError.valueError("Failed to parse committee state JSON")
        }
        let committee = try Self.committeeMembers(data).committee

        // cardano-cli returns the matching committee entries keyed by the cold credential
        // ("keyHash-<hex>" or "scriptHash-<hex>"). Pick the first (or only) entry.
        guard let (coldKey, anyEntry) = committee.first, let memberEntry = anyEntry.object else {
            throw CardanoChainError.valueError(
                "Committee member not found for hot credential: \(hot.credential.payload.toHex)")
        }

        let expiration: UInt64 = try LedgerValues.required(
            LedgerValues.integer(json: memberEntry["expiration"], "cardano-cli committee member expiration"),
            "cardano-cli committee member expiration")

        return CommitteeMemberInfo(
            coldCredential: try parseCommitteeColdKey(coldKey),
            hotCredential: hot,
            expiration: expiration,
            status: Self.committeeStatus(memberEntry) ?? .unrecognized
        )
    }

    // MARK: - Votes / Governance State

    public func govActionVotes(govActionID: GovActionID) async throws -> GovActionVotes {
        let proposals = try await fetchProposalsFromGovState()
        let currentEpoch: UInt64 = try await self.epoch().checked("cardano-cli epoch")

        let txHash = govActionID.transactionID.payload.toHex.lowercased()
        let index = govActionID.govActionIndex

        guard let proposal = proposals.first(where: {
            $0["actionId"].map { Self.actionIdMatches($0, txHash: txHash, index: index) } ?? false
        }) else {
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

    /// A stake distribution as cardano-cli prints it: a list of `[key, stake]`
    /// pairs or an object keyed by key. Every entry carries its stake.
    static func stakeDistribution(_ data: Data, _ what: String) throws -> [(key: ChainJSON, stake: UInt64)] {
        let json = try ChainJSON.decode(data, "cardano-cli \(what)")
        func stake(_ value: ChainJSON) throws -> UInt64 {
            // The ledger keeps a stake for every entry; a null one is not 0.
            try LedgerValues.required(GovernanceParsing.parseLovelace(value), "cardano-cli \(what) stake")
        }
        switch json {
        case .array(let pairs):
            return try pairs.map { pair in
                guard let pair = pair.array, pair.count == 2 else {
                    throw CardanoChainError.valueError("cardano-cli \(what) entry \(pair) is not [key, stake]")
                }
                return (pair[0], try stake(pair[1]))
            }
        case .object(let members):
            return try members.map { (ChainJSON.string($0.key), try stake($0.value)) }
        default:
            throw CardanoChainError.valueError("Unexpected \(what) JSON shape")
        }
    }

    public func drepStakeDistribution() async throws -> [SwiftCardanoNetwork.DRepStakeEntry] {
        let result = try await cli.query.drepStakeDistribution(
            arguments: ["--all-dreps", "--output-json"]
        )
        guard let data = result.data(using: .utf8) else {
            throw CardanoChainError.valueError("Failed to parse drep-stake-distribution as UTF-8")
        }
        return try Self.stakeDistribution(data, "drep-stake-distribution").map {
            SwiftCardanoNetwork.DRepStakeEntry(drep: try parseDRepKey($0.key), stake: $0.stake)
        }
    }

    public func spoStakeDistribution() async throws -> [SwiftCardanoNetwork.SPOStakeEntry] {
        let result = try await cli.query.spoStakeDistribution(
            arguments: ["--all-spos", "--output-json"]
        )
        guard let data = result.data(using: .utf8) else {
            throw CardanoChainError.valueError("Failed to parse spo-stake-distribution as UTF-8")
        }
        return try Self.stakeDistribution(data, "spo-stake-distribution").map {
            SwiftCardanoNetwork.SPOStakeEntry(poolOperator: try parsePoolKey($0.key), stake: $0.stake)
        }
    }

    public func committeeState() async throws -> CommitteeStateInfo {
        let result = try await cli.query.committeeState(arguments: ["--output-json"])

        guard let data = result.data(using: .utf8) else {
            throw CardanoChainError.valueError("Failed to parse committee-state JSON")
        }
        let (root, committee) = try Self.committeeMembers(data)

        var members: [CommitteeStateInfo.Member] = []
        for (coldKey, value) in committee {
            guard let entry = value.object else {
                throw CardanoChainError.valueError("cardano-cli committee member \(coldKey) is not an object")
            }
            // Any credential in `contents` counts, whatever the tag says, as before.
            var hot: CommitteeHotCredential? = nil
            if let contents = entry["hotCredsAuthStatus"]?["contents"],
               contents["keyHash"] != nil || contents["scriptHash"] != nil {
                hot = CommitteeHotCredential(
                    credential: try LedgerValues.credential(json: contents, "cardano-cli hot credential"))
            }
            members.append(CommitteeStateInfo.Member(
                coldCredential: try parseCommitteeColdKey(coldKey),
                hotCredential: hot,
                expiration: try LedgerValues.integer(json: entry["expiration"], "cardano-cli committee member expiration"),
                status: Self.committeeStatus(entry)
            ))
        }

        let threshold = try GovernanceParsing.parseThreshold(root["threshold"])
        return CommitteeStateInfo(members: members, threshold: threshold)
    }

    // MARK: - Vote-query helpers (private)

    private func fetchProposalsFromGovState() async throws -> [ChainJSON] {
        let result = try await cli.query.govState(arguments: ["--output-json"])
        guard let data = result.data(using: .utf8) else {
            throw CardanoChainError.valueError("Failed to parse gov-state JSON or missing proposals")
        }
        guard let proposals = try ChainJSON.decode(data, "cardano-cli gov-state")["proposals"]?.array else {
            throw CardanoChainError.valueError(
                "Failed to parse gov-state JSON or missing proposals")
        }
        return proposals
    }

    /// Each gov-state proposal's `proposalProcedure.govAction`, in proposal
    /// order, decoded exactly (numbers as `Decimal`, never `Double`).
    static func proposalGovActions(_ data: Data) throws -> [ChainJSON?] {
        let state = try ChainJSON.decode(data, "cardano-cli gov-state")
        guard let proposals = state["proposals"]?.array else {
            throw CardanoChainError.valueError("cardano-cli gov-state has no proposals")
        }
        return proposals.map { $0["proposalProcedure"]?["govAction"] }
    }

    /// A proposal's own id, which every proposal in the gov state carries.
    private func parseActionId(from proposal: ChainJSON) throws -> GovActionID {
        guard let actionId = proposal["actionId"], let txId = actionId["txId"]?.string else {
            throw CardanoChainError.valueError("cardano-cli proposal has no actionId: \(proposal)")
        }
        return GovActionID(
            transactionID: try LedgerValues.hash(hex: txId, as: TransactionId.self, "cardano-cli TransactionId"),
            govActionIndex: try LedgerValues.required(
                LedgerValues.integer(json: actionId["govActionIx"], "cardano-cli govActionIx"), "cardano-cli govActionIx")
        )
    }

    private func buildGovActionVotes(
        proposal: ChainJSON,
        actionID: GovActionID,
        currentEpoch: UInt64
    ) throws -> GovActionVotes {
        guard let proposalProcedure = proposal["proposalProcedure"], proposalProcedure.object != nil else {
            throw CardanoChainError.valueError("cardano-cli proposal \(actionID) has no proposalProcedure")
        }

        // Parse govAction fully from the proposal procedure.
        let govAction = try parseGovAction(proposalProcedure["govAction"])

        // Parse deposit + return address.
        let deposit: Coin = try LedgerValues.required(
            LedgerValues.integer(json: proposalProcedure["deposit"], "cardano-cli proposal deposit"),
            "cardano-cli proposal deposit")

        // Every proposal names the account its deposit is returned to.
        let returnAddr: RewardAccount = try LedgerValues.required(
            parseRewardAccount(proposalProcedure["returnAddr"]), "cardano-cli proposal returnAddr")

        // Parse anchor (optional).
        let anchor = try LedgerValues.anchor(json: proposalProcedure["anchor"], "cardano-cli proposal anchor")

        // Parse vote arrays.
        let committeeVotes = try parseCommitteeVotes(proposal["committeeVotes"])
        let dRepVotes = try parseDRepVotes(proposal["dRepVotes"])
        let stakePoolVotes = try parseStakePoolVotes(proposal["stakePoolVotes"])

        // Epochs.
        let proposedIn: UInt64? = try LedgerValues.integer(json: proposal["proposedIn"], "cardano-cli proposedIn")
        let expiresAfter: UInt64? = try LedgerValues.integer(json: proposal["expiresAfter"], "cardano-cli expiresAfter")
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

    /// Parse a cardano-cli `proposalProcedure.govAction`, decoded exactly as
    /// ``ChainJSON``, into a real `GovAction`, walking the `contents` of each
    /// variant. A missing tag or contents of the wrong shape throw.
    private func parseGovAction(_ json: ChainJSON?) throws -> GovAction {
        try LedgerGovActionJSON.govAction(json, "cardano-cli governance action") {
            try LedgerGovActionJSON.protocolParamUpdate($0, "cardano-cli")
        }
    }

    /// A reward account: the ledger's `{network, credential}` object, or its
    /// 29 bytes in hex.
    private func parseRewardAccount(_ json: ChainJSON?) throws -> RewardAccount? {
        guard let json = json.nonNull else { return nil }
        if let hex = json.string {
            let bytes = try LedgerValues.hexBytes(hex, "cardano-cli reward account")
            guard bytes.count == 29 else {
                throw CardanoChainError.valueError("cardano-cli reward account \(hex) is not 29 bytes")
            }
            return bytes
        }
        return try LedgerValues.rewardAccount(json: json, "cardano-cli reward account")
    }

    /// A DRep as cardano-cli writes one: a `keyHash-<hex>` / `scriptHash-<hex>`
    /// key (with or without a `drep-` prefix), `alwaysAbstain` /
    /// `alwaysNoConfidence`, or a `{keyHash | scriptHash}` object.
    private func parseDRepKey(_ json: ChainJSON) throws -> DRep {
        if let s = json.string {
            // `cardano-cli query drep-stake-distribution` emits keys with a
            // `drep-` prefix (`drep-keyHash-...`, `drep-alwaysAbstain`, etc).
            let stripped = s.hasPrefix("drep-") ? String(s.dropFirst("drep-".count)) : s
            switch stripped {
            case "alwaysAbstain", "AlwaysAbstain": return DRep(credential: .alwaysAbstain)
            case "alwaysNoConfidence", "AlwaysNoConfidence": return DRep(credential: .alwaysNoConfidence)
            default:
                return try drep(LedgerValues.credential(json: ChainJSON.string(stripped), "cardano-cli DRep"))
            }
        }
        return try drep(LedgerValues.credential(json: json, "cardano-cli DRep"))
    }

    private func drep(_ credential: CredentialType) -> DRep {
        switch credential {
        case .verificationKeyHash(let hash): DRep(credential: .verificationKeyHash(hash))
        case .scriptHash(let hash): DRep(credential: .scriptHash(hash))
        }
    }

    /// A stake pool: bech32 `pool…` (the gov-state proposal body), or the pool
    /// key hash in hex, bare or as `keyHash-<hex>` (the stake distribution).
    private func parsePoolKey(_ json: ChainJSON) throws -> PoolOperator {
        let text: String
        if let s = json.string {
            text = s.hasPrefix("keyHash-") ? String(s.dropFirst("keyHash-".count)) : s
        } else if let dict = json.object, dict.count == 1, let hex = dict["keyHash"]?.string {
            text = hex
        } else {
            throw CardanoChainError.valueError("cardano-cli stake pool \(json) is not a pool id")
        }
        if text.hasPrefix("pool") {
            return try PoolOperator(from: .string(text))
        }
        return PoolOperator(poolKeyHash: try LedgerValues.hash(hex: text, as: PoolKeyHash.self, "cardano-cli pool key hash"))
    }

    private func parseCommitteeColdKey(_ key: String) throws -> CommitteeColdCredential {
        CommitteeColdCredential(credential: try LedgerValues.credential(json: ChainJSON.string(key), "cardano-cli committee cold key"))
    }

    private func parseCommitteeHotKey(_ key: String) throws -> CommitteeHotCredential {
        CommitteeHotCredential(credential: try LedgerValues.credential(json: ChainJSON.string(key), "cardano-cli committee hot key"))
    }

    private func parseVoteValue(_ json: ChainJSON) throws -> Vote {
        guard let vote = GovernanceParsing.parseVote(json.string) else {
            throw CardanoChainError.valueError("cardano-cli vote \(json) is not a vote")
        }
        return vote
    }

    /// A vote map, `{voter: vote}`; none when absent or null.
    private func votes(_ json: ChainJSON?, _ what: String) throws -> [String: ChainJSON] {
        guard let json = json.nonNull else { return [:] }
        guard let object = json.object else {
            throw CardanoChainError.valueError("cardano-cli \(what) is not an object: \(json)")
        }
        return object
    }

    private func parseCommitteeVotes(_ json: ChainJSON?) throws -> [CommitteeVote] {
        try votes(json, "committeeVotes").map { (k, v) in
            CommitteeVote(credential: try parseCommitteeHotKey(k), vote: try parseVoteValue(v))
        }
    }

    private func parseDRepVotes(_ json: ChainJSON?) throws -> [DRepVote] {
        try votes(json, "dRepVotes").map { (k, v) in
            DRepVote(
                credential: DRepCredential(
                    credential: try LedgerValues.credential(json: ChainJSON.string(k), "cardano-cli DRep voter")),
                vote: try parseVoteValue(v))
        }
    }

    private func parseStakePoolVotes(_ json: ChainJSON?) throws -> [StakePoolVote] {
        try votes(json, "stakePoolVotes").map { (k, v) in
            StakePoolVote(poolOperator: try parsePoolKey(.string(k)), vote: try parseVoteValue(v))
        }
    }
}

#endif
