import Testing
import Foundation
import SwiftCardanoCore
import SwiftKoios
import OpenAPIRuntime
import HTTPTypes
@testable import SwiftCardanoChain

@Suite("Koios Chain Context Tests")
struct KoiosChainContextTests {
    @Test("Test Initialization", arguments: [
        (Network.mainnet, NetworkId.mainnet),
        (Network.preprod, NetworkId.testnet),
        (Network.preview, NetworkId.testnet),
    ])
    func testInit(_ networks: (SwiftCardanoCore.Network, NetworkId)) async throws {
        let koiosNetwork: SwiftKoios.Network
        switch networks.0 {
        case .mainnet:
            koiosNetwork = .mainnet
        case .preprod:
            koiosNetwork = .preprod
        case .preview:
            koiosNetwork = .preview
        default:
            koiosNetwork = .mainnet
        }
        
        let chainContext = try await KoiosChainContext(
            network: networks.0,
            client: Client(
                serverURL: try koiosNetwork.url(),
                transport: KoiosMockTransport()
            )
        )
        
        let epoch = try await chainContext.epoch()
        let network = chainContext.networkId
        
        #expect(network == networks.1)
        #expect(epoch == 500)
    }
    
    @Test("Test lastBlockSlot")
    func testLastBlockSlot() async throws {
        let chainContext = try await KoiosChainContext(
            network: .preview,
            client: Client(
                serverURL: try SwiftKoios.Network.preview.url(),
                transport: KoiosMockTransport()
            )
        )
        
        let lastBlockSlot = try await chainContext.lastBlockSlot()
        
        #expect(lastBlockSlot == 123456789)
    }
    
    @Test("Test genesisParameters")
    func testGenesisParameters() async throws {
        let chainContext = try await KoiosChainContext(
            network: .preview,
            client: Client(
                serverURL: try SwiftKoios.Network.preview.url(),
                transport: KoiosMockTransport()
            )
        )
        
        let genesisParameters = try await chainContext.genesisParameters()
        
        #expect(genesisParameters.activeSlotsCoefficient == 0.05)
        #expect(genesisParameters.epochLength == 432000)
        #expect(genesisParameters.maxKesEvolutions == 62)
        #expect(genesisParameters.maxLovelaceSupply == 45000000000000000)
        #expect(genesisParameters.networkId == "preview")
        #expect(genesisParameters.networkMagic == 2)
        #expect(genesisParameters.slotLength == 1)
        #expect(genesisParameters.securityParam == 2160)
        #expect(genesisParameters.slotsPerKesPeriod == 129600)
        #expect(genesisParameters.updateQuorum == 5)
    }
    
    @Test("Test protocolParameters", .disabled("Requires investigation of OpenAPI object container handling"))
    func testProtocolParameters() async throws {
        let chainContext = try await KoiosChainContext(
            network: .preview,
            client: Client(
                serverURL: try SwiftKoios.Network.preview.url(),
                transport: KoiosMockTransport()
            )
        )
        
        let protocolParameters = try await chainContext.protocolParameters()
        
        #expect(protocolParameters.txFeePerByte == 44)
        #expect(protocolParameters.txFeeFixed == 155381)
    }
    
    @Test("Test utxos")
    func testUTxOs() async throws {
        let chainContext = try await KoiosChainContext(
            network: .preview,
            client: Client(
                serverURL: try SwiftKoios.Network.preview.url(),
                transport: KoiosMockTransport()
            )
        )
        
        let address = try Address(
            from: .string(
                "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3"
            )
        )
        
        let utxos = try await chainContext.utxos(address: address)
        
        #expect(utxos.count == 1)
        #expect(
            utxos[0].input.transactionId.payload.toHex == "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58"
        )
        #expect(utxos[0].output.amount.coin == 1000000)
    }
    
    @Test("Test submitTxCBOR")
    func testSubmitTxCBOR() async throws {
        let chainContext = try await KoiosChainContext(
            network: .preview,
            client: Client(
                serverURL: try SwiftKoios.Network.preview.url(),
                transport: KoiosMockTransport()
            )
        )
        
        let txCBOR = "84a70081825820b35a4ba9ef3ce21adcd6879d08553642224304704d206c74d3ffb3e6eed3ca28000d80018182581d60cc30497f4ff962f4c1dca54cceefe39f86f1d7179668009f8eb71e598200a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680021a000493e00e8009a1581cec8b7d1dd0b124e8333d3fa8d818f6eac068231a287554e9ceae490ea24f5365636f6e6454657374746f6b656e1a009896804954657374746f6b656e1a00989680075820592a2df0e091566969b3044626faa8023dabe6f39c78f33bed9e105e55159221a200828258206443a101bdb948366fc87369336224595d36d8b0eee5602cba8b81a024e584735840846f408dee3b101fda0f0f7ca89e18b724b7ca6266eb29775d3967d6920cae7457accb91def9b77571e15dd2ede38b12cf92496ce7382fa19eb90ab7f73e49008258205797dc2cc919dfec0bb849551ebdf30d96e5cbe0f33f734a87fe826db30f7ef95840bdc771aa7b8c86a8ffcbe1b7a479c68503c8aa0ffde8059443055bf3e54b92f4fca5e0b9ca5bb11ab23b1390bb9ffce414fa398fc0b17f4dc76fe9f7e2c99c09018182018482051a075bcd1582041a075bcd0c8200581c9139e5c0a42f0f2389634c3dd18dc621f5594c5ba825d9a8883c66278200581c835600a2be276a18a4bebf0225d728f090f724f4c0acd591d066fa6ff5d90103a100a11902d1a16b7b706f6c6963795f69647da16d7b706f6c6963795f6e616d657da66b6465736372697074696f6e6a3c6f7074696f6e616c3e65696d6167656a3c72657175697265643e686c6f636174696f6ea367617277656176656a3c6f7074696f6e616c3e6568747470736a3c6f7074696f6e616c3e64697066736a3c72657175697265643e646e616d656a3c72657175697265643e667368613235366a3c72657175697265643e64747970656a3c72657175697265643e"
        
        let tx = try Transaction.fromCBORHex(txCBOR)
        
        let txId1 = try await chainContext.submitTx(tx: .transaction(tx))
        let txId2 = try await chainContext.submitTx(tx: .bytes(txCBOR.toData))
        let txId3 = try await chainContext.submitTx(tx: .string(txCBOR))
        
        #expect(
            txId1 == "d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908"
        )
        #expect(
            txId2 == "d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908"
        )
        #expect(
            txId3 == "d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908"
        )
    }
    
    @Test("Test stakeAddressInfo")
    func testStakeAddressInfo() async throws {
        let chainContext = try await KoiosChainContext(
            network: .preview,
            client: Client(
                serverURL: try SwiftKoios.Network.preview.url(),
                transport: KoiosMockTransport()
            )
        )
        
        let address = try Address(
            from: .string(
                "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n"
            )
        )
        
        let stakeAddressInfo = try await chainContext.stakeAddressInfo(address: address)
        
        #expect(
            stakeAddressInfo[0].address == "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n"
        )
        #expect(
            stakeAddressInfo[0].rewardAccountBalance == 319154618165
        )
        #expect(
            try stakeAddressInfo[0].stakeDelegation?.id() == "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy"
        )
    }
    
    @Test("Test stakePools")
    func testStakePools() async throws {
        let chainContext = try await KoiosChainContext(
            network: .preview,
            client: Client(
                serverURL: try SwiftKoios.Network.preview.url(),
                transport: KoiosMockTransport()
            )
        )
        
        let pools = try await chainContext.stakePools()
        
        #expect(pools.count == 3)
        #expect(pools.contains("pool1qqa8tkycj4zck4sy7n8mqr22x5g7tvm8hnp9st95wmuvvtw28th"))
    }
    
    @Test("Test queryChainTip")
    func testQueryChainTip() async throws {
        let chainContext = try await KoiosChainContext(
            network: .preview,
            client: Client(
                serverURL: try SwiftKoios.Network.preview.url(),
                transport: KoiosMockTransport()
            )
        )
        
        let tip = try await chainContext.queryChainTip()
        
        #expect(tip.block == 123456)
        #expect(tip.epoch == 500)
        #expect(tip.slot == 123456789)
        #expect(tip.hash == "abcd1234efgh5678ijkl9012mnop3456qrst7890uvwx1234yzab5678cdef9012")
    }
}

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
