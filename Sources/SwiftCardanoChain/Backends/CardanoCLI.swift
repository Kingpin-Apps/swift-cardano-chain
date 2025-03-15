import Foundation
import PotentCBOR
import PotentCodables
import SwiftCardanoCore

/// Docker configuration for Cardano CLI
public struct DockerConfig {
    /// The name of the Docker container containing the cardano-cli
    let containerName: String

    /// The path to the Docker host socket file
    let hostSocket: URL?

    public init(containerName: String, hostSocket: URL? = nil) {
        self.containerName = containerName
        self.hostSocket = hostSocket
    }
}

/// A Cardano CLI wrapper for interacting with the Cardano blockchain
public class CardanoCliChainContext: ChainContext {
    // MARK: - Properties

    private let binary: URL
    private let socket: URL?
    private let configFile: URL
    private var lastKnownBlockSlot: Int = 0
    private var lastChainTipFetch: TimeInterval = 0
    private var refetchChainTipInterval: TimeInterval
    private var utxoCache: [String: ([UTxO], TimeInterval)]
    private var datumCache: [String: Any]
    private let dockerConfig: DockerConfig?
    private let networkMagicNumber: Int?
    private let cache = Cache<String, Int>()
    private let cacheTTL: TimeInterval = 1.0  // 1 second TTL
    private let _network: SwiftCardanoChain.Network
    private var _genesisParameters: GenesisParameters?
    private var _protocolParameters: ProtocolParameters?

    // MARK: - ChainContext Protocol Properties

    public var network: SwiftCardanoCore.Network {
        switch self._network {
        case .mainnet:
            return .mainnet
        default:
            return .testnet
        }
    }

    public lazy var era: () async throws -> String = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }

        let result = try self.queryChainTip()
        return result["era"] as? String ?? ""
    }

    public lazy var epoch: () async throws -> Int = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }

        let result = try self.queryChainTip()
        return result["epoch"] as? Int ?? 0
    }

    public lazy var lastBlockSlot: () async throws -> Int = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }

        let cacheKey = "lastBlockSlot"

        if let cachedValue = self.cache.value(forKey: cacheKey) {
            return cachedValue
        }

        let result = try self.queryChainTip()
        let slot = result["slot"] as? Int ?? 0

        // Update cache
        self.cache.insert(slot, forKey: cacheKey)

        return slot
    }

    public lazy var genesisParam: () async throws -> GenesisParameters = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }

        if self._genesisParameters == nil {
            self._genesisParameters = try GenesisParameters(
                nodeConfigFilePath: self.configFile.path
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

    public lazy var protocolParam: () async throws -> ProtocolParameters = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }

        if try self.isChainTipUpdated() || self._protocolParameters == nil {
            self._protocolParameters = try self.queryCurrentProtocolParams()
        }

        return self._protocolParameters!
    }

    // MARK: - Initialization

    /// Initialize a new CardanoCliChainContext
    ///
    /// - Parameters:
    ///   - binary: Path to the cardano-cli binary
    ///   - socket: Path to the cardano-node socket
    ///   - configFile: Path to the cardano-node config file
    ///   - network: Network to use
    ///   - refetchChainTipInterval: Interval in seconds to refetch the chain tip
    ///   - utxoCacheSize: Size of the UTxO cache
    ///   - datumCacheSize: Size of the datum cache
    ///   - dockerConfig: Docker configuration if using Docker
    ///   - networkMagicNumber: Network magic number for custom networks
    public init(
        binary: URL,
        socket: URL,
        configFile: URL,
        network: SwiftCardanoChain.Network? = .mainnet,
        refetchChainTipInterval: TimeInterval? = nil,
        utxoCacheSize: Int = 10000,
        datumCacheSize: Int = 10000,
        dockerConfig: DockerConfig? = nil,
        networkMagicNumber: Int? = nil
    ) {
        self.binary = binary
        self.configFile = configFile
        self.refetchChainTipInterval = refetchChainTipInterval ?? 1000
        self.utxoCache = [:]
        self.datumCache = [:]
        self.dockerConfig = dockerConfig
        self.networkMagicNumber = networkMagicNumber
        self._network = network ?? .mainnet

        if dockerConfig == nil {
            // Check if the binary exists
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: binary.path, isDirectory: &isDirectory)
                || isDirectory.boolValue
            {
                fatalError("cardano-cli binary file not found: \(binary.path)")
            }

            // Check the socket path file and set the CARDANO_NODE_SOCKET_PATH environment variable
            if !FileManager.default.fileExists(atPath: socket.path, isDirectory: &isDirectory) {
                fatalError("cardano-node socket not found: \(socket.path)")
            } else if isDirectory.boolValue {
                fatalError("\(socket.path) is not a socket file")
            }

            self.socket = socket
            setenv("CARDANO_NODE_SOCKET_PATH", socket.path, 1)
        } else {
            self.socket = nil
        }
    }

    // MARK: - Private Methods

    /// Run a command using the cardano-cli
    ///
    /// - Parameter cmd: Command as an array of strings
    /// - Returns: The stdout if the command runs successfully
    /// - Throws: CardanoChainError if the command fails
    private func runCommand(_ cmd: [String]) throws -> String {
        if let dockerConfig = self.dockerConfig {
            // TODO: Implement Docker support
            // This would require a Swift Docker client library or using Process to call the docker command
            throw CardanoChainError.valueError("Docker support not implemented yet")
        } else {
            let process = Process()
            process.executableURL = self.binary
            process.arguments = cmd

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    return String(data: outputData, encoding: .utf8)?.trimmingCharacters(
                        in: .whitespacesAndNewlines) ?? ""
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    throw CardanoChainError.valueError(errorMessage)
                }
            } catch {
                throw CardanoChainError.valueError(
                    "Failed to run command: \(error.localizedDescription)")
            }
        }
    }

    /// Query the chain tip
    ///
    /// - Returns: The chain tip as a dictionary
    /// - Throws: CardanoChainError if the query fails
    private func queryChainTip() throws -> [String: Any] {
        let result = try runCommand(["query", "tip"] + self._network.arguments)
        guard let data = result.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            throw CardanoChainError.valueError("Failed to parse chain tip JSON")
        }

        self.lastChainTipFetch = Date().timeIntervalSince1970

        return json
    }

    /// Query the current protocol parameters
    ///
    /// - Returns: The protocol parameters as a dictionary
    /// - Throws: CardanoChainError if the query fails
    private func queryCurrentProtocolParams() throws -> ProtocolParameters {
        let result = try runCommand(["query", "protocol-parameters"] + self._network.arguments)
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
    private func isChainTipUpdated() throws -> Bool {
        // Fetch at almost every refetchChainTipInterval seconds
        if Date().timeIntervalSince1970 - lastChainTipFetch < refetchChainTipInterval {
            return false
        }

        let result = try queryChainTip()

        guard let syncProgress = result["syncProgress"] as? Double else {
            throw CardanoChainError.valueError("Failed to get sync progress")
        }

        return syncProgress != 100.0
    }

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
            let v1script = PlutusV1Script(cborData)
            return .plutusV1Script(v1script)
        } else if scriptType == "PlutusScriptV2" {
            guard let cborHex = script["cborHex"] as? String,
                let cborData = Data(hexString: cborHex)
            else {
                throw CardanoChainError.valueError("Invalid PlutusScriptV2 CBOR")
            }

            // Create PlutusV2Script from CBOR
            let v2script = PlutusV2Script(cborData)
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
    public func utxos(address: String) async throws -> [UTxO] {
        // Check if the UTxOs are in the cache
        let currentSlot = try await lastBlockSlot()
        let cacheKey = "\(currentSlot):\(address)"

        if let (cachedUtxos, _) = utxoCache[cacheKey] {
            return cachedUtxos
        }

        // Query the UTxOs
        let result = try runCommand(
            ["query", "utxo", "--address", address, "--out-file", "/dev/stdout"]
                + self._network.arguments
        )

        guard let data = result.data(using: .utf8),
            let rawUtxos = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [String: [String: Any]]
        else {
            throw CardanoChainError.valueError("Failed to parse UTxOs JSON")
        }

        var utxos: [UTxO] = []

        for (txHash, utxo) in rawUtxos {
            let parts = txHash.split(separator: "#")
            guard parts.count == 2,
                let txIdx = Int(parts[1])
            else {
                continue
            }

            let txId = String(parts[0])
            let txIn = TransactionInput(
                transactionId: try TransactionId(from: txId),
                index: UInt16(txIdx)
            )

            guard let utxoValue = utxo["value"] as? [String: Any] else {
                continue
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

                    guard let assets = amount as? [String: Int] else {
                        continue
                    }

                    for (assetHexName, assetAmount) in assets {
                        // Create Asset and add to MultiAsset
                        let policy = try ScriptHash(from: policyId)
                        let assetName = AssetName(from: assetHexName)

                        // Initialize the Asset for this policy if it doesn't exist
                        if multiAsset[policy] == nil {
                            multiAsset[policy] = Asset([:])
                        }
                        // Add the asset to the policy
                        multiAsset[policy]?[assetName] = assetAmount
                    }
                }
            }

            // Set the multi-asset on the value
            value.multiAsset = multiAsset

            // Handle datum hash
            var datumHash: DatumHash? = nil
            if let datumHashStr = utxo["datumhash"] as? String {
                datumHash = try DatumHash(from: datumHashStr)
            }

            // Handle datum
            var datum: Datum? = nil
            if let datumStr = utxo["datum"] as? String, let datumData = Data(hexString: datumStr) {
                datum = .cbor(CBOR(datumData))
            } else if let inlineDatum = utxo["inlineDatum"] as? [AnyValue: AnyValue] {
                // Convert inline datum dictionary to RawPlutusData
                // This would require proper implementation of RawPlutusData.fromDict
                datum = .dict(inlineDatum)
            }

            // Handle reference script
            var script: ScriptType? = nil
            if let referenceScript = utxo["referenceScript"] as? [String: Any] {
                script = try await getScript(from: referenceScript)
            }

            let address = try Address(from: utxo["address"] as? String ?? "")
            let txOut = TransactionOutput(
                address: address,
                amount: value,
                datumHash: datumHash,
                datum: datum,
                script: script
            )

            utxos.append(UTxO(input: txIn, output: txOut))
        }

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

        // Write the transaction to the temporary file
        let txJson: [String: Any] = [
            "type": "Witnessed Tx \(try await epoch())Era",
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
            let _ = try runCommand(
                ["transaction", "submit", "--tx-file", tempFile.path] + self._network.arguments)
        } catch {
            do {
                let _ = try runCommand(
                    ["latest", "transaction", "submit", "--tx-file", tempFile.path]
                        + self._network.arguments)
            } catch {
                throw CardanoChainError.transactionFailed(
                    "Failed to submit transaction: \(error.localizedDescription)")
            }
        }

        // Get the transaction ID
        var txid: String
        do {
            txid = try runCommand(["transaction", "txid", "--tx-file", tempFile.path])
        } catch {
            do {
                txid = try runCommand(["latest", "transaction", "txid", "--tx-file", tempFile.path])
            } catch {
                throw CardanoChainError.valueError(
                    "Unable to get transaction id for \(tempFile.path)")
            }
        }

        return txid
    }

    /// Get the stake address information
    ///
    /// - Parameter address: The stake address
    /// - Returns: List of StakeAddressInfo objects
    /// - Throws: CardanoChainError if the query fails
    public func stakeAddressInfo(address: String) async throws -> [StakeAddressInfo] {
        let result = try runCommand(
            [
                "query",
                "stake-address-info",
                "--address",
                address,
                "--out-file",
                "/dev/stdout",
            ] + self._network.arguments)

        guard let data = result.data(using: .utf8),
            let infoArray = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [[String: Any]]
        else {
            throw CardanoChainError.valueError("Failed to parse stake address info JSON")
        }

        return infoArray.map { rewardsState in
            StakeAddressInfo(
                address: address,
                delegationDeposit: rewardsState["delegationDeposit"] as? Int ?? 0,
                rewardAccountBalance: rewardsState["rewardAccountBalance"] as? Int ?? 0,
                stakeDelegation: rewardsState["stakeDelegation"] as? String,
                voteDelegation: rewardsState["voteDelegation"] as? String,
                delegateRepresentative: nil
            )
        }
    }

    /// Get the cardano-cli version
    ///
    /// - Returns: The cardano-cli version
    /// - Throws: CardanoChainError if the query fails
    public func version() throws -> String {
        return try runCommand(["version"])
    }

    /// Evaluate execution units of a transaction
    ///
    /// - Parameter cbor: The serialized transaction to be evaluated
    /// - Returns: A dictionary mapping redeemer strings to execution units
    /// - Throws: CardanoChainError if the evaluation fails
    public func evaluateTxCBOR(cbor: Data) async throws -> [String: ExecutionUnits] {
        // TODO: Implement transaction evaluation
        throw CardanoChainError.valueError("Transaction evaluation not implemented yet")
    }
}
