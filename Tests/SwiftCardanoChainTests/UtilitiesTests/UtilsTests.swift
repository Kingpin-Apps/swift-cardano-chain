//
//  
//  Product: SwiftCardanoChain
//  Project: SwiftCardanoChain
//  Package: SwiftCardanoChain
//  
//  Created by Hareem Adderley on 21/10/2025 AT 6:12 AM
//  Copyright © 2025 Kingpin Apps. All rights reserved.
//  

import Foundation
import Testing
@testable import SwiftCardanoChain

/// Test suite for Utils.swift utility functions
@Suite("Utils Functions")
struct UtilsTests {
    
    // MARK: - Asset Name Conversion Tests
    
    @Suite("Asset Name Conversion")
    struct AssetNameConversionTests {
        
        @Test("Convert ASCII asset names to HEX")
        func testConvertAssetNameASCII2HEX() {
            // Test basic ASCII conversion
            #expect(convertAssetNameASCII2HEX(assetName: "hello") == "68656c6c6f")
            #expect(convertAssetNameASCII2HEX(assetName: "TEST") == "54455354")
            #expect(convertAssetNameASCII2HEX(assetName: "123") == "313233")
            
            // Test special characters
            #expect(convertAssetNameASCII2HEX(assetName: "Hello World!") == "48656c6c6f20576f726c6421")
            
            // Test empty string
            #expect(convertAssetNameASCII2HEX(assetName: "") == "")
            
            // Test single character
            #expect(convertAssetNameASCII2HEX(assetName: "A") == "41")
        }
        
        @Test("Convert HEX asset names to ASCII")
        func testConvertAssetNameHEX2ASCII() {
            // Test basic HEX conversion
            #expect(convertAssetNameHEX2ASCII(assetName: "68656c6c6f") == "hello")
            #expect(convertAssetNameHEX2ASCII(assetName: "54455354") == "TEST")
            #expect(convertAssetNameHEX2ASCII(assetName: "313233") == "123")
            
            // Test special characters
            #expect(convertAssetNameHEX2ASCII(assetName: "48656c6c6f20576f726c6421") == "Hello World!")
            
            // Test empty string
            #expect(convertAssetNameHEX2ASCII(assetName: "") == "")
            
            // Test single character
            #expect(convertAssetNameHEX2ASCII(assetName: "41") == "A")
        }
        
        @Test("Round-trip asset name conversion")
        func testAssetNameRoundTrip() {
            let testNames = [
                "hello",
                "TEST123",
                "MyToken",
                "Special!@#",
                "unicode_test",
                "A",
                ""
            ]
            
            for name in testNames {
                let hex = convertAssetNameASCII2HEX(assetName: name)
                let ascii = convertAssetNameHEX2ASCII(assetName: hex)
                #expect(ascii == name, "Round-trip failed for: \(name)")
            }
        }
    }
    
    // MARK: - Ada Handle Format Tests
    
    @Suite("Ada Handle Format Validation")
    struct AdaHandleFormatTests {
        
        @Test("Valid root Ada handle formats")
        func testCheckAdaHandleFormatValidRoot() throws {
            let validRootHandles = [
                "$alice",
                "$a",
                "$test123",
                "$user_name",
                "$handle.test",
                "$A1B2C3D4E5F6789", // 15 chars (max length)
                "$MixedCase"
            ]
            
            for handle in validRootHandles {
                let result = try checkAdaHandleFormat(handle)
                #expect(result == handle.lowercased(), "Failed for handle: \(handle)")
            }
        }
        
        @Test("Valid sub/virtual Ada handle formats")
        func testCheckAdaHandleFormatValidSub() throws {
            let validSubHandles = [
                "$alice@bob",
                "$a@b",
                "$test123@user456",
                "$user_name@sub_handle",
                "$handle.test@sub.test",
                "$root@A1B2C3D4E5F6789", // 15 chars subhandle (max length)
                "$MixedCase@SubHandle"
            ]
            
            for handle in validSubHandles {
                let result = try checkAdaHandleFormat(handle)
                #expect(result == handle.lowercased(), "Failed for handle: \(handle)")
            }
        }
        
        @Test("Invalid Ada handle formats throw errors")
        func testCheckAdaHandleFormatInvalid() {
            let invalidHandles = [
                "alice", // Missing $
                "$", // No handle part
                "$@bob", // Empty root part
                "$alice@", // Empty sub part
                "$toolonghandle123456", // Root too long (16 chars)
                "$alice@toolongsubhandle123456", // Sub too long (16 chars)
                "$alice@bob@charlie", // Multiple @ symbols
                "$alice bob", // Space in handle
                "$alice#bob", // Invalid character
                "$alice@bo#b", // Invalid character in sub
                "", // Empty string
                "$alice@@bob" // Double @
            ]
            
            for handle in invalidHandles {
                #expect(throws: CardanoChainError.invalidAdaHandle(handle)) {
                    try checkAdaHandleFormat(handle)
                }
            }
        }
        
        @Test("Nil handle throws error")
        func testCheckAdaHandleFormatNil() {
            #expect(throws: CardanoChainError.invalidAdaHandle(nil)) {
                try checkAdaHandleFormat(nil)
            }
        }
        
        @Test("Case insensitive validation and lowercase output")
        func testCheckAdaHandleFormatCaseInsensitive() throws {
            let mixedCaseHandle = "$ALICE@BOB"
            let result = try checkAdaHandleFormat(mixedCaseHandle)
            #expect(result == "$alice@bob")
        }
    }
    
    // MARK: - Root Handle Validation Tests
    
    @Suite("Root Ada Handle Validation")
    struct RootHandleValidationTests {
        
        @Test("Valid root handles return true")
        func testIsValidAdaRootHandleValid() {
            let validRootHandles = [
                "$alice",
                "$a",
                "$test123",
                "$user_name",
                "$handle.test",
                "$A1B2C3D4E5F6789", // 15 chars (max length)
                "$MixedCase",
                "$123456789012345" // Exactly 15 chars
            ]
            
            for handle in validRootHandles {
                #expect(isValidAdaRootHandle(handle), "Should be valid root handle: \(handle)")
            }
        }
        
        @Test("Invalid root handles return false")
        func testIsValidAdaRootHandleInvalid() {
            let invalidRootHandles = [
                "$alice@bob", // Sub handle
                "alice", // Missing $
                "$", // No handle part
                "$toolonghandle123456", // Too long (16 chars)
                "$alice bob", // Space
                "$alice#test", // Invalid character
                "", // Empty
                "$alice@", // Has @ but no sub part
                nil // Nil
            ]
            
            for handle in invalidRootHandles {
                #expect(!isValidAdaRootHandle(handle), "Should be invalid root handle: \(String(describing: handle))")
            }
        }
        
        @Test("Case insensitive root handle validation")
        func testIsValidAdaRootHandleCaseInsensitive() {
            #expect(isValidAdaRootHandle("$ALICE"))
            #expect(isValidAdaRootHandle("$alice"))
            #expect(isValidAdaRootHandle("$Alice"))
            #expect(isValidAdaRootHandle("$aLiCe"))
        }
    }
    
    // MARK: - Sub Handle Validation Tests
    
    @Suite("Sub Ada Handle Validation")
    struct SubHandleValidationTests {
        
        @Test("Valid sub handles return true")
        func testIsValidAdaSubHandleValid() {
            let validSubHandles = [
                "$alice@bob",
                "$a@b",
                "$test123@user456",
                "$user_name@sub_handle",
                "$handle.test@sub.test",
                "$root@A1B2C3D4E5F6789", // 15 chars subhandle
                "$A1B2C3D4E5F6789@sub", // 15 chars root
                "$MixedCase@SubHandle",
                "$123456789012345@123456789012345" // Both parts exactly 15 chars
            ]
            
            for handle in validSubHandles {
                #expect(isValidAdaSubHandle(handle), "Should be valid sub handle: \(handle)")
            }
        }
        
        @Test("Invalid sub handles return false")
        func testIsValidAdaSubHandleInvalid() {
            let invalidSubHandles = [
                "$alice", // Root handle only
                "alice@bob", // Missing $
                "$@bob", // Empty root part
                "$alice@", // Empty sub part
                "$toolonghandle123456@bob", // Root too long
                "$alice@toolongsubhandle123456", // Sub too long
                "$alice@bob@charlie", // Multiple @
                "$alice bob@test", // Space in root
                "$alice@bo b", // Space in sub
                "$alice#@bob", // Invalid char in root
                "$alice@bo#b", // Invalid char in sub
                "", // Empty
                "$alice@@bob", // Double @
                nil // Nil
            ]
            
            for handle in invalidSubHandles {
                #expect(!isValidAdaSubHandle(handle), "Should be invalid sub handle: \(String(describing: handle))")
            }
        }
        
        @Test("Case insensitive sub handle validation")
        func testIsValidAdaSubHandleCaseInsensitive() {
            #expect(isValidAdaSubHandle("$ALICE@BOB"))
            #expect(isValidAdaSubHandle("$alice@bob"))
            #expect(isValidAdaSubHandle("$Alice@Bob"))
            #expect(isValidAdaSubHandle("$aLiCe@bOb"))
        }
    }
    
    // MARK: - Edge Case Tests
    
    @Suite("Edge Cases and Boundary Tests")
    struct EdgeCaseTests {
        
        @Test("Maximum length handle validation")
        func testMaximumLengthHandles() throws {
            // 15 character root handle (maximum allowed)
            let maxRootHandle = "$123456789012345"
            #expect(isValidAdaRootHandle(maxRootHandle))
            let result = try checkAdaHandleFormat(maxRootHandle)
            #expect(result == maxRootHandle.lowercased())
            
            // 15 character sub handle (maximum allowed)
            let maxSubHandle = "$root@123456789012345"
            #expect(isValidAdaSubHandle(maxSubHandle))
            let subResult = try checkAdaHandleFormat(maxSubHandle)
            #expect(subResult == maxSubHandle.lowercased())
            
            // Both parts at maximum length
            let maxBothHandle = "$123456789012345@123456789012345"
            #expect(isValidAdaSubHandle(maxBothHandle))
            let bothResult = try checkAdaHandleFormat(maxBothHandle)
            #expect(bothResult == maxBothHandle.lowercased())
        }
        
        @Test("Single character handles")
        func testSingleCharacterHandles() throws {
            // Single character root
            let singleRoot = "$a"
            #expect(isValidAdaRootHandle(singleRoot))
            let rootResult = try checkAdaHandleFormat(singleRoot)
            #expect(rootResult == "$a")
            
            // Single character sub
            let singleSub = "$a@b"
            #expect(isValidAdaSubHandle(singleSub))
            let subResult = try checkAdaHandleFormat(singleSub)
            #expect(subResult == "$a@b")
        }
        
        @Test("All allowed special characters")
        func testAllowedSpecialCharacters() throws {
            // Test handles with underscore and dot (which are definitely allowed)
            let handleWithUnderscoreDot = "$test_handle.123"
            #expect(isValidAdaRootHandle(handleWithUnderscoreDot))
            let result = try checkAdaHandleFormat(handleWithUnderscoreDot)
            #expect(result == handleWithUnderscoreDot.lowercased())
            
            let subWithUnderscoreDot = "$test_123@handle.456"
            #expect(isValidAdaSubHandle(subWithUnderscoreDot))
            let subResult = try checkAdaHandleFormat(subWithUnderscoreDot)
            #expect(subResult == subWithUnderscoreDot.lowercased())
        }
        
        @Test("Unicode and non-ASCII characters")
        func testUnicodeHandles() {
            // Unicode characters should be invalid
            let unicodeHandles = [
                "$alice🚀",
                "$café",
                "$тест",
                "$alice@café",
                "$тест@test"
            ]
            
            for handle in unicodeHandles {
                #expect(!isValidAdaRootHandle(handle), "Unicode should be invalid: \(handle)")
                #expect(!isValidAdaSubHandle(handle), "Unicode should be invalid: \(handle)")
                #expect(throws: CardanoChainError.invalidAdaHandle(handle)) {
                    try checkAdaHandleFormat(handle)
                }
            }
        }
        
        @Test("Empty string and whitespace handling")
        func testEmptyAndWhitespaceHandles() {
            let emptyAndWhitespaceHandles = [
                "",
                " ",
                "\t",
                "\n",
                "$",
                "$ ",
                " $alice",
                "$alice ",
                "$ @bob",
                "$alice@ ",
                "$alice @bob"
            ]
            
            for handle in emptyAndWhitespaceHandles {
                #expect(!isValidAdaRootHandle(handle), "Should be invalid: '\(handle)'")
                #expect(!isValidAdaSubHandle(handle), "Should be invalid: '\(handle)'")
                #expect(throws: CardanoChainError.invalidAdaHandle(handle)) {
                    try checkAdaHandleFormat(handle)
                }
            }
        }
    }
    
    // MARK: - Performance Tests
    
    @Suite("Performance Tests")
    struct PerformanceTests {
        
        @Test("Asset name conversion performance")
        func testAssetNameConversionPerformance() {
            let testString = "ThisIsAReasonablyLongAssetNameForTesting123"
            
            // Test ASCII to HEX conversion performance
            let startTime = Date()
            for _ in 0..<10000 {
                _ = convertAssetNameASCII2HEX(assetName: testString)
            }
            let asciiToHexTime = Date().timeIntervalSince(startTime)
            
            // Convert to hex for reverse test
            let hexString = convertAssetNameASCII2HEX(assetName: testString)
            
            // Test HEX to ASCII conversion performance
            let startTime2 = Date()
            for _ in 0..<10000 {
                _ = convertAssetNameHEX2ASCII(assetName: hexString)
            }
            let hexToAsciiTime = Date().timeIntervalSince(startTime2)
            
            // Performance should be reasonable (less than 2 seconds for 10k conversions)
            #expect(asciiToHexTime < 2.0, "ASCII to HEX conversion too slow: \(asciiToHexTime)s")
            #expect(hexToAsciiTime < 2.0, "HEX to ASCII conversion too slow: \(hexToAsciiTime)s")
        }
        
        @Test("Handle validation performance")
        func testHandleValidationPerformance() {
            let testHandles = [
                "$alice",
                "$bob@charlie",
                "$test123",
                "$invalid@handle@with@multiple@ats",
                "$toolonghandlenamethatexceedslimit",
                "$valid_handle-123.test"
            ]
            
            let startTime = Date()
            for _ in 0..<10000 {
                for handle in testHandles {
                    _ = isValidAdaRootHandle(handle)
                    _ = isValidAdaSubHandle(handle)
                }
            }
            let validationTime = Date().timeIntervalSince(startTime)
            
            // Performance should be reasonable (less than 15 seconds for 60k validations)
            #expect(validationTime < 15.0, "Handle validation too slow: \(validationTime)s")
        }
    }
}
