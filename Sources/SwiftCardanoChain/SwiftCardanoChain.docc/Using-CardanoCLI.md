# Using CardanoCliChainContext

Interact with a local Cardano node by shelling out to the `cardano-cli` binary.

## Overview

`CardanoCliChainContext` wraps a local `cardano-cli` installation. It is the right choice when
you control the server environment, already run a `cardano-node`, and want full local-node
fidelity without the extra dependency of Ogmios.

> Important: `CardanoCliChainContext` is not built by default. It exists only when you enable
> the package's `CLIBackends` trait, and only on macOS and Linux. That is also why it has no
> symbol page in this documentation, which is built with the default traits.

Chain state is cached internally to avoid redundant CLI invocations; the caching table at the
end of this guide lists what is kept and for how long.

**Supported networks:** any network your node runs. `.mainnet` is passed to `cardano-cli` as
`--mainnet`, every other network as `--testnet-magic` with its magic, so `.custom(magic)`
works for a private devnet.

## Prerequisites

- macOS or Linux.
- A running `cardano-node` with its socket accessible.
- `cardano-cli` installed and on `PATH` (or at a known path).
- The node configuration JSON file (e.g. `config.json` from the IOHK release bundles).

Add the package to your `Package.swift` with the `CLIBackends` trait. Package traits need
`swift-tools-version: 6.1` or later in your manifest:

```swift
// swift-tools-version: 6.1
.package(
    url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git",
    from: "0.16.1",
    traits: ["CLIBackends"]
)
```

`CLIBackends` pulls in [SwiftCardanoUtils](https://github.com/Kingpin-Apps/swift-cardano-utils),
which runs `cardano-cli` as a subprocess. It also enables the `NodeSocket` trait, so
`NodeSocketChainContext` is built too (see <doc:Using-NodeSocket>).

## Creating a Context

### From the Environment

With no paths, the context finds `cardano-cli` on `PATH` and reads the rest from environment
variables: the socket from `CARDANO_SOCKET_PATH`, the node config from `CARDANO_CONFIG`, and the
network from `NETWORK` (`mainnet` when unset).

```swift
import SwiftCardanoChain

let context = try await CardanoCliChainContext(network: .mainnet)
```

In this form `cardano-cli` runs against the network named by `NETWORK`; the `network` argument
only sets the context's `networkId`, so keep the two in step.

### Explicit Paths

```swift
import SwiftCardanoChain
import SystemPackage

let context = try await CardanoCliChainContext(
    nodeConfig: FilePath("/opt/cardano/mainnet/config.json"),
    binary:     FilePath("/usr/local/bin/cardano-cli"),
    socket:     FilePath("/ipc/node.socket"),
    network:    .mainnet
)
```

All three paths must be given for them to be used; with any of them missing, the context falls
back to the environment as above. In this form `era` and `ttlBuffer` (default `3600`, the slots
`CardanoCLI.getCurrentTTL()` adds to the tip) go into the `CardanoConfig` built for the CLI;
the environment form always uses Conway and `3600`, and the forms below take both from the
`CardanoConfig` or `CardanoCLI` you pass.

### With a Smaller UTxO Cache

```swift
let context = try await CardanoCliChainContext(
    nodeConfig: FilePath("/opt/cardano/preview/config.json"),
    binary:     FilePath("/usr/local/bin/cardano-cli"),
    socket:     FilePath("/ipc/node.socket"),
    network:    .preview,
    utxoCacheSize: 5_000   // address/slot entries kept before the cache is cleared
)
```

The initialiser also takes `refetchChainTipInterval` and `datumCacheSize`. Neither affects
caching: `refetchChainTipInterval` is used only by the deprecated `isChainTipUpdated()`, and
`datumCacheSize` is not used.

### From a `CardanoConfig` or a `CardanoCLI`

When you already have a SwiftCardanoUtils `CardanoConfig`, or want to share one `CardanoCLI`
between several contexts or inject one in tests:

```swift
import SwiftCardanoUtils

let context = try await CardanoCliChainContext(cardanoConfig: cardanoConfig)

let cli = try await CardanoCLI(configuration: Config(cardano: cardanoConfig))
let shared = try await CardanoCliChainContext(network: .preview, cli: cli)
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

A UTxO carrying a reference script returns it on `utxo.output.script`, for native
scripts and for PlutusV1, V2 and V3 alike.

> Note: `cardano-cli` only reports **unspent** outputs, so `utxo(input:)` returns `nil` for an
> input that has already been consumed. Validating a transaction that is already on chain
> needs a backend with historical lookup, such as BlockFrost or Koios.

### Protocol and Genesis Parameters

Genesis parameters are loaded once from the node config file and cached for the life of the
context. Protocol parameters are re-fetched when the epoch changes.

```swift
let params  = try await context.protocolParameters()
let genesis = try await context.genesisParameters()

print("Min fee per byte : \(params.txFeePerByte)")
print("Slot length      : \(genesis.slotLength.map { "\($0)" } ?? "n/a")s")
```

### Current Epoch, Era and Slot

```swift
let epoch = try await context.epoch()
let era   = try await context.era()
let slot  = try await context.lastBlockSlot()

print("Epoch \(epoch), \(era?.description ?? "unknown") era, slot \(slot)")
```

``ChainContext/chainTip()`` returns everything `cardano-cli query tip` reports — slot, block,
epoch, era, hash, slot in epoch, slots to the epoch's end and sync progress — in one call.

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

A rejected submission throws ``CardanoChainError/transactionFailed(_:)``.

## Evaluating Plutus Scripts

`cardano-cli` has no evaluation query, so the context evaluates locally: it resolves every
regular and reference input with `cardano-cli query utxo`, reads the protocol parameters and
slot timeline, and runs the scripts through the UPLC CEK machine in-process:

```swift
let units = try await context.evaluateTx(tx: transaction)

for (redeemer, eu) in units {
    print("\(redeemer): mem=\(eu.mem) steps=\(eu.steps)")
}
```

Because inputs are read from the live UTxO set, a transaction whose inputs are already spent
cannot be evaluated.

## Staking Queries

```swift
// Stake address rewards and delegation
let stakeInfo = try await context.stakeAddressInfo(address: stakeAddress)

// All registered stake pools
let pools = try await context.stakePools()

// Pool details; strict: true also downloads and verifies the off-chain metadata
let pool = try await context.stakePoolInfo(poolId: "pool1...", strict: true)

// KES period validity for a pool's operational certificate
let kesInfo = try await context.kesPeriodInfo(pool: nil, opCert: opCert)
```

`kesPeriodInfo` runs `cardano-cli query kes-period-info` and needs the operational
certificate; `pool` is not used. Without an `opCert` it throws
``CardanoChainError/valueError(_:)``.

Governance queries, the treasury, the DRep and SPO stake distributions and the committee state
are all answered from the node's ledger state. ``ChainContext/transactionCBOR(hash:)`` is not
available: a node cannot look up past transactions.

## Error Handling

Failures parsing `cardano-cli` output surface as ``CardanoChainError`` cases, mostly
``CardanoChainError/valueError(_:)`` and ``CardanoChainError/cardanoCLIError(_:)``. A failure
running `cardano-cli` itself (a missing binary, an unreachable socket) comes from
SwiftCardanoUtils and reaches you unwrapped:

```swift
do {
    let utxos = try await context.utxos(address: address)
} catch CardanoChainError.cardanoCLIError(let message) {
    print("cardano-cli error: \(message ?? "unknown")")
} catch CardanoChainError.valueError(let message) {
    print("Unexpected cardano-cli output: \(message ?? "unknown")")
} catch {
    print("Unexpected error: \(error)")
}
```

## Caching Behaviour

| Data | Cache strategy |
|---|---|
| Genesis parameters | Loaded once from the node config file; never re-fetched |
| Protocol parameters | Re-fetched when the epoch changes |
| Epoch, tip slot | Reused for ``ChainStateCache/lifetime`` (20 seconds) |
| UTxOs | Cached per address and tip slot, so a new block invalidates them; at most `utxoCacheSize` entries |
| Chain tip, era | Not cached — `cardano-cli query tip` runs on every call |

## See Also

- ``ChainContext``
- ``CardanoChainError``
- <doc:Using-NodeSocket>
