# ``SwiftCardanoChain``

Interact with the Cardano blockchain through a unified Swift interface backed by seven pluggable chain context implementations.

## Overview

SwiftCardanoChain provides a single ``ChainContext`` protocol and seven concrete implementations, each suited to a different deployment scenario:

| Context | When to use |
|---|---|
| ``BlockFrostChainContext`` | Cloud API — no local node required |
| ``KoiosChainContext`` | Decentralised community API — no local node required |
| ``CardanoCliChainContext`` | Local node via `cardano-cli` |
| ``OgmiosChainContext`` | Local node via the Ogmios WebSocket bridge |
| ``NodeSocketChainContext`` | Local node via the NtC Unix socket directly |
| ``YaciDevkitChainContext`` | Local throw-away devnet run by Yaci DevKit |
| ``OfflineTransferChainContext`` | Air-gapped / offline transaction signing |

Every context provides the same interface for:

- Reading chain state (UTxOs, protocol parameters, genesis parameters, epoch, era, slot, chain tip)
- Submitting and evaluating transactions — including a backend-agnostic local UPLC evaluator for contexts without a remote `evaluateTransaction` RPC
- Querying stake addresses, pools, DReps, governance actions, and committee members
- Querying treasury balance, DRep / SPO stake distributions, full constitutional committee state, and per-proposal vote tallies

### Quick Start

Pick the context that matches your environment and swap it for any other without changing the rest of your code.

```swift
import SwiftCardanoChain

// Cloud — simplest setup
let context = try await BlockFrostChainContext(
    network: .preview,
    environmentVariable: "BLOCKFROST_API_KEY"
)

// Local node via cardano-cli
let context = try await CardanoCliChainContext(
    nodeConfig: FilePath("/opt/cardano/preview/config.json"),
    binary:     FilePath("/usr/local/bin/cardano-cli"),
    socket:     FilePath("/ipc/node.socket"),
    network:    .preview
)

// All contexts share the same API
let utxos  = try await context.utxos(address: address)
let params = try await context.protocolParameters()
let epoch  = try await context.epoch()
```

## Reading Blockchain Data

### UTxOs

```swift
let address = try Address(from: .string("addr1..."))
let utxos   = try await context.utxos(address: address)

for utxo in utxos {
    print("TxHash: \(utxo.input.transactionId.payload.toHex)#\(utxo.input.index)")
    print("Lovelace: \(utxo.output.amount.coin)")

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
print("Slot length    : \(genesis.slotLength) s")
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

For slot, block, epoch, era, and sync progress in a single call:

```swift
let tip = try await context.chainTip()

print("Slot          : \(tip.slot)")
print("Block         : \(tip.block ?? 0)")
print("Epoch         : \(tip.epoch)")
print("Era           : \(tip.era ?? "unknown")")
print("Sync progress : \(tip.syncProgress.map { "\($0)%" } ?? "n/a")")
```

Local-node contexts populate every field; cloud APIs derive what they can and leave the
rest `nil`. ``OfflineTransferChainContext`` computes slot and epoch from cached genesis
parameters and the system clock.

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

Contexts that expose a remote evaluator (BlockFrost, Koios, Ogmios) call out directly:

```swift
let units = try await context.evaluateTx(tx: transaction)

for (redeemer, eu) in units {
    print("\(redeemer): mem=\(eu.mem) steps=\(eu.steps)")
}
```

For contexts without a remote evaluator (``CardanoCliChainContext``,
``NodeSocketChainContext``), the protocol provides a default that runs the UPLC CEK
machine in-process. Provide the resolved UTxOs for every regular and reference input,
plus the current protocol parameters:

```swift
let resolvedInputs = try await fetchResolvedInputs(for: transaction)
let params         = try await context.protocolParameters()

let units = try await context.evaluateTx(
    tx: transaction,
    resolvedInputs: resolvedInputs,
    protocolParameters: params
)
```

``OfflineTransferChainContext`` serves execution units from
``OfflineTransferEvaluation`` entries populated on the online machine.

## Staking Operations

```swift
let stakeAddress = try Address(from: .string("stake1..."))
let info = try await context.stakeAddressInfo(address: stakeAddress)

for entry in info {
    print("Rewards      : \(entry.rewardAccountBalance) lovelace")
    print("Pool         : \(entry.stakeDelegation ?? "unregistered")")
    print("Vote deleg.  : \(entry.voteDelegation ?? "none")")
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

print("Status   : \(votes.status?.rawValue ?? "active")")
print("Deposit  : \(votes.deposit) lovelace")
print("CC votes : \(votes.committeeVotes.count)")
print("DRep     : \(votes.dRepVotes.count)")
print("Pool     : \(votes.stakePoolVotes.count)")
```

Pull every active proposal in one round-trip (the analogue of
`cardano-cli query gov-state | jq .proposals`):

```swift
let all = try await context.govActionsAll()
```

### Stake Distributions

Effective stake delegated to each DRep and each stake pool for the current epoch —
the inputs the ratifier uses to decide proposal outcomes:

```swift
let drepStake = try await context.drepStakeDistribution()
let spoStake  = try await context.spoStakeDistribution()
```

### Constitutional Committee State

``ChainContext/committeeState()`` returns a ``CommitteeStateInfo`` capturing every
cold→hot authorization, term expirations, and the active quorum threshold:

```swift
let state = try await context.committeeState()
print("Quorum: \(state.threshold)")
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

## Network Support

| Network | BlockFrost | Koios | CardanoCLI | Ogmios | NodeSocket | YaciDevkit | OfflineTransfer |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| mainnet      | ✓ | ✓ | ✓ | ✓ | ✓ |   | ✓ |
| preprod      | ✓ | ✓ | ✓ | ✓ | ✓ |   | ✓ |
| preview      | ✓ | ✓ | ✓ | ✓ | ✓ |   | ✓ |
| guildnet     |   | ✓ |   |   |   |   |   |
| sanchonet    |   | ✓ |   |   |   |   |   |
| local devnet |   |   | ✓ | ✓ | ✓ | ✓ |   |

## Topics

### Chain Context Protocol

- ``ChainContext``
- ``ContextType``
- ``TransactionData``

### Cloud API Contexts

- ``BlockFrostChainContext``
- ``KoiosChainContext``

### Local Node Contexts

- ``CardanoCliChainContext``
- ``OgmiosChainContext``
- ``NodeSocketChainContext``
- ``YaciDevkitChainContext``

### Offline Context

- ``OfflineTransferChainContext``

### Chain Context Guides

- <doc:Using-BlockFrost>
- <doc:Using-Koios>
- <doc:Using-CardanoCLI>
- <doc:Using-Ogmios>
- <doc:Using-NodeSocket>
- <doc:Using-YaciDevkit>
- <doc:Using-OfflineTransfer>

### Error Handling

- ``CardanoChainError``

### Data Models

- ``StakePoolInfo``
- ``DRepInfo``
- ``GovActionInfo``
- ``GovActionVotes``
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
- ``HistoryType``
