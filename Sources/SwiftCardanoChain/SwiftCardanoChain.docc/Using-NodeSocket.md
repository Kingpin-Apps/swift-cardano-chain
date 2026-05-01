# Using NodeSocketChainContext

Connect directly to a local `cardano-node` over its Unix domain socket using the NtC mini-protocols.

## Overview

``NodeSocketChainContext`` communicates with a `cardano-node` using the Node-to-Client (NtC)
Ouroboros mini-protocols over a Unix domain socket — with no intermediary process.

This is the lowest-latency, highest-fidelity local backend available. It requires no additional
services such as `cardano-cli` or Ogmios; the library talks to the node directly via the
[`swift-cardano-network`](https://github.com/Kingpin-Apps/swift-cardano-network) package.

Each query method opens a fresh connection, runs the query, and closes the connection
automatically — even if the query throws. No explicit `close()` call is needed.

**Supported networks:** `.mainnet`, `.preprod`, `.preview`


## Prerequisites

- A running `cardano-node` with its Unix socket accessible.
- macOS 15+ or Linux with Unix socket support.
- The socket path (e.g. `/ipc/node.socket` inside a Docker container, or
  `~/.local/share/Daedalus/mainnet/cardano-node.socket` on desktop).

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.3.0")
```

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

### From a `CardanoConfig`

When you already have a `CardanoConfig` from `swift-cardano-utils`:

```swift
let context = try NodeSocketChainContext(cardanoConfig: cardanoConfig)
```

### With a Custom `CardanoNetworkConfiguration`

Override NtC protocol versions, connection timeouts, and other low-level settings:

```swift
var networkConfig = CardanoNetworkConfiguration.mainnet
networkConfig.connection.connectTimeoutSeconds = 30
networkConfig.connection.socketPath = "/ipc/node.socket"

let context = try NodeSocketChainContext(
    networkConfig: networkConfig,
    network: .mainnet
)
```

You can also pass a base config and a `CardanoConfig` together — the socket path from
`CardanoConfig` always wins:

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

### Protocol and Genesis Parameters

Protocol parameters are cached per epoch; genesis parameters are cached permanently.

```swift
let params  = try await context.protocolParameters()
let genesis = try await context.genesisParameters()

print("Max tx size: \(params.maxTxSize)")
print("Epoch length: \(genesis.epochLength) slots")
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

Phase-2 evaluation runs locally via UPLC (no round-trip to an external service):

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
ever minted a block without needing the cert file on hand):

```swift
let kesInfo = try await context.kesPeriodInfo(pool: pool, opCert: nil)
// kesInfo.onChainOpCertCount — the registered counter, or -1 if no blocks minted
// kesInfo.nextChainOpCertCount — expected next counter value
```

## Limitations

| Feature | Supported |
|---|:---:|
| UTxO queries | ✓ |
| Protocol / genesis parameters | ✓ |
| Tx submission | ✓ |
| Tx evaluation (UPLC) | ✓ |
| Staking queries | ✓ |
| KES period info | ✓ |

## Error Handling

Errors from the NtC layer surface as ``CardanoChainError/operationError(_:)``:

```swift
do {
    let utxos = try await context.utxos(address: address)
} catch CardanoChainError.operationError(let message) {
    print("NtC error: \(message ?? "unknown")")
} catch CardanoChainError.notImplemented(let message) {
    print("Not implemented: \(message ?? "unknown")")
} catch {
    print("Unexpected error: \(error)")
}
```

## Caching Behaviour

| Data | Cache lifetime |
|---|---|
| Epoch | 60-second TTL |
| Protocol parameters | Per epoch |
| Genesis parameters | Permanent |
| UTxOs | Not cached — fetched fresh each call |

## See Also

- ``NodeSocketChainContext``
- ``ChainContext``
- ``CardanoChainError``
