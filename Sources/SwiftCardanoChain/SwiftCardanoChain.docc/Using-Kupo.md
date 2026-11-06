# Using KupoChainContext

Read outputs, datums and scripts from a Kupo chain index, alone or in front of another context.

## Overview

``KupoChainContext`` reads from a [Kupo](https://cardanosolutions.github.io/kupo) chain index
through [swift-kupo](https://github.com/Kingpin-Apps/swift-kupo). Kupo indexes transaction
outputs by address, asset or output reference, together with their datums and reference
scripts, and — unless it prunes them — keeps spent outputs with the point they were spent
at. That lets it answer two things a node answers slowly or not at all: every output at an
address, and whether an output has been spent.

Kupo only indexes outputs. Everything else — protocol parameters, the tip, submitting and
evaluating transactions, stake and governance queries — goes to the context it wraps,
usually an ``OgmiosChainContext`` talking to the same node. Without a wrapped context those
calls throw ``CardanoChainError/notImplemented(_:)``.

The context is a plain struct and is built by default on every platform the package supports.

**Supported networks:** any network the Kupo server indexes. The `network` you pass sets the
context's ``KupoChainContext/networkId``; the data comes from whatever Kupo is following.

## Prerequisites

- A running Kupo server (port `1442` by default), synced with the network you want.
- For anything beyond outputs, datums and scripts: another context to wrap, such as Ogmios
  connected to the same node.

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.16.1")
```

## Creating a Context

### Kupo with Ogmios (Recommended)

```swift
import Foundation
import SwiftCardanoChain

let ogmios = try await OgmiosChainContext(host: "localhost", port: 1337, network: .preview)

let context = try KupoChainContext(
    url: URL(string: "http://localhost:1442")!,
    network: .preview,
    wrapping: ogmios
)
```

The context's ``KupoChainContext/name`` is then `"Kupo + Ogmios"`. Any ``ChainContext`` can
be wrapped — BlockFrost, a ``UTxORPCChainContext``, and so on.

### Kupo Alone

```swift
let kupo = try KupoChainContext(network: .preview)   // http://localhost:1442
```

On its own the context answers only what Kupo indexes: ``KupoChainContext/utxos(address:)``,
``KupoChainContext/utxo(input:)``, and the datum and script lookups below.

### From a swift-kupo Client

Pass a `Kupo` or its generated `Client` to reuse a transport or to test against canned
responses:

```swift
import SwiftKupo

let context = KupoChainContext(
    kupo: try Kupo(basePath: "https://kupo.example.com"),
    network: .mainnet,
    wrapping: ogmios
)

let mocked = KupoChainContext(client: myClient, network: .preview)
```

The `url:` initialiser throws only when swift-kupo cannot turn the URL into a base path; the
`kupo:` and `client:` initialisers do not throw. None of them contact the server.

## Reading Outputs

### UTxOs at an Address

```swift
let address = try Address(from: .string("addr_test1..."))
let utxos   = try await context.utxos(address: address)

for utxo in utxos {
    print("\(utxo.input.transactionId.payload.toHex)#\(utxo.input.index)")
    print("  \(utxo.output.amount.coin) lovelace")
}
```

Only unspent outputs are returned. Inline datums and reference scripts are filled in on each
output; when Kupo's match does not carry the datum or script itself, it is fetched by its hash.

### One Output, and Whether It Was Spent

```swift
if let (utxo, isSpent) = try await context.utxo(input: input) {
    print("\(utxo.output.amount.coin) lovelace, spent: \(isSpent)")
}
```

Unlike a node, Kupo can report `isSpent: true`. When Kupo has no record of the output — it
was never indexed, or Kupo pruned it — the wrapped context is asked instead; without one the
answer is `nil`.

### Datums and Scripts by Hash

```swift
// The datum, decoded, or nil when Kupo has not seen it
let datum = try await context.datum(hash: datumHash)

// The same datum as raw CBOR
let cbor = try await context.datumCBOR(hash: datumHash)

// A native or Plutus script, checked against its hash, or nil when Kupo has not seen it
let script = try await context.script(hash: scriptHash)
```

Kupo only stores datums and scripts it has seen on chain, so these return `nil` for anything
Kupo did not index. A script whose bytes do not hash to the requested hash throws
``CardanoChainError/valueError(_:)``.

## Everything Else

All other ``ChainContext`` calls are forwarded unchanged to the wrapped context:

```swift
let params = try await context.protocolParameters()       // from Ogmios
let txId   = try await context.submitTx(tx: .transaction(transaction))
let units  = try await context.evaluateTx(tx: transaction)
```

What those calls can do is whatever the wrapped context can do; see its guide.

## Limitations

| Feature | Kupo alone | Kupo + wrapped context |
|---|:---:|:---:|
| UTxOs at an address | ✓ | ✓ (from Kupo) |
| One UTxO, with spent status | ✓ | ✓ (Kupo first, then the wrapped context) |
| Datums and scripts by hash | ✓ | ✓ (from Kupo) |
| Protocol / genesis parameters, epoch, era, tip | — | Wrapped context |
| Submit and evaluate transactions | — | Wrapped context |
| Transaction lookup, stake, pool and governance queries | — | Wrapped context |

“—” means the call throws ``CardanoChainError/notImplemented(_:)``.

Kupo has to be told what to index when it starts. An address or asset outside its match
patterns is simply not there, and `utxos(address:)` returns an empty list for it rather than
an error.

## Error Handling

A failed Kupo request surfaces as ``CardanoChainError/operationError(_:)``; data Kupo returns
that cannot be read surfaces as ``CardanoChainError/valueError(_:)``. Errors from a wrapped
context pass through as that context throws them.

```swift
do {
    let utxos = try await context.utxos(address: address)
} catch CardanoChainError.operationError(let message) {
    print("Kupo request failed: \(message ?? "unknown")")
} catch CardanoChainError.notImplemented(let message) {
    print("Needs a wrapped context: \(message ?? "unknown")")
} catch {
    print("Unexpected error: \(error)")
}
```

## Caching Behaviour

``KupoChainContext`` keeps no cache of its own: every output, datum and script lookup is a
request to Kupo. Forwarded calls are cached, or not, by the wrapped context.

## See Also

- ``KupoChainContext``
- ``OgmiosChainContext``
- ``ChainContext``
- ``CardanoChainError``
