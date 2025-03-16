import Testing

@testable import SwiftCardanoChain

@Suite("Network Tests")
struct NetworkTests {
    @Test func testNetworkTestnetMagic() {
        // Test mainnet (should be nil)
        #expect(Network.mainnet.testnetMagic == nil)

        // Test testnet networks (should have specific magic numbers)
        #expect(Network.preprod.testnetMagic == 1)
        #expect(Network.preview.testnetMagic == 2)
        #expect(Network.guildnet.testnetMagic == 141)
        #expect(Network.sanchonet.testnetMagic == 4)

        // Test custom network
        let customMagic = 999
        #expect(Network.custom(customMagic).testnetMagic == customMagic)
    }

    @Test func testNetworkDescription() {
        // Test descriptions for predefined networks
        #expect(Network.mainnet.description == "mainnet")
        #expect(Network.preprod.description == "preprod")
        #expect(Network.preview.description == "preview")
        #expect(Network.guildnet.description == "guildnet")
        #expect(Network.sanchonet.description == "sanchonet")

        // Test description for custom network
        let customMagic = 999
        #expect(Network.custom(customMagic).description == "custom(\(customMagic))")
    }

    @Test func testNetworkArguments() {
        // Test mainnet arguments
        #expect(Network.mainnet.arguments == ["--mainnet"])

        // Test testnet network arguments
        #expect(Network.preprod.arguments == ["--testnet-magic", "1"])
        #expect(Network.preview.arguments == ["--testnet-magic", "2"])
        #expect(Network.guildnet.arguments == ["--testnet-magic", "141"])
        #expect(Network.sanchonet.arguments == ["--testnet-magic", "4"])

        // Test custom network arguments
        let customMagic = 999
        #expect(Network.custom(customMagic).arguments == ["--testnet-magic", "\(customMagic)"])
    }

    @Test func testNetworkEquality() async {
        // Create two instances of the same network type
        let mainnet1 = Network.mainnet
        let mainnet2 = Network.mainnet

        // Test equality using description as Network doesn't conform to Equatable
        #expect(mainnet1.description == mainnet2.description)

        // Test custom networks with same magic number
        let customMagic = 999
        let custom1 = Network.custom(customMagic)
        let custom2 = Network.custom(customMagic)

        #expect(custom1.description == custom2.description)
        #expect(custom1.testnetMagic == custom2.testnetMagic)
        #expect(custom1.arguments == custom2.arguments)
    }

    @Test func testNetworkArgumentsFormat() async {
        // Test that arguments are properly formatted for CLI use
        for network in [Network.preprod, Network.preview, Network.guildnet, Network.sanchonet] {
            let args = network.arguments
            #expect(args.count == 2)
            #expect(args[0] == "--testnet-magic")
            #expect(args[1] == "\(network.testnetMagic!)")
        }

        // Test mainnet separately as it has a different format
        let mainnetArgs = Network.mainnet.arguments
        #expect(mainnetArgs.count == 1)
        #expect(mainnetArgs[0] == "--mainnet")
    }
}
