![GitHub Workflow Status](https://github.com/Kingpin-Apps/swift-cardano-chain/actions/workflows/swift.yml/badge.svg)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKingpin-Apps%2Fswift-cardano-chain%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Kingpin-Apps/swift-cardano-chain)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKingpin-Apps%2Fswift-cardano-chain%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Kingpin-Apps/swift-cardano-chain)

# SwiftCardanoChain

A Swift library for interacting with the Cardano blockchain through a unified `ChainContext` protocol backed by six pluggable implementations.

## Installation

Add the package in Xcode via **File › Add Package Dependencies** and enter the repository URL:

```
https://github.com/Kingpin-Apps/swift-cardano-chain.git
```

Or add it to your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.3.0")
```

Then import it in your source files:

```swift
import SwiftCardanoChain
```

## Overview

SwiftCardanoChain provides a single `ChainContext` protocol and six concrete implementations.
Pick the one that matches your environment — the rest of your code stays the same.

| Context | When to use |
|---|---|
| `BlockFrostChainContext` | Cloud API — no local node required |
| `KoiosChainContext` | Decentralised community API — no local node required |
| `CardanoCliChainContext` | Local node via `cardano-cli` |
| `OgmiosChainContext` | Local node via the Ogmios WebSocket bridge |
| `NodeSocketChainContext` | Local node via the NtC Unix socket directly |
| `OfflineTransferChainContext` | Air-gapped / offline transaction signing |

All contexts support:

- Reading blockchain data (UTxOs, protocol parameters, genesis parameters, epoch, era, slot)
- Submitting and evaluating transactions
- Querying stake addresses, pools, DReps, governance actions, and committee members

## Getting Started

### BlockFrost (Cloud — No Local Node)

```swift
import SwiftCardanoChain

// From an environment variable (recommended)
let context = try await BlockFrostChainContext(
    network: .preview,
    environmentVariable: "BLOCKFROST_API_KEY"
)

// Or with a project ID directly
let context = try await BlockFrostChainContext(
    projectId: "previewXXXXXXXXXXXXXXXXXXXX",
    network: .preview
)
```

### Koios (Community API — No Local Node)

Supports `.mainnet`, `.preprod`, `.preview`, `.guildnet`, and `.sanchonet`.

```swift
// Without an API key (rate-limited)
let context = try await KoiosChainContext(network: .mainnet)

// With an API key
let context = try await KoiosChainContext(
    apiKey: "your-koios-api-key",
    network: .mainnet
)
```

### Cardano CLI (Local Node)

```swift
let context = try await CardanoCliChainContext(
    nodeConfig: FilePath("/opt/cardano/preview/config.json"),
    binary:     FilePath("/usr/local/bin/cardano-cli"),
    socket:     FilePath("/ipc/node.socket"),
    network:    .preview
)
```

### Ogmios (Local Node via WebSocket)

```swift
let context = try await OgmiosChainContext(
    host: "localhost",
    port: 1337,
    network: .mainnet
)
```

### NodeSocket (Local Node — Direct NtC)

```swift
let context = NodeSocketChainContext(
    socketPath: FilePath("/ipc/node.socket"),
    network: .mainnet
)
```

### OfflineTransfer (Air-Gapped Signing)

```swift
// Load a transfer file prepared by an online machine
let context = try OfflineTransferChainContext(
    filePath: FilePath("/path/to/transfer.json"),
    network: .mainnet
)
```

## Reading Blockchain Data

### UTxOs

```swift
let address = try Address(from: .string("addr1..."))
let utxos   = try await context.utxos(address: address)

for utxo in utxos {
    print("\(utxo.input.transactionId.payload.toHex)#\(utxo.input.index)")
    print("  \(utxo.output.amount.coin) lovelace")

    for (policyId, assets) in utxo.output.amount.multiAsset {
        for (assetName, amount) in assets {
            print("  \(policyId.payload.toHex).\(assetName.name.toHex) = \(amount)")
        }
    }
}
```

### Protocol Parameters

```swift
let params = try await context.protocolParameters()

print("Min fee per byte : \(params.txFeePerByte)")
print("Fixed fee        : \(params.txFeeFixed)")
print("Max tx size      : \(params.maxTxSize)")
print("UTxO cost/byte   : \(params.utxoCostPerByte)")
```

### Genesis Parameters

```swift
let genesis = try await context.genesisParameters()

print("Network magic  : \(genesis.networkMagic)")
print("Slot length    : \(genesis.slotLength)s")
print("Epoch length   : \(genesis.epochLength) slots")
print("Security param : \(genesis.securityParam)")
```

### Current Chain State

```swift
let epoch = try await context.epoch()
let slot  = try await context.lastBlockSlot()
let era   = try await context.era()

print("Epoch \(epoch), slot \(slot), era \(era?.description ?? "unknown")")
```

## Writing to the Blockchain

### Submitting Transactions

All contexts accept transactions in three forms:

```swift
// Transaction object
let txId = try await context.submitTx(tx: .transaction(transaction))

// CBOR bytes
let txId = try await context.submitTx(tx: .bytes(cborData))

// CBOR hex string
let txId = try await context.submitTx(tx: .string("84a700..."))

print("Submitted: \(txId)")
```

### Evaluating Plutus Script Execution Units

```swift
let units = try await context.evaluateTx(tx: transaction)

for (redeemer, eu) in units {
    print("\(redeemer): mem=\(eu.mem) steps=\(eu.steps)")
}
```

## Staking Operations

```swift
let stakeAddress = try Address(from: .string("stake1..."))
let stakeInfo    = try await context.stakeAddressInfo(address: stakeAddress)

for info in stakeInfo {
    print("Rewards : \(info.rewardAccountBalance) lovelace")
    print("Pool    : \(info.stakeDelegation ?? "unregistered")")
    print("DRep    : \(info.delegateRepresentative ?? "none")")
}
```

## Governance Queries (Conway Era)

```swift
// DRep information
let drepInfo = try await context.drepInfo(drep: someDRep)

// Governance action details
let govInfo = try await context.govActionInfo(govActionID: someActionId)

// Committee member state
let cmInfo = try await context.committeeMemberInfo(committeeMember: cred)
```

## Offline Signing Workflow

For air-gapped transaction signing, see the `OfflineTransferChainContext`:

```swift
// --- Online machine ---
var transfer = OfflineTransfer()
transfer.addUtxos(try await onlineContext.utxos(address: address), for: address)
transfer.protocol.protocolParameters = try await onlineContext.protocolParameters()
transfer.protocol.genesisParameters  = try await onlineContext.genesisParameters()
transfer.protocol.era                = try await onlineContext.era()
transfer.protocol.network            = .mainnet
try transfer.save(to: FilePath("/path/to/transfer.json"))

// --- Copy file to offline machine ---

// --- Offline machine ---
let offlineContext = try OfflineTransferChainContext(
    filePath: FilePath("/path/to/transfer.json"),
    network: .mainnet
)
let utxos = try await offlineContext.utxos(address: address)  // from the file
// ... build and sign transaction ...
try await offlineContext.submitTx(tx: .string(signedCborHex)) // writes to file

// --- Copy file back and submit online ---
let txId = try await onlineContext.submitTx(tx: .string(signedCborHex))
```

## Error Handling

All contexts throw `CardanoChainError`:

```swift
do {
    let utxos = try await context.utxos(address: address)
} catch let error as CardanoChainError {
    switch error {
    case .blockfrostError(let msg):      print("BlockFrost: \(msg ?? "")")
    case .koiosError(let msg):           print("Koios: \(msg ?? "")")
    case .cardanoCLIError(let msg):      print("CardanoCLI: \(msg ?? "")")
    case .operationError(let msg):       print("Operation: \(msg ?? "")")
    case .transactionFailed(let msg):    print("Tx failed: \(msg ?? "")")
    case .invalidArgument(let msg):      print("Bad argument: \(msg ?? "")")
    case .unsupportedNetwork(let msg):   print("Bad network: \(msg ?? "")")
    case .offlineTransferError(let msg): print("Offline: \(msg ?? "")")
    case .notImplemented(let msg):       print("Not implemented: \(msg ?? "")")
    default:                             print("Other: \(error)")
    }
} catch {
    print("Unexpected: \(error)")
}
```

## Network Support

| Network | BlockFrost | Koios | CardanoCLI | Ogmios | NodeSocket | OfflineTransfer |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| mainnet   | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| preprod   | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| preview   | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| guildnet  |   | ✓ |   |   |   |   |
| sanchonet |   | ✓ |   |   |   |   |

## Performance and Caching

| Context | Cached data |
|---|---|
| BlockFrost | Protocol params (per epoch), genesis params (permanent) |
| Koios | Protocol params (per epoch), genesis params (permanent) |
| CardanoCLI | Genesis params (permanent), protocol params (per tip update), UTxOs (per slot+address), datums (LRU) |
| Ogmios | Epoch + protocol params (60s TTL), genesis params (permanent) |
| NodeSocket | Epoch (60s TTL), protocol params (per epoch), genesis params (permanent) |
| OfflineTransfer | Everything read from file — no caching needed |

Configure CardanoCLI cache sizes at initialisation:

```swift
let context = try await CardanoCliChainContext(
    nodeConfig: FilePath("/opt/cardano/preview/config.json"),
    binary:     FilePath("/usr/local/bin/cardano-cli"),
    socket:     FilePath("/ipc/node.socket"),
    network:    .preview,
    refetchChainTipInterval: 30,   // seconds
    utxoCacheSize: 5_000,
    datumCacheSize: 1_000
)
```

## Documentation

Full DocC documentation with per-backend usage guides is available via Xcode's documentation
browser (**Product › Build Documentation**) or at Swift Package Index.
