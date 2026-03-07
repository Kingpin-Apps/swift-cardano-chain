import Testing
import Foundation
import SwiftCardanoCore
import SystemPackage
@testable import SwiftCardanoChain


// MARK: - Test Helpers

/// Creates a minimal PoolParams suitable for testing (all zeros/default values).
func makeDummyPoolParams() -> PoolParams {
    let poolKeyHash = PoolKeyHash(payload: Data(repeating: 0x01, count: 28))
    let vrfKeyHash = VrfKeyHash(payload: Data(repeating: 0x02, count: 32))
    let rewardAccount = RewardAccountHash(payload: Data(repeating: 0x03, count: 29))
    let margin = UnitInterval(numerator: 1, denominator: 20)
    let poolOwners = ListOrOrderedSet<VerificationKeyHash>.list([])
    return PoolParams(
        poolOperator: poolKeyHash,
        vrfKeyHash: vrfKeyHash,
        pledge: 500_000_000,
        cost: 340_000_000,
        margin: margin,
        rewardAccount: rewardAccount,
        poolOwners: poolOwners,
        relays: [],
        poolMetadata: nil
    )
}


// MARK: - StakePoolInfo Tests

@Suite("StakePoolInfo Tests")
struct StakePoolInfoTests {

    @Test("Test init with all fields")
    func testInitWithAllFields() {
        let poolParams = makeDummyPoolParams()
        let info = StakePoolInfo(
            poolParams: poolParams,
            livePledge: 500_000_000,
            liveStake: 13_492_420_330,
            liveSize: Decimal(string: "0.0000142"),
            activeStake: 12_000_000_000,
            activeSize: Decimal(string: "0.0000126"),
            opcertCounter: 5
        )

        #expect(info.livePledge == 500_000_000)
        #expect(info.liveStake == 13_492_420_330)
        #expect(info.liveSize == Decimal(string: "0.0000142"))
        #expect(info.activeStake == 12_000_000_000)
        #expect(info.activeSize == Decimal(string: "0.0000126"))
        #expect(info.opcertCounter == 5)
    }

    @Test("Test init with minimal fields (only poolParams)")
    func testInitWithMinimalFields() {
        let poolParams = makeDummyPoolParams()
        let info = StakePoolInfo(poolParams: poolParams)

        #expect(info.livePledge == nil)
        #expect(info.liveStake == nil)
        #expect(info.liveSize == nil)
        #expect(info.activeStake == nil)
        #expect(info.activeSize == nil)
        #expect(info.opcertCounter == nil)
    }

    @Test("Test optional fields default to nil")
    func testOptionalFieldsDefaultToNil() {
        let poolParams = makeDummyPoolParams()
        let info = StakePoolInfo(poolParams: poolParams)

        #expect(info.livePledge == nil)
        #expect(info.liveStake == nil)
        #expect(info.liveSize == nil)
        #expect(info.activeStake == nil)
        #expect(info.activeSize == nil)
        #expect(info.opcertCounter == nil)
    }

    @Test("Test fields are mutable (var)")
    func testMutableFields() {
        let poolParams = makeDummyPoolParams()
        var info = StakePoolInfo(poolParams: poolParams)

        info.livePledge = 1_000_000
        info.liveStake = 5_000_000_000
        info.liveSize = Decimal(0.001)
        info.activeStake = 4_000_000_000
        info.activeSize = Decimal(0.0008)
        info.opcertCounter = 3

        #expect(info.livePledge == 1_000_000)
        #expect(info.liveStake == 5_000_000_000)
        #expect(info.liveSize == Decimal(0.001))
        #expect(info.activeStake == 4_000_000_000)
        #expect(info.activeSize == Decimal(0.0008))
        #expect(info.opcertCounter == 3)
    }

    @Test("Test poolParams is accessible")
    func testPoolParamsAccessible() {
        let poolParams = makeDummyPoolParams()
        let info = StakePoolInfo(poolParams: poolParams)

        #expect(info.poolParams.pledge == 500_000_000)
        #expect(info.poolParams.cost == 340_000_000)
    }

    @Test("Test pool info with liveSize as Decimal fraction")
    func testLiveSizeDecimalFraction() {
        let poolParams = makeDummyPoolParams()
        let liveSize = Decimal(13_492_420_330) / Decimal(950_528_788_771_851)
        let info = StakePoolInfo(poolParams: poolParams, liveSize: liveSize)

        #expect(info.liveSize != nil)
        #expect(info.liveSize! > 0)
        #expect(info.liveSize! < 1)
    }
}


// MARK: - AddressInfo Tests

@Suite("AddressInfo Tests")
struct AddressInfoTests {

    @Test("Test init from payment address string")
    func testInitFromPaymentAddressString() throws {
        let addressString = "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
        let info = try AddressInfo(fromAddressString: addressString)

        #expect(info.address != nil)
        #expect(info.type == .payment)
        #expect(info.era == .shelley)
        #expect(info.adaHandle == nil)
        #expect(info.used == false)
        #expect(info.utxos.isEmpty)
        #expect(info.stakeAddressInfo.isEmpty)
    }

    @Test("Test init from stake address string")
    func testInitFromStakeAddressString() throws {
        let addressString = "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n"
        let info = try AddressInfo(fromAddressString: addressString)

        #expect(info.address != nil)
        #expect(info.type == .stake)
        #expect(info.era == .shelley)
    }

    @Test("Test init with custom name")
    func testInitWithCustomName() throws {
        let addressString = "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
        let info = try AddressInfo(fromAddressString: addressString, name: "My Test Wallet")

        #expect(info.name == "My Test Wallet")
    }

    @Test("Test default name when not provided")
    func testDefaultNameWhenNotProvided() throws {
        let addressString = "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
        let info = try AddressInfo(fromAddressString: addressString)

        #expect(info.name == "Unnamed Address")
    }

    @Test("Test init from ada handle - valid root handle")
    func testInitFromAdaHandleValidRoot() throws {
        let info = try AddressInfo(fromAdaHandle: "$alice")

        #expect(info.adaHandle == "$alice")
        #expect(info.address == nil)   // Ada handle not resolved yet
        #expect(info.type == nil)       // Type unknown until resolved
    }

    @Test("Test init from ada handle - valid subhandle")
    func testInitFromAdaHandleValidSubhandle() throws {
        let info = try AddressInfo(fromAdaHandle: "$alice@bob")

        #expect(info.adaHandle == "$alice@bob")
    }

    @Test("Test init from ada handle - with custom name")
    func testInitFromAdaHandleWithCustomName() throws {
        let info = try AddressInfo(fromAdaHandle: "$myhandle", name: "My Handle")

        #expect(info.adaHandle == "$myhandle")
        #expect(info.name == "My Handle")
    }

    @Test("Test init from ada handle - name defaults to handle value")
    func testInitFromAdaHandleNameDefaultsToHandle() throws {
        let info = try AddressInfo(fromAdaHandle: "$myhandle")

        // Name defaults to adaHandle when no name provided
        #expect(info.name == "$myhandle")
    }

    @Test("Test init from ada handle - invalid format throws")
    func testInitFromAdaHandleInvalidFormat() throws {
        #expect(throws: (any Error).self) {
            _ = try AddressInfo(fromAdaHandle: "notahandle")
        }
    }

    @Test("Test init from ada handle - too long throws")
    func testInitFromAdaHandleTooLongThrows() throws {
        #expect(throws: (any Error).self) {
            _ = try AddressInfo(fromAdaHandle: "$thishandleiswaytoolong")
        }
    }

    @Test("Test init without any identifier throws")
    func testInitWithoutAnyIdentifierThrows() throws {
        #expect(throws: (any Error).self) {
            _ = try AddressInfo()
        }
    }

    @Test("Test description returns address bech32")
    func testDescriptionReturnsAddressBech32() throws {
        let addressString = "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
        let info = try AddressInfo(fromAddressString: addressString)

        // Description should contain the address
        #expect(!info.description.isEmpty)
        #expect(info.description.hasPrefix("addr"))
    }

    @Test("Test description returns ada handle when no address")
    func testDescriptionReturnsAdaHandle() throws {
        let info = try AddressInfo(fromAdaHandle: "$alice")
        #expect(info.description == "$alice")
    }

    @Test("Test address type description")
    func testAddressTypeDescription() {
        #expect(AddressInfo.AddressType.payment.description == "Payment")
        #expect(AddressInfo.AddressType.stake.description == "Stake")
    }

    @Test("Test address era description")
    func testAddressEraDescription() {
        #expect(AddressInfo.AddressEra.byron.description == "Byron")
        #expect(AddressInfo.AddressEra.shelley.description == "Shelley")
    }

    @Test("Test AddressType init from bech32 prefix - payment")
    func testAddressTypeFromBech32PrefixPayment() {
        let type1 = AddressInfo.AddressType(fromAddressBech32: "addr_test1qp4kux...")
        #expect(type1 == .payment)

        let type2 = AddressInfo.AddressType(fromAddressBech32: "addr1v...")
        #expect(type2 == .payment)
    }

    @Test("Test AddressType init from bech32 prefix - stake")
    func testAddressTypeFromBech32PrefixStake() {
        let type1 = AddressInfo.AddressType(fromAddressBech32: "stake_test1u...")
        #expect(type1 == .stake)

        let type2 = AddressInfo.AddressType(fromAddressBech32: "stake1u...")
        #expect(type2 == .stake)
    }

    @Test("Test AddressType init from bech32 prefix - unknown")
    func testAddressTypeFromBech32PrefixUnknown() {
        let type1 = AddressInfo.AddressType(fromAddressBech32: "drep1k...")
        #expect(type1 == nil)

        let type2 = AddressInfo.AddressType(fromAddressBech32: "pool1qqa8...")
        #expect(type2 == nil)
    }

    @Test("Test AddressType init case insensitive")
    func testAddressTypeFromBech32CaseInsensitive() {
        let type1 = AddressInfo.AddressType(fromAddressBech32: "ADDR_TEST1Q...")
        #expect(type1 == .payment)

        let type2 = AddressInfo.AddressType(fromAddressBech32: "STAKE_TEST1U...")
        #expect(type2 == .stake)
    }

    @Test("Test AddressEra from enterprise address is Shelley")
    func testAddressEraFromEnterpriseAddress() throws {
        // Enterprise addresses (addr_test1v...) are Shelley era
        // Note: Byron addresses use base58 encoding and cannot be parsed by Address(from: .string(...))
        let enterpriseAddress = try Address(from: .string("addr_test1vr2p8st5t5cxqglyjky7vk98k7jtfhdpvhl4e97cezuhn0cqcexl7"))
        let era = AddressInfo.AddressEra(fromAddress: enterpriseAddress)
        #expect(era == .shelley)
    }

    @Test("Test AddressEra from Shelley address")
    func testAddressEraFromShelleyAddress() throws {
        let shelleyAddress = try Address(from: .string("addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"))
        let era = AddressInfo.AddressEra(fromAddress: shelleyAddress)
        #expect(era == .shelley)
    }

    @Test("Test init from direct address with payment and staking parts")
    func testInitFromBaseAddress() throws {
        let addressString = "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
        let address = try Address(from: .string(addressString))
        let info = try AddressInfo(address: address)

        #expect(info.type == .payment)
        #expect(info.era == .shelley)
        #expect(info.address != nil)
    }

    @Test("Test init with all optional fields")
    func testInitWithAllOptionalFields() throws {
        let address = try Address(from: .string("addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"))
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

    @Test("Test ada handle is normalized to lowercase")
    func testAdaHandleNormalizedToLowercase() throws {
        let info = try AddressInfo(fromAdaHandle: "$ALICE")

        // checkAdaHandleFormat lowercases the handle
        #expect(info.adaHandle == "$alice")
    }

    @Test("Test ada handle numbers and special chars are valid")
    func testAdaHandleNumbersAndSpecialChars() throws {
        let info = try AddressInfo(fromAdaHandle: "$a1_b-2.c")
        #expect(info.adaHandle == "$a1_b-2.c")
    }
}


// MARK: - NetworkDependable Tests

@Suite("NetworkDependable Tests")
struct NetworkDependableTests {

    @Test("Test forNetwork mainnet")
    func testForNetworkMainnet() {
        let policyIds = AdaHandlePolicyIds()
        let result = policyIds.forNetwork(.mainnet)

        #expect(result != nil)
        #expect(result == "f0ff48bbb7bbe9d59a40f1ce90e9e9d0ff5002ec48f232b49ca0fb9a")
    }

    @Test("Test forNetwork preprod")
    func testForNetworkPreprod() {
        let policyIds = AdaHandlePolicyIds()
        let result = policyIds.forNetwork(.preprod)

        #expect(result != nil)
        #expect(result == "f0ff48bbb7bbe9d59a40f1ce90e9e9d0ff5002ec48f232b49ca0fb9a")
    }

    @Test("Test forNetwork preview")
    func testForNetworkPreview() {
        let policyIds = AdaHandlePolicyIds()
        let result = policyIds.forNetwork(.preview)

        #expect(result != nil)
        #expect(result == "f0ff48bbb7bbe9d59a40f1ce90e9e9d0ff5002ec48f232b49ca0fb9a")
    }

    @Test("Test forNetwork guildnet")
    func testForNetworkGuildnet() {
        let policyIds = AdaHandlePolicyIds()
        let result = policyIds.forNetwork(.guildnet)

        // Guildnet returns empty string (not nil, but empty)
        #expect(result != nil)
    }

    @Test("Test forNetwork custom returns nil")
    func testForNetworkCustomReturnsNil() {
        let policyIds = AdaHandlePolicyIds()
        let result = policyIds.forNetwork(.custom(9999))

        #expect(result == nil)
    }

    @Test("Test forNetwork sanchonet returns nil")
    func testForNetworkSanchonetReturnsNil() {
        let policyIds = AdaHandlePolicyIds()
        let result = policyIds.forNetwork(.sanchonet)

        #expect(result == nil)
    }

    @Test("Test mainnet property directly")
    func testMainnetPropertyDirectly() {
        let policyIds = AdaHandlePolicyIds()
        #expect(!policyIds.mainnet.isEmpty)
    }

    @Test("Test preprod property directly")
    func testPreprodPropertyDirectly() {
        let policyIds = AdaHandlePolicyIds()
        #expect(policyIds.preprod != nil)
    }

    @Test("Test preview property directly")
    func testPreviewPropertyDirectly() {
        let policyIds = AdaHandlePolicyIds()
        #expect(policyIds.preview != nil)
    }
}


// MARK: - AdaHandleUtils Tests

@Suite("AdaHandleUtils Tests")
struct AdaHandleUtilsTests {

    // MARK: checkAdaHandleFormat

    @Test("Test valid root handles")
    func testValidRootHandles() throws {
        let validHandles = ["$alice", "$bob123", "$my_handle", "$a-b.c", "$a", "$abcdefghijklmno"]
        for handle in validHandles {
            let result = try checkAdaHandleFormat(handle)
            #expect(result == handle.lowercased(), "Expected '\(handle)' to be valid")
        }
    }

    @Test("Test valid subhandles")
    func testValidSubhandles() throws {
        let validHandles = ["$alice@bob", "$root1@sub2", "$my-handle@sub_domain"]
        for handle in validHandles {
            let result = try checkAdaHandleFormat(handle)
            #expect(result == handle.lowercased(), "Expected '\(handle)' to be valid")
        }
    }

    @Test("Test handle normalized to lowercase")
    func testHandleNormalizedToLowercase() throws {
        let result = try checkAdaHandleFormat("$ALICE")
        #expect(result == "$alice")
    }

    @Test("Test handle with mixed case normalized")
    func testHandleMixedCaseNormalized() throws {
        let result = try checkAdaHandleFormat("$MyHandle123")
        #expect(result == "$myhandle123")
    }

    @Test("Test invalid handle - no dollar prefix")
    func testInvalidHandleNoDollarPrefix() {
        #expect(throws: (any Error).self) {
            _ = try checkAdaHandleFormat("alice")
        }
    }

    @Test("Test invalid handle - too long")
    func testInvalidHandleTooLong() {
        #expect(throws: (any Error).self) {
            _ = try checkAdaHandleFormat("$thishandleiswaytoolong")
        }
    }

    @Test("Test invalid handle - empty after dollar")
    func testInvalidHandleEmptyAfterDollar() {
        #expect(throws: (any Error).self) {
            _ = try checkAdaHandleFormat("$")
        }
    }

    @Test("Test invalid handle - invalid characters")
    func testInvalidHandleInvalidCharacters() {
        #expect(throws: (any Error).self) {
            _ = try checkAdaHandleFormat("$alice!")
        }
        #expect(throws: (any Error).self) {
            _ = try checkAdaHandleFormat("$alice space")
        }
    }

    @Test("Test nil handle throws")
    func testNilHandleThrows() {
        #expect(throws: (any Error).self) {
            _ = try checkAdaHandleFormat(nil)
        }
    }

    // MARK: normalizeHandle

    @Test("Test normalizeHandle removes dollar prefix")
    func testNormalizeHandleRemovesDollarPrefix() {
        let result = normalizeHandle("$alice")
        #expect(result == "alice")
    }

    @Test("Test normalizeHandle trims whitespace")
    func testNormalizeHandleTrimsWhitespace() {
        let result = normalizeHandle("  $alice  ")
        #expect(result == "alice")
    }

    @Test("Test normalizeHandle lowercases")
    func testNormalizeHandleLowercases() {
        let result = normalizeHandle("$ALICE")
        #expect(result == "alice")
    }

    @Test("Test normalizeHandle without dollar prefix")
    func testNormalizeHandleWithoutDollarPrefix() {
        let result = normalizeHandle("alice")
        #expect(result == "alice")
    }

    @Test("Test normalizeHandle subhandle")
    func testNormalizeHandleSubhandle() {
        let result = normalizeHandle("$alice@bob")
        #expect(result == "alice@bob")
    }

    // MARK: isSubHandle

    @Test("Test isSubHandle with at sign")
    func testIsSubHandleWithAtSign() {
        #expect(isSubHandle("alice@bob") == true)
    }

    @Test("Test isSubHandle without at sign")
    func testIsSubHandleWithoutAtSign() {
        #expect(isSubHandle("alice") == false)
    }

    @Test("Test isSubHandle with multiple at signs")
    func testIsSubHandleWithMultipleAtSigns() {
        // Contains @ so is considered subhandle
        #expect(isSubHandle("alice@bob@charlie") == true)
    }

    // MARK: isValidAdaRootHandle

    @Test("Test isValidAdaRootHandle - valid")
    func testIsValidAdaRootHandleValid() {
        #expect(isValidAdaRootHandle("$alice") == true)
        #expect(isValidAdaRootHandle("$bob123") == true)
        #expect(isValidAdaRootHandle("$my_handle") == true)
        #expect(isValidAdaRootHandle("$a-b.c") == true)
    }

    @Test("Test isValidAdaRootHandle - invalid")
    func testIsValidAdaRootHandleInvalid() {
        #expect(isValidAdaRootHandle(nil) == false)
        #expect(isValidAdaRootHandle("alice") == false)
        #expect(isValidAdaRootHandle("$") == false)
        #expect(isValidAdaRootHandle("$thisistoolongforhandle") == false)
        #expect(isValidAdaRootHandle("$alice@bob") == false)   // subhandle, not root
        #expect(isValidAdaRootHandle("$alice!") == false)
    }

    // MARK: isValidAdaSubHandle

    @Test("Test isValidAdaSubHandle - valid")
    func testIsValidAdaSubHandleValid() {
        #expect(isValidAdaSubHandle("$alice@bob") == true)
        #expect(isValidAdaSubHandle("$root1@sub2") == true)
        #expect(isValidAdaSubHandle("$my-handle@sub_domain") == true)
    }

    @Test("Test isValidAdaSubHandle - invalid")
    func testIsValidAdaSubHandleInvalid() {
        #expect(isValidAdaSubHandle(nil) == false)
        #expect(isValidAdaSubHandle("$alice") == false)         // root handle, not sub
        #expect(isValidAdaSubHandle("alice@bob") == false)      // missing $
        #expect(isValidAdaSubHandle("$@bob") == false)          // empty root part
        #expect(isValidAdaSubHandle("$alice@") == false)        // empty sub part
        #expect(isValidAdaSubHandle("$thisistoolongforrootpart@bob") == false)
    }

    // MARK: convertAssetNameToHex

    @Test("Test convertAssetNameToHex with simple string")
    func testConvertAssetNameToHexSimple() {
        let result = convertAssetNameToHex("ada")
        #expect(result == "616461")   // 'a'=0x61, 'd'=0x64, 'a'=0x61
    }

    @Test("Test convertAssetNameToHex with empty string")
    func testConvertAssetNameToHexEmpty() {
        let result = convertAssetNameToHex("")
        #expect(result == "")
    }

    @Test("Test convertAssetNameToHex returns lowercase")
    func testConvertAssetNameToHexLowercase() {
        let result = convertAssetNameToHex("A")
        #expect(result == result.lowercased())
    }

    @Test("Test convertAssetNameToHex byte values")
    func testConvertAssetNameToHexByteValues() {
        // 'a' = 97 = 0x61, 'b' = 98 = 0x62
        let result = convertAssetNameToHex("ab")
        #expect(result == "6162")
    }

    // MARK: validatePaymentAddress

    @Test("Test validatePaymentAddress with valid payment address")
    func testValidatePaymentAddressValid() throws {
        // Base address (payment + staking parts)
        try validatePaymentAddress("addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3")
        // No throw expected
    }

    @Test("Test validatePaymentAddress with stake address throws")
    func testValidatePaymentAddressStakeAddressThrows() {
        #expect(throws: (any Error).self) {
            try validatePaymentAddress("stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n")
        }
    }

    // MARK: assetFingerprint

    @Test("Test assetFingerprint format")
    func testAssetFingerprintFormat() {
        let fingerprint = assetFingerprint(policyId: "abc123", assetNameHex: "def456")
        #expect(fingerprint == "abc123.def456")
    }

    @Test("Test getPolicyId for mainnet")
    func testGetPolicyIdForMainnet() throws {
        let policyId = try getPolicyId(for: .mainnet)
        #expect(policyId == "f0ff48bbb7bbe9d59a40f1ce90e9e9d0ff5002ec48f232b49ca0fb9a")
    }

    @Test("Test getPolicyId for preview")
    func testGetPolicyIdForPreview() throws {
        let policyId = try getPolicyId(for: .preview)
        #expect(policyId == "f0ff48bbb7bbe9d59a40f1ce90e9e9d0ff5002ec48f232b49ca0fb9a")
    }

    @Test("Test getPolicyId for preprod")
    func testGetPolicyIdForPreprod() throws {
        let policyId = try getPolicyId(for: .preprod)
        #expect(policyId == "f0ff48bbb7bbe9d59a40f1ce90e9e9d0ff5002ec48f232b49ca0fb9a")
    }

    @Test("Test getPolicyId for sanchonet throws")
    func testGetPolicyIdForSanchonetThrows() {
        #expect(throws: (any Error).self) {
            _ = try getPolicyId(for: .sanchonet)
        }
    }

    @Test("Test getPolicyId for custom network throws")
    func testGetPolicyIdForCustomNetworkThrows() {
        #expect(throws: (any Error).self) {
            _ = try getPolicyId(for: .custom(9999))
        }
    }

    // MARK: createHandlesClient

    @Test("Test createHandlesClient for non-mainnet throws")
    func testCreateHandlesClientNonMainnetThrows() {
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

    // MARK: extractResolvedAddressFromDatum

    @Test("Test extractResolvedAddressFromDatum returns nil for empty hex")
    func testExtractResolvedAddressFromDatumEmptyHex() throws {
        let result = try extractResolvedAddressFromDatum(datumHex: "", network: .mainnet)
        #expect(result == nil)
    }

    @Test("Test extractResolvedAddressFromDatum returns nil when key not present")
    func testExtractResolvedAddressFromDatumNoKey() throws {
        let result = try extractResolvedAddressFromDatum(datumHex: "deadbeef", network: .mainnet)
        #expect(result == nil)
    }

    @Test("Test extractResolvedAddressFromDatum returns nil when ada pattern not found after key")
    func testExtractResolvedAddressFromDatumNoAdaPattern() throws {
        // Contains resolved_addresses hex key but no "436164615839" address pattern
        let datumHex = "7265736f6c7665645f616464726573736573"
        let result = try extractResolvedAddressFromDatum(datumHex: datumHex, network: .mainnet)
        #expect(result == nil)
    }
}
