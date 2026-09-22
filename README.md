![GitHub Workflow Status](https://github.com/Kingpin-Apps/swift-cardano-chain/actions/workflows/swift.yml/badge.svg)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKingpin-Apps%2Fswift-cardano-chain%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Kingpin-Apps/swift-cardano-chain)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKingpin-Apps%2Fswift-cardano-chain%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Kingpin-Apps/swift-cardano-chain)

# SwiftCardanoChain

A Swift library for interacting with the Cardano blockchain through a unified `ChainContext` protocol backed by seven pluggable implementations.

## Installation

Add the package in Xcode via **File › Add Package Dependencies** and enter the repository URL:

```
https://github.com/Kingpin-Apps/swift-cardano-chain.git
```

Or add it to your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.5.0")
```

Then import it in your source files:

```swift
import SwiftCardanoChain
```

## Overview

SwiftCardanoChain provides a single `ChainContext` protocol and seven concrete implementations.
Pick the one that matches your environment — the rest of your code stays the same.

| Context | When to use |
|---|---|
| `BlockFrostChainContext` | Cloud API — no local node required |
| `KoiosChainContext` | Decentralised community API — no local node required |
| `CardanoCliChainContext` | Local node via `cardano-cli` |
| `OgmiosChainContext` | Local node via the Ogmios WebSocket bridge |
| `NodeSocketChainContext` | Local node via the NtC Unix socket directly |
| `YaciDevkitChainContext` | Local throw-away devnet run by Yaci DevKit |
| `OfflineTransferChainContext` | Air-gapped / offline transaction signing |

All contexts support:

- Reading blockchain data (UTxOs, protocol parameters, genesis parameters, epoch, era, slot, chain tip)
- Submitting and evaluating transactions (with a backend-agnostic local UPLC evaluator for contexts that don't expose a remote evaluator)
- Querying stake addresses, pools, DReps, governance actions, and committee members
- Querying treasury balance, DRep / SPO stake distributions, full constitutional committee state, and per-proposal vote tallies

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

### Yaci DevKit (Local Devnet)

Reads a [Yaci DevKit](https://github.com/bloxbean/yaci-devkit) devnet through its embedded
Yaci Store API, and genesis through the DevKit admin API. No API key, no node socket.

```swift
// DevKit defaults: store on 8080, admin API on 10000
let context = try YaciDevkitChainContext()

// Custom endpoints
let context = try YaciDevkitChainContext(
    apiURL:   "http://devkit.local:8080",
    adminURL: "http://devkit.local:10000",
    network:  .custom(42)
)
```

Yaci indexes certificates and outputs rather than ledger state, so some queries are
reconstructions and a few are unavailable. See the `Using-YaciDevkit` guide for the details.

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

// Resolve a single UTxO by transaction input
if let (utxo, isSpent) = try await context.utxo(input: input) {
    print(isSpent ? "Spent: \(utxo)" : "Unspent: \(utxo)")
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

### Chain Tip

For a single call that returns slot, block, epoch, era, and sync progress in one shot:

```swift
let tip = try await context.chainTip()

print("Slot          : \(tip.slot)")
print("Block         : \(tip.block ?? 0)")
print("Epoch         : \(tip.epoch)")
print("Era           : \(tip.era ?? "unknown")")
print("Sync progress : \(tip.syncProgress.map { "\($0)%" } ?? "n/a")")
```

`NodeSocket`, `Ogmios`, and `CardanoCLI` populate every field; cloud APIs derive the values
they can and leave the rest `nil`. `OfflineTransfer` derives slot and epoch from cached
genesis parameters and wall-clock time.

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

Contexts with a remote evaluator (BlockFrost, Koios, Ogmios) call out directly:

```swift
let units = try await context.evaluateTx(tx: transaction)

for (redeemer, eu) in units {
    print("\(redeemer): mem=\(eu.mem) steps=\(eu.steps)")
}
```

For contexts without a remote evaluator (CardanoCLI, NodeSocket), the protocol exposes a
local UPLC fallback. Fetch the resolved UTxOs for the transaction's inputs and reference
inputs using whatever transport you have, then hand them off:

```swift
let resolvedInputs = try await fetchResolvedInputs(for: transaction)
let params         = try await context.protocolParameters()

let units = try await context.evaluateTx(
    tx: transaction,
    resolvedInputs: resolvedInputs,
    protocolParameters: params
)
```

`OfflineTransferChainContext` returns execution units from `OfflineTransfer.evaluations`
populated on the online machine — see the offline signing section below.

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

## Treasury

```swift
let balance = try await context.treasury()
print("Treasury: \(balance) lovelace")
```

## Governance Queries (Conway Era)

### DRep, Governance Action, and Committee Member Info

```swift
// DRep information
let drepInfo = try await context.drepInfo(drep: someDRep)

// Governance action details
let govInfo = try await context.govActionInfo(govActionID: someActionId)

// Committee member state, looked up by either cold or hot credential
let cmInfo  = try await context.committeeMemberInfo(cold: coldCred)
let cmInfo2 = try await context.committeeMemberInfo(hot:  hotCred)
```

### Per-Proposal Vote Tally

`govActionVotes` returns a `GovActionVotes` aggregate carrying the proposal procedure
(deposit, return address, anchor) plus the three vote arrays (committee, DRep,
stake-pool) and lifecycle epochs (proposed / expires / ratified / enacted / dropped /
expired). Each empty array means no votes have been recorded for that voter class yet.

```swift
let votes = try await context.govActionVotes(govActionID: actionId)

print("Status   : \(votes.status?.rawValue ?? "active")")
print("Deposit  : \(votes.deposit) lovelace")
print("CC votes : \(votes.committeeVotes.count)")
print("DRep     : \(votes.dRepVotes.count)")
print("Pool     : \(votes.stakePoolVotes.count)")
```

To pull every active proposal in one round-trip (equivalent to
`cardano-cli query gov-state | jq .proposals`):

```swift
let all = try await context.govActionsAll()
let activeOnly = all.filter { $0.status == nil }
```

### Stake Distributions

Effective stake delegated to each DRep and each stake pool for the current epoch —
the inputs ratifier code uses to decide proposal outcomes. These map to
`cardano-cli query drep-stake-distribution --all-dreps` and
`cardano-cli query spo-stake-distribution --all-spos`.

```swift
let drepStake = try await context.drepStakeDistribution()
let spoStake  = try await context.spoStakeDistribution()
```

### Constitutional Committee State

```swift
let state = try await context.committeeState()
print("Quorum threshold: \(state.threshold)")
for member in state.members {
    print("\(member.coldCredential) → \(member.hotCredential.map(String.init(describing:)) ?? "unauthorized")")
}
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

// Optionally cache governance and committee snapshots for offline reads
transfer.treasury               = try await onlineContext.treasury()
transfer.govActionVotesList     = try await onlineContext.govActionsAll()
transfer.drepStakeEntries       = try await onlineContext.drepStakeDistribution()
transfer.spoStakeEntries        = try await onlineContext.spoStakeDistribution()
transfer.committeeStateSnapshot = try await onlineContext.committeeState()

// Optionally pre-compute Plutus execution units so the offline machine can serve them
let units = try await onlineContext.evaluateTx(tx: tx)
transfer.evaluations.append(
    OfflineTransferEvaluation(txCborHex: tx.toCBORData().toHex, executionUnits: units)
)

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

Every read and write through the offline context appends a typed entry to
`OfflineTransfer.history`, giving you a tamper-evident audit log of every action taken
against the file.

## Error Handling

All contexts throw `CardanoChainError`:

```swift
do {
    let utxos = try await context.utxos(address: address)
} catch let error as CardanoChainError {
    switch error {
    case .blockfrostError(let msg):      print("BlockFrost: \(msg ?? "")")
    case .koiosError(let msg):           print("Koios: \(msg ?? "")")
    case .yaciDevkitError(let msg):      print("Yaci DevKit: \(msg ?? "")")
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

| Network | BlockFrost | Koios | CardanoCLI | Ogmios | NodeSocket | YaciDevkit | OfflineTransfer |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| mainnet      | ✓ | ✓ | ✓ | ✓ | ✓ |   | ✓ |
| preprod      | ✓ | ✓ | ✓ | ✓ | ✓ |   | ✓ |
| preview      | ✓ | ✓ | ✓ | ✓ | ✓ |   | ✓ |
| guildnet     |   | ✓ |   |   |   |   |   |
| sanchonet    |   | ✓ |   |   |   |   |   |
| local devnet |   |   | ✓ | ✓ | ✓ | ✓ |   |

## Performance and Caching

| Context | Cached data |
|---|---|
| BlockFrost | Protocol params (per epoch), genesis params (permanent) |
| Koios | Protocol params (per epoch), genesis params (permanent) |
| CardanoCLI | Genesis params (permanent), protocol params (per tip update), UTxOs (per slot+address), datums (LRU) |
| Ogmios | Epoch + protocol params (60s TTL), genesis params (permanent) |
| NodeSocket | Epoch (60s TTL), protocol params (per epoch), genesis params (permanent) |
| YaciDevkit | Epoch (10s TTL), protocol params (per epoch), genesis params and files (permanent) |
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
