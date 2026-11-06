# Using OgmiosChainContext

Connect to a local Cardano node through the Ogmios WebSocket/HTTP bridge.

## Overview

``OgmiosChainContext`` speaks to a local [Ogmios](https://ogmios.dev) server — a lightweight
process that sits in front of `cardano-node` and exposes the Ouroboros mini-protocols over a
WebSocket and HTTP API.

Compared to `CardanoCliChainContext`, Ogmios has no subprocess overhead. Compared to
`NodeSocketChainContext`, it needs the extra Ogmios process, but it is built by default and
works on every platform the package supports, iOS and visionOS included, because it talks to
Ogmios over the network rather than through a local Unix socket. (Both of those contexts need
a package trait and run only on macOS and Linux.)

**Supported networks:** any network the node behind Ogmios runs. The `network` you pass sets
the context's `networkId`; the data comes from whichever node Ogmios is connected to.

## Prerequisites

- A running `cardano-node`.
- [Ogmios](https://ogmios.dev/getting-started/) installed and running, connected to that node.
  The default listen address is `localhost:1337`.

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.16.1")
```

## Creating a Context

### Default Local Instance (`localhost:1337`)

If Ogmios is running with its default settings, you only need to name the network:

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
    secure: true,
    network: .mainnet
)
```

`host` and `port` are used only when both are given; leave either out and the context
connects to `localhost:1337`.

### Injecting an Existing `OgmiosClient`

Share a client across multiple contexts or inject a mock in tests:

```swift
import SwiftOgmios

let client = try await OgmiosClient(host: "localhost", port: 1337)
let context = try await OgmiosChainContext(network: .mainnet, client: client)
```

SwiftOgmios declares its own `Address`, `Transaction` and other Cardano types. In a file that
imports it, write the ledger types with their module, such as `SwiftCardanoCore.Address`, or
the compiler reports them as ambiguous.

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
print("Slot length: \(genesis.slotLength.map { "\($0)" } ?? "n/a")s")
```

### Chain Tip

``OgmiosChainContext/chainTip()`` combines Ogmios's ledger tip (slot and hash) with its
`/health` endpoint, which supplies the block height, epoch, era and sync progress. If the
health check fails, those fields are left `nil`:

```swift
let tip = try await context.chainTip()

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

// From CBOR bytes
let txId = try await context.submitTx(tx: .bytes(cborData))

// From a CBOR hex string
let txId = try await context.submitTx(tx: .string("84a700..."))

print("Submitted: \(txId)")
```

## Evaluating Plutus Scripts

Ogmios evaluates the scripts remotely, against the ledger state of the node it is connected
to. Redeemer keys use this library's tag names (`cert:0`, not Ogmios's `publish:0`):

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
```

## Limitations

- ``ChainContext/transactionCBOR(hash:)`` throws ``CardanoChainError/notImplemented(_:)``:
  Ogmios serves the live ledger state and cannot look transactions up.
- ``ChainContext/drepStakeDistribution()`` and ``ChainContext/spoStakeDistribution()`` throw
  ``CardanoChainError/notImplemented(_:)``.
- ``ChainContext/utxo(input:)`` reads the live UTxO set, so a spent output returns `nil`
  rather than `isSpent: true`. Wrap Ogmios in a ``KupoChainContext`` to learn whether an
  output was spent.

## Error Handling

Context-level failures surface as ``CardanoChainError/operationError(_:)`` or
``CardanoChainError/valueError(_:)``; errors from the underlying SwiftOgmios client (a
connection failure, for example) can reach you unwrapped:

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
| Epoch | ``ChainStateCache/lifetime`` (20 seconds) |
| Protocol parameters | Per epoch |
| Genesis parameters | Permanent |
| UTxOs | Not cached |

## See Also

- ``OgmiosChainContext``
- ``ChainContext``
- ``CardanoChainError``
