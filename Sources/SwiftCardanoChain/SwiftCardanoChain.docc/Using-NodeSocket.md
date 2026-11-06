# Using NodeSocketChainContext

Connect directly to a local `cardano-node` over its Unix domain socket using the NtC mini-protocols.

## Overview

`NodeSocketChainContext` communicates with a `cardano-node` using the Node-to-Client (NtC)
Ouroboros mini-protocols over a Unix domain socket — with no intermediary process.

It requires no additional services such as `cardano-cli` or Ogmios; the library talks to the
node directly via the
[`swift-cardano-network`](https://github.com/Kingpin-Apps/swift-cardano-network) package.

Each query method opens a fresh connection, runs the query, and closes the connection
automatically — even if the query throws. No explicit `close()` call is needed.

> Important: `NodeSocketChainContext` is not built by default. It exists only when you enable
> the package's `NodeSocket` trait (or `CLIBackends`, which turns it on), and only on macOS
> and Linux. That is also why it has no symbol page in this documentation, which is built
> with the default traits.

**Supported networks:** `.mainnet`, `.preprod` and `.preview` through
`init(socketPath:network:)`. For any other network — a local devnet, SanchoNet — pass a
`CardanoNetworkConfiguration` with that network's magic (see below).

## Prerequisites

- macOS or Linux.
- A running `cardano-node` with its Unix socket accessible.
- The socket path (e.g. `/ipc/node.socket` inside a Docker container, or
  `~/.local/share/Daedalus/mainnet/cardano-node.socket` on desktop).

Add the package to your `Package.swift` with the `NodeSocket` trait. Package traits need
`swift-tools-version: 6.1` or later in your manifest:

```swift
// swift-tools-version: 6.1
.package(
    url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git",
    from: "0.16.1",
    traits: ["NodeSocket"]
)
```

`NodeSocket` builds the backend on macOS and Linux and leaves it out on iOS, tvOS, watchOS and
visionOS, so an app for several platforms can enable it; wrap your uses in
`#if os(macOS) || os(Linux)`. It does not bring in `SwiftCardanoUtils`. The `CLIBackends` trait
enables it too, and adds `init(cardanoConfig:networkConfig:)`, which reads the socket and
network from a `CardanoConfig`.

## Creating a Context

### From a Socket Path (Simplest)

```swift
import SwiftCardanoChain
import SystemPackage

let context = NodeSocketChainContext(
    socketPath: FilePath("/ipc/node.socket"),
    network: .mainnet
)
```

This uses the built-in handshake preset for `.mainnet`, `.preprod` or `.preview`. Any other
network gets a default configuration that handshakes with mainnet's network magic, which the
node will refuse; use a custom configuration for those.

### With a Custom `CardanoNetworkConfiguration`

Set the network magic, connection timeout, NtC protocol versions and other low-level settings:

```swift
import SwiftCardanoNetwork

var networkConfig = CardanoNetworkConfiguration()
networkConfig.connection.socketPath = "/ipc/node.socket"
networkConfig.connection.networkMagic = 42          // your devnet's magic
networkConfig.connection.connectTimeoutSeconds = 30

let context = try NodeSocketChainContext(
    networkConfig: networkConfig,
    network: .custom(42)
)
```

`CardanoNetworkConfiguration.mainnet`, `.preprod` and `.preview` are ready-made starting
points. The initialiser throws ``CardanoChainError/valueError(_:)`` when
`connection.socketPath` is not set.

### From a `CardanoConfig` (`CLIBackends` Only)

When you already have a `CardanoConfig` from `swift-cardano-utils`:

```swift
let context = try NodeSocketChainContext(cardanoConfig: cardanoConfig)
```

You can also pass a base network configuration — the socket path from `CardanoConfig` always
wins:

```swift
let context = try NodeSocketChainContext(
    cardanoConfig: cardanoConfig,
    networkConfig: networkConfig   // optional overrides
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

### Specific UTxO by Transaction Input

```swift
let input = TransactionInput(transactionId: txId, index: 0)
if let (utxo, isSpent) = try await context.utxo(input: input) {
    print("Found: \(utxo.output.amount.coin) lovelace, spent: \(isSpent)")
}
```

The node only answers from the live UTxO set, so `isSpent` is always `false` and a spent
output returns `nil`.

### Protocol and Genesis Parameters

Protocol parameters are cached per epoch; genesis parameters are cached permanently.

```swift
let params  = try await context.protocolParameters()
let genesis = try await context.genesisParameters()

print("Max tx size: \(params.maxTxSize)")
print("Epoch length: \(genesis.epochLength.map(String.init) ?? "n/a") slots")
```

### Current Epoch and Slot

```swift
let epoch = try await context.epoch()
let slot  = try await context.lastBlockSlot()
print("Epoch \(epoch), slot \(slot)")
```

``ChainContext/chainTip()`` adds the block height, hash, era, position in the epoch and sync
progress, using one connection.

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

Phase-2 evaluation runs locally via UPLC (no round-trip to an external service). The context
resolves every regular and reference input and reads the protocol parameters from the node,
then runs the scripts in-process:

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

`stakeAddressInfo(address:)` reports the reward balance and pool delegation; it does not
report the vote delegation, which is always `nil`.

## KES Period Info

Query KES period information by reading the consensus protocol state directly from the node.
Provide the `opCert` loaded from disk to include on-disk counter and KES start values.

```swift
let pool   = try PoolOperator(from: "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy")
let opCert = try OperationalCertificate.load(from: "/keys/node.cert")

let kesInfo = try await context.kesPeriodInfo(pool: pool, opCert: opCert)

if let onChain = kesInfo.onChainOpCertCount,
   let onDisk  = kesInfo.onDiskOpCertCount {
    print("On-chain counter : \(onChain)")
    print("On-disk counter  : \(onDisk)")
    if onChain == -1 {
        print("Pool has never minted a block")
    } else if onDisk >= kesInfo.nextChainOpCertCount ?? 0 {
        print("Certificate is ready for rotation")
    }
}
```

Pass `opCert: nil` to retrieve only the on-chain counter (e.g. to check whether a pool has
ever minted a block without needing the cert file on hand). `pool` is required and throws
``CardanoChainError/invalidArgument(_:)`` when `nil`:

```swift
let kesInfo = try await context.kesPeriodInfo(pool: pool, opCert: nil)
// kesInfo.onChainOpCertCount — the registered counter, or -1 if no blocks minted
// kesInfo.nextChainOpCertCount — expected next counter value
```

## Limitations

| Feature | Supported |
|---|:---:|
| UTxO queries (live set only) | ✓ |
| Protocol / genesis parameters | ✓ |
| Tx submission | ✓ |
| Tx evaluation (local UPLC) | ✓ |
| Staking queries | ✓ |
| KES period info | ✓ |
| Treasury, governance, DRep / SPO stake distributions, committee state | ✓ |
| Transaction lookup (`transactionCBOR(hash:)`) | — throws ``CardanoChainError/notImplemented(_:)`` |

## Error Handling

Errors from the context surface as ``CardanoChainError`` cases — for example
``CardanoChainError/transactionFailed(_:)`` for a rejected submission or
``CardanoChainError/valueError(_:)`` for a pool or proposal that is not found. Errors from the
NtC layer itself (a missing socket, a refused handshake) come from swift-cardano-network and
can reach you unwrapped:

```swift
do {
    let utxos = try await context.utxos(address: address)
} catch CardanoChainError.operationError(let message) {
    print("Node error: \(message ?? "unknown")")
} catch CardanoChainError.notImplemented(let message) {
    print("Not implemented: \(message ?? "unknown")")
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
| UTxOs | Not cached — fetched fresh each call |

## See Also

- ``ChainContext``
- ``CardanoChainError``
- <doc:Using-CardanoCLI>
