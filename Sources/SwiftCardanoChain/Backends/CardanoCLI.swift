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
        
        guard let nodeConfig = self.cli.configuration.cardano.config else {
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
    public func stakePools() async throws -> [String] {
        return try await cli.query.stakePools(arguments: [])
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
    /// - Returns: `PoolParams` object.
    /// - Throws: `CardanoChainError.cardanoCLIError` if the query fails or parsing fails.
    public func stakePoolInfo(poolId: String) async throws -> PoolParams {
        let response = try await cli.query.poolState(
            arguments: [
                "--stake-pool-id",
                poolId
            ]
        )
        
        // Parse the JSON response
        guard let data = response.data(using: .utf8) else {
            throw CardanoChainError.cardanoCLIError("Failed to convert response to data")
        }
        
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let rootDict = json as? [String: Any] else {
            throw CardanoChainError.cardanoCLIError("Invalid JSON response: expected dictionary")
        }
        
        // The response is keyed by pool ID (hex), get the first entry
        guard let poolEntry = rootDict.values.first as? [String: Any],
              let poolParams = poolEntry["poolParams"] as? [String: Any] else {
            throw CardanoChainError.cardanoCLIError("Pool not found or has no poolParams")
        }
        
        // Extract publicKey (poolOperator)
        guard let publicKeyHex = poolParams["publicKey"] as? String else {
            throw CardanoChainError.cardanoCLIError("Missing publicKey in poolParams")
        }
        let poolOperator = try PoolOperator(from: Data(hex: publicKeyHex))
        
        // Extract VRF key hash
        guard let vrfHex = poolParams["vrf"] as? String else {
            throw CardanoChainError.cardanoCLIError("Missing vrf in poolParams")
        }
        let vrfKeyHash = VrfKeyHash(payload: Data(hex: vrfHex))
        
        // Extract pledge and cost
        guard let pledge = poolParams["pledge"] as? Int else {
            throw CardanoChainError.cardanoCLIError("Missing pledge in poolParams")
        }
        guard let cost = poolParams["cost"] as? Int else {
            throw CardanoChainError.cardanoCLIError("Missing cost in poolParams")
        }
        
        // Extract margin (Double) and convert to UnitInterval
        guard let marginDouble = poolParams["margin"] as? Double else {
            throw CardanoChainError.cardanoCLIError("Missing margin in poolParams")
        }
        let marginDenom: UInt64 = 100_000_000
        let marginNum = UInt64((marginDouble * Double(marginDenom)).rounded())
        let margin = UnitInterval(numerator: marginNum, denominator: marginDenom)
        
        // Extract reward account
        guard let rewardAccountDict = poolParams["rewardAccount"] as? [String: Any],
              let credentialDict = rewardAccountDict["credential"] as? [String: Any],
              let keyHashHex = credentialDict["keyHash"] as? String else {
            throw CardanoChainError.cardanoCLIError("Missing or invalid rewardAccount in poolParams")
        }
        let networkStr = rewardAccountDict["network"] as? String ?? "Mainnet"
        let networkHeader: UInt8 = (networkStr == "Mainnet") ? 0xe1 : 0xe0
        var rewardAccountBytes = Data([networkHeader])
        rewardAccountBytes.append(Data(hex: keyHashHex))
        let rewardAccount = RewardAccountHash(payload: rewardAccountBytes)
        
        // Extract pool owners
        guard let ownersArray = poolParams["owners"] as? [String] else {
            throw CardanoChainError.cardanoCLIError("Missing owners in poolParams")
        }
        let poolOwnersList: [VerificationKeyHash] = ownersArray.map { ownerHex in
            VerificationKeyHash(payload: Data(hex: ownerHex))
        }
        let poolOwners = ListOrOrderedSet<VerificationKeyHash>.list(poolOwnersList)
        
        // Extract relays
        var relays: [Relay] = []
        if let relaysArray = poolParams["relays"] as? [[String: Any]] {
            for relayDict in relaysArray {
                if let singleHostAddr = relayDict["single host address"] as? [String: Any] {
                    let port = singleHostAddr["port"] as? Int
                    var ipv4: IPv4Address? = nil
                    var ipv6: IPv6Address? = nil
                    
                    if let ipv4String = singleHostAddr["IPv4"] as? String {
                        ipv4 = IPv4Address(ipv4String)
                    }
                    if let ipv6String = singleHostAddr["IPv6"] as? String {
                        ipv6 = IPv6Address(ipv6String)
                    }
                    relays.append(.singleHostAddr(SingleHostAddr(port: port, ipv4: ipv4, ipv6: ipv6)))
                } else if let singleHostName = relayDict["single host name"] as? [String: Any] {
                    let port = singleHostName["port"] as? Int
                    let dnsName = singleHostName["dnsName"] as? String
                    relays.append(.singleHostName(SingleHostName(port: port, dnsName: dnsName)))
                } else if let multiHostName = relayDict["multi host name"] as? [String: Any] {
                    let dnsName = multiHostName["dnsName"] as? String
                    relays.append(.multiHostName(MultiHostName(dnsName: dnsName)))
                }
            }
        }
        
        // Extract metadata
        var poolMetadata: PoolMetadata? = nil
        if let metadataDict = poolParams["metadata"] as? [String: Any],
           let urlString = metadataDict["url"] as? String,
           let hashHex = metadataDict["hash"] as? String,
           let hashData = Data(hexString: hashHex) {
            poolMetadata = try PoolMetadata(
                url: try Url(urlString),
                poolMetadataHash: PoolMetadataHash(payload: hashData)
            )
        }
        
        return PoolParams(
            poolOperator: poolOperator.poolKeyHash,
            vrfKeyHash: vrfKeyHash,
            pledge: pledge,
            cost: cost,
            margin: margin,
            rewardAccount: rewardAccount,
            poolOwners: poolOwners,
            relays: relays.isEmpty ? nil : relays,
            poolMetadata: poolMetadata
        )
    }
}
