# Using UTxORPCChainContext

Query and submit through a UTxO RPC (gRPC) server: cardano-node's built-in one, Dolos, Demeter, or cardano-node-api.

## Overview

``UTxORPCChainContext`` talks to a [UTxO RPC](https://utxorpc.org) server through
[swift-utxorpc](https://github.com/Kingpin-Apps/swift-utxorpc). UTxO RPC is a gRPC interface
served by cardano-node 11.x itself, by Dolos, by the hosted Demeter service, and by
cardano-node-api.

It answers the chain tip, protocol and genesis parameters, UTxOs by address or by output
reference, and submits and evaluates transactions. Of the stake queries, the protocol answers
only ``UTxORPCChainContext/stakePools()``, and it has no governance queries. Those — and
anything a server answers `UNIMPLEMENTED` — go to an optional wrapped context, such as
BlockFrost or Ogmios. Without one, they throw ``CardanoChainError/notImplemented(_:)``.

The context is a plain struct and is built by default on every platform the package supports.

**Supported networks:** any network the server follows. The `network` you pass sets the
context's ``UTxORPCChainContext/networkId`` and, when the server has no era summary, is used
to place the Byron–Shelley boundary when working out the epoch.

## Prerequisites

One of:

- **cardano-node 11.x** started with `"EnableRpc": true` in its config. Node 11.1.x serves UTxO
  RPC only on a Unix socket, `rpc.sock`, next to `node.socket`, in plaintext.
- **Dolos**, listening on TCP.
- **Demeter**, with its `dmtr-api-key` for the network you use.
- **cardano-node-api**, which speaks only the older `v1alpha` API.

Add both packages to your `Package.swift`. ``UTxORPCChainContext`` lives in SwiftCardanoChain;
the endpoint type you create it from, `UTxORPCEndpoint`, lives in swift-utxorpc's
`UTxORPCClient` module:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.16.1"),
.package(url: "https://github.com/Kingpin-Apps/swift-utxorpc.git", from: "0.1.0"),
```

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "SwiftCardanoChain", package: "swift-cardano-chain"),
        .product(name: "UTxORPCClient", package: "swift-utxorpc"),
    ]
)
```

## Creating a Context

### A Local cardano-node

```swift
import Foundation
import SwiftCardanoChain
import UTxORPCClient

let context = try UTxORPCChainContext(
    endpoint: .unixSocket("/opt/cardano/mainnet/socket/rpc.sock"),
    network: .mainnet
)
```

### Dolos or Another TCP Server

`UTxORPCEndpoint(url:)` reads `https://host[:port]` (TLS, port 443 by default),
`http://host[:port]` (plaintext, port 80 by default) or `unix:///path/to/rpc.sock`:

```swift
let dolos = try UTxORPCChainContext(
    endpoint: try UTxORPCEndpoint(url: URL(string: "http://dolos.local:50051")!),  // your server's gRPC address
    network: .preview
)
```

### Demeter, with Governance from BlockFrost

Hosted providers take an API key as a gRPC header. Header keys must be lowercase:

```swift
let blockfrost = try await BlockFrostChainContext(
    network: .preview,
    environmentVariable: "BLOCKFROST_API_KEY"
)

let demeter = try UTxORPCChainContext(
    endpoint: try UTxORPCEndpoint(
        url: URL(string: "https://preview.utxorpc-v0.demeter.run")!,
        headers: ["dmtr-api-key": apiKey]
    ),
    network: .preview,
    wrapping: blockfrost
)
```

The context's ``UTxORPCChainContext/name`` is then `"UTxO RPC + Blockfrost"`.

### cardano-node-api (`v1alpha`)

```swift
let legacy = try UTxORPCChainContext(
    endpoint: try UTxORPCEndpoint(
        url: URL(string: "http://node-api.local:9090")!,  // your server's gRPC address
        apiVersion: .v1alpha
    ),
    network: .preprod,
    wrapping: ogmios
)
```

### One Connection, or One per Call

`init(endpoint:network:wrapping:)` keeps one connection open for all calls; it reconnects on
its own and closes when the last context holding it goes away. To open a fresh connection for
each call instead — nothing stays open between calls, at the cost of a new connection (and,
for TLS, a handshake) every time — pass a ``UTxORPCEndpointConnector``:

```swift
let context = UTxORPCChainContext(
    connector: UTxORPCEndpointConnector(endpoint: .unixSocket("/ipc/rpc.sock")),
    network: .preview
)
```

Conform your own type to ``UTxORPCConnector`` to run calls over another transport, such as an
in-process server in tests.

## Reading Chain Data

### UTxOs

```swift
let address = try Address(from: .string("addr_test1..."))
let utxos   = try await context.utxos(address: address)

if let (utxo, isSpent) = try await context.utxo(input: input) {
    print("\(utxo.output.amount.coin) lovelace, spent: \(isSpent)")
}
```

`utxos(address:)` pages through `SearchUtxos` until it has every output. `utxo(input:)` reads
the live UTxO set, so a spent output is not found there; the wrapped context, if any, is then
asked — wrap a ``KupoChainContext`` to learn whether an output was spent.

### Parameters, Epoch and Tip

```swift
let params  = try await context.protocolParameters()
let genesis = try await context.genesisParameters()
let epoch   = try await context.epoch()
let tip     = try await context.chainTip()
```

- Protocol parameters come from `ReadParams`. A server whose parameters leave out the Conway
  governance fields (cardano-node-api) cannot fill them in, so the wrapped context answers.
- Genesis parameters come from `ReadGenesis`, or from the wrapped context on a server without
  it, and are kept for the life of the context.
- The epoch is worked out from the tip slot, using the server's era summary when it has one.
  cardano-node 11.1.x has none; the epoch then comes from the genesis parameters and the
  network's known Byron–Shelley transition.
- ``UTxORPCChainContext/chainTip()`` leaves the block height `nil` when the server does not
  report it (Dolos), and sync progress `nil` when the tip has no timestamp.

### Transactions Already on Chain

``UTxORPCChainContext/transactionCBOR(hash:)`` uses `ReadTx`, which Dolos serves and
cardano-node does not; it then falls back to the wrapped context.

## Submitting and Evaluating Transactions

```swift
let txId  = try await context.submitTx(tx: .transaction(transaction))
let units = try await context.evaluateTx(tx: transaction)
```

A rejected submission throws ``CardanoChainError/transactionFailed(_:)`` with the server's
reason.

Evaluation asks the server's `EvalTx` first. A transaction being built is not signed or
balanced yet, so ledger-rule complaints are expected. When the server reports only such
complaints and no script error (Dolos, and so Demeter, refuses an unsigned transaction with
`VKWitnessMissing`), or has no `EvalTx` at all (cardano-node-api), the scripts are evaluated
locally instead, with inputs read through `ReadUtxos` (or the wrapped context) and this
context's protocol parameters and slot timeline. If local evaluation cannot run either, the
server's report stands. A failing script throws ``CardanoChainError/transactionFailed(_:)``.
Local evaluation prices scripts with the server's cost models, which on Demeter can lag the
network's.

## What UTxO RPC Can and Cannot Answer

| Query | Source |
|---|---|
| UTxOs by address or output reference | `SearchUtxos` / `ReadUtxos` |
| Protocol parameters | `ReadParams`, or the wrapped context when the Conway fields are missing |
| Genesis parameters | `ReadGenesis`, or the wrapped context |
| Tip, epoch, era | `ReadTip`, `ReadEraSummary`, and cardano-node's own `GetEra` |
| Transaction CBOR | `ReadTx` (Dolos), or the wrapped context |
| Submit, evaluate | `SubmitTx`, `EvalTx` with local fallback |
| Stake pools | The wrapped context if there is one, otherwise `ReadState`'s stake pool distribution |
| Stake addresses, pool details, KES info, treasury, governance, stake distributions, committee | Wrapped context only |

Some differences between servers are worth planning around:

- **cardano-node** serves a live ledger view: it cannot look a transaction up by hash, and its
  `SearchUtxos` only matches exact addresses.
- **Without a wrapped context, ``UTxORPCChainContext/stakePools()`` lists only pools with
  delegated stake.** `ReadState` reports the stake pool distribution, so a pool that is
  registered but has no stake is left out. A wrapped context's list is complete and is used
  whenever one is present.
- **cardano-node-api** has no `ReadGenesis`, `EvalTx` or `ReadTx`, so it needs a wrapped
  context for genesis and protocol parameters, and with them the epoch and tip.

## Error Handling

```swift
do {
    let utxos = try await context.utxos(address: address)
} catch CardanoChainError.notImplemented(let message) {
    print("Not served here: \(message ?? "unknown")")
} catch CardanoChainError.operationError(let message) {
    print("UTxO RPC call failed: \(message ?? "unknown")")
} catch CardanoChainError.transactionFailed(let message) {
    print("Rejected: \(message ?? "unknown")")
} catch {
    print("Unexpected error: \(error)")
}
```

- A gRPC `UNIMPLEMENTED` that the context cannot route elsewhere becomes
  ``CardanoChainError/notImplemented(_:)``.
- Any other gRPC error becomes ``CardanoChainError/operationError(_:)``, naming the method and
  status code.
- A response that cannot be read becomes ``CardanoChainError/valueError(_:)``.
- Errors from a wrapped context pass through as that context throws them.

## Caching Behaviour

| Data | Cache lifetime |
|---|---|
| Genesis parameters | Permanent |
| Whether the server has an era summary / `cardano.rpc.Node` | Permanent, once found missing |
| Protocol parameters, tip, epoch | Not cached — read on every call |
| UTxOs | Not cached |

## See Also

- ``UTxORPCChainContext``
- ``UTxORPCConnector``
- ``UTxORPCConnectionConnector``
- ``UTxORPCEndpointConnector``
- ``KupoChainContext``
- ``ChainContext``
- ``CardanoChainError``
