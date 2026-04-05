import Foundation
import Testing
import SwiftCardanoCore
import SwiftCardanoUtils
import PotentCodables
import Mockable
import SystemPackage
import Command
@testable import SwiftCardanoChain

let configFilePath = Bundle.module.path(
    forResource: "config",
    ofType: "json",
    inDirectory: "data"
)

/// Creates a mock executable that returns specific outputs based on arguments
func createMockCardanoCLI(withResponses responses: [String: String] = [:]) -> String {
    let tempDir = FileManager.default.temporaryDirectory
    let binaryPath = tempDir.appendingPathComponent("mock-cardano-cli-\(UUID().uuidString)").path
    
    let mockScript = """
    #!/bin/bash
    exit 0
    """
    
    _ = FileManager.default.createFile(atPath: binaryPath, contents: mockScript.data(using: .utf8))
    
    // Make it executable
    let permissions = [FileAttributeKey.posixPermissions: 0o755]
    try? FileManager.default.setAttributes(permissions, ofItemAtPath: binaryPath)
    
    return binaryPath
}

func createMockConfig() -> Config {
    let cardanoConfig = CardanoConfig(
        cli: FilePath(createMockCardanoCLI()),
        node: FilePath("/tmp/mock-cardano-node"),
        hwCli: nil,
        signer: nil,
        socket: FilePath("/tmp/test-socket"),
        config: FilePath(configFilePath!),
        topology: nil,
        database: nil,
        port: nil,
        hostAddr: nil,
        network: Network.preview,
        era: Era.conway,
        ttlBuffer: 3600,
        workingDir: FilePath("/tmp/cardano-cli-tools"),
        showOutput: false
    )
    
    return Config(
        cardano: cardanoConfig,
        ogmios: nil,
        kupo: nil
    )
}

func createCardaonCLIMockCommandRunner(
    config: Config
) -> MockCommandRunning {
    let commandRunner = MockCommandRunning()
    given(commandRunner)
        .run(
            arguments: .value([config.cardano!.cli!.string, "--version"]),
            environment: .any,
            workingDirectory: .any
        )
        .willReturn(
            AsyncThrowingStream<CommandEvent, any Error> { continuation in
                continuation.yield(
                    .standardOutput([UInt8](CLIResponse.version.utf8))
                )
                continuation.finish()
            }
        )
    
        .run(
            arguments: .value([config.cardano!.cli!.string] + CLICommands.queryTip),
            environment: .any,
            workingDirectory: .any
        )
        .willReturn(
            AsyncThrowingStream<CommandEvent, any Error> { continuation in
                continuation.yield(
                    .standardOutput([UInt8](CLIResponse.tip100.utf8))
                )
                continuation.finish()
            }
        )
    
        .run(
            arguments: .value([config.cardano!.cli!.string] + CLICommands.utxoInput),
            environment: .any,
            workingDirectory: .any
        )
        .willReturn(
            AsyncThrowingStream<CommandEvent, any Error> { continuation in
                continuation.yield(
                    .standardOutput([UInt8](CLIResponse.utxos.utf8))
                )
                continuation.finish()
            }
        )
    
        .run(
            arguments: .value([config.cardano!.cli!.string] + CLICommands.treasury),
            environment: .any,
            workingDirectory: .any
        )
        .willReturn(
            AsyncThrowingStream<CommandEvent, any Error> { continuation in
                continuation.yield(
                    .standardOutput([UInt8](CLIResponse.treasury.utf8))
                )
                continuation.finish()
            }
        )
    
        .run(
            arguments: .value([config.cardano!.cli!.string] + CLICommands.drepStakeDistribution),
            environment: .any,
            workingDirectory: .any
        )
        .willReturn(
            AsyncThrowingStream<CommandEvent, any Error> { continuation in
                continuation.yield(
                    .standardOutput([UInt8](CLIResponse.drepStakeDistribution.utf8))
                )
                continuation.finish()
            }
        )
    
        .run(
            arguments: .value([config.cardano!.cli!.string] + CLICommands.drepKeyHash),
            environment: .any,
            workingDirectory: .any
        )
        .willReturn(
            AsyncThrowingStream<CommandEvent, any Error> { continuation in
                continuation.yield(
                    .standardOutput([UInt8](CLIResponse.drepKeyHash.utf8))
                )
                continuation.finish()
            }
        )
    
        .run(
            arguments: .value([config.cardano!.cli!.string] + CLICommands.drepScriptHash),
            environment: .any,
            workingDirectory: .any
        )
        .willReturn(
            AsyncThrowingStream<CommandEvent, any Error> { continuation in
                continuation.yield(
                    .standardOutput([UInt8](CLIResponse.drepScriptHash.utf8))
                )
                continuation.finish()
            }
        )
    
    return commandRunner
}

struct CLICommands {
    static let queryTip = ["conway", "query", "tip", "--testnet-magic", "2"]
    
    static let protocolParams = ["conway", "query", "protocol-parameters", "--testnet-magic", "2"]
    
    static let addressBuild = ["conway", "address", "build", "--payment-verification-key-file", "test.vkey", "--testnet-magic", "2"]
    
    static let stakePoolId = ["conway", "stake-pool", "id", "--cold-verification-key-file", "cold.vkey"]
    
    static let governanceDRepId = ["conway", "governance", "drep", "id", "--drep-verification-key-file", "drep.vkey"]
    
    static let utxos = ["conway", "query", "utxo", "--address", "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3", "--out-file",  "/dev/stdout", "--testnet-magic", "2"]
    
    static let utxoInput = ["conway", "query", "utxo", "--tx-in", "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58#0", "--output-json", "--out-file", "/dev/stdout", "--testnet-magic", "2"]
    
    static let stakeAddressInfo = ["conway", "query", "stake-address-info", "--address", "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",  "--out-file", "/dev/stdout", "--testnet-magic", "2"]
    
    static let stakePools = ["conway", "query", "stake-pools", "--testnet-magic", "2"]
    
    static let poolState = ["conway", "query", "pool-state", "--stake-pool-id", "pool1m5947rydk4n0ywe6ctlav0ztt632lcwjef7fsy93sflz7ctcx6z", "--testnet-magic", "2"]
    
    static let stakeSnapshot = ["conway", "query", "stake-snapshot", "--stake-pool-id", "pool1m5947rydk4n0ywe6ctlav0ztt632lcwjef7fsy93sflz7ctcx6z", "--testnet-magic", "2"]
    
    static let protocolState = ["conway", "query", "protocol-state", "--testnet-magic", "2"]
    
    static let treasury = ["conway", "query", "treasury", "--testnet-magic", "2"]
    
    static let drepStakeDistribution = ["conway", "query", "drep-stake-distribution", "--all-dreps", "--output-json", "--testnet-magic", "2"]
    
    static let drepKeyHash = ["conway", "query", "drep-state", "--drep-key-hash", "b02f7b335aebf284bbdc20bdc3b59e4e183ae2cfc47ad2d8bc19a241", "--include-stake", "--output-json", "--testnet-magic", "2"]
    
    static let drepScriptHash = ["conway", "query", "drep-state", "--drep-script-hash", "5a5ba42f130741d62384c390cfc84d9ceecc8a4bef38059ff18ba74b", "--include-stake", "--output-json", "--testnet-magic", "2"]
}

struct CLIResponse {
    static let version = """
    cardano-cli 10.8.0.0 - darwin-x86_64 - ghc-9.6
    git rev 420c94fbb075146c6ec7fba78c5b0482fafe72dd
    """
    
    static let tip75 = """
    {"block":123456,"epoch":450,"era":"conway","hash":"abcd1234","slot":123456789,"slotInEpoch":65579,"slotsToEpochEnd":20821,"syncProgress":"75.0"}
    """
    
    static let tip100 = """
    {"block":123456,"epoch":450,"era":"conway","hash":"abcd1234","slot":123456789,"slotInEpoch":65579,"slotsToEpochEnd":20821,"syncProgress":"100.0"}
    """
    
    static let protocolParams = """
    {"collateralPercentage":150,"committeeMaxTermLength":146,"committeeMinSize":7,"costModels":{"PlutusV1":[100788,420,1,1,1000,173,0,1,1000,59957,4,1,11183,32,201305,8356,4,16000,100,16000,100,16000,100,16000,100,16000,100,16000,100,100,100,16000,100,94375,32,132994,32,61462,4,72010,178,0,1,22151,32,91189,769,4,2,85848,228465,122,0,1,1,1000,42921,4,2,24548,29498,38,1,898148,27279,1,51775,558,1,39184,1000,60594,1,141895,32,83150,32,15299,32,76049,1,13169,4,22100,10,28999,74,1,28999,74,1,43285,552,1,44749,541,1,33852,32,68246,32,72362,32,7243,32,7391,32,11546,32,85848,228465,122,0,1,1,90434,519,0,1,74433,32,85848,228465,122,0,1,1,85848,228465,122,0,1,1,270652,22588,4,1457325,64566,4,20467,1,4,0,141992,32,100788,420,1,1,81663,32,59498,32,20142,32,24588,32,20744,32,25933,32,24623,32,53384111,14333,10],"PlutusV2":[100788,420,1,1,1000,173,0,1,1000,59957,4,1,11183,32,201305,8356,4,16000,100,16000,100,16000,100,16000,100,16000,100,16000,100,100,100,16000,100,94375,32,132994,32,61462,4,72010,178,0,1,22151,32,91189,769,4,2,85848,228465,122,0,1,1,1000,42921,4,2,24548,29498,38,1,898148,27279,1,51775,558,1,39184,1000,60594,1,141895,32,83150,32,15299,32,76049,1,13169,4,22100,10,28999,74,1,28999,74,1,43285,552,1,44749,541,1,33852,32,68246,32,72362,32,7243,32,7391,32,11546,32,85848,228465,122,0,1,1,90434,519,0,1,74433,32,85848,228465,122,0,1,1,85848,228465,122,0,1,1,955506,213312,0,2,270652,22588,4,1457325,64566,4,20467,1,4,0,141992,32,100788,420,1,1,81663,32,59498,32,20142,32,24588,32,20744,32,25933,32,24623,32,43053543,10,53384111,14333,10,43574283,26308,10],"PlutusV3":[100788,420,1,1,1000,173,0,1,1000,59957,4,1,11183,32,201305,8356,4,16000,100,16000,100,16000,100,16000,100,16000,100,16000,100,100,100,16000,100,94375,32,132994,32,61462,4,72010,178,0,1,22151,32,91189,769,4,2,85848,123203,7305,-900,1716,549,57,85848,0,1,1,1000,42921,4,2,24548,29498,38,1,898148,27279,1,51775,558,1,39184,1000,60594,1,141895,32,83150,32,15299,32,76049,1,13169,4,22100,10,28999,74,1,28999,74,1,43285,552,1,44749,541,1,33852,32,68246,32,72362,32,7243,32,7391,32,11546,32,85848,123203,7305,-900,1716,549,57,85848,0,1,90434,519,0,1,74433,32,85848,123203,7305,-900,1716,549,57,85848,0,1,1,85848,123203,7305,-900,1716,549,57,85848,0,1,955506,213312,0,2,270652,22588,4,1457325,64566,4,20467,1,4,0,141992,32,100788,420,1,1,81663,32,59498,32,20142,32,24588,32,20744,32,25933,32,24623,32,43053543,10,53384111,14333,10,43574283,26308,10,16000,100,16000,100,962335,18,2780678,6,442008,1,52538055,3756,18,267929,18,76433006,8868,18,52948122,18,1995836,36,3227919,12,901022,1,166917843,4307,36,284546,36,158221314,26549,36,74698472,36,333849714,1,254006273,72,2174038,72,2261318,64571,4,207616,8310,4,1293828,28716,63,0,1,1006041,43623,251,0,1,100181,726,719,0,1,100181,726,719,0,1,100181,726,719,0,1,107878,680,0,1,95336,1,281145,18848,0,1,180194,159,1,1,158519,8942,0,1,159378,8813,0,1,107490,3298,1,106057,655,1,1964219,24520,3]},"dRepActivity":20,"dRepDeposit":500000000,"dRepVotingThresholds":{"committeeNoConfidence":0.6,"committeeNormal":0.67,"hardForkInitiation":0.6,"motionNoConfidence":0.67,"ppEconomicGroup":0.67,"ppGovGroup":0.75,"ppNetworkGroup":0.67,"ppTechnicalGroup":0.67,"treasuryWithdrawal":0.67,"updateToConstitution":0.75},"executionUnitPrices":{"priceMemory":0.0577,"priceSteps":0.0000721},"govActionDeposit":100000000000,"govActionLifetime":6,"maxBlockBodySize":90112,"maxBlockExecutionUnits":{"memory":62000000,"steps":20000000000},"maxBlockHeaderSize":1100,"maxCollateralInputs":3,"maxTxExecutionUnits":{"memory":14000000,"steps":10000000000},"maxTxSize":16384,"maxValueSize":5000,"minFeeRefScriptCostPerByte":15,"minPoolCost":170000000,"monetaryExpansion":0.003,"poolPledgeInfluence":0.3,"poolRetireMaxEpoch":18,"poolVotingThresholds":{"committeeNoConfidence":0.51,"committeeNormal":0.51,"hardForkInitiation":0.51,"motionNoConfidence":0.51,"ppSecurityGroup":0.51},"protocolVersion":{"major":10,"minor":0},"stakeAddressDeposit":2000000,"stakePoolDeposit":500000000,"stakePoolTargetNum":500,"treasuryCut":0.2,"txFeeFixed":155381,"txFeePerByte":44,"utxoCostPerByte":4310}
    """
    
    static let addressBuild = "addr1v84rja0gwv0c8aexdlchaglrtwnjfxn946zs52uxtrxy5mqjr4vwn"
    
    static let stakePoolId = "pool1m5947rydk4n0ywe6ctlav0ztt632lcwjef7fsy93sflz7ctcx6z"
    
    static let governanceDRepId = "drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0"
    
    static var utxos: String {
        let dictionary = [
            "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58#0": [
                "address": "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3",
                "datum": nil,
                "inlineDatum": [
                    "constructor": 0,
                    "fields": [
                        [
                            "constructor": 0,
                            "fields": [
                                ["bytes": "2e11e7313e00ccd086cfc4f1c3ebed4962d31b481b6a153c23601c0f"],
                                ["bytes": "636861726c69335f6164615f6e6674"]
                            ]
                        ],
                        [
                            "constructor": 0,
                            "fields": [
                                ["bytes": ""],
                                ["bytes": ""]
                            ]
                        ],
                        [
                            "constructor": 0,
                            "fields": [
                                ["bytes": "8e51398904a5d3fc129fbf4f1589701de23c7824d5c90fdb9490e15a"],
                                ["bytes": "434841524c4933"]
                            ]
                        ],
                        [
                            "constructor": 0,
                            "fields": [
                                ["bytes": "d8d46a3e430fab5dc8c5a0a7fc82abbf4339a89034a8c804bb7e6012"],
                                ["bytes": "636861726c69335f6164615f6c71"]
                            ]
                        ],
                        ["int": 997],
                        [
                            "list": [
                                ["bytes": "4dd98a2ef34bc7ac3858bbcfdf94aaa116bb28ca7e01756140ba4d19"]
                            ]
                        ],
                        ["int": 10000000000]
                    ]
                ],
                "inlineDatumhash": "c56003cba9cfcf2f73cf6a5f4d6354d03c281bcd2bbd7a873d7475faa10a7123",
                "referenceScript": nil,
                "value": [
                    "2e11e7313e00ccd086cfc4f1c3ebed4962d31b481b6a153c23601c0f": [
                        "636861726c69335f6164615f6e6674": 1
                    ],
                    "8e51398904a5d3fc129fbf4f1589701de23c7824d5c90fdb9490e15a": [
                        "434841524c4933": 1367726755
                    ],
                    "d8d46a3e430fab5dc8c5a0a7fc82abbf4339a89034a8c804bb7e6012": [
                        "636861726c69335f6164615f6c71": 9223372035870126880
                    ],
                    "lovelace": 708864940
                ]
            ]
        ]
        
        let jsonData = try! JSONSerialization.data(withJSONObject: dictionary, options: [])
        return String(data: jsonData, encoding: .utf8)!
    }
    
    static let stakeAddressInfo = """
        [
            {
                "address": "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",
                "govActionDeposits": {
                    "c832f194684d672316212e01efc6d28177e8965b7cd6956981fe37cc6715963e#0": 100000000000
                },
                "rewardAccountBalance": 100000000000,
                "stakeDelegation": "pool1m5947rydk4n0ywe6ctlav0ztt632lcwjef7fsy93sflz7ctcx6z",
                "stakeRegistrationDeposit": 2000000,
                "voteDelegation": "keyHash-b02f7b335aebf284bbdc20bdc3b59e4e183ae2cfc47ad2d8bc19a241"
            }
        ]
        """
    
    static let stakePools = """
        pool1qqa8tkycj4zck4sy7n8mqr22x5g7tvm8hnp9st95wmuvvtw28th
        pool1qzq896ke4meh0tn9fl0dcnvtn2rzdz75lk3h8nmsuew8z5uln7r
        pool1qzhrd5sd0v0r6q2kqmaz07tvgry72whcjw0xsmnttgyuxtzpkkx
        pool1qzamfq0qzpggch2rk9daqq8skky7rhvs5g38lchnhw67sve4d36
        pool1qrjk9dqdaydy207lw4hf3zlxxg2qlxvxp9kvxx9fscccgwmgfv9
        """
    
    static let stakeSnapshot = """
        {
            "pools": {
                "dd0b5f0c8db566f23b3ac2ffd63c4b5ea2afe1d2ca7c9810b1827e2f": {
                    "stakeMark": 5000000000000,
                    "stakeSet": 4900000000000,
                    "stakeGo": 4800000000000
                }
            },
            "total": {
                "stakeMark": 25000000000000000,
                "stakeSet": 24900000000000000,
                "stakeGo": 24800000000000000
            }
        }
        """
    
    static let poolState = """
        {
            "dd0b5f0c8db566f23b3ac2ffd63c4b5ea2afe1d2ca7c9810b1827e2f": {
                "futurePoolParams": null,
                "poolParams": {
                    "spsCost": 340000000,
                    "spsDeposit": 500000000,
                    "spsMargin": 0.05,
                    "spsMetadata": {
                        "hash": "db7b7e2943b84fe628fd75eb3cc01fc5c136a0a1dbc2cfb5fdeee6afdd943af1",
                        "url": "https://meta.example.com/pool.json"
                    },
                    "spsOwners": [
                        "89218aeaab042f371399f159a08168b43a23f7c3b3db5c3a4c77a18e"
                    ],
                    "spsPledge": 10000000000,
                    "spsRelays": [
                        {
                            "single host address": {
                                "IPv4": "1.2.3.4",
                                "IPv6": null,
                                "port": 3001
                            }
                        },
                        {
                            "single host name": {
                                "dnsName": "relay1.example.com",
                                "port": 3002
                            }
                        }
                    ],
                    "spsRewardAccount": {
                        "credential": {
                            "keyHash": "89218aeaab042f371399f159a08168b43a23f7c3b3db5c3a4c77a18e"
                        },
                        "network": "Testnet"
                    },
                    "spsVrf": "adbafc4eae2ee532f0f0dc47e502debbfd1436bd16abfafe24e2af6db4bd149d"
                },
                "retiring": null
            }
        }
        """
    
    static let protocolState = """
        {
            "candidateNonce": "abc123def456abc123def456abc123def456abc123def456abc123def456abc1",
            "epochNonce": "def456abc123def456abc123def456abc123def456abc123def456abc123def4",
            "evolvingNonce": "abc123def456abc123def456abc123def456abc123def456abc123def456abc1",
            "labNonce": "def456abc123def456abc123def456abc123def456abc123def456abc123def4",
            "lastEpochBlockNonce": "abc123def456abc123def456abc123def456abc123def456abc123def456abc1",
            "lastSlot": 123456789,
            "oCertCounters": {
                "dd0b5f0c8db566f23b3ac2ffd63c4b5ea2afe1d2ca7c9810b1827e2f": 7
            }
        }
        """
    
    static let treasury = "1000000000000000"
    
    static let drepStakeDistribution = """
        {
            "drep-alwaysAbstain": 8784205971620742,
            "drep-alwaysNoConfidence": 194879536262091,
            "drep-keyHash-002e87e32c1735bef2af2825943a9c06714857d1fc19385b86e429a3": 12121160278,
            "drep-keyHash-00663f00c4c1ca6bb6405c68b5c30023a8d8c7f6acbeb06b7d0a4d2c": 194458026737,
            "drep-keyHash-008e918639050ec8b708e5d8ff5224595098a28f0fc6671c66e292ab": 98561167372699
        }
    """
    
    static let drepKeyHash = """
        [
            [
                {
                    "keyHash": "b02f7b335aebf284bbdc20bdc3b59e4e183ae2cfc47ad2d8bc19a241"
                },
                {
                    "anchor": {
                        "dataHash": "35aeb21ba4be07cf9fda041b635f107ef978238b3fccae9be1b571518ce9d1b7",
                        "url": "https://anchor.test"
                    },
                    "deposit": 500000000,
                    "expiry": 639,
                    "stake": 305554989074
                }
            ]
        ]
    """
    
    static let drepScriptHash = """
        [
            [
                {
                    "scriptHash": "5a5ba42f130741d62384c390cfc84d9ceecc8a4bef38059ff18ba74b"
                },
                {
                    "anchor": {
                        "dataHash": "35aeb21ba4be07cf9fda041b635f107ef978238b3fccae9be1b571518ce9d1b7",
                        "url": "https://anchor.test"
                    },
                    "deposit": 500000000,
                    "expiry": 639,
                    "stake": 305554989074
                }
            ]
        ]
    """
}

public struct MockCardanoCLIClient {
    public var binary: URL
    public var socket: URL?
    
    public init() throws {
        self.binary = URL(fileURLWithPath: "/usr/local/bin/cardano-cli") // Dummy path
        self.socket = URL(fileURLWithPath: "/tmp/cardano-node.socket") // Dummy path
    }
    
    public static func getCardanoCliPath() -> URL? {
        return URL(fileURLWithPath: "/usr/local/bin/cardano-cli")
    }
    
    public func runCommand(_ cmd: [String]) throws -> String {
        let dictionary: [String : Any?]
        if cmd.contains(["query", "tip"]){
            dictionary = [
                "block": 1460093,
                "epoch": 500,
                "era": "Babbage",
                "hash": "c1bda7b2975dd3bf9969a57d92528ba7d60383b6e1c4a37b68379c4f4330e790",
                "slot": 41008115,
                "slotInEpoch": 313715,
                "slotsToEpochEnd": 118285,
                "syncProgress": "100.00"
            ]
        } else if cmd.contains(["query", "protocol-parameters"]) {
            dictionary = [
                "collateralPercentage": 150,
                "committeeMaxTermLength": 365,
                "committeeMinSize": 3,
                "costModels": [
                    "PlutusV1": [
                        100788,
                        420,
                        1,
                        1,
                        1000,
                        173,
                        0,
                        1,
                        1000,
                        59957,
                        4,
                        1,
                        11183,
                        32,
                        201305,
                        8356,
                        4,
                        16000,
                        100,
                        16000,
                        100,
                        16000,
                        100,
                        16000,
                        100,
                        16000,
                        100,
                        16000,
                        100,
                        100,
                        100,
                        16000,
                        100,
                        94375,
                        32,
                        132994,
                        32,
                        61462,
                        4,
                        72010,
                        178,
                        0,
                        1,
                        22151,
                        32,
                        91189,
                        769,
                        4,
                        2,
                        85848,
                        228465,
                        122,
                        0,
                        1,
                        1,
                        1000,
                        42921,
                        4,
                        2,
                        24548,
                        29498,
                        38,
                        1,
                        898148,
                        27279,
                        1,
                        51775,
                        558,
                        1,
                        39184,
                        1000,
                        60594,
                        1,
                        141895,
                        32,
                        83150,
                        32,
                        15299,
                        32,
                        76049,
                        1,
                        13169,
                        4,
                        22100,
                        10,
                        28999,
                        74,
                        1,
                        28999,
                        74,
                        1,
                        43285,
                        552,
                        1,
                        44749,
                        541,
                        1,
                        33852,
                        32,
                        68246,
                        32,
                        72362,
                        32,
                        7243,
                        32,
                        7391,
                        32,
                        11546,
                        32,
                        85848,
                        228465,
                        122,
                        0,
                        1,
                        1,
                        90434,
                        519,
                        0,
                        1,
                        74433,
                        32,
                        85848,
                        228465,
                        122,
                        0,
                        1,
                        1,
                        85848,
                        228465,
                        122,
                        0,
                        1,
                        1,
                        270652,
                        22588,
                        4,
                        1457325,
                        64566,
                        4,
                        20467,
                        1,
                        4,
                        0,
                        141992,
                        32,
                        100788,
                        420,
                        1,
                        1,
                        81663,
                        32,
                        59498,
                        32,
                        20142,
                        32,
                        24588,
                        32,
                        20744,
                        32,
                        25933,
                        32,
                        24623,
                        32,
                        53384111,
                        14333,
                        10
                    ],
                    "PlutusV2": [
                        100788,
                        420,
                        1,
                        1,
                        1000,
                        173,
                        0,
                        1,
                        1000,
                        59957,
                        4,
                        1,
                        11183,
                        32,
                        201305,
                        8356,
                        4,
                        16000,
                        100,
                        16000,
                        100,
                        16000,
                        100,
                        16000,
                        100,
                        16000,
                        100,
                        16000,
                        100,
                        100,
                        100,
                        16000,
                        100,
                        94375,
                        32,
                        132994,
                        32,
                        61462,
                        4,
                        72010,
                        178,
                        0,
                        1,
                        22151,
                        32,
                        91189,
                        769,
                        4,
                        2,
                        85848,
                        228465,
                        122,
                        0,
                        1,
                        1,
                        1000,
                        42921,
                        4,
                        2,
                        24548,
                        29498,
                        38,
                        1,
                        898148,
                        27279,
                        1,
                        51775,
                        558,
                        1,
                        39184,
                        1000,
                        60594,
                        1,
                        141895,
                        32,
                        83150,
                        32,
                        15299,
                        32,
                        76049,
                        1,
                        13169,
                        4,
                        22100,
                        10,
                        28999,
                        74,
                        1,
                        28999,
                        74,
                        1,
                        43285,
                        552,
                        1,
                        44749,
                        541,
                        1,
                        33852,
                        32,
                        68246,
                        32,
                        72362,
                        32,
                        7243,
                        32,
                        7391,
                        32,
                        11546,
                        32,
                        85848,
                        228465,
                        122,
                        0,
                        1,
                        1,
                        90434,
                        519,
                        0,
                        1,
                        74433,
                        32,
                        85848,
                        228465,
                        122,
                        0,
                        1,
                        1,
                        85848,
                        228465,
                        122,
                        0,
                        1,
                        1,
                        955506,
                        213312,
                        0,
                        2,
                        270652,
                        22588,
                        4,
                        1457325,
                        64566,
                        4,
                        20467,
                        1,
                        4,
                        0,
                        141992,
                        32,
                        100788,
                        420,
                        1,
                        1,
                        81663,
                        32,
                        59498,
                        32,
                        20142,
                        32,
                        24588,
                        32,
                        20744,
                        32,
                        25933,
                        32,
                        24623,
                        32,
                        43053543,
                        10,
                        53384111,
                        14333,
                        10,
                        43574283,
                        26308,
                        10
                    ],
                    "PlutusV3": [
                        100788,
                        420,
                        1,
                        1,
                        1000,
                        173,
                        0,
                        1,
                        1000,
                        59957,
                        4,
                        1,
                        11183,
                        32,
                        201305,
                        8356,
                        4,
                        16000,
                        100,
                        16000,
                        100,
                        16000,
                        100,
                        16000,
                        100,
                        16000,
                        100,
                        16000,
                        100,
                        100,
                        100,
                        16000,
                        100,
                        94375,
                        32,
                        132994,
                        32,
                        61462,
                        4,
                        72010,
                        178,
                        0,
                        1,
                        22151,
                        32,
                        91189,
                        769,
                        4,
                        2,
                        85848,
                        123203,
                        7305,
                        -900,
                        1716,
                        549,
                        57,
                        85848,
                        0,
                        1,
                        1,
                        1000,
                        42921,
                        4,
                        2,
                        24548,
                        29498,
                        38,
                        1,
                        898148,
                        27279,
                        1,
                        51775,
                        558,
                        1,
                        39184,
                        1000,
                        60594,
                        1,
                        141895,
                        32,
                        83150,
                        32,
                        15299,
                        32,
                        76049,
                        1,
                        13169,
                        4,
                        22100,
                        10,
                        28999,
                        74,
                        1,
                        28999,
                        74,
                        1,
                        43285,
                        552,
                        1,
                        44749,
                        541,
                        1,
                        33852,
                        32,
                        68246,
                        32,
                        72362,
                        32,
                        7243,
                        32,
                        7391,
                        32,
                        11546,
                        32,
                        85848,
                        123203,
                        7305,
                        -900,
                        1716,
                        549,
                        57,
                        85848,
                        0,
                        1,
                        90434,
                        519,
                        0,
                        1,
                        74433,
                        32,
                        85848,
                        123203,
                        7305,
                        -900,
                        1716,
                        549,
                        57,
                        85848,
                        0,
                        1,
                        1,
                        85848,
                        123203,
                        7305,
                        -900,
                        1716,
                        549,
                        57,
                        85848,
                        0,
                        1,
                        955506,
                        213312,
                        0,
                        2,
                        270652,
                        22588,
                        4,
                        1457325,
                        64566,
                        4,
                        20467,
                        1,
                        4,
                        0,
                        141992,
                        32,
                        100788,
                        420,
                        1,
                        1,
                        81663,
                        32,
                        59498,
                        32,
                        20142,
                        32,
                        24588,
                        32,
                        20744,
                        32,
                        25933,
                        32,
                        24623,
                        32,
                        43053543,
                        10,
                        53384111,
                        14333,
                        10,
                        43574283,
                        26308,
                        10,
                        16000,
                        100,
                        16000,
                        100,
                        962335,
                        18,
                        2780678,
                        6,
                        442008,
                        1,
                        52538055,
                        3756,
                        18,
                        267929,
                        18,
                        76433006,
                        8868,
                        18,
                        52948122,
                        18,
                        1995836,
                        36,
                        3227919,
                        12,
                        901022,
                        1,
                        166917843,
                        4307,
                        36,
                        284546,
                        36,
                        158221314,
                        26549,
                        36,
                        74698472,
                        36,
                        333849714,
                        1,
                        254006273,
                        72,
                        2174038,
                        72,
                        2261318,
                        64571,
                        4,
                        207616,
                        8310,
                        4,
                        1293828,
                        28716,
                        63,
                        0,
                        1,
                        1006041,
                        43623,
                        251,
                        0,
                        1,
                        100181,
                        726,
                        719,
                        0,
                        1,
                        100181,
                        726,
                        719,
                        0,
                        1,
                        100181,
                        726,
                        719,
                        0,
                        1,
                        107878,
                        680,
                        0,
                        1,
                        95336,
                        1,
                        281145,
                        18848,
                        0,
                        1,
                        180194,
                        159,
                        1,
                        1,
                        158519,
                        8942,
                        0,
                        1,
                        159378,
                        8813,
                        0,
                        1,
                        107490,
                        3298,
                        1,
                        106057,
                        655,
                        1,
                        1964219,
                        24520,
                        3
                    ]
                ],
                "dRepActivity": 31,
                "dRepDeposit": 500000000,
                "dRepVotingThresholds": [
                    "committeeNoConfidence": 0.6,
                    "committeeNormal": 0.67,
                    "hardForkInitiation": 0.6,
                    "motionNoConfidence": 0.67,
                    "ppEconomicGroup": 0.67,
                    "ppGovGroup": 0.75,
                    "ppNetworkGroup": 0.67,
                    "ppTechnicalGroup": 0.67,
                    "treasuryWithdrawal": 0.67,
                    "updateToConstitution": 0.75
                ],
                "executionUnitPrices": [
                    "priceMemory": 5.77e-2,
                    "priceSteps": 7.21e-5
                ],
                "govActionDeposit": 100000000000,
                "govActionLifetime": 30,
                "maxBlockBodySize": 90112,
                "maxBlockExecutionUnits": [
                    "memory": 62000000,
                    "steps": 20000000000
                ],
                "maxBlockHeaderSize": 1100,
                "maxCollateralInputs": 3,
                "maxTxExecutionUnits": [
                    "memory": 14000000,
                    "steps": 10000000000
                ],
                "maxTxSize": 16384,
                "maxValueSize": 5000,
                "minFeeRefScriptCostPerByte": 15,
                "minPoolCost": 170000000,
                "monetaryExpansion": 3.0e-3,
                "poolPledgeInfluence": 0.3,
                "poolRetireMaxEpoch": 18,
                "poolVotingThresholds": [
                    "committeeNoConfidence": 0.51,
                    "committeeNormal": 0.51,
                    "hardForkInitiation": 0.51,
                    "motionNoConfidence": 0.51,
                    "ppSecurityGroup": 0.51
                ],
                "protocolVersion": [
                    "major": 10,
                    "minor": 0
                ],
                "stakeAddressDeposit": 2000000,
                "stakePoolDeposit": 500000000,
                "stakePoolTargetNum": 500,
                "treasuryCut": 0.2,
                "txFeeFixed": 155381,
                "txFeePerByte": 44,
                "utxoCostPerByte": 4310
            ]
        } else if cmd.contains(["query", "utxo", "--address"]) {
            dictionary = [
                "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58#0": [
                    "address": "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3",
                    "datum": nil,
                    "inlineDatum": [
                        "constructor": 0,
                        "fields": [
                            [
                                "constructor": 0,
                                "fields": [
                                    ["bytes": "2e11e7313e00ccd086cfc4f1c3ebed4962d31b481b6a153c23601c0f"],
                                    ["bytes": "636861726c69335f6164615f6e6674"]
                                ]
                            ],
                            [
                                "constructor": 0,
                                "fields": [
                                    ["bytes": ""],
                                    ["bytes": ""]
                                ]
                            ],
                            [
                                "constructor": 0,
                                "fields": [
                                    ["bytes": "8e51398904a5d3fc129fbf4f1589701de23c7824d5c90fdb9490e15a"],
                                    ["bytes": "434841524c4933"]
                                ]
                            ],
                            [
                                "constructor": 0,
                                "fields": [
                                    ["bytes": "d8d46a3e430fab5dc8c5a0a7fc82abbf4339a89034a8c804bb7e6012"],
                                    ["bytes": "636861726c69335f6164615f6c71"]
                                ]
                            ],
                            ["int": 997],
                            [
                                "list": [
                                    ["bytes": "4dd98a2ef34bc7ac3858bbcfdf94aaa116bb28ca7e01756140ba4d19"]
                                ]
                            ],
                            ["int": 10000000000]
                        ]
                    ],
                    "inlineDatumhash": "c56003cba9cfcf2f73cf6a5f4d6354d03c281bcd2bbd7a873d7475faa10a7123",
                    "referenceScript": nil,
                    "value": [
                        "2e11e7313e00ccd086cfc4f1c3ebed4962d31b481b6a153c23601c0f": [
                            "636861726c69335f6164615f6e6674": 1
                        ],
                        "8e51398904a5d3fc129fbf4f1589701de23c7824d5c90fdb9490e15a": [
                            "434841524c4933": 1367726755
                        ],
                        "d8d46a3e430fab5dc8c5a0a7fc82abbf4339a89034a8c804bb7e6012": [
                            "636861726c69335f6164615f6c71": 9223372035870126880
                        ],
                        "lovelace": 708864940
                    ]
                ]
            ]
        } else if cmd.contains(["transaction", "txid", "--tx-file"]) {
            return "d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908"
        } else if cmd.contains(["query", "stake-address-info", "--address"]) {
            dictionary = [
                "address": "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",
                "govActionDeposits": [:],
                "rewardAccountBalance": 319154618165,
                "stakeDelegation": "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy",
                "stakeRegistrationDeposit": 2000000,
                "voteDelegation": "keyHash-9be9b6efd0649b354b682f6875174d0ac9056cea40a8da6fd3935d82"
            ]
            
            let jsonData = try JSONSerialization.data(
                withJSONObject: [dictionary],
                options: [.prettyPrinted]
            )
            return String(data: jsonData, encoding: .utf8)!
        } else {
            dictionary = [:]
        }
        
        let jsonData = try JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.prettyPrinted]
        )
        return String(data: jsonData, encoding: .utf8)!
    }
}


