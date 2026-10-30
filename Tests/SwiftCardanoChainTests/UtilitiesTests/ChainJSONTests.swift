import BigInt
import Foundation
import SwiftBlockfrostAPI
import SwiftCardanoCore
import SwiftKoios
import SwiftYaciAPI
import Testing

@testable import SwiftCardanoChain

@Suite("Ledger JSON is read exactly, from every client")
struct ChainJSONTests {

    static let description = #"""
    {"tag": "ParameterChange", "contents": [null, {
        "txFeePerByte": 18446744073709551615,
        "monetaryExpansion": 0.3000000000000000001,
        "poolPledgeInfluence": 0.1234567890123456789,
        "minFeeRefScriptCostPerByte": 15.00000000000000001
    }, null]}
    """#

    private func parse(_ json: ChainJSON) throws -> ProtocolParamUpdate {
        guard case .parameterChangeAction(let change) = try LedgerGovActionJSON.govAction(json, "test", protocolParamUpdate: {
            try LedgerGovActionJSON.protocolParamUpdate($0, "test")
        }) else {
            throw CardanoChainError.valueError("not a parameter change")
        }
        return change.protocolParamUpdate
    }

    private func expectExact(_ update: ProtocolParamUpdate) {
        // UInt64.max and decimals with more digits than a Double holds survive.
        #expect(update.minFeeA == Coin(UInt64.max))
        #expect(update.expansionRate?.numerator == 3_000_000_000_000_000_001)
        #expect(update.expansionRate?.denominator == 10_000_000_000_000_000_000)
        #expect(update.poolPledgeInfluence?.numerator == 1_234_567_890_123_456_789)
        #expect(update.poolPledgeInfluence?.denominator == 10_000_000_000_000_000_000)
        #expect(update.minFeeRefScriptCoinsPerByte?.numerator == 1_500_000_000_000_000_001)
        #expect(update.minFeeRefScriptCoinsPerByte?.denominator == 100_000_000_000_000_000)
    }

    @Test("A description decoded straight into ChainJSON keeps every digit")
    func direct() throws {
        expectExact(try parse(ChainJSON.decode(Data(Self.description.utf8), "test")))
    }

    @Test("Blockfrost, Koios and Yaci ledger JSON convert to the same exact value")
    func adapters() throws {
        let data = Data(Self.description.utf8)
        let direct = try ChainJSON.decode(data, "test")
        let blockfrost = ChainJSON(try JSONDecoder().decode(SwiftBlockfrostAPI.LedgerJSON.self, from: data))
        let koios = ChainJSON(try JSONDecoder().decode(SwiftKoios.LedgerJSON.self, from: data))
        let yaci = ChainJSON(try JSONDecoder().decode(SwiftYaciAPI.LedgerJSON.self, from: data))
        #expect(blockfrost == direct)
        #expect(koios == direct)
        #expect(yaci == direct)
        for converted in [blockfrost, koios, yaci] {
            expectExact(try parse(converted))
        }
    }

    @Test("Decimal integers are read exactly and checked against the target width")
    func integers() throws {
        let max = try ChainJSON.decode(Data("18446744073709551615".utf8), "test")
        #expect(try LedgerValues.integer(json: max, as: UInt64.self, "test") == UInt64.max)
        #expect(throws: CardanoChainError.self) { try LedgerValues.integer(json: max, as: Int64.self, "test") }
        let fractional = try ChainJSON.decode(Data("1.5".utf8), "test")
        #expect(throws: CardanoChainError.self) { try LedgerValues.integer(json: fractional, as: UInt64.self, "test") }
        let negative = try ChainJSON.decode(Data("-1".utf8), "test")
        #expect(throws: CardanoChainError.self) { try LedgerValues.integer(json: negative, as: UInt64.self, "test") }
        #expect(try LedgerValues.integer(json: ChainJSON.number(Decimal(string: "1.5e3")!), as: Int.self, "test") == 1500)
        #expect(try LedgerValues.integer(json: ChainJSON.null, as: Int.self, "test") == nil)
        #expect(throws: CardanoChainError.self) { try LedgerValues.integer(json: ChainJSON.bool(true), as: Int.self, "test") }
        #expect(try LedgerValues.bigInt(json: ChainJSON.string("123456789012345678901234567890"), "test")
            == BigInt("123456789012345678901234567890"))
    }

    @Test("A ratio above one is not a unit interval; a fraction object is reduced")
    func fractions() throws {
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.unitInterval(json: ChainJSON.number(Decimal(string: "1.01")!), "test")
        }
        let reduced = try #require(try LedgerValues.unitInterval(
            json: .object(["numerator": .number(2), "denominator": .number(4)]), "test"))
        #expect(reduced.numerator == 1 && reduced.denominator == 2)
        #expect(throws: CardanoChainError.self) {
            try LedgerValues.unitInterval(json: ChainJSON.bool(false), "test")
        }
    }

    #if CLIBACKENDS
    @Test("cardano-cli gov-state actions are read in proposal order, exactly")
    func cliGovState() throws {
        let state = #"{"proposals": [{"proposalProcedure": {"govAction": \#(Self.description)}}, {"proposalProcedure": {}}]}"#
        let actions = try CardanoCliChainContext.proposalGovActions(Data(state.utf8))
        #expect(actions.count == 2)
        expectExact(try parse(try #require(actions[0])))
        #expect(actions[1] == nil)
    }
    #endif
}
