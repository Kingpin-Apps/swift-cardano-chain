import Foundation
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoChain

@Suite("StakePoolInfo Model Tests")
struct StakePoolInfoModelTests {

    @Test("init with all fields stores values")
    func initWithAllFields() {
        let info = StakePoolInfo(
            poolParams: ModelTestFixtures.makeDummyPoolParams(),
            livePledge: 500_000_000,
            liveStake: 13_492_420_330,
            liveSize: Decimal(string: "0.0000142"),
            activeStake: 12_000_000_000,
            activeSize: Decimal(string: "0.0000126"),
            opcertCounter: 5,
            status: .retiring(epoch: 42)
        )

        #expect(info.livePledge == 500_000_000)
        #expect(info.liveStake == 13_492_420_330)
        #expect(info.liveSize == Decimal(string: "0.0000142"))
        #expect(info.activeStake == 12_000_000_000)
        #expect(info.activeSize == Decimal(string: "0.0000126"))
        #expect(info.opcertCounter == 5)
        if case .retiring(let epoch)? = info.status {
            #expect(epoch == 42)
        } else {
            Issue.record("Expected retiring status")
        }
    }

    @Test("minimal init leaves optionals empty")
    func initWithMinimalFields() {
        let info = StakePoolInfo(poolParams: ModelTestFixtures.makeDummyPoolParams())

        #expect(info.livePledge == nil)
        #expect(info.liveStake == nil)
        #expect(info.liveSize == nil)
        #expect(info.activeStake == nil)
        #expect(info.activeSize == nil)
        #expect(info.opcertCounter == nil)
        #expect(info.status == nil)
    }

    @Test("fields remain mutable after init")
    func fieldsAreMutable() {
        var info = StakePoolInfo(poolParams: ModelTestFixtures.makeDummyPoolParams())

        info.livePledge = 1_000_000
        info.liveStake = 5_000_000_000
        info.liveSize = Decimal(0.001)
        info.activeStake = 4_000_000_000
        info.activeSize = Decimal(0.0008)
        info.opcertCounter = 3
        info.status = .registered

        #expect(info.livePledge == 1_000_000)
        #expect(info.liveStake == 5_000_000_000)
        #expect(info.liveSize == Decimal(0.001))
        #expect(info.activeStake == 4_000_000_000)
        #expect(info.activeSize == Decimal(0.0008))
        #expect(info.opcertCounter == 3)
        if case .registered? = info.status {
        } else {
            Issue.record("Expected registered status")
        }
    }

    @Test("pool params remain accessible through model")
    func poolParamsAccessible() {
        let info = StakePoolInfo(poolParams: ModelTestFixtures.makeDummyPoolParams())

        #expect(info.poolParams.pledge == 500_000_000)
        #expect(info.poolParams.cost == 340_000_000)
    }

    @Test("decimal size values can represent stake fraction")
    func liveSizeDecimalFraction() {
        let liveSize = Decimal(13_492_420_330) / Decimal(950_528_788_771_851)
        let info = StakePoolInfo(
            poolParams: ModelTestFixtures.makeDummyPoolParams(),
            liveSize: liveSize
        )

        #expect(info.liveSize != nil)
        #expect(info.liveSize! > 0)
        #expect(info.liveSize! < 1)
    }
}

private struct DummyNetworkValues: NetworkDependable {
    var mainnet: String { "mainnet" }
    var preprod: String? { "preprod" }
    var preview: String? { "preview" }
    var guildnet: String? { "guildnet" } 
}

@Suite("NetworkProtocols Model Tests")
struct NetworkDependableModelTests {

    @Test("forNetwork returns configured values for supported networks")
    func forNetworkReturnsConfiguredValue() {
        let values = DummyNetworkValues()

        #expect(values.forNetwork(.mainnet) == "mainnet")
        #expect(values.forNetwork(.preprod) == "preprod")
        #expect(values.forNetwork(.preview) == "preview")
        #expect(values.forNetwork(.guildnet) == "guildnet")
    }

    @Test("forNetwork returns nil for unsupported networks")
    func forNetworkReturnsNilForUnsupportedNetwork() {
        let values = DummyNetworkValues()

        #expect(values.forNetwork(.sanchonet) == nil)
        #expect(values.forNetwork(.custom(999)) == nil)
    }
}

@Suite("KESPeriodInfo Model Tests")
struct KESPeriodInfoModelTests {

    @Test("init stores all counters")
    func initStoresAllCounters() {
        let info = KESPeriodInfo(
            onChainOpCertCount: 12,
            onDiskOpCertCount: 13,
            nextChainOpCertCount: 14,
            onDiskKESStart: 800
        )

        #expect(info.onChainOpCertCount == 12)
        #expect(info.onDiskOpCertCount == 13)
        #expect(info.nextChainOpCertCount == 14)
        #expect(info.onDiskKESStart == 800)
    }

    @Test("default init leaves all values nil")
    func defaultInitLeavesValuesNil() {
        let info = KESPeriodInfo()

        #expect(info.onChainOpCertCount == nil)
        #expect(info.onDiskOpCertCount == nil)
        #expect(info.nextChainOpCertCount == nil)
        #expect(info.onDiskKESStart == nil)
    }
}
