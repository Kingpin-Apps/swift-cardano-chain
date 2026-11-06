![GitHub Workflow Status](https://github.com/Kingpin-Apps/swift-cardano-chain/actions/workflows/swift.yml/badge.svg)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKingpin-Apps%2Fswift-cardano-chain%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Kingpin-Apps/swift-cardano-chain)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKingpin-Apps%2Fswift-cardano-chain%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Kingpin-Apps/swift-cardano-chain)

# SwiftCardanoChain

A Swift library for interacting with the Cardano blockchain through a unified `ChainContext` protocol backed by nine pluggable implementations.

## Installation

Add the package in Xcode via **File › Add Package Dependencies** and enter the repository URL:

```
https://github.com/Kingpin-Apps/swift-cardano-chain.git
```

Or add it to your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.16.1")
```

Then import it in your source files:

```swift
import SwiftCardanoChain
```

### Optional Traits: `CLIBackends` and `NodeSocket`

Two contexts are **not built by default**. They exist only when you enable a package trait on
the dependency, and only on macOS and Linux:

| Trait | Builds | Notes |
|---|---|---|
| `CLIBackends` | `CardanoCliChainContext` and `NodeSocketChainContext` | Pulls in [SwiftCardanoUtils](https://github.com/Kingpin-Apps/swift-cardano-utils), which runs `cardano-cli` as a subprocess |
| `NodeSocket` | `NodeSocketChainContext` only | No SwiftCardanoUtils. Builds nothing on iOS, tvOS, watchOS and visionOS, so a multi-platform app can turn it on |

Package traits need `swift-tools-version: 6.1` or later in your manifest:

```swift
// swift-tools-version: 6.1
.package(
    url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git",
    from: "0.16.1",
    traits: ["CLIBackends"]   // or ["NodeSocket"]
)
```

## Overview

SwiftCardanoChain provides a single `ChainContext` protocol and nine concrete implementations.
Pick the one that matches your environment — the rest of your code stays the same.

| Context | When to use |
|---|---|
| `BlockFrostChainContext` | Cloud API — no local node required |
| `KoiosChainContext` | Decentralised community API — no local node required |
| `OgmiosChainContext` | A node through the Ogmios WebSocket/HTTP bridge |
| `KupoChainContext` | Kupo chain index, alone or wrapping another context |
| `UTxORPCChainContext` | UTxO RPC (gRPC): cardano-node 11.x's built-in server, Dolos, Demeter, or cardano-node-api |
| `YaciDevkitChainContext` | Local throw-away devnet run by Yaci DevKit |
| `OfflineTransferChainContext` | Air-gapped / offline transaction signing |
| `CardanoCliChainContext` | Local node via `cardano-cli` — `CLIBackends` trait, macOS/Linux only |
| `NodeSocketChainContext` | Local node via the NtC Unix socket directly — `NodeSocket` trait, macOS/Linux only |

Every context conforms to the same protocol, which covers:

- Reading blockchain data (UTxOs, protocol parameters, genesis parameters, epoch, era, slot, chain tip)
- Submitting and evaluating transactions (with a backend-agnostic local UPLC evaluator for contexts that don't expose a remote evaluator)
- Querying stake addresses, pools, DReps, governance actions, and committee members
- Querying treasury balance, DRep / SPO stake distributions, full constitutional committee state, and per-proposal vote tallies

Not every backend can answer every query: a call a backend has no source for throws
`CardanoChainError.notImplemented`. The per-backend DocC guides list what each can and cannot do.

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

Supports `.mainnet`, `.preprod` and `.preview`.

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

### Ogmios (Node via WebSocket)

```swift
let context = try await OgmiosChainContext(
    host: "localhost",
    port: 1337,
    network: .mainnet
)
```

Ogmios is built by default and works on every supported platform, iOS and visionOS included.

### Kupo (Chain Index, Optionally Wrapping Ogmios)

`KupoChainContext` reads outputs from a [Kupo](https://cardanosolutions.github.io/kupo)
index through [swift-kupo](https://github.com/Kingpin-Apps/swift-kupo): every unspent output
at an address, with datums and reference scripts, and whether an output was spent.

On its own it answers only what Kupo indexes — `utxos(address:)`, `utxo(input:)`, and
`datum(hash:)` / `datumCBOR(hash:)` / `script(hash:)`. Every other call throws
`CardanoChainError.notImplemented`:

```swift
let kupo = try KupoChainContext(
    url: URL(string: "http://localhost:1442")!,
    network: .preview
)
let utxos = try await kupo.utxos(address: address)
```

Wrap another context, usually Ogmios on the same node, and everything Kupo does not index —
protocol parameters, the tip, submitting and evaluating transactions, stake and governance
queries — goes to it. `utxo(input:)` also falls back to it when Kupo has no record of the output:

```swift
let ogmios = try await OgmiosChainContext(host: "localhost", port: 1337, network: .preview)
let context = try KupoChainContext(
    url: URL(string: "http://localhost:1442")!,
    network: .preview,
    wrapping: ogmios
)
```

To configure the HTTP client yourself, pass a swift-kupo `Kupo` or `Client` instead of a URL:
`KupoChainContext(kupo: try Kupo(basePath: "http://localhost:1442"), network: .preview, wrapping: ogmios)`.

### UTxO RPC (cardano-node 11.x, Dolos, Demeter)

`UTxORPCChainContext` talks [UTxO RPC](https://utxorpc.org) v1beta over gRPC through
[swift-utxorpc](https://github.com/Kingpin-Apps/swift-utxorpc). The `UTxORPCEndpoint` type
comes from swift-utxorpc's `UTxORPCClient` module, so add that product to your target and
`import UTxORPCClient`. cardano-node 11.x serves UTxO RPC itself when started with
`"EnableRpc": true`, on a `rpc.sock` next to `node.socket`:

```swift
import UTxORPCClient

let context = try UTxORPCChainContext(
    endpoint: .unixSocket("/opt/cardano/mainnet/socket/rpc.sock"),
    network: .mainnet
)
```

Hosted servers take a URL and headers, such as Demeter's API key:

```swift
let context = try UTxORPCChainContext(
    endpoint: try UTxORPCEndpoint(
        url: URL(string: "https://preview.utxorpc-v0.demeter.run")!,
        headers: ["dmtr-api-key": apiKey]
    ),
    network: .preview
)
```

It answers the tip, epoch, era, protocol and genesis parameters, UTxOs by address or
reference, and submits and evaluates transactions on the server (falling back to local
evaluation when the server cannot evaluate an unsigned transaction). Without a wrapped
context, on a server with `ReadState`, `stakePools()` comes from its stake pool distribution,
which leaves out registered pools that have no stake. UTxO RPC v1beta has no other stake
queries and no governance queries, and cardano-node cannot look a transaction up by hash.
On its own the context throws `notImplemented` for those; pass `wrapping:` another context
(Blockfrost, Ogmios, Kupo) and they go to it instead. A node's `SearchUtxos` scans the whole
UTxO set, so `utxos(address:)` takes seconds on mainnet, as it does over the node socket.

cardano-node-api speaks only the older v1alpha API. Give the endpoint `apiVersion: .v1alpha`
and a wrapped context: it has no `ReadGenesis`, `EvalTx` or `ReadTx`, and its `ReadParams`
leaves out the Conway governance parameters (and, in its last release, shifts the cost models by
one), so the protocol and genesis parameters come from the wrapped context. UTxOs, the tip
and submission go to cardano-node-api.

```swift
let context = try UTxORPCChainContext(
    endpoint: try UTxORPCEndpoint(url: URL(string: "http://127.0.0.1:9090")!, apiVersion: .v1alpha),
    network: .mainnet,
    wrapping: ogmios
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
reconstructions from the certificate log and genesis rather than state reads. `treasury()` and
`spoStakeDistribution()` have no Yaci equivalent and throw `notImplemented`, governance
outcome epochs are always `nil`, and `evaluateTx` needs DevKit started with
`ogmios_enabled=true`. See the `Using-YaciDevkit` guide for the full picture.

### OfflineTransfer (Air-Gapped Signing)

```swift
import SystemPackage

// Load a transfer file prepared by an online machine
let context = try OfflineTransferChainContext(
    filePath: FilePath("/path/to/transfer.json"),
    network: .mainnet
)
```

### Cardano CLI (Local Node — `CLIBackends` Trait, macOS/Linux)

Needs the `CLIBackends` trait (see [Installation](#optional-traits-clibackends-and-nodesocket)).

```swift
import SystemPackage

let context = try await CardanoCliChainContext(
    nodeConfig: FilePath("/opt/cardano/preview/config.json"),
    binary:     FilePath("/usr/local/bin/cardano-cli"),
    socket:     FilePath("/ipc/node.socket"),
    network:    .preview
)
```

With no paths, `CardanoCliChainContext(network:)` finds `cardano-cli` on `PATH` and reads the
socket, node config and network from the `CARDANO_SOCKET_PATH`, `CARDANO_CONFIG` and
`NETWORK` environment variables.

### NodeSocket (Local Node — Direct NtC, `NodeSocket` Trait, macOS/Linux)

Needs the `NodeSocket` or `CLIBackends` trait.

```swift
import SystemPackage

let context = NodeSocketChainContext(
    socketPath: FilePath("/ipc/node.socket"),
    network: .mainnet
)
```

`init(socketPath:network:)` has handshake presets for mainnet, preprod and preview. For any
other network, set `connection.networkMagic` on a `CardanoNetworkConfiguration` and use
`init(networkConfig:network:)`.

## Reading Blockchain Data

### UTxOs

```swift
let address = try Address(from: .string("addr1..."))
let utxos   = try await context.utxos(address: address)

for utxo in utxos {
    print("\(utxo.input.transactionId.payload.toHex)#\(utxo.input.index)")
    print("  \(utxo.output.amount.coin) lovelace")

    for (policyId, assets) in utxo.output.amount.multiAsset.data {
        for (assetName, amount) in assets.data {
            print("  \(policyId.payload.toHex).\(assetName.payload.toHex) = \(amount)")
        }
    }
}

// Resolve a single UTxO by transaction input
if let (utxo, isSpent) = try await context.utxo(input: input) {
    print(isSpent ? "Spent: \(utxo)" : "Unspent: \(utxo)")
}
```

Backends that only see the live UTxO set (CardanoCLI, NodeSocket, Ogmios, and UTxO RPC
without a wrapped context) return `nil` for a spent output rather than `isSpent: true`.

### Protocol Parameters

```swift
let params = try await context.protocolParameters()

print("Min fee per byte : \(params.txFeePerByte)")
print("Fixed fee        : \(params.txFeeFixed)")
print("Max tx size      : \(params.maxTxSize)")
print("UTxO cost/byte   : \(params.utxoCostPerByte)")
```

### Genesis Parameters

Every field of `GenesisParameters` is optional:

```swift
let genesis = try await context.genesisParameters()

print("Network magic  : \(genesis.networkMagic.map(String.init) ?? "n/a")")
print("Slot length    : \(genesis.slotLength.map { "\($0) s" } ?? "n/a")")
print("Epoch length   : \(genesis.epochLength.map { "\($0) slots" } ?? "n/a")")
print("Security param : \(genesis.securityParam.map(String.init) ?? "n/a")")
```

### Transactions by Hash

BlockFrost, Koios and UTxO RPC servers that serve `ReadTx` (Dolos) return a transaction already
on chain, exactly as it was submitted; Kupo forwards to its wrapped context. Backends that only
see the live ledger (a node, Ogmios, Yaci Store) throw `notImplemented`.
`transaction(hash:)` decodes it and checks that its id is the one asked for:

```swift
let cbor = try await context.transactionCBOR(hash: txId)
let tx   = try await context.transaction(hash: txId)
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

print("Slot          : \(tip.slot.map(String.init) ?? "n/a")")
print("Block         : \(tip.block.map(String.init) ?? "n/a")")
print("Epoch         : \(tip.epoch.map(String.init) ?? "n/a")")
print("Era           : \(tip.era ?? "unknown")")
print("Sync progress : \(tip.syncProgress.map { "\($0)%" } ?? "n/a")")
```

Every field of `ChainTip` is optional. NodeSocket and CardanoCLI fill them all; Ogmios fills
the block height, epoch, era and sync progress only when its `/health` check answers; cloud
APIs and some UTxO RPC servers leave out what they cannot report. `OfflineTransfer` derives
slot and epoch from cached genesis parameters and wall-clock time.

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

`OfflineTransferChainContext` does not broadcast: it saves the transaction into the transfer
file.

### Evaluating Plutus Script Execution Units

`evaluateTx(tx:)` returns the execution units of each redeemer, keyed `<tag>:<index>`, on every
context:

```swift
let units = try await context.evaluateTx(tx: transaction)

for (redeemer, eu) in units {
    print("\(redeemer): mem=\(eu.mem) steps=\(eu.steps)")
}
```

| Context | How scripts are evaluated |
|---|---|
| BlockFrost, Koios, Ogmios | Remotely, by the service |
| YaciDevkit | Remotely, through Yaci Store; needs DevKit started with Ogmios enabled |
| UTxO RPC | Remote `EvalTx`, falling back to local evaluation when the server cannot evaluate |
| CardanoCLI, NodeSocket | Locally: inputs are resolved from the node, then run through the UPLC CEK machine in-process |
| Kupo | Forwarded to the wrapped context |
| OfflineTransfer | From `OfflineTransfer.evaluations` saved on the online machine |

The local evaluator is also available directly, when you already hold the UTxOs for every
regular and reference input or want to evaluate without asking a remote service:

```swift
var resolvedInputs: [UTxO] = []
let inputs = transaction.transactionBody.inputs.asArray
    + (transaction.transactionBody.referenceInputs?.asList ?? [])
for input in inputs {
    if let (utxo, _) = try await context.utxo(input: input) {
        resolvedInputs.append(utxo)
    }
}

let units = try await context.evaluateTx(
    tx: transaction,
    resolvedInputs: resolvedInputs,
    protocolParameters: try await context.protocolParameters(),
    slotTimeline: try await context.slotTimeline()
)
```

A transaction with a validity interval needs the slot timeline: its scripts see the
interval as POSIX time. `slotTimeline()` reads it from the chain's genesis.

## Staking Operations

```swift
let stakeAddress = try Address(from: .string("stake1..."))
let stakeInfo    = try await context.stakeAddressInfo(address: stakeAddress)

for info in stakeInfo {
    print("Rewards : \(info.rewardAccountBalance) lovelace")
    print("Pool    : \(info.stakeDelegation.map { "\($0)" } ?? "not delegated")")
    print("DRep    : \(info.voteDelegation.map { "\($0)" } ?? "none")")
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

print("Status   : \(votes.status.map { "\($0)" } ?? "not concluded")")
print("Deposit  : \(votes.deposit) lovelace")
print("CC votes : \(votes.committeeVotes.count)")
print("DRep     : \(votes.dRepVotes.count)")
print("Pool     : \(votes.stakePoolVotes.count)")
```

### Listing Proposals

`openGovActions()` lists the actions that can still be voted on, without their votes.
`govActionsAll()` returns a `GovActionVotes` for every proposal the backend lists:

```swift
let open = try await context.openGovActions()
let all  = try await context.govActionsAll()
let notConcluded = all.filter { $0.status == nil }
```

Contexts that read the node's ledger state (CardanoCLI, NodeSocket, Ogmios) answer
`govActionsAll()` with the proposals in the current governance state in one query —
equivalent to `cardano-cli query gov-state | jq .proposals`. BlockFrost and Koios return every
proposal they have indexed, concluded ones included, and make further requests per proposal
to fetch the votes.

### Stake Distributions

Effective stake delegated to each DRep and each stake pool for the current epoch —
the inputs ratifier code uses to decide proposal outcomes. These map to
`cardano-cli query drep-stake-distribution --all-dreps` and
`cardano-cli query spo-stake-distribution --all-spos`.

```swift
let drepStake = try await context.drepStakeDistribution()
let spoStake  = try await context.spoStakeDistribution()
```

Only CardanoCLI and NodeSocket answer both. YaciDevkit answers the DRep distribution only;
BlockFrost, Koios and Ogmios throw `notImplemented` for both; Kupo and UTxO RPC pass them to
the wrapped context; OfflineTransfer serves the saved entries.

### Constitutional Committee State

```swift
let state = try await context.committeeState()
if let quorum = state.threshold {  // nil when there is no committee
    print("Quorum threshold: \(quorum.numerator)/\(quorum.denominator)")
}
for member in state.members {
    print("\(member.coldCredential) → \(member.hotCredential.map(String.init(describing:)) ?? "unauthorized")")
}
```

## Offline Signing Workflow

For air-gapped transaction signing, use `OfflineTransferChainContext`:

```swift
import SystemPackage

// --- Online machine ---
var transfer = OfflineTransfer()
transfer.addresses.append(
    try AddressInfo(address: address, utxos: try await onlineContext.utxos(address: address))
)
transfer.protocol.protocolParameters = try await onlineContext.protocolParameters()
transfer.protocol.genesisParameters  = try await onlineContext.genesisParameters()
transfer.protocol.era                = try await onlineContext.era()
transfer.protocol.network            = .mainnet

// Optionally cache governance and committee snapshots for offline reads
// (each call needs an online context that answers it)
transfer.treasury               = try await onlineContext.treasury()
transfer.govActionVotesList     = try await onlineContext.govActionsAll()
transfer.drepStakeEntries       = try await onlineContext.drepStakeDistribution()
transfer.spoStakeEntries        = try await onlineContext.spoStakeDistribution()
transfer.committeeStateSnapshot = try await onlineContext.committeeState()

// Optionally pre-compute Plutus execution units so the offline machine can serve them.
// They are matched on the exact transaction CBOR.
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
_ = try await offlineContext.submitTx(tx: .string(signedCborHex)) // writes to file

// --- Copy file back and submit online ---
let returned = try OfflineTransfer.load(from: FilePath("/path/to/transfer.json"))
if let cborHex = returned.transactions.last?.txJson?.cborHex {
    let txId = try await onlineContext.submitTx(tx: .string(cborHex))
}
```

`OfflineTransfer.history` is a list of dated `HistoryType` entries describing what was done
with the file. The offline context adds a `saveTransaction` entry each time `submitTx` saves a
transaction; reads add nothing. It is a plain JSON array, not protected against editing.

If a value was not saved into the file, single-item reads (parameters, a pool, a DRep, the
treasury, an evaluation…) throw `CardanoChainError.offlineTransferError`, while list reads
return an empty list. `transactionCBOR(hash:)` always throws `notImplemented`.

## Error Handling

Contexts throw `CardanoChainError` for the failures they detect. Errors from an underlying
client library (a network failure, for example) can also reach you unwrapped, so keep a
final `catch`:

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

| Network | BlockFrost | Koios | Ogmios | Kupo | UTxO RPC | CardanoCLI | NodeSocket | YaciDevkit | OfflineTransfer |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| mainnet      | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |   | ✓ |
| preprod      | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |   | ✓ |
| preview      | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |   | ✓ |
| guildnet     |   | ✓ | ✓ | ✓ | ✓ | ✓ | ✓¹ |   | ✓ |
| sanchonet    |   | ✓ | ✓ | ✓ | ✓ | ✓ | ✓¹ |   | ✓ |
| local devnet |   |   | ✓ | ✓ | ✓ | ✓ | ✓¹ | ✓ | ✓ |

- BlockFrost and Koios throw `CardanoChainError.unsupportedNetwork` from their initialisers for
  any other network.
- Ogmios, Kupo, UTxO RPC and CardanoCLI work with whatever network the server or node behind
  them follows; CardanoCLI passes `--testnet-magic` for every network except mainnet.
- ¹ NodeSocket needs `init(networkConfig:network:)` with `connection.networkMagic` set for
  networks other than mainnet, preprod and preview.
- YaciDevkit talks to a DevKit devnet (magic `42` by default).
- OfflineTransfer serves whatever network the transfer file was prepared on.

## Performance and Caching

| Context | Cached data |
|---|---|
| BlockFrost | Epoch (until the epoch's end time), protocol params (per epoch), genesis params (permanent) |
| Koios | Epoch (until the epoch's end time), protocol params (per epoch), genesis params (permanent) |
| CardanoCLI | Tip slot and epoch (20s), protocol params (per epoch), genesis params (permanent), UTxOs (per tip slot + address) |
| Ogmios | Epoch (20s), protocol params (per epoch), genesis params (permanent) |
| NodeSocket | Epoch (20s), protocol params (per epoch), genesis params (permanent) |
| Kupo | Nothing; forwarded calls are cached by the wrapped context |
| UTxO RPC | Genesis params (permanent); one connection kept open for all calls when created from an endpoint |
| YaciDevkit | Epoch (10s), protocol params (per epoch), genesis params and files (permanent) |
| OfflineTransfer | Everything read from file — no caching needed |

The 20-second lifetime is `ChainStateCache.lifetime`. CardanoCLI's UTxO cache size is set at
initialisation; its `refetchChainTipInterval` and `datumCacheSize` parameters do not affect
caching:

```swift
let context = try await CardanoCliChainContext(
    nodeConfig: FilePath("/opt/cardano/preview/config.json"),
    binary:     FilePath("/usr/local/bin/cardano-cli"),
    socket:     FilePath("/ipc/node.socket"),
    network:    .preview,
    utxoCacheSize: 5_000   // address/slot entries kept before the cache is cleared
)
```

## Documentation

Full DocC documentation with per-backend usage guides is available via Xcode's documentation
browser (**Product › Build Documentation**) or at
[Swift Package Index](https://swiftpackageindex.com/Kingpin-Apps/swift-cardano-chain/documentation/swiftcardanochain).
The SPI documentation is built with the default traits, so `CardanoCliChainContext` and
`NodeSocketChainContext` have guides there but no symbol pages.
