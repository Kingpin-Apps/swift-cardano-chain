# Using CardanoCliChainContext

Interact with a local Cardano node by shelling out to the `cardano-cli` binary.

## Overview

``CardanoCliChainContext`` wraps a local `cardano-cli` installation. It is the right choice when
you control the server environment, already run a `cardano-node`, and want full local-node
fidelity without the extra dependency of Ogmios or a direct NtC socket.

Protocol parameters, UTxO sets, and the chain tip are cached internally to avoid redundant CLI
invocations. Cache lifetimes and sizes are configurable at initialisation time.

**Supported networks:** `.mainnet`, `.preprod`, `.preview`

## Prerequisites

- A running `cardano-node` with its socket accessible.
- `cardano-cli` installed and on `PATH` (or at a known path).
- The node configuration JSON file (e.g. `config.json` from the IOHK release bundles).

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.3.0")
```

## Creating a Context

### Minimal Setup (Uses `~/.cardano-cli/config`)

If you have the Cardano configuration stored in the default location:

```swift
import SwiftCardanoChain

let context = try await CardanoCliChainContext(network: .mainnet)
```

### Explicit Paths

```swift
let context = try await CardanoCliChainContext(
    nodeConfig: FilePath("/opt/cardano/mainnet/config.json"),
    binary:     FilePath("/usr/local/bin/cardano-cli"),
    socket:     FilePath("/ipc/node.socket"),
    network:    .mainnet
)
```

### With Custom Cache Settings

```swift
let context = try await CardanoCliChainContext(
    nodeConfig: FilePath("/opt/cardano/preview/config.json"),
    binary:     FilePath("/usr/local/bin/cardano-cli"),
    socket:     FilePath("/ipc/node.socket"),
    network:    .preview,
    refetchChainTipInterval: 30,   // seconds between tip refreshes
    utxoCacheSize: 5_000,          // max cached UTxO sets
    datumCacheSize: 1_000          // max cached datums
)
```

### Providing a Pre-Built `CardanoCLI` Instance

Useful when you share a CLI instance across multiple contexts or in tests:

```swift
let cli = try await CardanoCLI(configuration: myConfig)
let context = try await CardanoCliChainContext(network: .preview, cli: cli)
```

## Reading Chain Data

### UTxOs at an Address

UTxO results are cached by address and slot number:

```swift
let address = try Address(from: .string("addr1..."))
let utxos   = try await context.utxos(address: address)

for utxo in utxos {
    print("\(utxo.input.transactionId.payload.toHex)#\(utxo.input.index)")
    print("  \(utxo.output.amount.coin) lovelace")
}
```

### Protocol and Genesis Parameters

Genesis parameters are loaded once from the node config file and cached permanently.
Protocol parameters are re-fetched when the chain tip advances.

```swift
let params  = try await context.protocolParameters()
let genesis = try await context.genesisParameters()

print("Min fee per byte : \(params.txFeePerByte)")
print("Slot length      : \(genesis.slotLength)s")
```

### Current Epoch, Era and Slot

```swift
let epoch = try await context.epoch()
let era   = try await context.era()
let slot  = try await context.lastBlockSlot()

print("Epoch \(epoch), \(era?.description ?? "unknown") era, slot \(slot)")
```

## Submitting Transactions

`cardano-cli` submits transactions through the local node socket:

```swift
// From a transaction object
let txId = try await context.submitTx(tx: .transaction(transaction))

// From CBOR bytes
let txId = try await context.submitTx(tx: .bytes(cborData))

// From a CBOR hex string
let txId = try await context.submitTx(tx: .string("84a700..."))

print("Submitted: \(txId)")
```

## Evaluating Plutus Scripts

Script evaluation is delegated to `cardano-cli transaction build` in evaluation mode:

```swift
let units = try await context.evaluateTx(tx: transaction)

for (redeemer, eu) in units {
    print("\(redeemer): mem=\(eu.mem) steps=\(eu.steps)")
}
```

## Staking Queries

```swift
// Stake address rewards and delegation
let stakeInfo = try await context.stakeAddressInfo(address: stakeAddress)

// All registered stake pools
let pools = try await context.stakePools()

// KES period validity for a pool's operational certificate
let kesInfo = try await context.kesPeriodInfo(pool: poolOperator, opCert: opCert)
```

## Error Handling

CLI errors surface as ``CardanoChainError/cardanoCLIError(_:)``:

```swift
do {
    let utxos = try await context.utxos(address: address)
} catch CardanoChainError.cardanoCLIError(let message) {
    print("cardano-cli error: \(message ?? "unknown")")
} catch CardanoChainError.operationError(let message) {
    print("Operation error: \(message ?? "unknown")")
} catch {
    print("Unexpected error: \(error)")
}
```

## Caching Behaviour

| Data | Cache strategy |
|---|---|
| Genesis parameters | Loaded once from config file; never re-fetched |
| Protocol parameters | Re-fetched when `isChainTipUpdated()` returns `true` |
| UTxOs | Cached per address + slot; invalidated when slot advances |
| Datums | LRU cache; size configurable via `datumCacheSize` |
| Chain tip (slot) | Fetched at most once per `refetchChainTipInterval` seconds |

## See Also

- ``CardanoCliChainContext``
- ``ChainContext``
- ``CardanoChainError``
