import Foundation
import PotentCBOR
import PotentCodables
import SwiftCardanoCore
import SwiftCardanoUtils
import SystemPackage


/// A Cardano CLI wrapper for interacting with the Cardano blockchain
public class CardanoCliChainContext: ChainContext {    
    // MARK: - Properties
    
    public var name: String {  "Cardano-CLI" }
    public var type: ContextType { .online }
    
    public let cli: CardanoCLI
    private var lastKnownBlockSlot: Int = 0
    private var lastChainTipFetch: TimeInterval = 0
    private var refetchChainTipInterval: TimeInterval
    private var utxoCache: [String: ([UTxO], TimeInterval)]
    private var datumCache: [String: Any]
    private let cache = Cache<String, Int>()
    private let cacheTTL: TimeInterval = 1.0  // 1 second TTL
    private let _network: Network
    private var _genesisParameters: GenesisParameters?
    private var _protocolParameters: ProtocolParameters?

    // MARK: - ChainContext Protocol Properties

    public var networkId: NetworkId {
        self._network.networkId
    }

    public lazy var era: () async throws -> Era? = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }

        let era = try await cli.getEra()
        return era
    }

    public lazy var epoch: () async throws -> Int = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }
        
        let epoch = try await cli.getEpoch()
        return epoch
    }

    public lazy var lastBlockSlot: () async throws -> Int = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }

        let cacheKey = "lastBlockSlot"

        if let cachedValue = self.cache.value(forKey: cacheKey) {
            return cachedValue
        }

        let slot = try await cli.getTip()

        // Update cache
        self.cache.insert(slot, forKey: cacheKey)

        return slot
    }

    public lazy var genesisParameters: () async throws -> GenesisParameters = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }
        
        guard let nodeConfig = self.cli.cardanoConfig.config else {
            throw CardanoChainError.valueError("Cardano node config is nil")
        }

        if self._genesisParameters == nil {
            self._genesisParameters = try GenesisParameters(
                nodeConfigFilePath: nodeConfig.string
            )

            // Set the refetch chain tip interval if not provided
            if self.refetchChainTipInterval == 0 {
                self.refetchChainTipInterval =
                    Double((self._genesisParameters?.slotLength!)!)
                    / (self._genesisParameters?.activeSlotsCoefficient!)!
            }
        }

        return self._genesisParameters!
    }

    public lazy var protocolParameters: () async throws -> ProtocolParameters = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }

        if try await self.isChainTipUpdated() || self._protocolParameters == nil {
            self._protocolParameters = try await self.queryCurrentProtocolParams()
        }

        return self._protocolParameters!
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
    ///   - client: An instance of a CLIClient. If nil, a default CardanoCLIClient will be created.
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
                  let socket = socket {
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
    public func queryChainTip() async throws -> ChainTip {
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
            guard let cborHex = script["cborHex"] as? String,
                let cborData = Data(hexString: cborHex)
            else {
                throw CardanoChainError.valueError("Invalid PlutusScriptV1 CBOR")
            }

            // Create PlutusV1Script from CBOR
            let v1script = PlutusV1Script(data: cborData)
            return .plutusV1Script(v1script)
        } else if scriptType == "PlutusScriptV2" {
            guard let cborHex = script["cborHex"] as? String,
                let cborData = Data(hexString: cborHex)
            else {
                throw CardanoChainError.valueError("Invalid PlutusScriptV2 CBOR")
            }

            // Create PlutusV2Script from CBOR
            let v2script = PlutusV2Script(data: cborData)
            return .plutusV2Script(v2script)
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
            "--tx-in", txInStr, "--output-json", "--out-file",  "/dev/stdout"
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
                if let lovelace = amount as? Int {
                    value.coin = Int(lovelace)
                }
            } else {
                let policyId = asset
                guard let assets = amount as? [String: Int] else { continue }
                for (assetHexName, assetAmount) in assets {
                    let policy = try ScriptHash(from: .string(policyId))
                    let assetName = AssetName(from: assetHexName)
                    if multiAsset[policy] == nil {
                        multiAsset[policy] = Asset([:])
                    }
                    multiAsset[policy]?[assetName] = assetAmount
                }
            }
        }

        value.multiAsset = multiAsset

        var datumHash: DatumHash? = nil
        if let datumHashStr = utxoEntry["datumhash"] as? String {
            datumHash = try DatumHash(from: .string(datumHashStr))
        }

        var datumOption: DatumOption? = nil
        if let datumStr = utxoEntry["datum"] as? String,
           let datumData = Data(hexString: datumStr)
        {
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

        let address = try Address(from: .string(utxoEntry["address"] as! String))
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

    /// Evaluate execution units of a transaction
    ///
    /// - Parameter cbor: The serialized transaction to be evaluated
    /// - Returns: A dictionary mapping redeemer strings to execution units
    /// - Throws: CardanoChainError if the evaluation fails
    public func evaluateTxCBOR(cbor: Data) async throws -> [String: ExecutionUnits] {
        // TODO: Implement transaction evaluation
        throw CardanoChainError.notImplemented("Transaction evaluation not implemented yet")
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
    public func kesPeriodInfo(pool: PoolOperator? = nil, opCert: OperationalCertificate?) async throws -> KESPeriodInfo {
        guard let opCert = opCert else {
            throw CardanoChainError.valueError("Operational certificate is required for KES period info")
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
        
        let onChainOpCertCount = dict["qKesNodeStateOperationalCertificateNumber"] as? Int ?? -1
        let onDiskOpCertCount = dict["qKesOnDiskOperationalCertificateNumber"] as? Int ?? 0
        let onDiskKESStart = dict["qKesStartKesInterval"] as? Int ?? 0
        
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
    public func stakePoolInfo(poolId: String) async throws -> StakePoolInfo {
        let poolOperator = try PoolOperator(from: poolId)
        
        let poolState = try await cli.query.poolState(
            pool: poolOperator
        )
        
        guard let poolEntry = poolState.pools.first(where: { $0.key == poolOperator }) else {
            throw CardanoChainError.cardanoCLIError("Pool not found or has no poolParams")
        }
        
        let poolParams = try await poolEntry.value.poolParams.toPoolParams(
            poolOperator: poolOperator,
            strict: true
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
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [[Any]],
                  let firstEntry = entries.first,
                  firstEntry.count == 2,
                  let stateDict = firstEntry[1] as? [String: Any] else {
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
            
            let deposit = (stateDict["deposit"] as? Int).map { Coin(UInt64($0)) }
            let expiry = (stateDict["expiry"] as? Int).map { UInt64($0) }
            let stakeRaw = stateDict["stake"] as? Int ?? 0
            
            var anchor: Anchor? = nil
            if let anchorDict = stateDict["anchor"] as? [String: Any],
               let urlStr = anchorDict["url"] as? String,
               let hashStr = anchorDict["dataHash"] as? String,
               let hashData = Data(hexString: hashStr) {
                anchor = try? Anchor(
                    anchorUrl: Url(urlStr),
                    anchorDataHash: AnchorDataHash(payload: hashData)
                )
            }
            
            return DRepInfo(
                active: true,
                drep: drep,
                anchor: anchor,
                deposit: deposit,
                stake: Coin(UInt64(stakeRaw)),
                expiry: expiry,
                status: .registered
            )
        }
        
        switch drep.credential {
            case .alwaysAbstain, .alwaysNoConfidence:
                let distKey = drep.credential == .alwaysAbstain
                    ? "drep-alwaysAbstain"
                    : "drep-alwaysNoConfidence"
                
                let distResult = try await cli
                    .query
                    .drepStakeDistribution(arguments: [
                        "--all-dreps",
                        "--output-json"
                    ])
                
                var stake = Coin(0)
                
                if let distData = distResult.data(using: .utf8),
                   let distDict = try? JSONSerialization.jsonObject(with: distData) as? [String: Any],
                   let stakeRaw = distDict[distKey] as? Int64 {
                    stake = Coin(UInt64(stakeRaw))
                }
                
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
                    "--output-json"
                ])
                return try parseDRepStateResult(result, drep: drep)

            case .scriptHash(let hash):
                let result = try await cli.query.drepState(arguments: [
                    "--drep-script-hash", hash.payload.toHex,
                    "--include-stake",
                    "--output-json"
                ])
                return try parseDRepStateResult(result, drep: drep)
        }
    }
}
