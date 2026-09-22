import Foundation
import HTTPTypes
import OpenAPIRuntime
import SwiftYaciAPI

@testable import SwiftCardanoChain

// MARK: - Shared identifiers

/// Well-known identifiers shared by the Yaci mock and its tests.
enum YaciMockData {
    static let paymentAddress =
        "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
    static let stakeAddress = "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n"
    static let unknownStakeAddress =
        "stake_test1urxvenxvenxvenxvenxvenxvenxvenxvenxvenxvenxvenqyemcr5"
    /// Registered, then deregistered again: the certificate log has both.
    static let deregisteredStakeAddress =
        "stake_test1urwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhg0lg529"

    static let poolABech32 = "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy"
    static let poolAHex = "0f292fcaa02b8b2f9b3c8f9fd8e0bb21abedb692a6d5058df3ef2735"
    static let poolBHex = "1111111111111111111111111111111111111111111111111111111a"
    static let poolCHex = "2222222222222222222222222222222222222222222222222222222b"

    static let drepHex = "b02f7b335aebf284bbdc20bdc3b59e4e183ae2cfc47ad2d8bc19a241"
    static let drepBech32 = "drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0"
    static let retiredDrepHex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    static let unknownDrepHex = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    static let ccColdHex = "1980dbf1ad624b0cb5410359b5ab14d008561994a6c2b6c53fabec00"
    static let ccColdResignedHex = "349e55f83e9af24813e6cb368df6a80d38951b2a334dfcdf26815558"
    static let ccHotHex = "646d1b3ac94568a422b687db6c47acdf849f1674982ae4f9a494be43"

    static let utxoTxHash = "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58"
    static let spentTxHash = "d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908"
    static let policyId = "b0d07d45fe9514f80213f4020e5a61241458be626841cde717cb38a7"
    static let assetNameHex = "6574636f696e"
    static let dataHash = "9e1199a988ba72ffd6e9c269cadb3b53b5f360ff99f112d9b2ee30c4d74ad88b"
    /// CBOR for the PlutusData integer 42.
    static let inlineDatumHex = "182a"
    static let nativeScriptHash = "33333333333333333333333333333333333333333333333333333333"
    static let vrfKeyHash = "5b8b5ffbb4f9a1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081920"

    static let proposalTxHash = "2dd15e0ef6e6a17841cb9541c27724072ce4d4b79b91e58432fbaa32d9572531"
    static let infoProposalTxHash = "4dab331457b61b824bbc6ba4b9d9be4750e25c0b5dd42207aeb63c7431a6b704"
    static let anchorHash = "09a9d51df80d12097227fc010657f190fb5d71fe75aa020335b04be07b8e3efd"
    static let submittedTxHash = "d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908"

    static let currentEpoch = 12
}

// MARK: - Admin API mock

/// Serves the genesis fixtures under `Tests/.../data` in place of the DevKit admin API.
struct MockYaciDevkitAdmin: YaciDevkitAdminFetching {
    /// Eras whose genesis document should fail to load, to exercise the fallbacks.
    var failing: Set<String> = []
    /// Raw bodies keyed by era that take precedence over the fixtures.
    var overrides: [String: String] = [:]

    func genesis(era: String) async throws -> Data {
        if failing.contains(era) {
            throw CardanoChainError.yaciDevkitError("No \(era) genesis in this devnet")
        }
        if let override = overrides[era] {
            return Data(override.utf8)
        }
        guard
            let url = Bundle.module.url(
                forResource: "\(era)-genesis", withExtension: "json", subdirectory: "data")
        else {
            throw CardanoChainError.yaciDevkitError("Missing fixture for \(era) genesis")
        }
        return try Data(contentsOf: url)
    }
}

// MARK: - Yaci Store mock transport

/// Records the requests the mock served, so tests can assert on paths and query strings.
final class YaciRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(operationID: String, path: String, query: String)] = []

    func record(operationID: String, path: String, query: String) {
        lock.lock()
        defer { lock.unlock() }
        _requests.append((operationID, path, query))
    }

    var requests: [(operationID: String, path: String, query: String)] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func count(of operationID: String) -> Int {
        requests.filter { $0.operationID == operationID }.count
    }
}

struct MockYaciTransport: ClientTransport {
    /// Raw JSON bodies keyed by operation ID that take precedence over the canned responses.
    var overrides: [String: String] = [:]
    /// Operation IDs the mock should answer with an error status.
    var failing: [String: Int] = [:]
    /// Serve a full first page of UTxOs so the pagination loop has to fetch a second one.
    var paginatedUtxos = false
    /// A reference script to hang off the first UTxO: hash, Yaci type and CBOR hex.
    var referenceScript: (hash: String, type: String, cbor: String)? = nil
    /// Answer the indexed committee view with an empty member list, forcing the live fallback.
    var emptyIndexedCommittee = false
    let log = YaciRequestLog()

    func send(
        _ request: HTTPTypes.HTTPRequest,
        body: OpenAPIRuntime.HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
        let components = URLComponents(string: request.path ?? "")
        let path = components?.path ?? ""
        let query = components?.query ?? ""
        log.record(operationID: operationID, path: path, query: query)

        let queryItems = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let page = Int(queryItems["page"] ?? "0") ?? 0

        func json(_ text: String, status: HTTPResponse.Status = .ok) -> (
            HTTPResponse, HTTPBody?
        ) {
            (
                HTTPResponse(status: status, headerFields: [.contentType: "application/json"]),
                HTTPBody(Data(text.utf8))
            )
        }

        if let status = failing[operationID] {
            return (
                HTTPResponse(status: .init(code: status), headerFields: [.contentType: "text/plain"]),
                HTTPBody(Data("mock failure for \(operationID)".utf8))
            )
        }
        if let override = overrides[operationID] {
            return json(override)
        }

        switch operationID {
        case "getLatestEpoch":
            return json(#"{"epoch": \#(YaciMockData.currentEpoch), "block_count": 40}"#)

        case "getLatestBlock", "getBlockByNumber":
            return json(
                """
                {"time": 1700000000, "height": 1234, "number": 1234,
                 "hash": "abcd1234efgh5678ijkl9012mnop3456qrst7890uvwx1234yzab5678cdef9012",
                 "slot": 98765, "epoch": \(YaciMockData.currentEpoch), "era": 7, "epoch_slot": 345,
                 "slot_leader": "\(YaciMockData.poolAHex)", "op_cert_counter": "3",
                 "nonce_vrf": null, "leader_vrf": null}
                """)

        case "getBlocksBySlotLeaderEpoch":
            guard path.contains(YaciMockData.poolAHex) || path.contains(YaciMockData.poolABech32),
                queryItems["epoch"] == String(YaciMockData.currentEpoch)
            else { return json("[]") }
            return json(
                #"[{"hash": "b1", "number": 1200, "epoch": 12}, {"hash": "b2", "number": 1234, "epoch": 12}]"#
            )

        case "getLatestProtocolParams":
            return json(YaciMockResponses.protocolParams)

        case "getUtxos_1":
            guard path.contains(YaciMockData.paymentAddress) else { return json("[]") }
            if paginatedUtxos {
                // A full page, then a short one: the second page is only fetched if the
                // pagination loop keeps going.
                let count = page == 0 ? 100 : (page == 1 ? 5 : 0)
                let rows = (0..<count).map { index in
                    """
                    {"tx_hash": "\(YaciMockData.utxoTxHash)", "output_index": \(page * 100 + index),
                     "address": "\(YaciMockData.paymentAddress)",
                     "amount": [{"unit": "lovelace", "quantity": "1000000"}]}
                    """
                }
                return json("[" + rows.joined(separator: ",") + "]")
            }
            guard page == 0 else { return json("[]") }
            let refScript = referenceScript.map { #""reference_script_hash": "\#($0.hash)","# } ?? ""
            return json(
                """
                [
                  {"tx_hash": "\(YaciMockData.utxoTxHash)", "output_index": 0,
                   "address": "\(YaciMockData.paymentAddress)",
                   "amount": [{"unit": "lovelace", "quantity": "1000000"},
                              {"unit": "\(YaciMockData.policyId)\(YaciMockData.assetNameHex)",
                               "policy_id": "\(YaciMockData.policyId)",
                               "asset_name": "\(YaciMockData.assetNameHex)", "quantity": "50"}],
                   "inline_datum": "\(YaciMockData.inlineDatumHex)", \(refScript)
                   "epoch": 12, "block_number": 1200},
                  {"tx_hash": "\(YaciMockData.utxoTxHash)", "output_index": 1,
                   "address": "\(YaciMockData.paymentAddress)",
                   "amount": [{"unit": "lovelace", "quantity": "2000000"}],
                   "data_hash": "\(YaciMockData.dataHash)"}
                ]
                """)

        case "getUtxo":
            if path.hasSuffix("/\(YaciMockData.utxoTxHash)/0") {
                return json(
                    """
                    {"tx_hash": "\(YaciMockData.utxoTxHash)", "output_index": 0,
                     "owner_addr": "\(YaciMockData.paymentAddress)", "lovelace_amount": 1000000,
                     "amounts": [{"unit": "lovelace", "quantity": 1000000},
                                 {"unit": "\(YaciMockData.policyId)\(YaciMockData.assetNameHex)",
                                  "policy_id": "\(YaciMockData.policyId)",
                                  "asset_name": "\(YaciMockData.assetNameHex)", "quantity": 50}],
                     "inline_datum": "\(YaciMockData.inlineDatumHex)"}
                    """)
            }
            if path.hasSuffix("/\(YaciMockData.spentTxHash)/1") {
                return json(
                    """
                    {"tx_hash": "\(YaciMockData.spentTxHash)", "output_index": 1,
                     "owner_addr": "\(YaciMockData.paymentAddress)", "lovelace_amount": 7000000,
                     "amounts": [{"unit": "lovelace", "quantity": 7000000}]}
                    """)
            }
            return (HTTPResponse(status: .notFound), nil)

        case "getScriptByHash":
            if let script = referenceScript, path.contains(script.hash) {
                return json(#"{"script_hash": "\#(script.hash)", "type": "\#(script.type)"}"#)
            }
            return json(
                #"{"script_hash": "\#(YaciMockData.nativeScriptHash)", "type": "timelock"}"#)

        case "getScriptCborByHash":
            guard let script = referenceScript else { return (HTTPResponse(status: .notFound), nil) }
            return json(#"{"cbor": "\#(script.cbor)"}"#)

        case "getScriptJsonByHash":
            return json(#"{"json": {"type": "sig", "keyHash": "\#(YaciMockData.ccHotHex)"}}"#)

        case "submitTx_1":
            guard let body, let data = try? await Data(collecting: body, upTo: 1024 * 1024),
                !data.isEmpty
            else { return (HTTPResponse(status: .badRequest), nil) }
            return json("\"\(YaciMockData.submittedTxHash)\"", status: .accepted)

        case "evaluateTx":
            return json(
                """
                {"result": {"EvaluationResult": {
                    "spend:0": {"memory": 1000000, "steps": 500000000},
                    "withdraw:1": {"memory": 2000, "steps": 3000},
                    "publish:0": {"memory": 10, "steps": 20}
                }}}
                """)

        case "getStakeAccountDetails":
            // Yaci answers 200 with zeroed amounts for any well-formed stake address, including
            // one it has never seen, so the mock does the same rather than 404ing.
            guard path.contains(YaciMockData.stakeAddress) else {
                let unknown = path.split(separator: "/").last.map(String.init) ?? ""
                return json(
                    """
                    {"stake_address": "\(unknown)", "controlled_amount": 0,
                     "withdrawable_amount": 0, "pool_id": null}
                    """)
            }
            return json(
                """
                {"stake_address": "\(YaciMockData.stakeAddress)", "controlled_amount": 619154618165,
                 "withdrawable_amount": 319154618165, "pool_id": "\(YaciMockData.poolABech32)"}
                """)

        case "getStakeRegistrations":
            guard page == 0 else { return json("[]") }
            return json(
                """
                [{"tx_hash": "s1", "cert_index": 0, "slot": 40, "type": "STAKE_REGISTRATION",
                  "address": "\(YaciMockData.stakeAddress)", "epoch": 1},
                 {"tx_hash": "s2", "cert_index": 0, "slot": 70, "type": "REG_CERT",
                  "address": "\(YaciMockData.deregisteredStakeAddress)", "epoch": 1}]
                """)

        case "getStakeDeRegistrations":
            guard page == 0 else { return json("[]") }
            return json(
                """
                [{"tx_hash": "s3", "cert_index": 0, "slot": 90, "type": "UNREG_CERT",
                  "address": "\(YaciMockData.deregisteredStakeAddress)", "epoch": 2}]
                """)

        case "getDelegationsByAddress":
            guard page == 0, path.contains(YaciMockData.stakeAddress) else { return json("[]") }
            return json(
                """
                [{"slot": 50, "cert_index": 0, "address": "\(YaciMockData.stakeAddress)",
                  "drep_type": "ABSTAIN"},
                 {"slot": 60, "cert_index": 0, "address": "\(YaciMockData.stakeAddress)",
                  "drep_type": "ADDR_KEYHASH", "drep_hash": "\(YaciMockData.drepHex)",
                  "drep_id": "\(YaciMockData.drepBech32)"}]
                """)

        case "getPoolRegistrations":
            return json(page == 0 ? YaciMockResponses.poolRegistrations : "[]")

        case "getRetirements":
            guard page == 0 else { return json("[]") }
            return json(
                """
                [{"tx_hash": "r1", "cert_index": 0, "pool_id": "\(YaciMockData.poolAHex)",
                  "retirement_epoch": 10, "epoch": 8, "slot": 200},
                 {"tx_hash": "r2", "cert_index": 0, "pool_id": "\(YaciMockData.poolBHex)",
                  "retirement_epoch": 20, "epoch": 9, "slot": 130},
                 {"tx_hash": "r3", "cert_index": 0, "pool_id": "\(YaciMockData.poolCHex)",
                  "retirement_epoch": 5, "epoch": 3, "slot": 60}]
                """)

        case "getPoolDetails":
            return (HTTPResponse(status: .notFound), nil)

        case "getDRepRegistrations":
            guard page == 0 else { return json("[]") }
            return json(
                """
                [{"tx_hash": "d1", "cert_index": 0, "type": "REG_DREP_CERT", "slot": 10,
                  "deposit": 500000000, "drep_hash": "\(YaciMockData.drepHex)",
                  "drep_id": "\(YaciMockData.drepBech32)", "anchor_url": "https://anchor.test/old",
                  "anchor_hash": "\(YaciMockData.anchorHash)", "cred_type": "ADDR_KEYHASH", "epoch": 1},
                 {"tx_hash": "d2", "cert_index": 0, "type": "REG_DREP_CERT", "slot": 15,
                  "deposit": 500000000, "drep_hash": "\(YaciMockData.retiredDrepHex)",
                  "cred_type": "ADDR_KEYHASH", "epoch": 1}]
                """)

        case "getDRepUpdates":
            guard page == 0 else { return json("[]") }
            return json(
                """
                [{"tx_hash": "d3", "cert_index": 0, "type": "UPDATE_DREP_CERT", "slot": 20,
                  "drep_hash": "\(YaciMockData.drepHex)", "anchor_url": "https://anchor.test/new",
                  "anchor_hash": "\(YaciMockData.anchorHash)", "cred_type": "ADDR_KEYHASH", "epoch": 2}]
                """)

        case "getDRepDeRegistrations":
            guard page == 0 else { return json("[]") }
            return json(
                """
                [{"tx_hash": "d4", "cert_index": 0, "type": "UNREG_DREP_CERT", "slot": 30,
                  "drep_hash": "\(YaciMockData.retiredDrepHex)", "cred_type": "ADDR_KEYHASH", "epoch": 3}]
                """)

        case "getDRepStakeDistr":
            guard path.contains(YaciMockData.drepHex) else {
                return (HTTPResponse(status: .notFound), nil)
            }
            return json(
                #"{"drep_hash": "\#(YaciMockData.drepHex)", "drep_type": "ADDR_KEYHASH", "amount": 4200000, "epoch": 12}"#
            )

        case "getGovActionProposalList":
            guard page == 0 else { return json("[]") }
            return json("[\(YaciMockResponses.treasuryProposal), \(YaciMockResponses.infoProposal)]")

        case "getGovActionProposalByTx":
            if path.contains(YaciMockData.proposalTxHash) {
                return json("[\(YaciMockResponses.treasuryProposal)]")
            }
            if path.contains(YaciMockData.infoProposalTxHash) {
                return json("[\(YaciMockResponses.infoProposal)]")
            }
            return json("[]")

        case "getVotingProceduresByGovActionProposalTx":
            guard page == 0, path.contains(YaciMockData.proposalTxHash) else { return json("[]") }
            // The last row belongs to a different governance action in the same transaction, so
            // it must be filtered out by index rather than counted.
            return json(
                """
                [{"slot": 1, "index": 0, "voter_type": "CONSTITUTIONAL_COMMITTEE_HOT_KEY_HASH",
                  "voter_hash": "\(YaciMockData.ccHotHex)", "vote": "YES", "gov_action_index": 0},
                 {"slot": 2, "index": 0, "voter_type": "DREP_KEY_HASH",
                  "voter_hash": "\(YaciMockData.drepHex)", "vote": "NO", "gov_action_index": 0},
                 {"slot": 3, "index": 0, "voter_type": "STAKING_POOL_KEY_HASH",
                  "voter_hash": "\(YaciMockData.poolAHex)", "vote": "ABSTAIN", "gov_action_index": 0},
                 {"slot": 4, "index": 0, "voter_type": "DREP_KEY_HASH",
                  "voter_hash": "\(YaciMockData.drepHex)", "vote": "YES", "gov_action_index": 0},
                 {"slot": 5, "index": 0, "voter_type": "DREP_KEY_HASH",
                  "voter_hash": "\(YaciMockData.retiredDrepHex)", "vote": "NO", "gov_action_index": 9}]
                """)

        case "getVotingProceduresForGovActionProposal":
            // Yaci's indexed variant drops the stake-pool and committee votes, which is why the
            // backend does not use it. Serving it empty keeps that fact visible.
            return json("[]")

        case "getCommitteeMembers":
            if emptyIndexedCommittee {
                return json(#"{"threshold_numerator": 0, "threshold_denominator": 0, "members": []}"#)
            }
            return json(
                """
                {"threshold_numerator": 2, "threshold_denominator": 3,
                 "members": [
                   {"hash": "\(YaciMockData.ccColdHex)", "cred_type": "SCRIPTHASH",
                    "start_epoch": 0, "expired_epoch": 726},
                   {"hash": "\(YaciMockData.ccColdResignedHex)", "cred_type": "SCRIPTHASH",
                    "start_epoch": 0, "expired_epoch": 653}
                 ]}
                """)

        case "getCommitteeInfo":
            return json(
                """
                {"threshold": 0.6,
                 "members": [{"hash": "\(YaciMockData.ccColdHex)", "cred_type": "SCRIPTHASH",
                              "expired_epoch": 726}]}
                """)

        case "getCommitteeRegistrations":
            guard page == 0 else { return json("[]") }
            return json(
                """
                [{"tx_hash": "c1", "cert_index": 0, "slot": 5, "cold_key": "\(YaciMockData.ccColdHex)",
                  "hot_key": "\(YaciMockData.ccHotHex)", "cred_type": "SCRIPTHASH", "epoch": 0}]
                """)

        case "getCommitteeDeRegistrations":
            guard page == 0 else { return json("[]") }
            return json(
                """
                [{"tx_hash": "c2", "cert_index": 0, "slot": 9,
                  "cold_key": "\(YaciMockData.ccColdResignedHex)", "cred_type": "SCRIPTHASH", "epoch": 0}]
                """)

        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }
}

// MARK: - Canned bodies

enum YaciMockResponses {
    /// `/epochs/latest/parameters` as Yaci Store serves it: cost models as maps keyed by
    /// operation name, string-typed lovelace amounts, and the newer `dvt_ppnetwork_group`
    /// spelling of the DRep thresholds.
    static let protocolParams = """
        {"min_fee_a": 44, "min_fee_b": 155381, "max_block_size": 90112, "max_tx_size": 16384,
         "max_block_header_size": 1100, "key_deposit": "2000000", "pool_deposit": "500000000",
         "e_max": 18, "n_opt": 500, "a0": 0.3, "rho": 0.003, "tau": 0.2,
         "decentralisation_param": 0, "protocol_major_ver": 10, "protocol_minor_ver": 0,
         "min_pool_cost": "170000000",
         "cost_models": {"PlutusV1": {"addInteger-cpu-arguments-intercept": 1,
                                      "addInteger-cpu-arguments-slope": 2},
                         "PlutusV2": {"a": 7, "b": 8, "c": 9},
                         "PlutusV3": {"a": 1, "b": 2, "c": 3}},
         "price_mem": 0.0577, "price_step": 0.0000721,
         "max_tx_ex_mem": "14000000", "max_tx_ex_steps": "10000000000",
         "max_block_ex_mem": "62000000", "max_block_ex_steps": "20000000000",
         "max_val_size": "5000", "collateral_percent": 150, "max_collateral_inputs": 3,
         "coins_per_utxo_size": "4310",
         "pvt_motion_no_confidence": 0.51, "pvt_committee_normal": 0.51,
         "pvt_committee_no_confidence": 0.51, "pvt_hard_fork_initiation": 0.51,
         "pvtpp_security_group": 0.51,
         "dvt_motion_no_confidence": 0.67, "dvt_committee_normal": 0.67,
         "dvt_committee_no_confidence": 0.6, "dvt_update_to_constitution": 0.75,
         "dvt_hard_fork_initiation": 0.6, "dvt_ppnetwork_group": 0.67,
         "dvt_ppeconomic_group": 0.67, "dvt_pptechnical_group": 0.67, "dvt_ppgov_group": 0.75,
         "dvt_treasury_withdrawal": 0.67, "committee_min_size": 7,
         "committee_max_term_length": 146, "gov_action_lifetime": 6,
         "gov_action_deposit": 100000000000, "drep_deposit": 500000000, "drep_activity": 20,
         "min_fee_ref_script_cost_per_byte": 15}
        """

    /// Pool A registers at slot 100, announces retirement at 200, then re-registers at 300 —
    /// which cancels the retirement. Pool B registers at 120 and is retiring at epoch 20.
    /// Pool C registers at 50 and retired at epoch 5.
    static let poolRegistrations = """
        [{"tx_hash": "p1", "cert_index": 0, "pool_id": "\(YaciMockData.poolAHex)",
          "pool_id_bech32": "\(YaciMockData.poolABech32)",
          "vrf_key_hash": "\(YaciMockData.vrfKeyHash)",
          "pledge": 1000000000, "cost": 340000000, "margin": 0.01,
          "reward_account": "\(YaciMockData.stakeAddress)",
          "pool_owners": ["\(YaciMockData.ccHotHex)"], "relays": [], "epoch": 4, "slot": 100},
         {"tx_hash": "p2", "cert_index": 0, "pool_id": "\(YaciMockData.poolBHex)",
          "vrf_key_hash": "\(YaciMockData.vrfKeyHash)",
          "pledge": 5, "cost": 6, "margin": 0.5,
          "reward_account": "\(YaciMockData.stakeAddress)", "pool_owners": [], "relays": [],
          "epoch": 4, "slot": 120},
         {"tx_hash": "p3", "cert_index": 0, "pool_id": "\(YaciMockData.poolCHex)",
          "vrf_key_hash": "\(YaciMockData.vrfKeyHash)",
          "pledge": 1, "cost": 2, "margin": 0.0,
          "reward_account": "\(YaciMockData.stakeAddress)", "pool_owners": [], "relays": [],
          "epoch": 2, "slot": 50},
         {"tx_hash": "p4", "cert_index": 1, "pool_id": "\(YaciMockData.poolAHex)",
          "pool_id_bech32": "\(YaciMockData.poolABech32)",
          "vrf_key_hash": "\(YaciMockData.vrfKeyHash)",
          "pledge": 2000000000, "cost": 345000000, "margin": 0.05,
          "margin_numerator": 1, "margin_denominator": 20,
          "reward_account": "\(YaciMockData.stakeAddress)",
          "pool_owners": ["\(YaciMockData.ccHotHex)", "\(YaciMockData.stakeAddress)"],
          "relays": [{"port": 3001, "ipv4": "203.0.113.7"},
                     {"port": 6000, "dnsName": "relay.example.com"},
                     {"port": 0, "dnsName": "_cardano._tcp.example.com"}],
          "metadata_url": "https://example.com/pool.json",
          "metadata_hash": "\(YaciMockData.anchorHash)", "epoch": 11, "slot": 300}]
        """

    static let treasuryProposal = """
        {"tx_hash": "\(YaciMockData.proposalTxHash)", "index": 0, "slot": 400,
         "deposit": 100000000000, "return_address": "\(YaciMockData.stakeAddress)",
         "type": "TREASURY_WITHDRAWALS_ACTION",
         "details": {"type": "TREASURY_WITHDRAWALS_ACTION",
                     "withdrawals": {"\(YaciMockData.stakeAddress)": 8035714000000},
                     "policyHash": null},
         "anchor_url": "https://example.com", "anchor_hash": "\(YaciMockData.anchorHash)",
         "epoch": 10}
        """

    static let infoProposal = """
        {"tx_hash": "\(YaciMockData.infoProposalTxHash)", "index": 0, "slot": 500,
         "deposit": 100000000000, "return_address": "\(YaciMockData.stakeAddress)",
         "type": "INFO_ACTION", "details": {"type": "INFO_ACTION"}, "epoch": 11}
        """
}
