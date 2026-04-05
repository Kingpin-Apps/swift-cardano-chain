import Foundation
import OpenAPIRuntime
import HTTPTypes
import SwiftKoios


// MARK: - Koios Mock Transport

struct KoiosMockTransport: ClientTransport {
    func send(
        _ request: HTTPTypes.HTTPRequest,
        body: OpenAPIRuntime.HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
        var responseBody: Data = Data()
        var statusCode: HTTPResponse.Status = .ok
        
        switch operationID {
            case "epoch_info":
                responseBody = try JSONEncoder().encode([
                    KoiosEpochInfo(
                        epochNo: 500,
                        outSum: "1000000000000",
                        fees: "100000000",
                        txCount: 10000,
                        blkCount: 21600,
                        startTime: Int(Date().timeIntervalSince1970) - 86400,
                        endTime: Int(Date().timeIntervalSince1970) + 86400,
                        firstBlockTime: Int(Date().timeIntervalSince1970) - 86400,
                        lastBlockTime: Int(Date().timeIntervalSince1970),
                        activeStake: "25000000000000000",
                        totalRewards: "500000000000",
                        avgBlkReward: "500000000"
                    )
                ])
                
            case "totals":
                responseBody = try JSONEncoder().encode([
                    Components.Schemas.TotalsPayload(
                        epochNo: 500,
                        circulation: "45000000000000000",
                        treasury: "1000000000000000",
                        reward: "5000000000000000",
                        supply: "2000000000000000",
                        reserves: "38000000000000000",
                        fees: "15000000000000000",
                        depositsStake: "2000000000000000",
                        depositsDrep: "10000000000000",
                        depositsProposal: "10000000000000",
                        
                    )
                ])
                
            case "drep_info":
                responseBody = """
            [
                {
                    "drep_id": "drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0",
                    "hex": "b02f7b335aebf284bbdc20bdc3b59e4e183ae2cfc47ad2d8bc19a241",
                    "has_script": false,
                    "drep_status": "registered",
                    "deposit": "500000000",
                    "active": true,
                    "expires_epoch_no": 639,
                    "amount": "500000000",
                    "meta_url": "https://anchor.test",
                    "meta_hash": "35aeb21ba4be07cf9fda041b635f107ef978238b3fccae9be1b571518ce9d1b7"
                },
            ]
            """.data(using: .utf8)!
                
            case "tip":
                responseBody = """
            [{
                "hash": "abcd1234efgh5678ijkl9012mnop3456qrst7890uvwx1234yzab5678cdef9012",
                "epoch_no": 500,
                "abs_slot": 123456789,
                "epoch_slot": 65579,
                "block_no": 123456,
                "block_time": \(Int(Date().timeIntervalSince1970))
            }]
            """.data(using: .utf8)!
                
            case "genesis":
                responseBody = """
            [{
                "networkmagic": "2",
                "networkid": "preview",
                "activeslotcoeff": "0.05",
                "updatequorum": "5",
                "maxlovelacesupply": "45000000000000000",
                "epochlength": "432000",
                "systemstart": \(Int(Date(timeIntervalSince1970: 1654041600).timeIntervalSince1970)),
                "slotsperkesperiod": "129600",
                "slotlength": "1",
                "maxkesrevolutions": "62",
                "securityparam": "2160",
                "alonzogenesis": "genesis.alonzo.json"
            }]
            """.data(using: .utf8)!
                
            case "cli_protocol_params":
                responseBody = KoiosMockResponses.protocolParams.data(using: .utf8)!
                
            case "address_utxos":
                responseBody = """
            [{
                "tx_hash": "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58",
                "tx_index": 0,
                "address": "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3",
                "value": [
                    {"unit": "lovelace", "quantity": "1000000"},
                    {"unit": "b0d07d45fe9514f80213f4020e5a61241458be626841cde717cb38a76e7574636f696e", "quantity": "50"}
                ],
                "stake_address": null,
                "payment_cred": null,
                "epoch_no": 500,
                "block_height": 123456,
                "block_time": \(Int(Date().timeIntervalSince1970)),
                "datum_hash": null,
                "inline_datum": null,
                "reference_script": null,
                "asset_list": null,
                "is_spent": false
            }]
            """.data(using: .utf8)!
                
            case "utxo_info":
                responseBody = """
            [{
                "tx_hash": "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58",
                "tx_index": 0,
                "address": "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3",
                "value": "1000000",
                "stake_address": null,
                "payment_cred": null,
                "epoch_no": 500,
                "block_height": 123456,
                "block_time": \(Int(Date().timeIntervalSince1970)),
                "datum_hash": null,
                "inline_datum": null,
                "reference_script": null,
                "asset_list": [
                    {"policy_id": "b0d07d45fe9514f80213f4020e5a61241458be626841cde717cb38a76e7574636f696e", "asset_name": "6574636f696e", "quantity": "50"}
                ],
                "is_spent": false
            }]
            """.data(using: .utf8)!
                
            case "submittx":
                responseBody = try JSONEncoder().encode(
                    "d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908"
                )
                statusCode = .accepted
                
            case "ogmios":
                responseBody = """
            {
                "jsonrpc": "2.0",
                "method": "evaluateTransaction",
                "result": [
                    {
                        "validator": {"purpose": "spend", "index": 0},
                        "budget": {"memory": 1000000, "cpu": 500000000}
                    }
                ]
            }
            """.data(using: .utf8)!
                
            case "account_info":
                responseBody = """
            [{
                "stake_address": "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",
                "status": "registered",
                "delegated_pool": "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy",
                "delegated_drep": "drep15cfxz9exyn5rx0807zvxfrvslrjqfchrd4d47kv9e0f46uedqtc",
                "total_balance": "619154618165",
                "utxo": "300000000000",
                "rewards": "319154618165",
                "withdrawals": "12125369253",
                "rewards_available": "319154618165"
            }]
            """.data(using: .utf8)!
                
            case "pool_list":
                responseBody = """
            [
                {"pool_id_bech32": "pool1qqa8tkycj4zck4sy7n8mqr22x5g7tvm8hnp9st95wmuvvtw28th"},
                {"pool_id_bech32": "pool1qzq896ke4meh0tn9fl0dcnvtn2rzdz75lk3h8nmsuew8z5uln7r"},
                {"pool_id_bech32": "pool1qzhrd5sd0v0r6q2kqmaz07tvgry72whcjw0xsmnttgyuxtzpkkx"}
            ]
            """.data(using: .utf8)!
                
            case "pool_info":
                responseBody = """
            [{
                "pool_id_bech32": "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy",
                "pool_id_hex": "0f292fcaa02b8b2f9b3c8f9fd8e0bb21abedb692a6d5058df3ef2735",
                "active_epoch_no": 100,
                "vrf_key_hash": "vrf_key_hash",
                "margin": 0.05,
                "fixed_cost": "340000000",
                "pledge": "1000000000000",
                "reward_addr": "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",
                "owners": ["stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n"],
                "relays": [],
                "meta_url": null,
                "meta_hash": null,
                "meta_json": null,
                "pool_status": "registered",
                "retiring_epoch": null,
                "op_cert": "opcert_hash",
                "op_cert_counter": 42,
                "active_stake": "1000000000000",
                "sigma": 0.001,
                "block_count": 1000,
                "live_pledge": "1000000000000",
                "live_stake": "1000000000000",
                "live_delegators": 100,
                "live_saturation": 0.5
            }]
            """.data(using: .utf8)!
                
            default:
                return (
                    HTTPResponse(status: .notFound),
                    nil
                )
        }
        
        return (
            HTTPResponse(
                status: statusCode,
                headerFields: [.contentType: "application/json"]
            ),
            .init(responseBody)
        )
    }
}

// MARK: - Koios Mock Response Types

struct KoiosEpochInfo: Codable {
    let epochNo: Int
    let outSum: String
    let fees: String
    let txCount: Int
    let blkCount: Int
    let startTime: Int
    let endTime: Int
    let firstBlockTime: Int
    let lastBlockTime: Int
    let activeStake: String?
    let totalRewards: String?
    let avgBlkReward: String?
    
    enum CodingKeys: String, CodingKey {
        case epochNo = "epoch_no"
        case outSum = "out_sum"
        case fees
        case txCount = "tx_count"
        case blkCount = "blk_count"
        case startTime = "start_time"
        case endTime = "end_time"
        case firstBlockTime = "first_block_time"
        case lastBlockTime = "last_block_time"
        case activeStake = "active_stake"
        case totalRewards = "total_rewards"
        case avgBlkReward = "avg_blk_reward"
    }
}

struct KoiosMockResponses {
    static let protocolParams = """
    {"collateralPercentage":150,"committeeMaxTermLength":146,"committeeMinSize":7,"costModels":{"PlutusV1":[100788,420,1,1,1000,173,0,1,1000,59957,4,1,11183,32,201305,8356,4,16000,100,16000,100,16000,100,16000,100,16000,100,16000,100,100,100,16000,100,94375,32,132994,32,61462,4,72010,178,0,1,22151,32,91189,769,4,2,85848,228465,122,0,1,1,1000,42921,4,2,24548,29498,38,1,898148,27279,1,51775,558,1,39184,1000,60594,1,141895,32,83150,32,15299,32,76049,1,13169,4,22100,10,28999,74,1,28999,74,1,43285,552,1,44749,541,1,33852,32,68246,32,72362,32,7243,32,7391,32,11546,32,85848,228465,122,0,1,1,90434,519,0,1,74433,32,85848,228465,122,0,1,1,85848,228465,122,0,1,1,270652,22588,4,1457325,64566,4,20467,1,4,0,141992,32,100788,420,1,1,81663,32,59498,32,20142,32,24588,32,20744,32,25933,32,24623,32,53384111,14333,10],"PlutusV2":[100788,420,1,1,1000,173,0,1,1000,59957,4,1,11183,32,201305,8356,4,16000,100,16000,100,16000,100,16000,100,16000,100,16000,100,100,100,16000,100,94375,32,132994,32,61462,4,72010,178,0,1,22151,32,91189,769,4,2,85848,228465,122,0,1,1,1000,42921,4,2,24548,29498,38,1,898148,27279,1,51775,558,1,39184,1000,60594,1,141895,32,83150,32,15299,32,76049,1,13169,4,22100,10,28999,74,1,28999,74,1,43285,552,1,44749,541,1,33852,32,68246,32,72362,32,7243,32,7391,32,11546,32,85848,228465,122,0,1,1,90434,519,0,1,74433,32,85848,228465,122,0,1,1,85848,228465,122,0,1,1,955506,213312,0,2,270652,22588,4,1457325,64566,4,20467,1,4,0,141992,32,100788,420,1,1,81663,32,59498,32,20142,32,24588,32,20744,32,25933,32,24623,32,43053543,10,53384111,14333,10,43574283,26308,10],"PlutusV3":[100788,420,1,1,1000,173,0,1,1000,59957,4,1,11183,32,201305,8356,4,16000,100,16000,100,16000,100,16000,100,16000,100,16000,100,100,100,16000,100,94375,32,132994,32,61462,4,72010,178,0,1,22151,32,91189,769,4,2,85848,123203,7305,-900,1716,549,57,85848,0,1,1,1000,42921,4,2,24548,29498,38,1,898148,27279,1,51775,558,1,39184,1000,60594,1,141895,32,83150,32,15299,32,76049,1,13169,4,22100,10,28999,74,1,28999,74,1,43285,552,1,44749,541,1,33852,32,68246,32,72362,32,7243,32,7391,32,11546,32,85848,123203,7305,-900,1716,549,57,85848,0,1,90434,519,0,1,74433,32,85848,123203,7305,-900,1716,549,57,85848,0,1,1,85848,123203,7305,-900,1716,549,57,85848,0,1,955506,213312,0,2,270652,22588,4,1457325,64566,4,20467,1,4,0,141992,32,100788,420,1,1,81663,32,59498,32,20142,32,24588,32,20744,32,25933,32,24623,32,43053543,10,53384111,14333,10,43574283,26308,10,16000,100,16000,100,962335,18,2780678,6,442008,1,52538055,3756,18,267929,18,76433006,8868,18,52948122,18,1995836,36,3227919,12,901022,1,166917843,4307,36,284546,36,158221314,26549,36,74698472,36,333849714,1,254006273,72,2174038,72,2261318,64571,4,207616,8310,4,1293828,28716,63,0,1,1006041,43623,251,0,1,100181,726,719,0,1,100181,726,719,0,1,100181,726,719,0,1,107878,680,0,1,95336,1,281145,18848,0,1,180194,159,1,1,158519,8942,0,1,159378,8813,0,1,107490,3298,1,106057,655,1,1964219,24520,3]},"dRepActivity":20,"dRepDeposit":500000000,"dRepVotingThresholds":{"committeeNoConfidence":0.6,"committeeNormal":0.67,"hardForkInitiation":0.6,"motionNoConfidence":0.67,"ppEconomicGroup":0.67,"ppGovGroup":0.75,"ppNetworkGroup":0.67,"ppTechnicalGroup":0.67,"treasuryWithdrawal":0.67,"updateToConstitution":0.75},"executionUnitPrices":{"priceMemory":0.0577,"priceSteps":0.0000721},"govActionDeposit":100000000000,"govActionLifetime":6,"maxBlockBodySize":90112,"maxBlockExecutionUnits":{"memory":62000000,"steps":20000000000},"maxBlockHeaderSize":1100,"maxCollateralInputs":3,"maxTxExecutionUnits":{"memory":14000000,"steps":10000000000},"maxTxSize":16384,"maxValueSize":5000,"minFeeRefScriptCostPerByte":15,"minPoolCost":170000000,"monetaryExpansion":0.003,"poolPledgeInfluence":0.3,"poolRetireMaxEpoch":18,"poolVotingThresholds":{"committeeNoConfidence":0.51,"committeeNormal":0.51,"hardForkInitiation":0.51,"motionNoConfidence":0.51,"ppSecurityGroup":0.51},"protocolVersion":{"major":10,"minor":0},"stakeAddressDeposit":2000000,"stakePoolDeposit":500000000,"stakePoolTargetNum":500,"treasuryCut":0.2,"txFeeFixed":155381,"txFeePerByte":44,"utxoCostPerByte":4310}
    """
}
