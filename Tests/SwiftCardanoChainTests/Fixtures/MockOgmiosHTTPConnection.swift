import Foundation
import SwiftOgmios
import SwiftCardanoCore
@testable import SwiftCardanoChain

// MARK: - Mock Infrastructure

/// Mock HTTP connection that routes JSON-RPC requests to pre-defined responses.
final class MockOgmiosHTTPConnection: HTTPConnectable, @unchecked Sendable {
    
    func sendRequest(json: String) async throws -> Data {
        guard let requestData = json.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let method = request["method"] as? String
        else {
            return Data()
        }
        
        switch method {
            case "queryLedgerState/epoch":
                return OgmiosMockData.epoch
            case "queryLedgerState/tip":
                return OgmiosMockData.tip
            case "queryNetwork/genesisConfiguration":
                return OgmiosMockData.genesisConfigurationShelley
            case "queryLedgerState/protocolParameters":
                return OgmiosMockData.protocolParameters
            case "queryLedgerState/stakePools":
                return OgmiosMockData.stakePools
            case "queryLedgerState/utxo":
                return OgmiosMockData.utxo
            case "queryLedgerState/rewardAccountSummaries":
                return OgmiosMockData.rewardAccountSummaries
            case "queryLedgerState/operationalCertificates":
                return OgmiosMockData.operationalCertificates
            case "queryLedgerState/stakePoolsPerformances":
                return OgmiosMockData.stakePoolsPerformances
            case "queryLedgerState/treasuryAndReserves":
                return OgmiosMockData.treasury
            case "submitTransaction":
                return OgmiosMockData.submitTransaction
            case "evaluateTransaction":
                return OgmiosMockData.evaluateTransaction
            default:
                return Data()
        }
    }
    
    func get(url: URL) async throws -> Data {
        return OgmiosMockData.health
    }
}

/// Pre-defined mock JSON responses for Ogmios API.
enum OgmiosMockData {
    
    static let epoch = """
    {
      "result" : 1052,
      "method" : "queryLedgerState/epoch",
      "id" : "5ZrIS",
      "jsonrpc" : "2.0"
    }
    """.data(using: .utf8)!
    
    static let tip = """
    {
      "method" : "queryLedgerState/tip",
      "jsonrpc" : "2.0",
      "result" : {
        "id" : "4dc5188a99ce636e624ab72104f6f18031dcd849c151ce1c8ef4871b7c3913b9",
        "slot" : 90918798
      },
      "id" : "9mkRM"
    }
    """.data(using: .utf8)!
    
    static let genesisConfigurationShelley = """
    {"jsonrpc":"2.0","method":"queryNetwork/genesisConfiguration","result":{"era":"shelley","startTime":"2022-10-25T00:00:00Z","networkMagic":2,"network":"testnet","activeSlotsCoefficient":"1/20","securityParameter":432,"epochLength":86400,"slotsPerKesPeriod":129600,"maxKesEvolutions":62,"slotLength":{"milliseconds":1000},"updateQuorum":5,"maxLovelaceSupply":45000000000000000,"initialParameters":{"minFeeCoefficient":44,"minFeeConstant":{"ada":{"lovelace":155381}},"maxBlockBodySize":{"bytes":65536},"maxBlockHeaderSize":{"bytes":1100},"maxTransactionSize":{"bytes":16384},"stakeCredentialDeposit":{"ada":{"lovelace":2000000}},"stakePoolDeposit":{"ada":{"lovelace":500000000}},"stakePoolRetirementEpochBound":18,"desiredNumberOfStakePools":150,"stakePoolPledgeInfluence":"3/10","minStakePoolCost":{"ada":{"lovelace":340000000}},"monetaryExpansion":"3/1000","treasuryExpansion":"1/5","federatedBlockProductionRatio":"1/1","extraEntropy":"neutral","minUtxoDepositConstant":{"ada":{"lovelace":1000000}},"minUtxoDepositCoefficient":0,"version":{"major":6,"minor":0}},"initialDelegates":[],"initialFunds":{},"initialStakePools":{"stakePools":{},"delegators":{}}},"id":"jNkSV"}
    """.data(using: .utf8)!
    
    static let protocolParameters = """
    {
        "jsonrpc": "2.0",
        "method": "queryLedgerState/protocolParameters",
        "result": {
            "minFeeCoefficient": 44,
            "minFeeConstant": {"ada": {"lovelace": 155381}},
            "minFeeReferenceScripts": {"base": 15.0, "range": 25600, "multiplier": 1.2},
            "maxBlockBodySize": {"bytes": 90112},
            "maxBlockHeaderSize": {"bytes": 1100},
            "maxTransactionSize": {"bytes": 16384},
            "stakeCredentialDeposit": {"ada": {"lovelace": 2000000}},
            "stakePoolDeposit": {"ada": {"lovelace": 500000000}},
            "stakePoolRetirementEpochBound": 18,
            "desiredNumberOfStakePools": 500,
            "stakePoolPledgeInfluence": "3/10",
            "monetaryExpansion": "3/1000",
            "treasuryExpansion": "1/5",
            "minStakePoolCost": {"ada": {"lovelace": 170000000}},
            "minUtxoDepositConstant": {"ada": {"lovelace": 0}},
            "minUtxoDepositCoefficient": 4310,
            "maxValueSize": {"bytes": 5000},
            "collateralPercentage": 150,
            "maxCollateralInputs": 3,
            "maxExecutionUnitsPerBlock": {"memory": 62000000, "cpu": 20000000000},
            "maxExecutionUnitsPerTransaction": {"memory": 14000000, "cpu": 10000000000},
            "scriptExecutionPrices": {"memory": "577/10000", "cpu": "721/10000000"},
            "version": {"major": 10, "minor": 0},
            "governanceActionDeposit": {"ada": {"lovelace": 100000000000}},
            "governanceActionLifetime": 6,
            "delegateRepresentativeDeposit": {"ada": {"lovelace": 500000000}},
            "delegateRepresentativeMaxIdleTime": 20,
            "constitutionalCommitteeMinSize": 7,
            "constitutionalCommitteeMaxTermLength": 146
        },
        "id": null
    }
    """.data(using: .utf8)!
    
    static let stakePools = """
    {
        "jsonrpc": "2.0",
        "method": "queryLedgerState/stakePools",
        "result": {
            "pool1qqa8tkycj4zck4sy7n8mqr22x5g7tvm8hnp9st95wmuvvtw28th": {
                "id": "pool1qqa8tkycj4zck4sy7n8mqr22x5g7tvm8hnp9st95wmuvvtw28th",
                "vrfVerificationKeyHash": "44b93933fc9cba358fdc9bab0f9b5762ecf31c5a32fcdfad63ea2ff9bc385f07",
                "owners": ["1b515807ebb8a99331ddeb20395267e83f29b80716ada5ea37c0a062"],
                "cost": {"ada": {"lovelace": 340000000}},
                "margin": "0/1",
                "pledge": {"ada": {"lovelace": 500000000}},
                "rewardAccount": "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",
                "metadata": {
                    "url": "https://example.com/pool-metadata.json",
                    "hash": "b5f8f69913ca29e453f2ac9fd0d2a906e2f50f75d14ee78d2afb08cbb5a96294"
                },
                "relays": [
                    {
                        "type": "singleHostName",
                        "hostname": "relay.example.com",
                        "port": 3001
                    }
                ],
                "stake": {"ada": {"lovelace": 13492420330}}
            },
            "pool1qzq896ke4meh0tn9fl0dcnvtn2rzdz75lk3h8nmsuew8z5uln7r": {
                "id": "pool1qzq896ke4meh0tn9fl0dcnvtn2rzdz75lk3h8nmsuew8z5uln7r",
                "vrfVerificationKeyHash": "a63ae2342ab8c541978c1f12f0a2338b78b1486c9c6fcdc5d516df4f08bbd93f",
                "owners": ["2c234567abb8a99331ddeb20395267e83f29b80716ada5ea37c0a062"],
                "cost": {"ada": {"lovelace": 170000000}},
                "margin": "1/100",
                "pledge": {"ada": {"lovelace": 1000000000}},
                "rewardAccount": "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",
                "relays": [
                    {
                        "type": "singleHostAddr",
                        "ipv4": "192.168.1.100",
                        "port": 3001
                    }
                ]
            }
        },
        "id": null
    }
    """.data(using: .utf8)!
    
    static let utxo = """
    {
        "jsonrpc": "2.0",
        "method": "queryLedgerState/utxo",
        "result": [
            {
                "transaction": {
                    "id": "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58"
                },
                "index": 0,
                "address": "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3",
                "value": {
                    "ada": {
                        "lovelace": 5000000
                    }
                }
            },
            {
                "transaction": {
                    "id": "b35a4ba9ef3ce21adcd6879d08553642224304704d206c74d3ffb3e6eed3ca28"
                },
                "index": 1,
                "address": "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3",
                "value": {
                    "ada": {
                        "lovelace": 2000000
                    }
                }
            }
        ],
        "id": null
    }
    """.data(using: .utf8)!
    
    static let rewardAccountSummaries = """
    {
        "jsonrpc": "2.0",
        "method": "queryLedgerState/rewardAccountSummaries",
        "result": [
            {
                "from": "verificationKey",
                "credential": "1b515807ebb8a99331ddeb20395267e83f29b80716ada5ea37c0a062",
                "rewards": {
                    "ada": {
                        "lovelace": 91570554888
                    }
                },
                "deposit": {
                    "ada": {
                        "lovelace": 2000000
                    }
                }
            }
        ],
        "id": null
    }
    """.data(using: .utf8)!
    
    static let operationalCertificates = """
    {
      "jsonrpc" : "2.0",
      "id" : "4tKK9",
      "method" : "queryLedgerState/operationalCertificates",
      "result" : {
        "pool1ssvpmsymcz8nd6tu3wgdhy93ajw0yrdauh9gp3djxvda5g6nqma" : 0,
        "pool14cwzrv0mtr68kp44t9fn5wplk9ku20g6rv98sxggd3azg60qukm" : 6,
        "pool18ut2jlv66s0dh70pp4za2pu42dg57jynflkj9fexamcfqcsmc5q" : 0
      }
    }
    """.data(using: .utf8)!
    
    static let stakePoolsPerformances = """
    {
        "jsonrpc": "2.0",
        "method": "queryLedgerState/stakePoolsPerformances",
        "result": {
            "desiredNumberOfStakePools": 500,
            "stakePoolPledgeInfluence": "3/10",
            "totalRewardsInEpoch": {"ada": {"lovelace": 13695546392205}},
            "activeStakeInEpoch": {"ada": {"lovelace": 950528788771851}},
            "totalStakeInEpoch": {"ada": {"lovelace": 36069364086442721}},
            "stakePools": {
                "pool1qqa8tkycj4zck4sy7n8mqr22x5g7tvm8hnp9st95wmuvvtw28th": {
                    "id": "pool1qqa8tkycj4zck4sy7n8mqr22x5g7tvm8hnp9st95wmuvvtw28th",
                    "stake": {"ada": {"lovelace": 13492420330}},
                    "ownerStake": {"ada": {"lovelace": 2497634194}},
                    "approximatePerformance": 0.885,
                    "parameters": {
                        "cost": {"ada": {"lovelace": 340000000}},
                        "margin": "0/1",
                        "pledge": {"ada": {"lovelace": 500000000}}
                    }
                }
            }
        },
        "id": null
    }
    """.data(using: .utf8)!
    
    static let submitTransaction = """
    {
      "jsonrpc": "2.0",
      "method": "submitTransaction",
      "result": {
        "transaction": {
          "id": "a3edaf9627d81c28a51a729b370f97452f485c70b8ac9dca15791e0ae26618ae"
        }
      },
      "id": null
    }
    """.data(using: .utf8)!
    
    static let evaluateTransaction = """
    {
      "jsonrpc": "2.0",
      "method": "evaluateTransaction",
      "result": [
        {
          "validator": {"purpose": "spend", "index": 1},
          "budget": {"memory": 5236222, "cpu": 1212353}
        },
        {
          "validator": {"purpose": "mint", "index": 0},
          "budget": {"memory": 5000, "cpu": 42}
        }
      ]
    }
    """.data(using: .utf8)!
    
    static let health = """
    {
      "currentEra": "conway",
      "lastKnownTip": {
        "slot": 90918798,
        "id": "4dc5188a99ce636e624ab72104f6f18031dcd849c151ce1c8ef4871b7c3913b9",
        "height": 3595887
      },
      "connectionStatus": "connected",
      "networkSynchronization": 1
    }
    """.data(using: .utf8)!
    
    static let treasury = """
    {
        "jsonrpc": "2.0",
        "method": "queryLedgerState/treasuryAndReserves",
        "result": {
            "treasury": {
                "ada": {
                    "lovelace": 1000000000000000
                }
            },
            "reserves": {
                "ada": {
                    "lovelace": 1000000000000000
                }
            }
        },
        "id": null
    }
    """.data(using: .utf8)!
}

/// Helper to create a mock OgmiosChainContext for testing.
func createMockOgmiosChainContext(network: SwiftCardanoCore.Network = .preview) async throws -> OgmiosChainContext {
    let mockConnection = MockOgmiosHTTPConnection()
    let client = try await OgmiosClient(
        host: "localhost",
        port: 1337,
        httpOnly: true,
        httpConnection: mockConnection
    )
    return try await OgmiosChainContext(network: network, client: client)
}
