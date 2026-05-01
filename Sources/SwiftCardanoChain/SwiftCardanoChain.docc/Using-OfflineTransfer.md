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
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.3.0")
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

## Limitations

Operations that require live network access are not available:

| Feature | Supported |
|---|:---:|
| UTxOs from transfer file | ✓ |
| Protocol parameters | ✓ |
| Genesis parameters | ✓ |
| Era / epoch (derived) | ✓ |
| Tx submission (writes to file) | ✓ |
| Live UTxO queries | ✗ |
| Staking / pool queries | ✗ |
| Tx evaluation | ✗ |
| Governance queries | ✗ |

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
