import Foundation
import SwiftCardanoCore
import SwiftCardanoNetwork
import SwiftCardanoUtils
import SystemPackage
import Testing

@testable import SwiftCardanoChain

// MARK: - Test Suite
//
// These tests cover deterministic, connection-free behavior of
// `NodeSocketChainContext`: configuration mapping, genesis conversion,
// and helper functions. End-to-end queries require a running
// `cardano-node` socket and are not exercised here.

@Suite("NodeSocket Chain Context Tests")
struct NodeSocketChainContextTests {

    // MARK: - Network ID

    @Test("Test network ID conversion")
    func testNetworkIdConversion() async throws {
        #expect(Network.mainnet.networkId == .mainnet)
        #expect(Network.preprod.networkId == .testnet)
        #expect(Network.preview.networkId == .testnet)
    }

    // MARK: - Era from epoch

    @Test("Test era from epoch")
    func testEraFromEpoch() async throws {
        // Conway epoch boundary on mainnet is 507; pick well into Conway.
        let conwayEra = Era.fromEpoch(epoch: EpochNumber(550))
        #expect(conwayEra == .conway)

        // Byron era epoch.
        let byronEra = Era.fromEpoch(epoch: EpochNumber(0))
        #expect(byronEra == .byron)
    }

    // MARK: - Network configuration mapping

    @Test("networkConfigPreset returns matching preset for each network")
    func testNetworkConfigPreset() async throws {
        let mainnet = NodeSocketChainContext.networkConfigPreset(for: .mainnet)
        #expect(mainnet.connection.networkMagic == 764_824_073)

        let preview = NodeSocketChainContext.networkConfigPreset(for: .preview)
        #expect(preview.connection.networkMagic == 2)

        let preprod = NodeSocketChainContext.networkConfigPreset(for: .preprod)
        #expect(preprod.connection.networkMagic == 1)
    }

    @Test("makeNetworkConfig overrides socketPath but preserves base tunables")
    func testMakeNetworkConfigPreservesOverrides() async throws {
        var base = CardanoNetworkConfiguration.preview
        base.connection.connectTimeoutSeconds = 42.5
        base.connection.socketPath = "/should/be/replaced"
        base.protocol.ntcVersions = [99, 98]

        let merged = NodeSocketChainContext.makeNetworkConfig(
            socketPath: "/ipc/node.socket",
            network: .preview,
            base: base
        )

        #expect(merged.connection.socketPath == "/ipc/node.socket")
        #expect(merged.connection.connectTimeoutSeconds == 42.5)
        #expect(merged.protocol.ntcVersions == [99, 98])
        #expect(merged.connection.networkMagic == 2)  // preview magic preserved
    }

    @Test("makeNetworkConfig falls back to network preset when no base provided")
    func testMakeNetworkConfigFallsBackToPreset() async throws {
        let merged = NodeSocketChainContext.makeNetworkConfig(
            socketPath: "/ipc/node.socket",
            network: .mainnet,
            base: nil
        )

        #expect(merged.connection.socketPath == "/ipc/node.socket")
        #expect(merged.connection.networkMagic == 764_824_073)
    }

    // MARK: - init(cardanoConfig:) validation

    @Test("init(cardanoConfig:) throws when socket is nil")
    func testInitMissingSocketThrows() throws {
        let config = CardanoConfig(
            socket: nil,
            network: .preview,
            era: .conway,
            ttlBuffer: 3600
        )

        #expect(throws: CardanoChainError.self) {
            _ = try NodeSocketChainContext(cardanoConfig: config)
        }
    }

    // MARK: - Genesis conversion

    @Test("convertShelleyGenesis maps fields correctly")
    func testConvertShelleyGenesis() async throws {
        let path = Bundle.module.path(
            forResource: "shelley-genesis",
            ofType: "json",
            inDirectory: "data"
        )!
        let genesis = try ShelleyGenesis.load(from: path)

        let params = try NodeSocketChainContext.convertShelleyGenesis(
            genesis, network: .preview)

        #expect(params.activeSlotsCoefficient == genesis.activeSlotsCoeff)
        #expect(params.epochLength == Int(genesis.epochLength))
        #expect(params.maxKesEvolutions == Int(genesis.maxKESEvolutions))
        #expect(params.maxLovelaceSupply == Int(genesis.maxLovelaceSupply))
        #expect(params.networkId == genesis.networkId)
        #expect(params.networkMagic == Int(genesis.networkMagic))
        #expect(params.slotLength == Int(genesis.slotLength))
        #expect(params.securityParam == Int(genesis.securityParam))
        #expect(params.slotsPerKesPeriod == Int(genesis.slotsPerKESPeriod))
        #expect(
            params.systemStart
                == ISO8601DateFormatter().date(from: genesis.systemStart))
        #expect(params.updateQuorum == genesis.updateQuorum)
    }

    // MARK: - Point → slot extraction

    @Test("slot(from:) extracts slot from blockPoint and returns 0 for origin")
    func testSlotFromPoint() async throws {
        let originSlot = NodeSocketChainContext.slot(from: .origin)
        #expect(originSlot == 0)

        let blockSlot = NodeSocketChainContext.slot(
            from: .blockPoint(slot: 12_345, hash: BlockHash(Data(repeating: 0, count: 32))))
        #expect(blockSlot == 12_345)
    }

    // MARK: - kesPeriodInfo nil-pool guard

    @Test("kesPeriodInfo throws invalidArgument when pool is nil")
    func testKesPeriodInfoNilPoolThrows() async throws {
        let context = NodeSocketChainContext(
            socketPath: FilePath("/nonexistent/node.socket"),
            network: .preview
        )
        await #expect(throws: CardanoChainError.self) {
            _ = try await context.kesPeriodInfo(pool: nil, opCert: nil)
        }
    }

    // MARK: - Transaction data conversion

    @Test("Test transaction data conversion")
    func testTransactionDataConversion() async throws {
        let cborHex =
            "84a70081825820b35a4ba9ef3ce21adcd6879d08553642224304704d206c74d3ffb3e6eed3ca28000d80018182581d60cc30497f4ff962f4c1dca54cceefe39f86f1d7179668009f8eb71e598200a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680021a000493e00e8009a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680075820592a2df0e091566969b3044626faa8023dabe6f39c78f33bed9e105e55159221a200828258206443a101bdb948366fc87369336224595d36d8b0eee5602cba8b81a024e584735840846f408dee3b101fda0f0f7ca89e18b724b7ca6266eb29775d3967d6920cae7457accb91def9b77571e15dd2ede38b12cf92496ce7382fa19eb90ab7f73e49008258205797dc2cc919dfec0bb849551ebdf30d96e5cbe0f33f734a87fe826db30f7ef95840bdc771aa7b8c86a8ffcbe1b7a479c68503c8aa0ffde8059443055bf3e54b92f4fca5e0b9ca5bb11ab23b1390bb9ffce414fa398fc0b17f4dc76fe9f7e2c99c09018182018482051a075bcd1582041a075bcd0c8200581c9139e5c0a42f0f2389634c3dd18dc621f5594c5ba825d9a8883c66278200581c835600a2be276a18a4bebf0225d728f090f724f4c0acd591d066fa6ff5d90103a100a11902d1a16b7b706f6c6963795f69647da16d7b706f6c6963795f6e616d657da66b6465736372697074696f6e6a3c6f7074696f6e616c3e65696d6167656a3c72657175697265643e686c6f636174696f6ea367617277656176656a3c6f7074696f6e616c3e6568747470736a3c6f7074696f6e616c3e64697066736a3c72657175697265643e646e616d656a3c72657175697265643e667368613235366a3c72657175697265643e64747970656a3c72657175697265643e"

        let tx = try Transaction.fromCBORHex(cborHex)

        let txData1 = TransactionData.transaction(tx)
        if case .transaction(_) = txData1 {
            #expect(Bool(true))
        } else {
            #expect(Bool(false), "Expected .transaction case")
        }

        let cborData = Data(hex: cborHex)
        let txData2 = TransactionData.bytes(cborData)
        if case .bytes(let data) = txData2 {
            #expect(data.toHex == cborHex)
        }

        let txData3 = TransactionData.string(cborHex)
        if case .string(let str) = txData3 {
            #expect(str == cborHex)
        }
    }
}
