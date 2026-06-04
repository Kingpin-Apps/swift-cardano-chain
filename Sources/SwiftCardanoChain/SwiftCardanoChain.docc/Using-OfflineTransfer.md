# Using OfflineTransferChainContext

Build and sign Cardano transactions on an air-gapped machine using a JSON transfer file.

## Overview

``OfflineTransferChainContext`` enables transaction signing on machines that have no network
access — a critical requirement for cold wallets, HSM-backed signers, and high-security setups.

The workflow is:

1. **Online machine** — query the chain (UTxOs, protocol parameters, etc.) and serialise the
   data into an `OfflineTransfer` JSON file.
2. **Transfer** — copy the JSON file to the air-gapped machine (USB drive, QR code, etc.).
3. **Offline machine** — initialise `OfflineTransferChainContext` with the file and build/sign
   the transaction. The signed CBOR is written back into the same JSON file.
4. **Return** — copy the file back to the online machine and submit the transaction.

Unlike every other context, `OfflineTransferChainContext` has `type == .offline` — it never
opens a network connection and throws ``CardanoChainError/notImplemented(_:)`` for operations
that inherently require one (e.g. `stakePools()`).

## Prerequisites

- An `OfflineTransfer` JSON file prepared by the online machine.
- No network access required on the signing machine.

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.5.0")
```

## Step 1 — Prepare the Transfer File (Online Machine)

Use any online ``ChainContext`` to populate the data and save it:

```swift
import SwiftCardanoChain

// Any online context will do
let onlineContext = try await BlockFrostChainContext(
    network: .mainnet,
    environmentVariable: "BLOCKFROST_API_KEY"
)

// Build the offline transfer model
var transfer = OfflineTransfer()

// Add UTxOs for each address that will be spent
let address = try Address(from: .string("addr1..."))
let utxos   = try await onlineContext.utxos(address: address)
transfer.addUtxos(utxos, for: address)

// Capture protocol and genesis parameters
transfer.protocol.protocolParameters = try await onlineContext.protocolParameters()
transfer.protocol.genesisParameters  = try await onlineContext.genesisParameters()
transfer.protocol.era                = try await onlineContext.era()
transfer.protocol.network            = .mainnet

// Optionally cache treasury / governance state for offline reads
transfer.treasury               = try await onlineContext.treasury()
transfer.govActionVotesList     = try await onlineContext.govActionsAll()
transfer.drepStakeEntries       = try await onlineContext.drepStakeDistribution()
transfer.spoStakeEntries        = try await onlineContext.spoStakeDistribution()
transfer.committeeStateSnapshot = try await onlineContext.committeeState()

// Optionally pre-compute Plutus execution units so the offline machine
// can serve `evaluateTx` without a network round-trip.
let units = try await onlineContext.evaluateTx(tx: tx)
transfer.evaluations.append(
    OfflineTransferEvaluation(txCborHex: tx.toCBORData().toHex, executionUnits: units)
)

// Save to disk
try transfer.save(to: FilePath("/path/to/transfer.json"))
```

## Step 2 — Transfer the File

Copy `/path/to/transfer.json` to the offline machine by any secure means (USB, encrypted
transfer, QR code, etc.).

## Step 3 — Sign on the Offline Machine

```swift
import SwiftCardanoChain
import SystemPackage

// Load the transfer file — no network call is made
let context = try OfflineTransferChainContext(
    filePath: FilePath("/path/to/transfer.json"),
    network: .mainnet
)

// UTxOs come from the transfer file, not the network
let utxos = try await context.utxos(address: signerAddress)

// Build and sign a transaction using the offline data
// (transaction building is handled by swift-cardano-core)
let signedCborHex = "84a700..."

// "Submit" writes the CBOR back into the transfer file
let txId = try await context.submitTx(tx: .string(signedCborHex))
print("Recorded as: \(txId)")
```

## Step 4 — Return and Submit (Online Machine)

```swift
// Reload the transfer file — it now contains the signed tx CBOR
let transfer = try OfflineTransfer.load(from: FilePath("/path/to/transfer.json"))

// Extract the signed transaction and submit it
let cborHex = transfer.signedTransactions.last!.cborHex
let txId    = try await onlineContext.submitTx(tx: .string(cborHex))
print("Submitted: \(txId)")
```

## Reading Chain Data (Offline)

All data comes from the transfer file rather than the network:

```swift
// UTxOs for an address (populated during step 1)
let utxos = try await context.utxos(address: address)

// Protocol parameters from the transfer file
let params = try await context.protocolParameters()

// Genesis parameters from the transfer file
let genesis = try await context.genesisParameters()

// Era from the transfer file
let era = try await context.era()
```

## Checking Context Type

You can branch on `type` to detect whether you are running online or offline:

```swift
if context.type == .offline {
    print("Running in offline mode — no network calls will be made.")
}
```

## Cached Reads

Every read is served from the data that was populated on the online machine and
serialised into the file. If a field was not populated before the file was transferred,
the corresponding call throws ``CardanoChainError/offlineTransferError(_:)``.

| Call | Source field on `OfflineTransfer` |
|---|---|
| `utxos(address:)` / `utxo(input:)` | `addresses` |
| `protocolParameters()` | `protocol.protocolParameters` |
| `genesisParameters()` | `protocol.genesisParameters` |
| `era()` / `epoch()` / `lastBlockSlot()` / `chainTip()` | `protocol` + system clock |
| `stakePools()` / `stakePoolInfo(poolId:)` | `stakePools`, `stakePoolInfos` |
| `stakeAddressInfo(address:)` | `addresses[].stakeAddressInfo` |
| `kesPeriodInfo(...)` | `kesPeriodInfos` |
| `treasury()` | `treasury` |
| `drepInfo(drep:)` | `drepInfos` |
| `govActionInfo(govActionID:)` | `govActionInfos` |
| `govActionVotes(govActionID:)` / `govActionsAll()` | `govActionVotesList` |
| `committeeMemberInfo(cold:)` / `committeeMemberInfo(hot:)` | `committeeMemberInfos` |
| `committeeState()` | `committeeStateSnapshot` |
| `drepStakeDistribution()` / `spoStakeDistribution()` | `drepStakeEntries`, `spoStakeEntries` |
| `evaluateTx(...)` / `evaluateTxCBOR(cbor:)` | `evaluations` (matched by tx CBOR hex) |
| `submitTxCBOR(cbor:)` (writes signed CBOR back into the file) | `transactions`, `history` |

`submitTx` does not broadcast to the network — it appends the signed CBOR to the file
so the online side can submit it on return.

## Error Handling

Offline errors surface as ``CardanoChainError/offlineTransferError(_:)``:

```swift
do {
    let params = try await context.protocolParameters()
} catch CardanoChainError.offlineTransferError(let message) {
    print("Offline transfer error: \(message ?? "unknown")")
    // Likely cause: protocol parameters were not included in the transfer file
} catch CardanoChainError.notImplemented(let message) {
    print("Operation requires network: \(message ?? "unknown")")
} catch {
    print("Unexpected error: \(error)")
}
```

## Audit Trail

Every action taken on the transfer file is recorded in an `OfflineTransfer.history` array via
`HistoryType` entries — giving you a tamper-evident audit log of what data was read, what
transactions were built, and when each step occurred.

## See Also

- ``OfflineTransferChainContext``
- ``OfflineTransfer``
- ``ChainContext``
- ``CardanoChainError``
