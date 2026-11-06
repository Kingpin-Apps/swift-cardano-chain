# ``SwiftCardanoChain``

Interact with the Cardano blockchain through a unified Swift interface backed by nine pluggable chain context implementations.

## Overview

SwiftCardanoChain provides a single ``ChainContext`` protocol and nine concrete implementations, each suited to a different deployment scenario:

| Context | When to use |
|---|---|
| ``BlockFrostChainContext`` | Cloud API — no local node required |
| ``KoiosChainContext`` | Decentralised community API — no local node required |
| ``OgmiosChainContext`` | A node through the Ogmios WebSocket/HTTP bridge |
| ``KupoChainContext`` | Kupo chain index, alone or wrapping another context |
| ``UTxORPCChainContext`` | UTxO RPC (gRPC): cardano-node 11.x's built-in server, Dolos, Demeter, or cardano-node-api |
| ``YaciDevkitChainContext`` | Local throw-away devnet run by Yaci DevKit |
| ``OfflineTransferChainContext`` | Air-gapped / offline transaction signing |
| `CardanoCliChainContext` | Local node via `cardano-cli` — needs the `CLIBackends` trait, macOS/Linux only |
| `NodeSocketChainContext` | Local node via the NtC Unix socket directly — needs the `NodeSocket` trait, macOS/Linux only |

The last two are not built by default, so they have no symbol pages in this documentation.
They exist only when you enable a package trait on your dependency, and only on macOS and
Linux:

- `CLIBackends` builds `CardanoCliChainContext` and `NodeSocketChainContext`. It pulls in
  SwiftCardanoUtils, which runs `cardano-cli` as a subprocess.
- `NodeSocket` builds `NodeSocketChainContext` alone, without SwiftCardanoUtils. On iOS, tvOS,
  watchOS and visionOS it builds nothing, so a multi-platform app can turn it on.

```swift
// swift-tools-version: 6.1
.package(
    url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git",
    from: "0.16.1",
    traits: ["CLIBackends"]   // or ["NodeSocket"]
)
```

See <doc:Using-CardanoCLI> and <doc:Using-NodeSocket> for details.

Every context conforms to the same protocol, which covers:

- Reading chain state (UTxOs, protocol parameters, genesis parameters, epoch, era, slot, chain tip)
- Submitting and evaluating transactions — including a backend-agnostic local UPLC evaluator for contexts without a remote evaluator
- Querying stake addresses, pools, DReps, governance actions, and committee members
- Querying treasury balance, DRep / SPO stake distributions, full constitutional committee state, and per-proposal vote tallies

Not every backend can answer every query. A call a backend has no source for throws
``CardanoChainError/notImplemented(_:)``; each guide lists what its context can and cannot do.

### Quick Start

Pick the context that matches your environment and swap it for any other without changing the rest of your code.

```swift
import SwiftCardanoChain

// Cloud — simplest setup
let context = try await BlockFrostChainContext(
    network: .preview,
    environmentVariable: "BLOCKFROST_API_KEY"
)

// …or a node behind Ogmios
let context = try await OgmiosChainContext(
    host: "localhost",
    port: 1337,
    network: .preview
)

// All contexts share the same API
let utxos  = try await context.utxos(address: address)
let params = try await context.protocolParameters()
let epoch  = try await context.epoch()
```

With the `CLIBackends` trait enabled, on macOS or Linux, a local node through `cardano-cli`
works the same way:

```swift
import SwiftCardanoChain
import SystemPackage

let context = try await CardanoCliChainContext(
    nodeConfig: FilePath("/opt/cardano/preview/config.json"),
    binary:     FilePath("/usr/local/bin/cardano-cli"),
    socket:     FilePath("/ipc/node.socket"),
    network:    .preview
)
```

## Reading Blockchain Data

### UTxOs

```swift
let address = try Address(from: .string("addr1..."))
let utxos   = try await context.utxos(address: address)

for utxo in utxos {
    print("TxHash: \(utxo.input.transactionId.payload.toHex)#\(utxo.input.index)")
    print("Lovelace: \(utxo.output.amount.coin)")

    for (policyId, assets) in utxo.output.amount.multiAsset.data {
        for (assetName, amount) in assets.data {
            print("  \(policyId.payload.toHex).\(assetName.payload.toHex) = \(amount)")
        }
    }
}
```

To look up a single output, and whether it has been spent, use
``ChainContext/utxo(input:)``. Backends that only see the live UTxO set return `nil` for a
spent output rather than `isSpent: true`.

### Protocol Parameters

```swift
let params = try await context.protocolParameters()

print("Min fee per byte : \(params.txFeePerByte)")
print("Fixed fee        : \(params.txFeeFixed)")
print("Max tx size      : \(params.maxTxSize)")
print("UTxO cost/byte   : \(params.utxoCostPerByte)")
```

### Genesis Parameters

Every field of `GenesisParameters` is optional, since not every backend reports all of them:

```swift
let genesis = try await context.genesisParameters()

print("Network magic  : \(genesis.networkMagic.map(String.init) ?? "n/a")")
print("Slot length    : \(genesis.slotLength.map { "\($0) s" } ?? "n/a")")
print("Epoch length   : \(genesis.epochLength.map { "\($0) slots" } ?? "n/a")")
print("Security param : \(genesis.securityParam.map(String.init) ?? "n/a")")
```

### Current Chain State

```swift
let epoch = try await context.epoch()
let slot  = try await context.lastBlockSlot()
let era   = try await context.era()

print("Epoch \(epoch), slot \(slot), era \(era?.description ?? "unknown")")
```

### Chain Tip

For slot, block, epoch, era, and sync progress in a single call:

```swift
let tip = try await context.chainTip()

print("Slot          : \(tip.slot.map(String.init) ?? "n/a")")
print("Block         : \(tip.block.map(String.init) ?? "n/a")")
print("Epoch         : \(tip.epoch.map(String.init) ?? "n/a")")
print("Era           : \(tip.era ?? "unknown")")
print("Sync progress : \(tip.syncProgress.map { "\($0)%" } ?? "n/a")")
```

Every field of `ChainTip` is optional, and how many are filled depends on the backend: a node
queried directly fills them all, while hosted APIs and some UTxO RPC servers leave out what
they cannot report. ``OfflineTransferChainContext`` works out only the slot and epoch, from
the cached genesis parameters and the system clock, and takes the era from the transfer file.

### Transactions Already on Chain

``ChainContext/transactionCBOR(hash:)`` returns a confirmed transaction's bytes, and
`transaction(hash:)` decodes them and checks the id. Backends that only see the live ledger —
a node, Ogmios, Yaci Store — cannot look transactions up and throw
``CardanoChainError/notImplemented(_:)``.

## Writing to the Blockchain

### Submitting Transactions

```swift
// Pre-built transaction object
let txId = try await context.submitTx(tx: .transaction(transaction))

// Raw CBOR bytes
let txId = try await context.submitTx(tx: .bytes(cborData))

// CBOR hex string
let txId = try await context.submitTx(tx: .string("84a700..."))

print("Submitted: \(txId)")
```

### Evaluating Plutus Script Execution Units

``ChainContext/evaluateTx(tx:)`` returns the execution units of each redeemer, keyed
`<tag>:<index>`:

```swift
let units = try await context.evaluateTx(tx: transaction)

for (redeemer, eu) in units {
    print("\(redeemer): mem=\(eu.mem) steps=\(eu.steps)")
}
```

How the scripts are run depends on the context:

| Context | Evaluation |
|---|---|
| BlockFrost, Koios, Ogmios | Remote: the service evaluates against its ledger state |
| YaciDevkit | Remote, through Yaci Store; needs DevKit started with Ogmios enabled |
| UTxO RPC | Remote `EvalTx`, falling back to local evaluation when the server cannot evaluate |
| `CardanoCliChainContext`, `NodeSocketChainContext` | Local: inputs are resolved from the node, then run through the UPLC CEK machine in-process |
| Kupo | Forwarded to the wrapped context |
| OfflineTransfer | Served from ``OfflineTransferEvaluation`` entries saved on the online machine |

The local evaluator is also available directly. Call it when you already hold the UTxOs for
every regular and reference input, plus the protocol parameters, or to evaluate without asking
a remote service. A transaction with a validity interval also needs the chain's slot timeline:

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

## Staking Operations

```swift
let stakeAddress = try Address(from: .string("stake1..."))
let info = try await context.stakeAddressInfo(address: stakeAddress)

for entry in info {
    print("Rewards      : \(entry.rewardAccountBalance) lovelace")
    print("Pool         : \(entry.stakeDelegation.map { "\($0)" } ?? "not delegated")")
    print("Vote deleg.  : \(entry.voteDelegation.map { "\($0)" } ?? "none")")
}
```

## Treasury

```swift
let balance = try await context.treasury()
print("Treasury: \(balance) lovelace")
```

## Governance (Conway Era)

### DRep, Governance Action, and Committee Member Info

```swift
let drepInfo = try await context.drepInfo(drep: someDRep)
let govInfo  = try await context.govActionInfo(govActionID: someActionId)

// Committee members can be looked up by either credential
let cmInfo  = try await context.committeeMemberInfo(cold: coldCred)
let cmInfo2 = try await context.committeeMemberInfo(hot:  hotCred)
```

### Per-Proposal Vote Tally

``ChainContext/govActionVotes(govActionID:)`` returns a ``GovActionVotes`` aggregate
carrying the proposal procedure (deposit, return address, anchor), the three vote
arrays (committee, DRep, stake-pool), and lifecycle epochs (proposed / expires /
ratified / enacted / dropped / expired).

```swift
let votes = try await context.govActionVotes(govActionID: actionId)

print("Status   : \(votes.status.map { "\($0)" } ?? "not concluded")")
print("Deposit  : \(votes.deposit) lovelace")
print("CC votes : \(votes.committeeVotes.count)")
print("DRep     : \(votes.dRepVotes.count)")
print("Pool     : \(votes.stakePoolVotes.count)")
```

`status` is `nil` until the action is ratified, enacted, dropped or expired.

### Listing Proposals

``ChainContext/openGovActions()`` lists the actions that can still be voted on, without their
votes. ``ChainContext/govActionsAll()`` returns a ``GovActionVotes`` for every proposal the
backend lists:

```swift
let open = try await context.openGovActions()
let all  = try await context.govActionsAll()
```

What `govActionsAll()` covers depends on the backend. Contexts that read the node's ledger
state (`cardano-cli`, NodeSocket, Ogmios) return the proposals in the current governance
state in one query — the analogue of `cardano-cli query gov-state | jq .proposals`.
BlockFrost and Koios return every proposal they have indexed, concluded ones included, and
make further requests per proposal to fetch the votes.

### Stake Distributions

Effective stake delegated to each DRep and each stake pool for the current epoch —
the inputs the ratifier uses to decide proposal outcomes:

```swift
let drepStake = try await context.drepStakeDistribution()
let spoStake  = try await context.spoStakeDistribution()
```

Both come from the node's ledger state, so only `CardanoCliChainContext` and
`NodeSocketChainContext` answer both. ``YaciDevkitChainContext`` answers the DRep distribution
only; BlockFrost, Koios and Ogmios throw ``CardanoChainError/notImplemented(_:)`` for both;
Kupo and UTxO RPC pass them to the context they wrap; and OfflineTransfer serves the entries
saved in the transfer file.

### Constitutional Committee State

``ChainContext/committeeState()`` returns a ``CommitteeStateInfo`` capturing every
cold→hot authorization, term expirations, and the active quorum threshold — the
ledger's exact fraction, or `nil` when there is no committee (a state of no confidence):

```swift
let state = try await context.committeeState()
if let quorum = state.threshold {
    print("Quorum: \(quorum.numerator)/\(quorum.denominator)")
} else {
    print("No committee")
}
for member in state.members {
    print("\(member.coldCredential) → \(member.hotCredential.map(String.init(describing:)) ?? "unauthorized")")
}
```

## Error Handling

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

Errors from an underlying client library (a network failure, for example) can also reach you
unwrapped, so keep the final `catch`.

## Network Support

| Network | BlockFrost | Koios | Ogmios | Kupo | UTxO RPC | CardanoCLI | NodeSocket | YaciDevkit | OfflineTransfer |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| mainnet      | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |   | ✓ |
| preprod      | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |   | ✓ |
| preview      | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |   | ✓ |
| guildnet     |   | ✓ | ✓ | ✓ | ✓ | ✓ | ✓¹ |   | ✓ |
| sanchonet    |   | ✓ | ✓ | ✓ | ✓ | ✓ | ✓¹ |   | ✓ |
| local devnet |   |   | ✓ | ✓ | ✓ | ✓ | ✓¹ | ✓ | ✓ |

- BlockFrost and Koios throw ``CardanoChainError/unsupportedNetwork(_:)`` from their
  initialisers for any other network.
- Ogmios, Kupo, UTxO RPC and `cardano-cli` work with whatever network the server or node
  behind them follows; the `network` you pass sets ``ChainContext/networkId`` (and, for
  `cardano-cli`, its `--testnet-magic`).
- ¹ `NodeSocketChainContext(socketPath:network:)` has handshake presets for mainnet, preprod
  and preview only. For any other network, build a `CardanoNetworkConfiguration` with
  `connection.networkMagic` set and pass it to `init(networkConfig:network:)`.
- YaciDevkit talks to a DevKit devnet (magic `42` by default).
- OfflineTransfer serves whatever network the transfer file was prepared on.

## Topics

### Chain Context Protocol

- ``ChainContext``
- ``ContextType``
- ``TransactionData``
- ``ChainStateCache``

### Cloud API Contexts

- ``BlockFrostChainContext``
- ``KoiosChainContext``

### Node and Indexer Contexts

- ``OgmiosChainContext``
- ``KupoChainContext``
- ``UTxORPCChainContext``
- ``UTxORPCConnector``
- ``UTxORPCConnectionConnector``
- ``UTxORPCEndpointConnector``
- ``UTxORPCServices``

### Devnet Context

- ``YaciDevkitChainContext``
- ``YaciDevkitAdminFetching``

### Offline Context

- ``OfflineTransferChainContext``

### Chain Context Guides

- <doc:Using-BlockFrost>
- <doc:Using-Koios>
- <doc:Using-Ogmios>
- <doc:Using-Kupo>
- <doc:Using-UTxORPC>
- <doc:Using-YaciDevkit>
- <doc:Using-OfflineTransfer>
- <doc:Using-CardanoCLI>
- <doc:Using-NodeSocket>

### Error Handling

- ``CardanoChainError``

### Data Models

- ``StakePoolInfo``
- ``DRepInfo``
- ``GovActionInfo``
- ``GovActionVotes``
- ``OpenGovAction``
- ``CommitteeMemberInfo``
- ``CommitteeStateInfo``
- ``KESPeriodInfo``

### Offline Transfer Models

- ``OfflineTransfer``
- ``OfflineTransferProtocolData``
- ``OfflineTransferTransaction``
- ``OfflineTransferTransactionJSON``
- ``OfflineTransferEvaluation``
- ``OfflineTransferHistory``
- ``OfflineTransferFileEntry``
- ``AddressInfo``
- ``HistoryType``
