import Foundation
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoChain

@Suite("Hex from a backend is read strictly")
struct LedgerValuesHexTests {

    static let notHex: [String] = [
        "abc",  // odd length: the lenient readers pad or drop a digit
        "zz",  // not hex digits
        "+f",  // a sign, which UInt8(_:radix:) accepts
        "0x00",  // a prefix
        "ab cd",  // a space, which hexStringToData strips
    ]

    @Test("Text that is not exactly hex throws", arguments: notHex)
    func notHexThrows(_ text: String) {
        #expect(throws: CardanoChainError.self) { try LedgerValues.hexBytes(text, "value") }
    }

    @Test("Hex in either case reads as its bytes")
    func hexReads() throws {
        #expect(try LedgerValues.hexBytes("", "value") == Data())
        #expect(try LedgerValues.hexBytes("00ffAB", "value") == Data([0x00, 0xFF, 0xAB]))
    }

    static let wrongKeyHashLengths: [String] = [
        String(repeating: "00", count: 27),
        String(repeating: "00", count: 29),
        String(repeating: "00", count: 32),
    ]

    @Test("A key or script hash that is not 28 bytes throws", arguments: wrongKeyHashLengths)
    func keyHashLength(_ hex: String) {
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.hash(hex: hex, as: VerificationKeyHash.self, "key hash")
        }
        #expect(throws: CardanoChainError.self) { try LedgerValues.hash(hex: hex, as: ScriptHash.self, "script hash") }
    }

    static let wrongTxIdLengths: [String] = [
        String(repeating: "00", count: 28),
        String(repeating: "00", count: 33),
        // 63 digits: hexStringToData would pad this to 32 bytes.
        String(repeating: "0", count: 63),
    ]

    @Test("A transaction id or datum hash that is not 32 bytes throws", arguments: wrongTxIdLengths)
    func txIdLength(_ hex: String) {
        #expect(throws: CardanoChainError.self) { try LedgerValues.hash(hex: hex, as: TransactionId.self, "tx id") }
        #expect(throws: CardanoChainError.self) { try LedgerValues.hash(hex: hex, as: DatumHash.self, "datum hash") }
    }

    @Test("Hashes of the right length read as their bytes")
    func hashesRead() throws {
        let key = String(repeating: "ab", count: 28)
        let tx = String(repeating: "cd", count: 32)
        #expect(try LedgerValues.hash(hex: key, as: VerificationKeyHash.self, "key").payload.toHex == key)
        #expect(try LedgerValues.hash(hex: tx, as: TransactionId.self, "tx").payload.toHex == tx)
    }

    static let badCredentials: [String] = [
        "keyHash-abc",
        "scriptHash-" + String(repeating: "00", count: 29),
        "keyhash-" + String(repeating: "00", count: 28),
        String(repeating: "00", count: 28),
    ]

    @Test("A credential that is malformed or the wrong length throws", arguments: badCredentials)
    func badCredential(_ text: String) {
        #expect(throws: CardanoChainError.self) { try LedgerValues.credential(json: ChainJSON.string(text), "credential") }
    }

    @Test("A reward account is read with its network and credential kind")
    func rewardAccount() throws {
        let hash = String(repeating: "11", count: 28)
        let testnetKey = try LedgerValues.rewardAccount(
            json: ["network": "Testnet", "credential": ["keyHash": .string(hash)]], "account")
        #expect(testnetKey.first == 0xE0)
        let mainnetScript = try LedgerValues.rewardAccount(
            json: ["network": "Mainnet", "credential": ["scriptHash": .string(hash)]], "account")
        #expect(mainnetScript.first == 0xF1)
        #expect(mainnetScript.count == 29)
        // A bare credential has no network, and one is not guessed.
        #expect(throws: CardanoChainError.self) { try LedgerValues.rewardAccount(json: ["keyHash": .string(hash)], "account") }
    }

    static let badAssetUnits: [String] = [
        String(repeating: "00", count: 27),  // shorter than a policy id
        String(repeating: "00", count: 61),  // a name over 32 bytes
        String(repeating: "00", count: 28) + "0",  // odd length
    ]

    @Test("An asset unit that is not a policy id and name throws", arguments: badAssetUnits)
    func badAssetUnit(_ unit: String) {
        #expect(throws: CardanoChainError.self) { try LedgerValues.asset(unit: unit, "unit") }
    }
}
