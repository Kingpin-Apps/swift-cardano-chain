import Foundation
import SwiftCardanoCore
import SystemPackage
import Testing

@testable import SwiftCardanoChain

@Suite("OfflineTransfer Component Model Tests")
struct OfflineTransferComponentModelTests {

    @Test("general encodes using snake case version keys")
    func generalEncodesSnakeCaseKeys() throws {
        let general = OfflineTransferGeneral(offlineVersion: "1.0.0", onlineVersion: "2.0.0")
        let object = try JSONObject.encode(general)

        #expect(object["offline_version"] as? String == "1.0.0")
        #expect(object["online_version"] as? String == "2.0.0")
    }

    @Test("protocol data encodes protocol parameter keys")
    func protocolDataEncodesSnakeCaseKeys() throws {
        let data = OfflineTransferProtocolData(era: .conway, network: .preview)
        let object = try JSONObject.encode(data)

        #expect(object.keys.contains("era"))
        #expect(object.keys.contains("network"))
        #expect(object["era"] != nil)
        #expect(object["network"] != nil)
        #expect(object.keys.contains("protocol_parameters") == false)
        #expect(object.keys.contains("genesis_parameters") == false)
    }

    @Test("history and file entries auto-populate ISO8601 dates")
    func componentDefaultsPopulateDates() throws {
        let history = OfflineTransferHistory(action: "NEW")
        let fileEntry = OfflineTransferFileEntry(name: "payment.skey", size: 128)

        #expect(history.action == "NEW")
        #expect(history.date != nil)
        #expect(fileEntry.name == "payment.skey")
        #expect(fileEntry.size == 128)
        #expect(fileEntry.date != nil)
        #expect(ISO8601DateFormatter().date(from: history.date!) != nil)
        #expect(ISO8601DateFormatter().date(from: fileEntry.date!) != nil)
    }

    @Test("transaction and evaluation encode expected JSON keys")
    func transactionAndEvaluationEncodeExpectedKeys() throws {
        let tx = OfflineTransferTransaction(
            date: "2025-01-01T00:00:00Z",
            era: .conway,
            stakeAddress: ModelTestFixtures.stakeAddressString,
            fromAddress: ModelTestFixtures.paymentAddressString,
            fromName: "Treasury",
            toAddress: ModelTestFixtures.paymentAddressString,
            toName: "Recipient",
            txJson: OfflineTransferTransactionJSON(
                type: "Tx ConwayEra",
                description: "Signed Transaction",
                cborHex: "deadbeef"
            )
        )
        let evaluation = OfflineTransferEvaluation(
            txCborHex: "deadbeef",
            executionUnits: ["spend:0": ExecutionUnits(mem: 7_000_000, steps: 5_000_000_000)]
        )

        let txObject = try JSONObject.encode(tx)
        let evaluationObject = try JSONObject.encode(evaluation)

        #expect(txObject["stake_address"] as? String == ModelTestFixtures.stakeAddressString)
        #expect(txObject["from_address"] as? String == ModelTestFixtures.paymentAddressString)
        #expect(txObject["from_name"] as? String == "Treasury")
        #expect(txObject["to_name"] as? String == "Recipient")
        #expect(txObject["tx_json"] != nil)
        #expect(evaluationObject["tx_cbor_hex"] as? String == "deadbeef")
        #expect(evaluationObject["execution_units"] != nil)
    }
}

@Suite("OfflineTransfer Root Model Tests")
struct OfflineTransferModelTests {

    @Test("root model saves and loads nested model data")
    func rootModelRoundTripsThroughDisk() throws {
        let path = ModelTestFixtures.temporaryFilePath(extension: "json")
        defer { try? FileManager.default.removeItem(atPath: path.string) }
        let drep = try DRep.fromBech32("drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0")

        let transfer = OfflineTransfer(
            general: OfflineTransferGeneral(offlineVersion: "1.0.0", onlineVersion: "2.0.0"),
            protocol: OfflineTransferProtocolData(era: .conway, network: .preview),
            history: [OfflineTransferHistory(date: "2025-01-01T00:00:00Z", action: "NEW")],
            files: [
                OfflineTransferFileEntry(
                    name: "payment.vkey", date: "2025-01-01T01:00:00Z", size: 10)
            ],
            transactions: [
                OfflineTransferTransaction(
                    date: "2025-01-01T02:00:00Z",
                    era: .conway,
                    fromName: "Treasury",
                    toName: "Recipient",
                    txJson: OfflineTransferTransactionJSON(
                        type: "Tx ConwayEra", description: "Signed", cborHex: "bead")
                )
            ],
            addresses: [try AddressInfo(fromAdaHandle: "$alice")],
            stakePoolInfos: [StakePoolInfo(poolParams: ModelTestFixtures.makeDummyPoolParams())],
            kesPeriodInfos: [KESPeriodInfo(onChainOpCertCount: 10, nextChainOpCertCount: 11)],
            treasury: Coin(999),
            drepInfos: [DRepInfo(active: true, drep: drep, stake: Coin(42))],
            govActionInfos: [
                GovActionInfo(
                    govActionId: ModelTestFixtures.makeGovActionID(),
                    govAction: GovAction.infoAction(InfoAction()))
            ],
            committeeMemberInfos: [
                CommitteeMemberInfo(
                    coldCredential: CommitteeColdCredential(
                        credential: .verificationKeyHash(
                            VerificationKeyHash(payload: Data(repeating: 0xaa, count: 28)))
                    ),
                    hotCredential: nil,
                    expiration: EpochNumber(300)
                )
            ],
            evaluations: [
                OfflineTransferEvaluation(
                    txCborHex: "bead",
                    executionUnits: ["spend:0": ExecutionUnits(mem: 1, steps: 2)]
                )
            ]
        )

        try transfer.save(to: path)
        let loaded = try OfflineTransfer.load(from: path)

        #expect(loaded.general.offlineVersion == "1.0.0")
        #expect(loaded.general.onlineVersion == "2.0.0")
        #expect(loaded.protocol.era == .conway)
        #expect(loaded.protocol.network == .preview)
        #expect(loaded.history.count == 1)
        #expect(loaded.files.count == 1)
        #expect(loaded.transactions.count == 1)
        #expect(loaded.addresses.first?.adaHandle == "$alice")
        #expect(loaded.stakePoolInfos.count == 1)
        #expect(loaded.kesPeriodInfos.first?.nextChainOpCertCount == 11)
        #expect(loaded.treasury == Coin(999))
        #expect(loaded.drepInfos.first?.stake == Coin(42))
        #expect(loaded.govActionInfos.count == 1)
        #expect(loaded.committeeMemberInfos.first?.expiration == EpochNumber(300))
        #expect(
            loaded.evaluations.first?.executionUnits["spend:0"] == ExecutionUnits(mem: 1, steps: 2))
    }

    @Test("new creates file with initial history entry")
    func newCreatesFile() throws {
        let path = ModelTestFixtures.temporaryFilePath(extension: "json")
        defer { try? FileManager.default.removeItem(atPath: path.string) }

        let transfer = try OfflineTransfer.new(at: path)

        #expect(FileManager.default.fileExists(atPath: path.string))
        #expect(transfer.history.count == 1)
        #expect(transfer.history.first?.action == "NEW")
        #expect(ISO8601DateFormatter().date(from: transfer.history.first?.date ?? "") != nil)
    }
}

private enum JSONObject {
    static func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
