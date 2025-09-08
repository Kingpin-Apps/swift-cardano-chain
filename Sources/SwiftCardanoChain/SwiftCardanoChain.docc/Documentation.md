# ``SwiftCardanoChain``

A Swift implementation of Cardano Chain Contexts for interacting with the Cardano blockchain.

## Overview

SwiftCardanoChain provides two powerful chain context implementations that allow you to read from and write to the Cardano blockchain:

- **BlockFrostChainContext**: Uses the BlockFrost API for cloud-based blockchain interactions
- **CardanoCliChainContext**: Uses the Cardano CLI for local node interactions

Both implementations conform to the `ChainContext` protocol and provide the same interface for:
- Reading blockchain data (UTxOs, protocol parameters, genesis parameters)
- Writing transactions to the blockchain
- Evaluating transaction execution units
- Querying stake address information

## Getting Started

### BlockFrost Chain Context

The BlockFrost chain context is ideal for applications that need to interact with the Cardano blockchain without running a local node.

```swift
import SwiftCardanoChain

// Initialize with environment variable
let chainContext = try await BlockFrostChainContext<Never>(
    network: .preview,
    environmentVariable: "BLOCKFROST_API_KEY"
)

// Or initialize with project ID directly
let chainContext = try await BlockFrostChainContext<Never>(
    projectId: "your-project-id",
    network: .mainnet
)
```

### Cardano CLI Chain Context

The Cardano CLI chain context is perfect for applications that have access to a local Cardano node.

```swift
import SwiftCardanoChain

let chainContext = try CardanoCliChainContext<Never>(
    configFile: URL(fileURLWithPath: "/path/to/config.json"),
    network: .preview
)
```

## Reading Blockchain Data

### Getting UTxOs

Retrieve all UTxOs for a specific address:

```swift
let address = try Address(
    from: .string("addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3")
)

let utxos = try await chainContext.utxos(address: address)

for utxo in utxos {
    print("Transaction ID: \(utxo.input.transactionId.payload.toHex)")
    print("Output Index: \(utxo.input.index)")
    print("Address: \(try utxo.output.address.toBech32())")
    print("Amount: \(utxo.output.amount.coin) lovelace")
    
    // Handle multi-assets if present
    for (policyId, assets) in utxo.output.amount.multiAsset {
        for (assetName, amount) in assets {
            print("Asset: \(policyId.payload.toHex).\(assetName.name.toHex) = \(amount)")
        }
    }
}
```

### Getting Protocol Parameters

Retrieve current protocol parameters:

```swift
let protocolParams = try await chainContext.protocolParameters()

print("Min fee per byte: \(protocolParams.txFeePerByte)")
print("Fixed fee: \(protocolParams.txFeeFixed)")
print("Max transaction size: \(protocolParams.maxTxSize)")
print("UTxO cost per byte: \(protocolParams.utxoCostPerByte)")
```

### Getting Genesis Parameters

Retrieve genesis parameters for the network:

```swift
let genesisParams = try await chainContext.genesisParameters()

print("Network ID: \(genesisParams.networkId)")
print("Network Magic: \(genesisParams.networkMagic)")
print("Slot length: \(genesisParams.slotLength) seconds")
print("Epoch length: \(genesisParams.epochLength) slots")
print("Security parameter: \(genesisParams.securityParam)")
```

### Getting Current Blockchain State

```swift
// Get current epoch
let currentEpoch = try await chainContext.epoch()
print("Current epoch: \(currentEpoch)")

// Get last block slot
let lastSlot = try await chainContext.lastBlockSlot()
print("Last block slot: \(lastSlot)")

// Get network type
let network = chainContext.network
print("Network: \(network)")
```

## Writing to the Blockchain

### Submitting Transactions

The chain contexts provide multiple ways to submit transactions:

#### Submit a Transaction Object

```swift
// Assuming you have a built transaction
let transaction: Transaction<Never> = // ... your transaction

let txId = try await chainContext.submitTx(tx: .transaction(transaction))
print("Transaction submitted with ID: \(txId)")
```

#### Submit CBOR Data

```swift
let cborData = transaction.toCBORData()
let txId = try await chainContext.submitTx(tx: .bytes(cborData))
print("Transaction submitted with ID: \(txId)")
```

#### Submit CBOR Hex String

```swift
let cborHex = "84a70081825820b35a4ba9ef3ce21adcd6879d..."
let txId = try await chainContext.submitTx(tx: .string(cborHex))
print("Transaction submitted with ID: \(txId)")
```

### Evaluating Transaction Execution Units

Before submitting a transaction with Plutus scripts, you may need to evaluate execution units:

```swift
// Evaluate using transaction object
let executionUnits = try await chainContext.evaluateTx(tx: transaction)

for (redeemerIndex, units) in executionUnits {
    print("Redeemer \(redeemerIndex): \(units.mem) memory, \(units.steps) steps")
}

// Or evaluate using CBOR data
let executionUnits = try await chainContext.evaluateTxCBOR(cbor: cborData)
```

## Staking Operations

### Querying Stake Address Information

```swift
let stakeAddress = try Address(
    from: .string("stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n")
)

let stakeInfo = try await chainContext.stakeAddressInfo(address: stakeAddress)

for info in stakeInfo {
    print("Address: \(info.address)")
    print("Balance: \(info.rewardAccountBalance) lovelace")
    print("Delegated to pool: \(info.stakeDelegation ?? "None")")
    print("Vote delegation: \(info.voteDelegation ?? "None")")
    print("DRep: \(info.delegateRepresentative ?? "None")")
}
```

## Error Handling

Both chain contexts use the `CardanoChainError` enum for error handling:

```swift
do {
    let utxos = try await chainContext.utxos(address: address)
    // Process UTxOs
} catch let error as CardanoChainError {
    switch error {
    case .blockfrostError(let message):
        print("BlockFrost API error: \(message)")
    case .transactionFailed(let message):
        print("Transaction failed: \(message)")
    case .invalidArgument(let message):
        print("Invalid argument: \(message)")
    case .valueError(let message):
        print("Value error: \(message)")
    case .unsupportedNetwork(let message):
        print("Unsupported network: \(message)")
    }
} catch {
    print("Unexpected error: \(error)")
}
```

## Network Configuration

Both chain contexts support multiple Cardano networks:

```swift
// Mainnet
let mainnetContext = try await BlockFrostChainContext<Never>(
    projectId: "mainnet-project-id",
    network: .mainnet
)

// Preprod testnet
let preprodContext = try await BlockFrostChainContext<Never>(
    projectId: "preprod-project-id",
    network: .preprod
)

// Preview testnet
let previewContext = try await BlockFrostChainContext<Never>(
    projectId: "preview-project-id",
    network: .preview
)
```

## Understanding ReedemerType

The `ChainContext` protocol uses a generic `associatedtype` called `ReedemerType` that must conform to `CBORSerializable & Hashable`. This type parameter determines how Plutus script redeemers are represented in your transactions.

### What are Redeemers?

In Cardano's extended UTxO (eUTxO) model, when you spend UTxOs that are locked by Plutus scripts, you must provide:
- **Datum**: Data associated with the UTxO (the "lock")
- **Redeemer**: Data you provide to "unlock" the UTxO (the "key")
- **Script Context**: Information about the transaction (provided automatically)

The `ReedemerType` generic parameter specifies the Swift type used to represent redeemer data in your transactions.

### When to Use `Never`

Use `Never` as your `ReedemerType` when your application:

1. **Only performs simple transactions** without Plutus scripts
2. **Only reads blockchain data** (UTxOs, protocol parameters, etc.)
3. **Submits pre-built transactions** as CBOR data or hex strings
4. **Doesn't need to construct transactions** with custom redeemer types

```swift
// For read-only operations or simple transactions
let chainContext = try await BlockFrostChainContext<Never>(
    projectId: "your-project-id",
    network: .mainnet
)

// Reading data works perfectly with Never
let utxos = try await chainContext.utxos(address: address)
let protocolParams = try await chainContext.protocolParameters()

// Submitting pre-built transactions works too
let txId = try await chainContext.submitTx(tx: .string(cborHex))
```

### When to Use Custom Types

Define a custom `ReedemerType` when your application:

1. **Constructs transactions** that interact with specific Plutus scripts
2. **Has domain-specific redeemer data** structures
3. **Needs type safety** for redeemer construction

```swift
// Define your custom redeemer type
struct MyRedeemer: CBORSerializable, Hashable {
    let action: String
    let amount: Int
    let recipient: String
    
    func toCBOR() -> CBOR {
        // Implementation to serialize to CBOR
        return .array([
            .textString(action),
            .unsignedInteger(UInt64(amount)),
            .textString(recipient)
        ])
    }
    
    static func fromCBOR(_ cbor: CBOR) throws -> MyRedeemer {
        // Implementation to deserialize from CBOR
        guard case let .array(items) = cbor,
              items.count == 3,
              case let .textString(action) = items[0],
              case let .unsignedInteger(amount) = items[1],
              case let .textString(recipient) = items[2] else {
            throw CBORError.invalidFormat
        }
        return MyRedeemer(action: action, amount: Int(amount), recipient: recipient)
    }
}

// Use your custom redeemer type
let chainContext = try await BlockFrostChainContext<MyRedeemer>(
    projectId: "your-project-id",
    network: .mainnet
)

// Now you can work with strongly-typed transactions
let transaction = Transaction<MyRedeemer>(
    body: transactionBody,
    witnessSet: witnessSet
)

let txId = try await chainContext.submitTx(tx: .transaction(transaction))
```

### Common Redeemer Types

#### Unit Redeemer (for simple unlocking)
```swift
struct UnitRedeemer: CBORSerializable, Hashable {
    func toCBOR() -> CBOR {
        return .null  // Plutus Unit type
    }
    
    static func fromCBOR(_ cbor: CBOR) throws -> UnitRedeemer {
        return UnitRedeemer()
    }
}
```

#### Action-based Redeemer (for different script actions)
```swift
enum ScriptAction: CBORSerializable, Hashable {
    case mint(amount: Int)
    case burn(amount: Int)
    case transfer(to: String)
    
    func toCBOR() -> CBOR {
        switch self {
        case .mint(let amount):
            return .array([.unsignedInteger(0), .unsignedInteger(UInt64(amount))])
        case .burn(let amount):
            return .array([.unsignedInteger(1), .unsignedInteger(UInt64(amount))])
        case .transfer(let to):
            return .array([.unsignedInteger(2), .textString(to)])
        }
    }
    
    static func fromCBOR(_ cbor: CBOR) throws -> ScriptAction {
        guard case let .array(items) = cbor,
              items.count >= 2,
              case let .unsignedInteger(tag) = items[0] else {
            throw CBORError.invalidFormat
        }
        
        switch tag {
        case 0:
            guard case let .unsignedInteger(amount) = items[1] else {
                throw CBORError.invalidFormat
            }
            return .mint(amount: Int(amount))
        case 1:
            guard case let .unsignedInteger(amount) = items[1] else {
                throw CBORError.invalidFormat
            }
            return .burn(amount: Int(amount))
        case 2:
            guard case let .textString(to) = items[1] else {
                throw CBORError.invalidFormat
            }
            return .transfer(to: to)
        default:
            throw CBORError.invalidFormat
        }
    }
}
```

### Practical Guidelines

1. **Start with `Never`** if you're unsure - it works for most use cases
2. **Use `Never` for prototyping** and testing blockchain interactions
3. **Define custom types** only when you need to construct transactions with specific script interactions
4. **Keep redeemer types simple** and focused on the data your scripts need
5. **Test CBOR serialization** thoroughly - incorrect serialization will cause transaction failures

### Type Safety Benefits

Using specific redeemer types provides:
- **Compile-time safety**: Catch redeemer structure errors at build time
- **Clear documentation**: Types serve as documentation for script interfaces
- **IDE support**: Better autocomplete and refactoring capabilities
- **Maintainability**: Easier to update when script interfaces change

## Performance Considerations

### Caching

Both implementations include intelligent caching:

- **Protocol parameters** are cached per epoch
- **Genesis parameters** are cached permanently
- **UTxOs** are cached by slot and address (CardanoCLI only)
- **Chain tip** data has configurable refresh intervals

### Resource Management

```swift
// Configure CardanoCLI context with custom cache sizes
let cliContext = try CardanoCliChainContext<Never>(
    configFile: configURL,
    network: .preview,
    refetchChainTipInterval: 30.0, // Refresh every 30 seconds
    utxoCacheSize: 5000,          // Cache up to 5000 UTxO sets
    datumCacheSize: 1000          // Cache up to 1000 datums
)
```

## Topics

### Chain Contexts

- ``BlockFrostChainContext``
- ``CardanoCliChainContext``
- ``ChainContext``

### Data Types

- ``TransactionData``
- ``CardanoChainError``
- ``Network``

### Blockchain Operations

- Reading UTxOs
- Submitting Transactions
- Evaluating Execution Units
- Querying Protocol Parameters
- Accessing Genesis Parameters
- Stake Address Information
