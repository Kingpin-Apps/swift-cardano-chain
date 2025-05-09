import Foundation
import PotentCBOR
import PotentCodables
import SwiftCardanoCore

/// Structure representing the chain tip
public struct ChainTip: Codable {
    let block: Int
    let epoch: Int
    let era: String
    let hash: String
    let slot: Int
    let slotInEpoch: Int
    let slotsToEpochEnd: Int
    let syncProgress: String
}

/// A Cardano CLI wrapper for interacting with the Cardano blockchain
public class CardanoCliChainContext<T: Codable & Hashable>: ChainContext {
    public typealias ReedemerType = T
    
    // MARK: - Properties

    private let binary: URL
    private let socket: URL?
    private let configFile: URL
    private var lastKnownBlockSlot: Int = 0
    private var lastChainTipFetch: TimeInterval = 0
    private var refetchChainTipInterval: TimeInterval
    private var utxoCache: [String: ([UTxO], TimeInterval)]
    private var datumCache: [String: Any]
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

        let chainTip = try self.queryChainTip()
        return chainTip.era
    }

    public lazy var epoch: () async throws -> Int = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }
        
        let chainTip = try self.queryChainTip()
        return chainTip.epoch
    }

    public lazy var lastBlockSlot: () async throws -> Int = { [weak self] in
        guard var self = self else {
            throw CardanoChainError.valueError("Self is nil")
        }

        let cacheKey = "lastBlockSlot"

        if let cachedValue = self.cache.value(forKey: cacheKey) {
            return cachedValue
        }

        let chainTip = try self.queryChainTip()
        let slot = chainTip.slot

        // Update cache
        self.cache.insert(slot, forKey: cacheKey)

        return slot
    }

    public lazy var genesisParameters: () async throws -> GenesisParameters = { [weak self] in
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

    public lazy var protocolParameters: () async throws -> ProtocolParameters = { [weak self] in
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
    ///   - configFile: Path to the cardano-node config file
    ///   - binary: Path to the cardano-cli binary
    ///   - socket: Path to the cardano-node socket
    ///   - network: Network to use
    ///   - refetchChainTipInterval: Interval in seconds to refetch the chain tip
    ///   - utxoCacheSize: Size of the UTxO cache
    ///   - datumCacheSize: Size of the datum cache
    public init(
        configFile: URL,
        binary: URL? = nil,
        socket: URL? = nil,
        network: SwiftCardanoChain.Network? = .mainnet,
        refetchChainTipInterval: TimeInterval? = nil,
        utxoCacheSize: Int = 10000,
        datumCacheSize: Int = 10000
    ) throws {
        
        self.configFile = configFile
        self.refetchChainTipInterval = refetchChainTipInterval ?? 1000
        self.utxoCache = [:]
        self.datumCache = [:]
        self._network = network ?? .mainnet

        if let binary = binary {
            // Check if the binary exists
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: binary.path, isDirectory: &isDirectory)
                || isDirectory.boolValue
            {
                throw CardanoChainError.cardanoCLIError("cardano-cli binary file not found: \(binary.path)")
            }
            
            // Check if is executable
            if !FileManager.default.isExecutableFile(atPath: binary.path) {
                throw CardanoChainError.cardanoCLIError("cardano-cli binary file is not executable: \(binary.path)")
            }
            
            self.binary = binary
        } else if let binary = CardanoCliChainContext.getCardanoCliPath() {
            self.binary = binary
        } else {
            throw CardanoChainError.cardanoCLIError("cardano-cli binary not found")
        }
        
        var isDirectory: ObjCBool = false
        if socket != nil {
            if !FileManager.default
                .fileExists(
                    atPath: socket!.path,
                    isDirectory: &isDirectory
                ) {
                throw CardanoChainError.cardanoCLIError("cardano-node socket not found: \(socket!.path)")
            } else if isDirectory.boolValue {
                throw CardanoChainError.cardanoCLIError("\(socket!.path) is not a socket file")
            }
            self.socket = socket
        } else if let socket = ProcessInfo.processInfo.environment["CARDANO_NODE_SOCKET_PATH"] {
            self.socket = URL(fileURLWithPath: socket)
        } else {
            throw CardanoChainError.cardanoCLIError("CARDANO_NODE_SOCKET_PATH not set")
        }
            
        setenv("CARDANO_NODE_SOCKET_PATH", self.socket!.path, 1)
    }

    // MARK: - Private Methods
    
    public static func getCardanoCliPath() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["cardano-cli"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !outputString.isEmpty {
                    return URL(fileURLWithPath: outputString)
                }
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                print("Failed to run command: \(errorMessage)")
            }
        } catch {
            print("Failed to run command: \(error.localizedDescription)")
        }
        
        return nil
    }

    /// Run a command using the cardano-cli
    ///
    /// - Parameter cmd: Command as an array of strings
    /// - Returns: The stdout if the command runs successfully
    /// - Throws: CardanoChainError if the command fails
    private func runCommand(_ cmd: [String]) throws -> String {
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
                "Failed to run command: \(error.localizedDescription): \(cmd)")
        }
    }

    /// Query the chain tip
    ///
    /// - Returns: The chain tip as a dictionary
    /// - Throws: CardanoChainError if the query fails
    private func queryChainTip() throws -> ChainTip {
        let result = try runCommand(["query", "tip"] + self._network.arguments)
        guard let data = result.data(using: .utf8),
              let chainTip = try? JSONDecoder().decode(ChainTip.self, from: data)
        else {
            throw CardanoChainError.valueError("Failed to parse chain tip JSON")
        }

        self.lastChainTipFetch = Date().timeIntervalSince1970

        return chainTip
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

        let chainTip = try queryChainTip()

        return Double(chainTip.syncProgress) != 100.0
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
        let result = try runCommand(
            ["query", "utxo", "--address", address.toBech32(), "--out-file", "/dev/stdout"]
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
                transactionId: try TransactionId(from: .string(txId)),
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
                        let policy = try ScriptHash(from: .string(policyId))
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
                datumHash = try DatumHash(from: .string(datumHashStr))
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

            let address = try Address(
                from: .string(utxo["address"] as! String)
            )
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
    public func stakeAddressInfo(address: Address) async throws -> [StakeAddressInfo] {
        let result = try runCommand(
            [
                "query",
                "stake-address-info",
                "--address",
                address.toBech32(),
                "--out-file",
                "/dev/stdout",
            ] + self._network.arguments)

        guard let data = result.data(using: .utf8),
            let infoArray = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [[String: Any]]
        else {
            throw CardanoChainError.valueError("Failed to parse stake address info JSON")
        }

        return try infoArray.map { rewardsState in
            StakeAddressInfo(
                address: try address.toBech32(),
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
