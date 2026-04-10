import Foundation
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoChain

@Suite("AdaHandleUtils Tests")
struct AdaHandleUtilsTests {

    @Suite("Normalization")
    struct NormalizationTests {

        @Test("normalizeHandle trims, strips $, and lowercases")
        func testNormalizeHandle() {
            #expect(normalizeHandle("$Alice") == "alice")
            #expect(normalizeHandle("  $ALICE@Sub  ") == "alice@sub")
            #expect(normalizeHandle("NoPrefix") == "noprefix")
            #expect(normalizeHandle("$alice@bob") == "alice@bob")
        }

        @Test("isSubHandle detects @")
        func testIsSubHandle() {
            #expect(isSubHandle("alice@sub"))
            #expect(!isSubHandle("alice"))
            #expect(isSubHandle("alice@bob@charlie"))
        }
    }

    @Suite("Ada Handle Format Validation")
    struct AdaHandleFormatValidationTests {

        @Test("valid root handles return normalized lowercase values")
        func testValidRootHandles() throws {
            let validHandles = [
                "$alice", "$bob123", "$my_handle", "$a-b.c", "$a", "$abcdefghijklmno",
            ]

            for handle in validHandles {
                #expect(try checkAdaHandleFormat(handle) == handle.lowercased())
            }
        }

        @Test("valid sub handles return normalized lowercase values")
        func testValidSubHandles() throws {
            let validHandles = ["$alice@bob", "$root1@sub2", "$my-handle@sub_domain"]

            for handle in validHandles {
                #expect(try checkAdaHandleFormat(handle) == handle.lowercased())
            }
        }

        @Test("mixed-case handles normalize to lowercase")
        func testMixedCaseHandleNormalization() throws {
            #expect(try checkAdaHandleFormat("$ALICE") == "$alice")
            #expect(try checkAdaHandleFormat("$MyHandle123") == "$myhandle123")
        }

        @Test("invalid handle formats throw")
        func testInvalidHandleFormatsThrow() {
            let invalidHandles: [String?] = [
                "alice",
                "$thishandleiswaytoolong",
                "$",
                "$alice!",
                "$alice space",
                nil,
            ]

            for handle in invalidHandles {
                #expect(throws: (any Error).self) {
                    _ = try checkAdaHandleFormat(handle)
                }
            }
        }
    }

    @Suite("Root Ada Handle Validation")
    struct RootHandleValidationTests {

        @Test("valid root handles return true")
        func testValidRootHandleValues() {
            #expect(isValidAdaRootHandle("$alice"))
            #expect(isValidAdaRootHandle("$bob123"))
            #expect(isValidAdaRootHandle("$my_handle"))
            #expect(isValidAdaRootHandle("$a-b.c"))
        }

        @Test("invalid root handles return false")
        func testInvalidRootHandleValues() {
            #expect(!isValidAdaRootHandle(nil))
            #expect(!isValidAdaRootHandle("alice"))
            #expect(!isValidAdaRootHandle("$"))
            #expect(!isValidAdaRootHandle("$thisistoolongforhandle"))
            #expect(!isValidAdaRootHandle("$alice@bob"))
            #expect(!isValidAdaRootHandle("$alice!"))
        }
    }

    @Suite("Sub Ada Handle Validation")
    struct SubHandleValidationTests {

        @Test("valid sub handles return true")
        func testValidSubHandleValues() {
            #expect(isValidAdaSubHandle("$alice@bob"))
            #expect(isValidAdaSubHandle("$root1@sub2"))
            #expect(isValidAdaSubHandle("$my-handle@sub_domain"))
        }

        @Test("invalid sub handles return false")
        func testInvalidSubHandleValues() {
            #expect(!isValidAdaSubHandle(nil))
            #expect(!isValidAdaSubHandle("$alice"))
            #expect(!isValidAdaSubHandle("alice@bob"))
            #expect(!isValidAdaSubHandle("$@bob"))
            #expect(!isValidAdaSubHandle("$alice@"))
            #expect(!isValidAdaSubHandle("$thisistoolongforrootpart@bob"))
        }
    }

    @Suite("Asset Helpers")
    struct AssetHelperTests {

        @Test("convertAssetNameToHex converts UTF-8 bytes to lowercase hex")
        func testConvertAssetNameToHex() {
            #expect(convertAssetNameToHex("alice") == "616c696365")
            #expect(convertAssetNameToHex("A") == "41")
            #expect(convertAssetNameToHex("") == "")
            #expect(convertAssetNameToHex("ada") == "616461")
            #expect(convertAssetNameToHex("ab") == "6162")
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
            #expect(throws: AdaHandleError.self) {
                _ = try getPolicyId(for: .custom(9999))
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

        @Test("createHandlesClient throws for non-mainnet networks")
        func testCreateHandlesClientThrowsForNonMainnetNetworks() {
            #expect(throws: (any Error).self) {
                _ = try createHandlesClient(network: .preview)
            }
            #expect(throws: (any Error).self) {
                _ = try createHandlesClient(network: .preprod)
            }
            #expect(throws: (any Error).self) {
                _ = try createHandlesClient(network: .sanchonet)
            }
        }
    }

    @Suite("Datum Parsing")
    struct DatumParsingTests {

        @Test("extractResolvedAddressFromDatum returns nil for empty hex")
        func testExtractResolvedAddressFromDatumEmptyHex() throws {
            let result = try extractResolvedAddressFromDatum(datumHex: "", network: .mainnet)
            #expect(result == nil)
        }

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
