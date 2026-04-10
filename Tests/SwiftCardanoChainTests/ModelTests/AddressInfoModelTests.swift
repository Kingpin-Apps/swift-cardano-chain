import Foundation
import SwiftCardanoCore
import SystemPackage
import Testing

@testable import SwiftCardanoChain

@Suite("AddressInfo Model Tests")
struct AddressInfoModelTests {

    @Test("init from payment address infers payment Shelley metadata")
    func initFromPaymentAddressString() throws {
        let info = try AddressInfo(fromAddressString: ModelTestFixtures.paymentAddressString)

        #expect(info.address != nil)
        #expect(info.type == .payment)
        #expect(info.era == .shelley)
        #expect(info.adaHandle == nil)
        #expect(info.used == false)
        #expect(info.utxos.isEmpty)
        #expect(info.stakeAddressInfo.isEmpty)
    }

    @Test("init from stake address infers stake Shelley metadata")
    func initFromStakeAddressString() throws {
        let info = try AddressInfo(fromAddressString: ModelTestFixtures.stakeAddressString)

        #expect(info.address != nil)
        #expect(info.type == .stake)
        #expect(info.era == .shelley)
    }

    @Test("init from file loads address and defaults name from filename stem")
    func initFromFileLoadsAddress() throws {
        let path = ModelTestFixtures.temporaryFilePath(named: "wallet", extension: "addr")
        defer { try? FileManager.default.removeItem(atPath: path.string) }

        try ModelTestFixtures.write(ModelTestFixtures.paymentAddressString, to: path)
        let info = try AddressInfo(fromFile: path)

        #expect(info.addressFile?.string == path.string)
        #expect(try info.address?.toBech32() == ModelTestFixtures.paymentAddressString)
        #expect(info.name == "wallet")
        #expect(info.type == .payment)
        #expect(info.era == .shelley)
    }

    @Test("custom name is preserved when loading from file")
    func initFromFilePreservesCustomName() throws {
        let path = ModelTestFixtures.temporaryFilePath(named: "ignored-name", extension: "addr")
        defer { try? FileManager.default.removeItem(atPath: path.string) }

        try ModelTestFixtures.write(ModelTestFixtures.paymentAddressString, to: path)
        let info = try AddressInfo(fromFile: path, name: "Treasury Wallet")

        #expect(info.name == "Treasury Wallet")
    }

    @Test("ada handle defaults name to normalized handle")
    func initFromAdaHandleDefaultsName() throws {
        let info = try AddressInfo(fromAdaHandle: "$ALICE")

        #expect(info.adaHandle == "$alice")
        #expect(info.name == "$ALICE")
        #expect(info.address == nil)
        #expect(info.type == nil)
    }

    @Test("subhandle format is accepted")
    func initFromAdaHandleSubhandle() throws {
        let info = try AddressInfo(fromAdaHandle: "$alice@bob")

        #expect(info.adaHandle == "$alice@bob")
    }

    @Test("missing identifiers throws")
    func initWithoutIdentifierThrows() throws {
        #expect(throws: (any Error).self) {
            _ = try AddressInfo()
        }
    }

    @Test("invalid ada handle format throws")
    func initFromInvalidAdaHandleThrows() throws {
        #expect(throws: (any Error).self) {
            _ = try AddressInfo(fromAdaHandle: "notahandle")
        }
    }

    @Test("direct init stores optional metadata")
    func initStoresOptionalMetadata() throws {
        let address = try Address(from: .string(ModelTestFixtures.paymentAddressString))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let info = try AddressInfo(
            address: address,
            base16: "aabbcc",
            encoding: "bech32",
            totalAmount: 5_000_000,
            totalAssetCount: 2,
            date: date,
            used: true
        )

        #expect(info.base16 == "aabbcc")
        #expect(info.encoding == "bech32")
        #expect(info.totalAmount == 5_000_000)
        #expect(info.totalAssetCount == 2)
        #expect(info.date == date)
        #expect(info.used == true)
    }

    @Test("description prefers address over other identifiers")
    func descriptionReturnsAddressBech32() throws {
        let info = try AddressInfo(fromAddressString: ModelTestFixtures.paymentAddressString)

        #expect(info.description == ModelTestFixtures.paymentAddressString)
    }

    @Test("description falls back to ada handle")
    func descriptionReturnsAdaHandle() throws {
        let info = try AddressInfo(fromAdaHandle: "$alice")

        #expect(info.description == "$alice")
    }

    @Test("address type prefix detection is case insensitive")
    func addressTypeFromBech32Prefix() {
        #expect(AddressInfo.AddressType(fromAddressBech32: "ADDR_TEST1Q...") == .payment)
        #expect(AddressInfo.AddressType(fromAddressBech32: "STAKE_TEST1U...") == .stake)
        #expect(AddressInfo.AddressType(fromAddressBech32: "pool1qq...") == nil)
    }

    @Test("address type and era descriptions are human readable")
    func nestedDescriptions() {
        #expect(AddressInfo.AddressType.payment.description == "Payment")
        #expect(AddressInfo.AddressType.stake.description == "Stake")
        #expect(AddressInfo.AddressEra.byron.description == "Byron")
        #expect(AddressInfo.AddressEra.shelley.description == "Shelley")
    }

    @Test("address era infers Shelley for enterprise address")
    func addressEraFromEnterpriseAddress() throws {
        let enterpriseAddress = try Address(
            from: .string("addr_test1vr2p8st5t5cxqglyjky7vk98k7jtfhdpvhl4e97cezuhn0cqcexl7")
        )

        #expect(AddressInfo.AddressEra(fromAddress: enterpriseAddress) == .shelley)
    }
}
