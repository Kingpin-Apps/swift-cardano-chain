# Using BlockFrostChainContext

Connect to the Cardano blockchain through the BlockFrost cloud API — no local node required.

## Overview

``BlockFrostChainContext`` is the simplest way to get started with SwiftCardanoChain. It routes
all chain queries through the [BlockFrost](https://blockfrost.io) REST API, so you only need a
project ID — no `cardano-node`, no Ogmios, no local infrastructure.

**Supported networks:** `.mainnet`, `.preprod`, `.preview`

## Prerequisites

1. Sign up at [blockfrost.io](https://blockfrost.io) and create a project for the network you
   want to target.
2. Copy your project ID (it looks like `mainnetXXXXXXXXXXXXXXXXXXXX`).

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.3.0")
```

## Creating a Context

### From an Environment Variable (Recommended)

Keeping credentials in environment variables avoids committing secrets to source control.

```swift
import SwiftCardanoChain

let context = try await BlockFrostChainContext(
    network: .mainnet,
    environmentVariable: "BLOCKFROST_API_KEY"
)
```

Set the variable in your shell, CI environment, or Xcode scheme:

```
export BLOCKFROST_API_KEY=mainnetXXXXXXXXXXXXXXXXXXXX
```

### With a Project ID Directly

```swift
let context = try await BlockFrostChainContext(
    projectId: "mainnetXXXXXXXXXXXXXXXXXXXX",
    network: .mainnet
)
```

### With a Custom Base URL

Useful for BlockFrost-compatible self-hosted endpoints:

```swift
let context = try await BlockFrostChainContext(
    projectId: "your-key",
    network: .mainnet,
    basePath: "https://your-custom-endpoint.example.com"
)
```

## Reading Chain Data

### UTxOs at an Address

```swift
let address = try Address(from: .string("addr1..."))
let utxos   = try await context.utxos(address: address)

for utxo in utxos {
    print("\(utxo.input.transactionId.payload.toHex)#\(utxo.input.index)")
    print("  \(utxo.output.amount.coin) lovelace")
}
```

### Protocol and Genesis Parameters

Protocol parameters are cached per epoch; genesis parameters are cached permanently.

```swift
let params  = try await context.protocolParameters()
let genesis = try await context.genesisParameters()

print("Min fee per byte: \(params.txFeePerByte)")
print("Slot length: \(genesis.slotLength)s")
```

### Current Epoch and Slot

```swift
let epoch = try await context.epoch()
let slot  = try await context.lastBlockSlot()
print("Epoch \(epoch), slot \(slot)")
```

## Submitting Transactions

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

BlockFrost supports remote evaluation of Plutus execution units:

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

// Details for a specific pool
let pool = try await context.stakePoolInfo(poolId: "pool1...")

// Treasury balance
let treasury = try await context.treasury()
```

## Governance Queries (Conway era)

```swift
// DRep information
let drepInfo = try await context.drepInfo(drep: someDRep)

// Governance action
let govInfo = try await context.govActionInfo(govActionID: someActionId)

// Committee member state
let cmInfo = try await context.committeeMemberInfo(committeeMember: cred)
```

## Error Handling

BlockFrost errors surface as ``CardanoChainError/blockfrostError(_:)``:

```swift
do {
    let utxos = try await context.utxos(address: address)
} catch CardanoChainError.blockfrostError(let message) {
    print("BlockFrost API error: \(message ?? "unknown")")
} catch CardanoChainError.unsupportedNetwork(let message) {
    print("Network not supported: \(message ?? "unknown")")
} catch {
    print("Unexpected error: \(error)")
}
```

## Caching Behaviour

| Data | Cache lifetime |
|---|---|
| Protocol parameters | Per epoch (refreshed when epoch changes) |
| Genesis parameters | Permanent (never re-fetched) |
| UTxOs | Not cached — fetched on every call |
| Epoch / slot | Per request |

## See Also

- ``BlockFrostChainContext``
- ``ChainContext``
- ``CardanoChainError``
