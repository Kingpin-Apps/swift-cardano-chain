import Foundation
import OpenAPIRuntime
import HTTPTypes
import SwiftBlockfrostAPI


struct MockTransport: ClientTransport {
    func send(_ request: HTTPTypes.HTTPRequest, body: OpenAPIRuntime.HTTPBody?, baseURL: URL, operationID: String) async throws -> (
        HTTPTypes.HTTPResponse,
        OpenAPIRuntime.HTTPBody?
    ) {
        var body: Data = Data()
        switch operationID {
            case "get/txs/{hash}/cbor":
                body = try JSONEncoder().encode(
                    Components.Schemas.TxContentCbor(cbor: try ChainFixtures.mapRedeemerTransactionHex())
                )
            case "get/txs/{hash}/utxos":
                body = try JSONEncoder().encode(
                    Components.Schemas.TxContentUtxo(
                        hash: "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58",
                        inputs: [
                            .init(
                                address: "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3",
                                amount: [
                                    .init(
                                        unit: "lovelace",
                                        quantity: "1000000"
                                    )
                                ],
                                txHash: "abcd1234efgh5678ijkl9012mnop3456qrst7890uvwx1234yzab5678cdef9012",
                                outputIndex: 0,
                                dataHash: nil,
                                inlineDatum: nil,
                                referenceScriptHash: nil,
                                collateral: false,
                                reference: false
                            )
                        ],
                        outputs: [
                            .init(
                                address: "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3",
                                amount: [
                                    .init(
                                        unit: "lovelace",
                                        quantity: "5000000"
                                    ),
                                    .init(
                                        unit: "b0d07d45fe9514f80213f4020e5a61241458be626841cde717cb38a76e7574636f696e",
                                        quantity: "50"
                                    )
                                ],
                                outputIndex: 0,
                                dataHash: nil,
                                inlineDatum: nil,
                                collateral: false,
                                referenceScriptHash: nil,
                                consumedByTx: nil
                            )
                        ]
                    )
                )
            case "get/blocks/latest":
                body = try JSONEncoder().encode(
                    Components.Schemas.BlockContent(
                        time: Int(Date().timeIntervalSince1970),
                        height: 1000,
                        hash: "hash",
                        slot: 1000,
                        epoch: 500,
                        epochSlot: 500,
                        slotLeader: "slotLeader",
                        size: 1000,
                        txCount: 10,
                        output: "output",
                        fees: "100",
                        blockVrf: "blockVrf",
                        previousBlock: "previousBlock",
                        nextBlock: nil,
                        confirmations: 1
                    )
                )
            case "get/epochs/latest":
                body = try JSONEncoder().encode(
                    Components.Schemas.EpochContent(
                        epoch: 500,
                        startTime: 0,
                        endTime: Int(Date().timeIntervalSince1970)+3600,
                        firstBlockTime: 0,
                        lastBlockTime: 0,
                        blockCount: 0,
                        txCount: 0,
                        output: "output",
                        fees: "100",
                        activeStake: nil
                    ))
            case "get/genesis":
                body = try JSONEncoder().encode(
                    Components.Schemas.GenesisContent(
                        activeSlotsCoefficient: 0.05,
                        updateQuorum: 5,
                        maxLovelaceSupply: "45000000000000000",
                        networkMagic: 764824073,
                        epochLength: 432000,
                        systemStart: 1506203091,
                        slotsPerKesPeriod: 129600,
                        slotLength: 1,
                        maxKesEvolutions: 62,
                        securityParam: 2160
                    )
                )
            case "get/epochs/latest/parameters":
                body = try JSONEncoder().encode(
                    Components.Schemas.EpochParamContent(
                        epoch: 581,
                        minFeeA: 44,
                        minFeeB: 155381,
                        maxBlockSize: 90112,
                        maxTxSize: 16384,
                        maxBlockHeaderSize: 1100,
                        keyDeposit: "2000000",
                        poolDeposit: "500000000",
                        eMax: 18,
                        nOpt: 500,
                        a0: 0.3,
                        rho: 0.003,
                        tau: 0.2,
                        decentralisationParam: 0,
                        extraEntropy: nil,
                        protocolMajorVer: 10,
                        protocolMinorVer: 0,
                        minUtxo: "4310",
                        minPoolCost: "170000000",
                        nonce: "08a120eae439ecd70be199f5b34abcf3d0c07425906cceae7363b737d6887f59",
                        costModelsRaw: Components.Schemas.EpochParamContent.CostModelsRawPayload(
                            // Raw list form, which is what Blockfrost now serves and what the
                            // ledger hashes. The deprecated `cost_models` map is keyed by operation
                            // name and sorts wrong for Plutus V3.
                            additionalProperties: OpenAPIObjectContainer(unvalidatedValue: [
                                "PlutusV1": [
                                    100788, 420, 1, 1, 1000, 173, 0, 1, 1000, 59957, 4, 1, 11183,
                                    32, 201305, 8356, 4, 16000, 100, 16000, 100, 16000, 100, 16000,
                                    100, 16000, 100, 16000, 100, 100, 100, 16000, 100, 94375, 32,
                                    132994, 32, 61462, 4, 72010, 178, 0, 1, 22151, 32, 91189, 769,
                                    4, 2, 85848, 228465, 122, 0, 1, 1, 1000, 42921, 4, 2, 24548,
                                    29498, 38, 1, 898148, 27279, 1, 51775, 558, 1, 39184, 1000,
                                    60594, 1, 141895, 32, 83150, 32, 15299, 32, 76049, 1, 13169, 4,
                                    22100, 10, 28999, 74, 1, 28999, 74, 1, 43285, 552, 1, 44749,
                                    541, 1, 33852, 32, 68246, 32, 72362, 32, 7243, 32, 7391, 32,
                                    11546, 32, 85848, 228465, 122, 0, 1, 1, 90434, 519, 0, 1,
                                    74433, 32, 85848, 228465, 122, 0, 1, 1, 85848, 228465, 122, 0,
                                    1, 1, 270652, 22588, 4, 1457325, 64566, 4, 20467, 1, 4, 0,
                                    141992, 32, 100788, 420, 1, 1, 81663, 32, 59498, 32, 20142, 32,
                                    24588, 32, 20744, 32, 25933, 32, 24623, 32, 53384111, 14333,
                                    10
                                ],
                                "PlutusV2": [
                                    100788, 420, 1, 1, 1000, 173, 0, 1, 1000, 59957, 4, 1, 11183,
                                    32, 201305, 8356, 4, 16000, 100, 16000, 100, 16000, 100, 16000,
                                    100, 16000, 100, 16000, 100, 100, 100, 16000, 100, 94375, 32,
                                    132994, 32, 61462, 4, 72010, 178, 0, 1, 22151, 32, 91189, 769,
                                    4, 2, 85848, 228465, 122, 0, 1, 1, 1000, 42921, 4, 2, 24548,
                                    29498, 38, 1, 898148, 27279, 1, 51775, 558, 1, 39184, 1000,
                                    60594, 1, 141895, 32, 83150, 32, 15299, 32, 76049, 1, 13169, 4,
                                    22100, 10, 28999, 74, 1, 28999, 74, 1, 43285, 552, 1, 44749,
                                    541, 1, 33852, 32, 68246, 32, 72362, 32, 7243, 32, 7391, 32,
                                    11546, 32, 85848, 228465, 122, 0, 1, 1, 90434, 519, 0, 1,
                                    74433, 32, 85848, 228465, 122, 0, 1, 1, 85848, 228465, 122, 0,
                                    1, 1, 955506, 213312, 0, 2, 270652, 22588, 4, 1457325, 64566,
                                    4, 20467, 1, 4, 0, 141992, 32, 100788, 420, 1, 1, 81663, 32,
                                    59498, 32, 20142, 32, 24588, 32, 20744, 32, 25933, 32, 24623,
                                    32, 43053543, 10, 53384111, 14333, 10, 43574283, 26308, 10
                                ],
                                "PlutusV3": [
                                    100788, 420, 1, 1, 1000, 173, 0, 1, 1000, 59957, 4, 1, 11183,
                                    32, 201305, 8356, 4, 16000, 100, 16000, 100, 16000, 100, 16000,
                                    100, 16000, 100, 16000, 100, 100, 100, 16000, 100, 94375, 32,
                                    132994, 32, 61462, 4, 72010, 178, 0, 1, 22151, 32, 91189, 769,
                                    4, 2, 85848, 123203, 7305, -900, 1716, 549, 57, 85848, 0, 1, 1,
                                    1000, 42921, 4, 2, 24548, 29498, 38, 1, 898148, 27279, 1,
                                    51775, 558, 1, 39184, 1000, 60594, 1, 141895, 32, 83150, 32,
                                    15299, 32, 76049, 1, 13169, 4, 22100, 10, 28999, 74, 1, 28999,
                                    74, 1, 43285, 552, 1, 44749, 541, 1, 33852, 32, 68246, 32,
                                    72362, 32, 7243, 32, 7391, 32, 11546, 32, 85848, 123203, 7305,
                                    -900, 1716, 549, 57, 85848, 0, 1, 90434, 519, 0, 1, 74433, 32,
                                    85848, 123203, 7305, -900, 1716, 549, 57, 85848, 0, 1, 1,
                                    85848, 123203, 7305, -900, 1716, 549, 57, 85848, 0, 1, 955506,
                                    213312, 0, 2, 270652, 22588, 4, 1457325, 64566, 4, 20467, 1, 4,
                                    0, 141992, 32, 100788, 420, 1, 1, 81663, 32, 59498, 32, 20142,
                                    32, 24588, 32, 20744, 32, 25933, 32, 24623, 32, 43053543, 10,
                                    53384111, 14333, 10, 43574283, 26308, 10, 16000, 100, 16000,
                                    100, 962335, 18, 2780678, 6, 442008, 1, 52538055, 3756, 18,
                                    267929, 18, 76433006, 8868, 18, 52948122, 18, 1995836, 36,
                                    3227919, 12, 901022, 1, 166917843, 4307, 36, 284546, 36,
                                    158221314, 26549, 36, 74698472, 36, 333849714, 1, 254006273,
                                    72, 2174038, 72, 2261318, 64571, 4, 207616, 8310, 4, 1293828,
                                    28716, 63, 0, 1, 1006041, 43623, 251, 0, 1, 100181, 726, 719,
                                    0, 1, 100181, 726, 719, 0, 1, 100181, 726, 719, 0, 1, 107878,
                                    680, 0, 1, 95336, 1, 281145, 18848, 0, 1, 180194, 159, 1, 1,
                                    158519, 8942, 0, 1, 159378, 8813, 0, 1, 107490, 3298, 1,
                                    106057, 655, 1, 1964219, 24520, 3
                                ]
                            ])
                        ),
                        priceMem: 0.0577,
                        priceStep: 0.0000721,
                        maxTxExMem: "14000000",
                        maxTxExSteps: "10000000000",
                        maxBlockExMem: "62000000",
                        maxBlockExSteps: "20000000000",
                        maxValSize: "5000",
                        collateralPercent: 150,
                        maxCollateralInputs: 3,
                        coinsPerUtxoSize: "4310",
                        coinsPerUtxoWord: "4310",
                        pvtMotionNoConfidence: 0.51,
                        pvtCommitteeNormal: 0.51,
                        pvtCommitteeNoConfidence: 0.67,
                        pvtHardForkInitiation: 0.67,
                        dvtMotionNoConfidence: 0.6,
                        dvtCommitteeNormal: 0.75,
                        dvtCommitteeNoConfidence: 0.6,
                        dvtUpdateToConstitution: 0.67,
                        dvtHardForkInitiation: 0.67,
                        dvtPPNetworkGroup: 0.67,
                        dvtPPEconomicGroup: 0.75,
                        dvtPPTechnicalGroup: 0.67,
                        dvtPPGovGroup: 0.75,
                        dvtTreasuryWithdrawal: 0.67,
                        committeeMinSize: "7",
                        committeeMaxTermLength: "100000000000",
                        govActionLifetime: "500000000",
                        govActionDeposit: "20",
                        drepDeposit: "500000000",
                        drepActivity: "20",
                        pvtppSecurityGroup:  0.51,
                        pvtPPSecurityGroup: 0.51,
                        minFeeRefScriptCostPerByte: 15
                    )
                )
            case "get/addresses/{address}/utxos":
                body = try JSONEncoder().encode(
                    Components.Schemas.AddressUtxoContent([
                        .init(
                            address: "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3",
                            txHash: "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58",
                            txIndex: 0,
                            outputIndex: 0,
                            amount: [
                                .init(unit: "lovelace", quantity: "1000000"),
                                .init(unit: "b0d07d45fe9514f80213f4020e5a61241458be626841cde717cb38a76e7574636f696e", quantity: "50")
                            ],
                            block: "123456",
                            dataHash: nil,
                            inlineDatum: nil,
                            referenceScriptHash: nil
                        )
                    ])
                )
            case "post/tx/submit":
                body = try JSONEncoder().encode(
                    "d1662b24fa9fe985fc2dce47455df399cb2e31e1e1819339e885801cc3578908"
                )
            case "get/accounts/{stake_address}":
                body = try JSONEncoder().encode(
                    Components.Schemas
                        .AccountContent(
                            stakeAddress: "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",
                            active: true,
                            registered: true,
                            controlledAmount: "619154618165",
                            rewardsSum: "319154618165",
                            withdrawalsSum: "12125369253",
                            reservesSum: "319154618165",
                            treasurySum: "12000000",
                            withdrawableAmount: "319154618165",
                            poolId: "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy",
                            drepId: "drep15cfxz9exyn5rx0807zvxfrvslrjqfchrd4d47kv9e0f46uedqtc"
                        )
                )
            case "get/pools/{pool_id}/blocks":
                body = try JSONEncoder().encode(
                    ["abcd1234efgh5678ijkl9012mnop3456qrst7890uvwx1234yzab5678cdef9012"]
                )
            case "get/blocks/{hash_or_number}":
                body = try JSONEncoder().encode(
                    Components.Schemas.BlockContent(
                        time: Int(Date().timeIntervalSince1970),
                        height: 123456,
                        hash: "abcd1234efgh5678ijkl9012mnop3456qrst7890uvwx1234yzab5678cdef9012",
                        slot: 123456789,
                        epoch: 500,
                        epochSlot: 65579,
                        slotLeader: "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy",
                        size: 1000,
                        txCount: 10,
                        output: "1000000000",
                        fees: "200000",
                        blockVrf: "vrf_vk1test",
                        opCertCounter: "42",
                        previousBlock: "prevblock",
                        nextBlock: nil,
                        confirmations: 100
                    )
                )
            case "get/network":
                body = try JSONEncoder().encode(
                    Components.Schemas.Network(
                        supply: Components.Schemas.Network.SupplyPayload(
                            max: "1000000000000000",
                            total: "2000000000000000",
                            circulating: "4500000000000000",
                            locked: "5000000000000000",
                            treasury: "1000000000000000",
                            reserves: "1500000000000000"
                        ),
                        stake: Components.Schemas.Network.StakePayload(
                            live: "1500000000000", active: "1000000000000",
                        )
                    )
                )
            case "get/governance/dreps/{drep_id}":
                body = try JSONEncoder().encode(
                    Components.Schemas.Drep(
                        drepId: "drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0",
                        hex: "b02f7b335aebf284bbdc20bdc3b59e4e183ae2cfc47ad2d8bc19a241",
                        amount: "500000000",
                        active: true,
                        activeEpoch: 639,
                        hasScript: false,
                        retired: false,
                        expired: false,
                        lastActiveEpoch: 619
                    )
                )

            case "get/governance/dreps/{drep_id}/metadata":
                body = try JSONEncoder().encode(
                    Components.Schemas.DrepMetadata(
                        drepId: "drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0",
                        hex: "b02f7b335aebf284bbdc20bdc3b59e4e183ae2cfc47ad2d8bc19a241",
                        url: "https://anchor.test",
                        hash: "35aeb21ba4be07cf9fda041b635f107ef978238b3fccae9be1b571518ce9d1b7",
                        jsonMetadata: Components.Schemas.DrepMetadata.JsonMetadataPayload(),
                        bytes: "",
                    )
                )
            case "get/governance/proposals/{tx_hash}/{cert_index}":
                body = try JSONEncoder().encode(
                    Components.Schemas.Proposal(
                        id: "gov_action1qkm52uwlnw0gtcyh9259sjuwsyrnjdfd3hg7tjzrl463xtv4wfxysqqqqqfd6vw0",
                        txHash: "2dd15e0ef6e6a17841cb9541c27724072ce4d4b79b91e58432fbaa32d9572531",
                        certIndex: 1,
                        governanceType: .treasuryWithdrawals,
                        governanceDescription: Components.Schemas.Proposal.GovernanceDescriptionPayload(),
                        deposit: "12000",
                        returnAddress: "stake_test1urd3hs7rlxwwdzthe6hj026dmyt3y0heuulctscyydh2kgck6nkmz",
                        ratifiedEpoch: nil,
                        enactedEpoch: 123,
                        droppedEpoch: nil,
                        expiredEpoch: nil,
                        expiration: 120
                    )
                )
            case "get/governance/proposals/{tx_hash}/{cert_index}/parameters":
                body = try JSONEncoder().encode(
                    Components.Schemas.ProposalParameters(
                        id: "gov_action1qkm52uwlnw0gtcyh9259sjuwsyrnjdfd3hg7tjzrl463xtv4wfxysqqqqqfd6vw0",
                        txHash: "2dd15e0ef6e6a17841cb9541c27724072ce4d4b79b91e58432fbaa32d9572531",
                        certIndex: 1,
                        parameters: Components.Schemas.ProposalParameters.ParametersPayload(
                            a0: 0.3,
                            rho: 0.003,
                            tau: 0.2,
                            decentralisationParam: 0.5,
                            protocolMajorVer: 10,
                            protocolMinorVer: 0
                        )
                    )
                )
            case "get/governance/proposals/{tx_hash}/{cert_index}/withdrawals":
                body = try JSONEncoder().encode(
                    [
                        Components.Schemas.ProposalWithdrawalsPayload(
                            stakeAddress: "stake_test1urd3hs7rlxwwdzthe6hj026dmyt3y0heuulctscyydh2kgck6nkmz",
                            amount: "20000000"
                        )
                    ]
                )
            case "get/governance/proposals":
                body = try JSONEncoder().encode(
                    [
                        Components.Schemas.ProposalsPayload(
                            id: "gov_action1qkm52uwlnw0gtcyh9259sjuwsyrnjdfd3hg7tjzrl463xtv4wfxysqqqqqfd6vw0",
                            txHash: "2dd15e0ef6e6a17841cb9541c27724072ce4d4b79b91e58432fbaa32d9572531",
                            certIndex: 1,
                            governanceType: .treasuryWithdrawals
                        )
                    ]
                )
            case "get/governance/proposals/{tx_hash}/{cert_index}/votes":
                body = try JSONEncoder().encode(
                    [
                        Components.Schemas.ProposalVotesPayload(
                            txHash: "0000000000000000000000000000000000000000000000000000000000000001",
                            certIndex: 0,
                            voterRole: .constitutionalCommittee,
                            voter: "cc_hot1qgqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqvcdjk7",
                            vote: .yes
                        ),
                        Components.Schemas.ProposalVotesPayload(
                            txHash: "0000000000000000000000000000000000000000000000000000000000000002",
                            certIndex: 0,
                            voterRole: .drep,
                            voter: "drep1kqhhkv66a0egfw7uyz7u8dv7fcvr4ck0c3ad9k9urx3yzhefup0",
                            vote: .abstain
                        ),
                        Components.Schemas.ProposalVotesPayload(
                            txHash: "0000000000000000000000000000000000000000000000000000000000000003",
                            certIndex: 0,
                            voterRole: .spo,
                            voter: "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy",
                            vote: .no
                        )
                    ]
                )
            case "get/governance/proposals/{tx_hash}/{cert_index}/metadata":
                body = try JSONEncoder().encode(
                    Components.Schemas.ProposalMetadata(
                        id: "gov_action1qkm52uwlnw0gtcyh9259sjuwsyrnjdfd3hg7tjzrl463xtv4wfxysqqqqqfd6vw0",
                        txHash: "2dd15e0ef6e6a17841cb9541c27724072ce4d4b79b91e58432fbaa32d9572531",
                        certIndex: 1,
                        url: "https://anchor.test",
                        hash: "35aeb21ba4be07cf9fda041b635f107ef978238b3fccae9be1b571518ce9d1b7",
                        bytes: ""
                    )
                )
            case "get/governance/committee":
                body = try JSONEncoder().encode(
                    Components.Schemas.Committee(
                        govActionId: nil,
                        proposalTxHash: nil,
                        proposalIndex: nil,
                        isDissolved: false,
                        quorum: Components.Schemas.Committee.QuorumPayload(
                            numerator: 2,
                            denominator: 3
                        ),
                        members: [
                            Components.Schemas.Committee.MembersPayloadPayload(
                                ccColdId: "cc_cold1zgqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqz3la7s",
                                ccColdHex: "13493790d9b03483a1e1e684ea4faf1ee48a58f402574e7f2246f4d4",
                                ccColdHasScript: false,
                                ccHotId: "cc_hot1qgqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqvcdjk7",
                                ccHotHex: "0000000000000000000000000000000000000000000000000000000000",
                                ccHotHasScript: false,
                                status: .authorized,
                                expirationEpoch: 800
                            )
                        ]
                    )
                )
            default:
                return (
                    HTTPResponse(status: .notFound),
                    nil
                )
        }
        return (
            HTTPResponse(
                status: .ok,
                headerFields: [.contentType: "application/json"]
            ),
            .init(body)
        )
    }
}



// MARK: - Blockfrost Pool Mock Transport

struct BlockfrostPoolMockTransport: ClientTransport {
    private let fallback = MockTransport()
    
    func send(
        _ request: HTTPTypes.HTTPRequest,
        body: OpenAPIRuntime.HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
        let responseBody: Data
        
        if operationID == "get/pools/{pool_id}/blocks" || operationID == "get/blocks/{hash_or_number}" {
            return try await fallback.send(request, body: body, baseURL: baseURL, operationID: operationID)
        } else if operationID.contains("get/pools/") && operationID.contains("/relays") {
            responseBody = """
                [
                    {
                        "dns": "relay.example.com",
                        "srv": null,
                        "ipv4": null,
                        "ipv6": null,
                        "port": 3001
                    }
                ]
                """.data(using: .utf8)!
        } else if operationID.contains("get/pools/") && operationID.contains("/metadata") {
            responseBody = """
                {
                    "pool_id": "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy",
                    "hex": "0f292fcaa02b8b2f9b3c8f9fd8e0bb21abedb692a6d5058df3ef2735",
                    "url": "https://example.com/metadata.json",
                    "hash": "9a1c27f8a16e560a3b6d574e0fe6e573c15e3b6f65cf8e0f7c2c31f5e9fc2b4a",
                    "ticker": "TEST",
                    "name": "Test Pool",
                    "description": "A test pool",
                    "homepage": "https://example.com"
                }
                """.data(using: .utf8)!
        } else if operationID.contains("get/pools/") {
            responseBody = """
                {
                    "pool_id": "pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy",
                    "hex": "0f292fcaa02b8b2f9b3c8f9fd8e0bb21abedb692a6d5058df3ef2735",
                    "vrf_key": "vrf_key_hash_placeholder_32_bytes_00",
                    "blocks_minted": 100,
                    "blocks_epoch": 10,
                    "live_stake": "1000000000000",
                    "live_size": 0.001,
                    "live_saturation": 0.5,
                    "live_delegators": 100,
                    "active_stake": "1000000000000",
                    "active_size": 0.001,
                    "declared_pledge": "100000000000",
                    "live_pledge": "100000000000",
                    "margin_cost": 0.05,
                    "fixed_cost": "340000000",
                    "reward_account": "stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n",
                    "owners": ["stake_test1upyz3gk6mw5he20apnwfn96cn9rscgvmmsxc9r86dh0k66gswf59n"],
                    "registration": [],
                    "retirement": []
                }
                """.data(using: .utf8)!
        } else {
            return try await fallback.send(request, body: body, baseURL: baseURL, operationID: operationID)
        }

        return (
            HTTPResponse(
                status: .ok,
                headerFields: [.contentType: "application/json"]
            ),
            .init(responseBody)
        )
    }
}

// MARK: - Blockfrost Parameter-Change Mock Transport

/// Variant of `MockTransport` that returns `parameter_change` as the
/// governanceType of the single proposal — used to exercise the Conway
/// protocol-parameter UnitInterval/NonNegativeInterval conversion path in
/// `govActionInfo`. Everything else delegates to the default mock.
struct ParameterChangeMockTransport: ClientTransport {
    private let fallback = MockTransport()

    func send(
        _ request: HTTPTypes.HTTPRequest,
        body: OpenAPIRuntime.HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
        if operationID == "get/governance/proposals/{tx_hash}/{cert_index}" {
            let payload = try JSONEncoder().encode(
                Components.Schemas.Proposal(
                    id: "gov_action1qkm52uwlnw0gtcyh9259sjuwsyrnjdfd3hg7tjzrl463xtv4wfxysqqqqqfd6vw0",
                    txHash: "2dd15e0ef6e6a17841cb9541c27724072ce4d4b79b91e58432fbaa32d9572531",
                    certIndex: 1,
                    governanceType: .parameterChange,
                    governanceDescription: Components.Schemas.Proposal.GovernanceDescriptionPayload(),
                    deposit: "12000",
                    returnAddress: "stake_test1urd3hs7rlxwwdzthe6hj026dmyt3y0heuulctscyydh2kgck6nkmz",
                    ratifiedEpoch: nil,
                    enactedEpoch: 123,
                    droppedEpoch: nil,
                    expiredEpoch: nil,
                    expiration: 120
                )
            )
            return (
                HTTPResponse(
                    status: .ok,
                    headerFields: [.contentType: "application/json"]
                ),
                .init(payload)
            )
        }
        return try await fallback.send(request, body: body, baseURL: baseURL, operationID: operationID)
    }
}


// MARK: - Blockfrost Native-Script Mock Transport

/// Hangs a `timelock` reference script off the single address UTxO and serves the script
/// endpoints Blockfrost uses to resolve it.
struct BlockfrostNativeScriptMockTransport: ClientTransport {
    static let scriptHash = "33333333333333333333333333333333333333333333333333333333"
    static let keyHash = "646d1b3ac94568a422b687db6c47acdf849f1674982ae4f9a494be43"

    private let fallback = MockTransport()

    func send(
        _ request: HTTPTypes.HTTPRequest,
        body: OpenAPIRuntime.HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?) {
        let payload: String

        switch operationID {
            case "get/addresses/{address}/utxos":
                payload = """
                    [{
                        "address": "addr_test1qp4kux2v7xcg9urqssdffff5p0axz9e3hcc43zz7pcuyle0e20hkwsu2ndpd9dh9anm4jn76ljdz0evj22stzrw9egxqmza5y3",
                        "tx_hash": "39a7a284c2a0948189dc45dec670211cd4d72f7b66c5726c08d9b3df11e44d58",
                        "tx_index": 0,
                        "output_index": 0,
                        "amount": [{"unit": "lovelace", "quantity": "1000000"}],
                        "block": "123456",
                        "data_hash": null,
                        "inline_datum": null,
                        "reference_script_hash": "\(Self.scriptHash)"
                    }]
                    """
            case "get/scripts/{script_hash}":
                payload = """
                    {"script_hash": "\(Self.scriptHash)", "type": "timelock", "serialised_size": null}
                    """
            case "get/scripts/{script_hash}/json":
                payload = #"{"json": {"type": "sig", "keyHash": "\#(Self.keyHash)"}}"#
            default:
                return try await fallback.send(
                    request, body: body, baseURL: baseURL, operationID: operationID)
        }

        return (
            HTTPResponse(
                status: .ok,
                headerFields: [.contentType: "application/json"]
            ),
            .init(Data(payload.utf8))
        )
    }
}
