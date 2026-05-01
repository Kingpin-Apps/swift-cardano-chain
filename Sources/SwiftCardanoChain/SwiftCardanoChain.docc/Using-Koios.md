# Using KoiosChainContext

Connect to the Cardano blockchain through the Koios decentralised community API.

## Overview

``KoiosChainContext`` routes chain queries through [Koios](https://www.koios.rest), an
elastic, community-hosted query layer for Cardano. Because multiple independent nodes serve the
same REST interface, there is no single point of failure.

An API key is optional for low-volume usage; create one at the Koios website for higher rate
limits.

**Supported networks:** `.mainnet`, `.preprod`, `.preview`, `.guildnet`, `.sanchonet`

> Note: Koios is the only backend in this library that supports `.guildnet` and `.sanchonet`.

## Prerequisites

- No local node required.
- Optionally obtain an API key from [koios.rest](https://www.koios.rest) for higher rate limits.

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.3.0")
```

## Creating a Context

### Without an API Key (Rate-Limited)

```swift
import SwiftCardanoChain

let context = try await KoiosChainContext(network: .mainnet)
```

### From an Environment Variable (Recommended for Production)

```swift
let context = try await KoiosChainContext(
    network: .mainnet,
    environmentVariable: "KOIOS_API_KEY"
)
```

Set the variable in your environment:

```
export KOIOS_API_KEY=your-koios-api-key
```

### With an API Key Directly

```swift
let context = try await KoiosChainContext(
    apiKey: "your-koios-api-key",
    network: .preprod
)
```

### With a Custom Base URL

Point at a self-hosted Koios-compatible endpoint:

```swift
let context = try await KoiosChainContext(
    apiKey: "your-key",
    network: .mainnet,
    basePath: "https://your-koios-instance.example.com"
)
```

### Targeting Specialised Networks

```swift
// Guild testnet
let guildContext = try await KoiosChainContext(network: .guildnet)

// Sancho testnet (governance preview)
let sanchoContext = try await KoiosChainContext(network: .sanchonet)
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

### Protocol and Genesis Parameters

Protocol parameters are cached per epoch; genesis parameters are cached permanently.

```swift
let params  = try await context.protocolParameters()
let genesis = try await context.genesisParameters()

print("Min fee per byte: \(params.txFeePerByte)")
print("Network magic: \(genesis.networkMagic)")
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

// From a CBOR hex string
let txId = try await context.submitTx(tx: .string("84a700..."))

print("Submitted: \(txId)")
```

## Evaluating Plutus Scripts

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

## Governance Queries (Conway era)

```swift
let drepInfo = try await context.drepInfo(drep: someDRep)
let govInfo  = try await context.govActionInfo(govActionID: someActionId)
let cmInfo   = try await context.committeeMemberInfo(committeeMember: cred)
```

## Error Handling

Koios errors surface as ``CardanoChainError/koiosError(_:)``:

```swift
do {
    let utxos = try await context.utxos(address: address)
} catch CardanoChainError.koiosError(let message) {
    print("Koios API error: \(message ?? "unknown")")
} catch CardanoChainError.unsupportedNetwork(let message) {
    print("Network not supported by Koios: \(message ?? "unknown")")
} catch {
    print("Unexpected error: \(error)")
}
```

## Caching Behaviour

| Data | Cache lifetime |
|---|---|
| Protocol parameters | Per epoch |
| Genesis parameters | Permanent |
| UTxOs | Not cached |

## See Also

- ``KoiosChainContext``
- ``ChainContext``
- ``CardanoChainError``
