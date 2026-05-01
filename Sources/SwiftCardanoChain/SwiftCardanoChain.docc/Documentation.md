# ``SwiftCardanoChain``

Interact with the Cardano blockchain through a unified Swift interface backed by six pluggable chain context implementations.

## Overview

SwiftCardanoChain provides a single ``ChainContext`` protocol and six concrete implementations, each suited to a different deployment scenario:

| Context | When to use |
|---|---|
| ``BlockFrostChainContext`` | Cloud API — no local node required |
| ``KoiosChainContext`` | Decentralised community API — no local node required |
| ``CardanoCliChainContext`` | Local node via `cardano-cli` |
| ``OgmiosChainContext`` | Local node via the Ogmios WebSocket bridge |
| ``NodeSocketChainContext`` | Local node via the NtC Unix socket directly |
| ``OfflineTransferChainContext`` | Air-gapped / offline transaction signing |

Every context provides the same interface for:

- Reading chain state (UTxOs, protocol parameters, genesis parameters, epoch, era, slot)
- Submitting and evaluating transactions
- Querying stake addresses, pools, DReps, governance actions, and committee members

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

```swift
let units = try await context.evaluateTx(tx: transaction)

for (redeemer, eu) in units {
    print("\(redeemer): mem=\(eu.mem) steps=\(eu.steps)")
}
```

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

## Error Handling

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

### Offline Context

- ``OfflineTransferChainContext``

### Chain Context Guides

- <doc:Using-BlockFrost>
- <doc:Using-Koios>
- <doc:Using-CardanoCLI>
- <doc:Using-Ogmios>
- <doc:Using-NodeSocket>
- <doc:Using-OfflineTransfer>

### Error Handling

- ``CardanoChainError``

### Data Models

- ``StakePoolInfo``
- ``DRepInfo``
- ``GovActionInfo``
- ``CommitteeMemberInfo``
- ``KESPeriodInfo``
