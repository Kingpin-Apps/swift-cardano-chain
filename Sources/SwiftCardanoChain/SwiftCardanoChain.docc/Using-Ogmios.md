# Using OgmiosChainContext

Connect to a local Cardano node through the Ogmios WebSocket/HTTP bridge.

## Overview

``OgmiosChainContext`` speaks to a local [Ogmios](https://ogmios.dev) server — a lightweight
process that sits in front of `cardano-node` and exposes the Ouroboros mini-protocols over a
WebSocket and HTTP API.

Compared to ``CardanoCliChainContext``, Ogmios is lower latency (no subprocess overhead) and
exposes richer query semantics. Compared to ``NodeSocketChainContext``, it requires the extra
Ogmios process but works on all platforms including those without Unix socket support.

**Supported networks:** `.mainnet`, `.preprod`, `.preview` (any network your local node runs)

## Prerequisites

- A running `cardano-node`.
- [Ogmios](https://ogmios.dev/getting-started/) installed and running, connected to that node.
  The default listen address is `localhost:1337`.

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.3.0")
```

## Creating a Context

### Default Local Instance (`localhost:1337`)

If Ogmios is running with its default settings, you can connect with no arguments:

```swift
import SwiftCardanoChain

let context = try await OgmiosChainContext(network: .mainnet)
```

### Explicit Host and Port

```swift
let context = try await OgmiosChainContext(
    host: "localhost",
    port: 1337,
    network: .mainnet
)
```

### Remote or TLS-Secured Ogmios

```swift
// TLS-secured remote instance
let context = try await OgmiosChainContext(
    host: "ogmios.example.com",
    port: 443,
    path: "/",
    secure: true,
    network: .mainnet
)
```

### Injecting an Existing `OgmiosClient`

Share a client across multiple contexts or inject a mock in tests:

```swift
let client = try await OgmiosClient(host: "localhost", port: 1337)
let context = try await OgmiosChainContext(network: .mainnet, client: client)
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

```swift
let params  = try await context.protocolParameters()
let genesis = try await context.genesisParameters()

print("Min fee per byte: \(params.txFeePerByte)")
print("Slot length: \(genesis.slotLength)s")
```

### Chain Tip

Ogmios exposes a richer chain tip than most backends:

```swift
let tip = try await context.queryChainTip()

print("Block  : \(tip.block ?? 0)")
print("Slot   : \(tip.slot ?? 0)")
print("Epoch  : \(tip.epoch ?? 0)")
print("Hash   : \(tip.hash ?? "none")")
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

// From a CBOR hex string
let txId = try await context.submitTx(tx: .string("84a700..."))

print("Submitted: \(txId)")
```

## Evaluating Plutus Scripts

Ogmios forwards evaluation requests to the node's local UPLC evaluator:

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
```

## Error Handling

Ogmios errors surface as ``CardanoChainError/operationError(_:)``:

```swift
do {
    let utxos = try await context.utxos(address: address)
} catch CardanoChainError.operationError(let message) {
    print("Ogmios error: \(message ?? "unknown")")
} catch {
    print("Unexpected error: \(error)")
}
```

## Caching Behaviour

| Data | Cache lifetime |
|---|---|
| Epoch / protocol parameters | 60-second TTL |
| Genesis parameters | Permanent |
| UTxOs | Not cached |

## See Also

- ``OgmiosChainContext``
- ``ChainContext``
- ``CardanoChainError``
