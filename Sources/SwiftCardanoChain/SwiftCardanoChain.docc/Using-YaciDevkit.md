# Using YaciDevkitChainContext

Develop against a throw-away local devnet run by Yaci DevKit.

## Overview

``YaciDevkitChainContext`` talks to a [Yaci DevKit](https://github.com/bloxbean/yaci-devkit)
devnet: a one-command Cardano network that starts in seconds, comes pre-funded, and can be
reset whenever you want a clean slate. Chain data is read through
[SwiftYaciAPI](https://github.com/Kingpin-Apps/swift-yaci-api), the generated client for the
[Yaci Store](https://github.com/bloxbean/yaci-store) REST API that DevKit embeds. Genesis comes
from DevKit's own admin (cluster) API, because Yaci Store serves none.

Use it for the inner development loop. There is no API key, no `cardano-node` socket, and no
Ogmios process to run, and a devnet epoch is minutes rather than days, so the whole
delegation and governance lifecycle can be exercised in a single sitting.

**Supported networks:** whatever magic your devnet was started with. DevKit's default is `42`,
which is the context's default too.

## Prerequisites

- A running Yaci DevKit. Its store listens on port 8080 and its admin API on port 10000.
- For ``ChainContext/evaluateTx(tx:)``, start DevKit with Ogmios enabled
  (`ogmios_enabled=true`).

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.8.0")
```

## Creating a Context

### Default Local DevKit

```swift
import SwiftCardanoChain

let context = try YaciDevkitChainContext()
```

That reads the store at `http://localhost:8080` and the admin API at `http://localhost:10000`.

### Custom Endpoints

```swift
let context = try YaciDevkitChainContext(
    apiURL:   "http://devkit.local:8080",
    adminURL: "http://devkit.local:10000",
    network:  .custom(42)
)
```

The admin URL defaults to port 10000 on the store's host, so it only needs to be given when
DevKit was started with a different layout. A trailing `/api/v1` on the store URL is accepted
and dropped.

### Injecting a Client

Pass a pre-built client to reuse a transport or to test against canned responses:

```swift
import SwiftYaciAPI

let client = Client(serverURL: url, transport: myTransport)
let context = try YaciDevkitChainContext(client: client, admin: myAdminClient)
```

## Reading Chain Data

### UTxOs at an Address

```swift
let address = try Address(from: .string("addr_test1..."))
let utxos   = try await context.utxos(address: address)

for utxo in utxos {
    print("\(utxo.input.transactionId.payload.toHex)#\(utxo.input.index)")
    print("  \(utxo.output.amount.coin) lovelace")
}
```

Yaci pages its list endpoints, and this context reads every page, so a wallet with more than
ten UTxOs is returned in full.

### Resolving One UTxO

```swift
if let (utxo, isSpent) = try await context.utxo(input: input) {
    print(isSpent ? "spent" : "unspent")
}
```

Yaci keeps outputs after they are spent but records no spent flag, so this decides the
question by looking for the output in its own address' live set. That costs one extra
paginated request.

### Protocol and Genesis Parameters

```swift
let params  = try await context.protocolParameters()
let genesis = try await context.genesisParameters()
```

Cost models are read from the genesis files rather than from the store. The store reports each
model as a map keyed by operation name, and Plutus V3's ledger order is not alphabetical, so a
transaction built from the store's ordering is rejected with `PPViewHashesDontMatch`.

## Submitting and Evaluating Transactions

```swift
let txId = try await context.submitTx(tx: .transaction(transaction))

// Needs DevKit started with ogmios_enabled=true
let units = try await context.evaluateTx(tx: transaction)
```

## What Yaci Can and Cannot Answer

Yaci Store indexes certificates and outputs rather than ledger state. Several queries are
therefore reconstructions from the certificate log, and a few have no data source at all.

| Query | Source |
|---|---|
| Genesis parameters, cost models | DevKit admin API (genesis files) |
| Stake pools | Pool certificate log, merged with the pools set up in genesis |
| Pool parameters | Registration certificate, then genesis, then per-epoch state |
| Pool status | Per-epoch pool state, falling back to the certificate log |
| Stake address registration | Folded from the stake certificate log |
| DRep info | Folded from DRep registration / update / retirement certificates |
| Governance actions, votes | Proposal and voting-procedure log |
| Committee state | Current committee, with hot keys folded from the certificate log |
| KES period info | Latest block minted by the pool |
| Treasury, SPO stake distribution | Not available |

Some consequences are worth planning around:

- **Governance outcomes are unknown.** Yaci does not index governance state, so
  `ratifiedEpoch`, `enactedEpoch`, `droppedEpoch` and `expiredEpoch` are always `nil`, which
  makes ``GovActionInfo/status`` report `nil` — "still open" — for every action, including ones
  that have concluded. ``ChainContext/govActionsAll()`` likewise returns every indexed
  proposal, not only the active ones.
- **Pool stake figures are absent.** ``StakePoolInfo`` carries the registered parameters and
  the pool's status; `liveStake`, `activeStake` and `opcertCounter` are left `nil` rather than
  guessed at. The `pledge` inside `poolParams` is the declared pledge from the certificate.
- **A devnet's own block producer is set up in genesis**, not by a registration certificate, so
  it is read from the Shelley genesis instead of the certificate log. Its relays are parsed
  best-effort, because genesis encodes them differently from the certificate log and a devnet
  usually declares none.
- **Registration is read from certificates, not from the account.** Yaci answers
  `/accounts/{stakeAddress}` with 200 and zeroed amounts for any well-formed stake address,
  including one it has never seen, so a successful response says nothing about registration.
  the `active` flag on `StakeAddressInfo` therefore comes from the stake certificate log, and
  an address with no certificate reports `false`.
- **A pruned or still-syncing store misleads.** Reconstruction treats an unseen certificate as
  one that was never submitted.

``ChainContext/treasury()`` and ``ChainContext/spoStakeDistribution()`` have no Yaci
equivalent and throw ``CardanoChainError/notImplemented(_:)``.

The DRep stake distribution and the live committee view read the node through DevKit's
local-state endpoints, which are only served while the cluster is running. A DRep whose stake
cannot be read reports `0`.

## Verified Against a Live Devnet

This backend is exercised against a running DevKit as well as against mocked responses. The
live run registers a stake address, a stake pool with three relay shapes, a DRep and a
governance action, votes on that action from both the DRep and the pool, and reads all of it
back, alongside the devnet's own genesis-configured block producer and its operational
certificate.

``ChainContext/committeeMemberInfo(cold:)`` is the one query with no live coverage, because a
DevKit devnet starts with an empty constitutional committee.

## Error Handling

Yaci failures surface as ``CardanoChainError/yaciDevkitError(_:)``:

```swift
do {
    let utxos = try await context.utxos(address: address)
} catch CardanoChainError.yaciDevkitError(let message) {
    print("Yaci DevKit error: \(message ?? "unknown")")
} catch CardanoChainError.notImplemented(let message) {
    print("Not available from Yaci: \(message ?? "unknown")")
} catch {
    print("Unexpected error: \(error)")
}
```

## Caching Behaviour

| Data | Cache lifetime |
|---|---|
| Epoch | 10 seconds — devnet epochs are short |
| Protocol parameters | Per epoch |
| Genesis parameters and files | Permanent |
| UTxOs | Not cached |

## See Also

- ``YaciDevkitChainContext``
- ``YaciDevkitAdminFetching``
- ``ChainContext``
- ``CardanoChainError``
