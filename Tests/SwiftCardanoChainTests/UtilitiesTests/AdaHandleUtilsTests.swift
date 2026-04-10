import Foundation
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoChain

@Suite("AdaHandleUtils Utilities Tests")
struct AdaHandleUtilsUtilitiesTests {

    @Suite("Normalization")
    struct NormalizationTests {

        @Test("normalizeHandle trims, strips $, and lowercases")
        func testNormalizeHandle() {
            #expect(normalizeHandle("$Alice") == "alice")
            #expect(normalizeHandle("  $ALICE@Sub  ") == "alice@sub")
            #expect(normalizeHandle("NoPrefix") == "noprefix")
        }

        @Test("isSubHandle detects @")
        func testIsSubHandle() {
            #expect(isSubHandle("alice@sub"))
            #expect(!isSubHandle("alice"))
        }
    }

    @Suite("Asset Helpers")
    struct AssetHelperTests {

        @Test("convertAssetNameToHex converts UTF-8 bytes to lowercase hex")
        func testConvertAssetNameToHex() {
            #expect(convertAssetNameToHex("alice") == "616c696365")
            #expect(convertAssetNameToHex("A") == "41")
            #expect(convertAssetNameToHex("") == "")
        }

        @Test("assetFingerprint combines policy and asset name hex")
        func testAssetFingerprint() {
            let policyId = "policy123"
            let assetNameHex = "616c696365"
            #expect(
                assetFingerprint(policyId: policyId, assetNameHex: assetNameHex)
                    == "policy123.616c696365")
        }
    }

    @Suite("Network Policy IDs")
    struct NetworkPolicyIdTests {

        @Test("getPolicyId returns configured values for supported networks")
        func testGetPolicyIdSupportedNetworks() throws {
            let expected = "f0ff48bbb7bbe9d59a40f1ce90e9e9d0ff5002ec48f232b49ca0fb9a"
            #expect(try getPolicyId(for: .mainnet) == expected)
            #expect(try getPolicyId(for: .preprod) == expected)
            #expect(try getPolicyId(for: .preview) == expected)
            #expect(try getPolicyId(for: .guildnet) == "")
        }

        @Test("getPolicyId throws for unsupported network")
        func testGetPolicyIdUnsupportedNetwork() {
            #expect(throws: AdaHandleError.self) {
                _ = try getPolicyId(for: .sanchonet)
            }
        }
    }

    @Suite("Address Validation")
    struct AddressValidationTests {

        @Test("validatePaymentAddress accepts payment address")
        func testValidatePaymentAddressAcceptsPaymentAddress() throws {
            let paymentAddress = "addr1v84rja0gwv0c8aexdlchaglrtwnjfxn946zs52uxtrxy5mqjr4vwn"
            try validatePaymentAddress(paymentAddress)
        }

        @Test("validatePaymentAddress rejects stake address")
        func testValidatePaymentAddressRejectsStakeAddress() {
            let stakeAddress = "stake1u9ylzsgxaa6xctf4juup682ar3juj85n8tx3hthnljg47zctvm3rc"

            do {
                try validatePaymentAddress(stakeAddress)
                Issue.record("Expected AdaHandleError.adahandleInvalidAddress")
            } catch AdaHandleError.adahandleInvalidAddress(let badAddress) {
                #expect(badAddress == stakeAddress)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Suite("Datum Parsing")
    struct DatumParsingTests {

        @Test("extractResolvedAddressFromDatum returns nil when key is missing")
        func testExtractResolvedAddressFromDatumMissingKey() throws {
            let noKeyDatum = "deadbeef"
            let result = try extractResolvedAddressFromDatum(
                datumHex: noKeyDatum, network: .mainnet)
            #expect(result == nil)
        }

        @Test("extractResolvedAddressFromDatum returns nil when address pattern is missing")
        func testExtractResolvedAddressFromDatumMissingAddressPattern() throws {
            let datumWithKeyOnly = AdaHandleConstants.datumResolvedKeyHex + "abcd1234"
            let result = try extractResolvedAddressFromDatum(
                datumHex: datumWithKeyOnly, network: .mainnet)
            #expect(result == nil)
        }

        @Test("extractResolvedAddressFromDatum returns nil for invalid address bytes")
        func testExtractResolvedAddressFromDatumInvalidAddressHex() throws {
            let invalidAddressPayload = String(repeating: "zz", count: 57)
            let datum =
                AdaHandleConstants.datumResolvedKeyHex + "436164615839" + invalidAddressPayload
            let result = try extractResolvedAddressFromDatum(datumHex: datum, network: .mainnet)
            #expect(result == nil)
        }
    }
}
