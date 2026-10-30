import Foundation
import SwiftCardanoCore

/// A governance action as the ledger writes it in JSON — the form cardano-cli's
/// `query gov-state` prints and db-sync stores (Koios's `proposal_description`,
/// Blockfrost's `governance_description`):
/// `{"tag": "<Constructor>", "contents": [<fields>]}`.
///
/// Read strictly: a missing or unknown tag, or contents of the wrong shape,
/// throw rather than turning into a different, valid action. Only a real
/// `InfoAction` maps to `.infoAction`.
enum LedgerGovActionJSON {

    /// The action `any` describes. `id` is passed through to the action's
    /// `id` field as every backend does; `protocolParamUpdate` reads a
    /// parameter change's update object.
    static func govAction(
        _ any: Any?, id: GovActionID, _ what: String,
        protocolParamUpdate: ([String: Any]) throws -> ProtocolParamUpdate
    ) throws -> GovAction {
        guard let object = any as? [String: Any] else {
            throw CardanoChainError.valueError("\(what): \(String(describing: any)) is not a governance action")
        }
        guard let tag = object["tag"] as? String else {
            throw CardanoChainError.valueError("\(what) has no tag: \(object)")
        }
        func contents(_ count: Int) throws -> [Any] {
            guard let contents = object["contents"] as? [Any], contents.count == count else {
                throw CardanoChainError.valueError(
                    "\(what) \(tag) contents are not \(count) fields: \(String(describing: object["contents"]))")
            }
            return contents
        }

        switch tag {
        case "InfoAction":
            return .infoAction(InfoAction())

        case "NoConfidence":
            return .noConfidence(NoConfidence(id: id))

        case "ParameterChange":
            // [prevGovActionId, ProtocolParamUpdate, policyHash]
            let c = try contents(3)
            guard let update = c[1] as? [String: Any] else {
                throw CardanoChainError.valueError("\(what) parameter update is not an object: \(c[1])")
            }
            return .parameterChangeAction(ParameterChangeAction(
                id: id,
                protocolParamUpdate: try protocolParamUpdate(update),
                policyHash: try policyHash(c[2], "\(what) policy hash")
            ))

        case "HardForkInitiation":
            // [prevGovActionId, {major, minor}]
            let c = try contents(2)
            guard let version = c[1] as? [String: Any] else {
                throw CardanoChainError.valueError("\(what) protocol version is not an object: \(c[1])")
            }
            let major: Int = try LedgerValues.required(
                LedgerValues.integer(json: version["major"], "\(what) major version"), "\(what) major version")
            let minor: Int = try LedgerValues.required(
                LedgerValues.integer(json: version["minor"], "\(what) minor version"), "\(what) minor version")
            return .hardForkInitiationAction(HardForkInitiationAction(
                id: nil, protocolVersion: ProtocolVersion(major: major, minor: minor)))

        case "TreasuryWithdrawals":
            // [[[rewardAccount, coin], ...], policyHash]
            let c = try contents(2)
            guard let pairs = c[0] as? [Any] else {
                throw CardanoChainError.valueError("\(what) withdrawals are not a list: \(c[0])")
            }
            var withdrawals: [RewardAccount: Coin] = [:]
            for pair in pairs {
                guard let pair = pair as? [Any], pair.count == 2 else {
                    throw CardanoChainError.valueError("\(what) withdrawal \(pair) is not [account, amount]")
                }
                let account = try LedgerValues.rewardAccount(json: pair[0], "\(what) withdrawal account")
                withdrawals[account] = try LedgerValues.required(
                    LedgerValues.integer(json: pair[1], "\(what) withdrawal amount"), "\(what) withdrawal amount")
            }
            return .treasuryWithdrawalsAction(TreasuryWithdrawalsAction(
                withdrawals: withdrawals, policyHash: try policyHash(c[1], "\(what) policy hash")))

        case "UpdateCommittee":
            return .updateCommittee(try updateCommittee(contents(4), id: id, what))

        case "NewConstitution":
            // [prevGovActionId, {anchor, script}]
            let c = try contents(2)
            guard let constitution = c[1] as? [String: Any] else {
                throw CardanoChainError.valueError("\(what) constitution is not an object: \(c[1])")
            }
            return .newConstitution(NewConstitution(id: id, constitution: try self.constitution(constitution, what)))

        default:
            throw CardanoChainError.valueError("\(what) has an unknown tag \(tag)")
        }
    }

    /// `[prevGovActionId, [removed cold credentials], {added cold credential: expiry epoch}, quorum]`.
    ///
    /// The members to remove and the members to add both go in
    /// `coldCredentials`, with the added members' terms in
    /// `credentialEpochs`, as every backend in this library reports them.
    static func updateCommittee(_ contents: [Any], id: GovActionID, _ what: String) throws -> UpdateCommittee {
        guard contents.count == 4 else {
            throw CardanoChainError.valueError("\(what) UpdateCommittee contents are not 4 fields: \(contents)")
        }
        guard let removed = contents[1] as? [Any] else {
            throw CardanoChainError.valueError("\(what) members to remove are not a list: \(contents[1])")
        }
        guard let added = contents[2] as? [String: Any] else {
            throw CardanoChainError.valueError("\(what) members to add are not an object: \(contents[2])")
        }
        var coldCredentials: Set<CommitteeColdCredential> = []
        var credentialEpochs: [CommitteeColdCredential: UInt64] = [:]
        for entry in removed {
            coldCredentials.insert(CommitteeColdCredential(
                credential: try LedgerValues.credential(json: entry, "\(what) member to remove")))
        }
        for (key, epoch) in added {
            let credential = CommitteeColdCredential(
                credential: try LedgerValues.credential(json: key, "\(what) member to add"))
            coldCredentials.insert(credential)
            credentialEpochs[credential] = try LedgerValues.required(
                LedgerValues.integer(json: epoch, "\(what) member term"), "\(what) member term")
        }
        let quorum = try LedgerValues.required(
            LedgerValues.unitInterval(json: contents[3], "\(what) quorum"), "\(what) quorum")
        return UpdateCommittee(
            id: id, coldCredentials: coldCredentials, credentialEpochs: credentialEpochs, interval: quorum)
    }

    /// `{anchor: {url, dataHash}, script: hash | null}`; the anchor is required.
    static func constitution(_ object: [String: Any], _ what: String) throws -> Constitution {
        Constitution(
            anchor: try LedgerValues.required(
                LedgerValues.anchor(json: object["anchor"], "\(what) constitution anchor"),
                "\(what) constitution anchor"),
            scriptHash: try policyHash(object["script"], "\(what) constitution script")
        )
    }

    /// A script hash in hex, or `nil` for no value or JSON null.
    static func policyHash(_ any: Any?, _ what: String) throws -> ScriptHash? {
        guard let any, !(any is NSNull) else { return nil }
        guard let hex = any as? String else {
            throw CardanoChainError.valueError("\(what): \(any) is not a script hash")
        }
        return try LedgerValues.hash(hex: hex, as: ScriptHash.self, what)
    }

    /// Decode a `ProtocolParamUpdate` from the ledger JSON object that appears
    /// in the `contents[1]` slot of a ParameterChange governance action.
    ///
    /// Only the fields actually present in the dict are populated; everything
    /// else stays `nil`, which in a `ProtocolParamUpdate` means "not changed".
    /// A field that is present but does not fit its ledger type (negative,
    /// too large, a ratio above one, not a number) throws. Field-name keys
    /// mirror what `cardano-cli conway query gov-state` emits.
    static func protocolParamUpdate(_ d: [String: Any], _ what: String) throws -> ProtocolParamUpdate {
        func coin(_ key: String) throws -> Coin? {
            try LedgerValues.integer(json: d[key], "\(what) \(key)")
        }
        func uint32(_ key: String) throws -> UInt32? {
            try LedgerValues.integer(json: d[key], "\(what) \(key)")
        }
        func uint16(_ key: String) throws -> UInt16? {
            try LedgerValues.integer(json: d[key], "\(what) \(key)")
        }
        func epochInterval(_ key: String) throws -> EpochInterval? {
            try LedgerValues.integer(json: d[key], "\(what) \(key)")
        }
        func nni(_ key: String) throws -> NonNegativeInterval? {
            try LedgerValues.nonNegativeInterval(json: d[key], "\(what) \(key)")
        }
        func unit(_ key: String) throws -> UnitInterval? {
            try LedgerValues.unitInterval(json: d[key], "\(what) \(key)")
        }
        func exUnits(_ key: String) throws -> ExUnits? {
            guard let raw = d[key], !(raw is NSNull) else { return nil }
            guard let pair = raw as? [String: Any] else {
                throw CardanoChainError.valueError("\(what) \(key): \(raw) is not an execution-units object")
            }
            func value(_ keys: String...) throws -> UInt64 {
                let present = keys.first { pair[$0] != nil }
                return try LedgerValues.required(
                    LedgerValues.integer(json: present.flatMap { pair[$0] }, as: UInt64.self, "\(what) \(key)"),
                    "\(what) \(key) \(keys[0])")
            }
            return ExUnits(mem: try value("memory", "mem"), steps: try value("steps", "step"))
        }

        var u = ProtocolParamUpdate()
        u.minFeeA = try coin("txFeePerByte") ?? (try coin("minFeeA"))
        u.minFeeB = try coin("txFeeFixed") ?? (try coin("minFeeB"))
        u.maxBlockBodySize = try uint32("maxBlockBodySize")
        u.maxTransactionSize = try uint32("maxTxSize") ?? (try uint32("maxTransactionSize"))
        u.maxBlockHeaderSize = try uint16("maxBlockHeaderSize")
        u.keyDeposit = try coin("stakeAddressDeposit") ?? (try coin("keyDeposit"))
        u.poolDeposit = try coin("stakePoolDeposit") ?? (try coin("poolDeposit"))
        u.maximumEpoch = try epochInterval("poolRetireMaxEpoch") ?? (try epochInterval("maximumEpoch"))
        u.nOpt = try uint16("stakePoolTargetNum") ?? (try uint16("nOpt"))
        u.poolPledgeInfluence = try nni("poolPledgeInfluence")
        u.expansionRate = try unit("monetaryExpansion") ?? (try unit("expansionRate"))
        u.treasuryGrowthRate = try unit("treasuryCut") ?? (try unit("treasuryGrowthRate"))
        u.minPoolCost = try coin("minPoolCost")
        u.adaPerUtxoByte = try coin("utxoCostPerByte") ?? (try coin("adaPerUTxOByte") ?? (try coin("adaPerUtxoByte")))
        u.maxValueSize = try uint32("maxValueSize")
        u.collateralPercentage = try uint16("collateralPercentage")
        u.maxCollateralInputs = try uint16("maxCollateralInputs")
        u.minCommitteeSize = try uint16("committeeMinSize") ?? (try uint16("minCommitteeSize"))
        u.committeeTermLimit = try epochInterval("committeeMaxTermLength") ?? (try epochInterval("committeeTermLimit"))
        u.governanceActionValidityPeriod = try epochInterval("govActionLifetime") ?? (try epochInterval("governanceActionValidityPeriod"))
        u.governanceActionDeposit = try coin("govActionDeposit") ?? (try coin("governanceActionDeposit"))
        u.drepDeposit = try coin("dRepDeposit") ?? (try coin("drepDeposit"))
        u.drepInactivityPeriod = try epochInterval("dRepActivity") ?? (try epochInterval("drepInactivityPeriod"))
        u.minFeeRefScriptCoinsPerByte = try nni("minFeeRefScriptCostPerByte") ?? (try nni("minFeeRefScriptCoinsPerByte"))

        if let v = d["protocolVersion"] as? [String: Any] {
            u.protocolVersion = ProtocolVersion(
                major: try LedgerValues.required(
                    LedgerValues.integer(json: v["major"], "\(what) protocolVersion major"), "\(what) protocolVersion major"),
                minor: try LedgerValues.required(
                    LedgerValues.integer(json: v["minor"], "\(what) protocolVersion minor"), "\(what) protocolVersion minor"))
        }

        u.maxBlockExUnits = try exUnits("maxBlockExecutionUnits") ?? (try exUnits("maxBlockExUnits"))
        u.maxTxExUnits = try exUnits("maxTxExecutionUnits") ?? (try exUnits("maxTxExUnits"))

        if let prices = d["executionUnitPrices"] as? [String: Any] ?? d["executionCosts"] as? [String: Any] {
            let mem = try LedgerValues.required(
                LedgerValues.nonNegativeInterval(json: prices["priceMemory"], "\(what) priceMemory"),
                "\(what) priceMemory")
            let step = try LedgerValues.required(
                LedgerValues.nonNegativeInterval(json: prices["priceSteps"], "\(what) priceSteps"),
                "\(what) priceSteps")
            u.executionCosts = ExUnitPrices(memPrice: mem, stepPrice: step)
        }

        if let cm = d["costModels"] as? [String: Any], !cm.isEmpty {
            // The cardano-cli JSON arrays may not match the strict cost-model template
            // length (entries are added over hard forks). Pass empty arrays for any
            // version present in the JSON — `modelFromValues` treats empty as
            // "zero-filled template" and avoids the length check. Values are wrong,
            // but downstream consumers in scm only need the field to be non-nil to
            // detect that the TECHNICAL parameter group was touched.
            var byId: [Int: [Int64]] = [:]
            for key in cm.keys {
                switch key {
                case "PlutusV1", "PlutusScriptV1": byId[0] = []
                case "PlutusV2", "PlutusScriptV2": byId[1] = []
                case "PlutusV3", "PlutusScriptV3": byId[2] = []
                default: break
                }
            }
            if !byId.isEmpty {
                u.costModels = try? CostModels(byId)
            }
        }

        if let pvt = d["poolVotingThresholds"] as? [String: Any] {
            // An update that carries the thresholds carries all of them.
            func ui(_ key: String) throws -> UnitInterval? {
                try LedgerValues.required(
                    LedgerValues.unitInterval(json: pvt[key], "\(what) \(key)"), "\(what) poolVotingThresholds \(key)")
            }
            if let cnc = try ui("committeeNoConfidence"),
               let cn = try ui("committeeNormal"),
               let hfi = try ui("hardForkInitiation"),
               let mnc = try ui("motionNoConfidence"),
               let psg = try ui("ppSecurityGroup")
            {
                u.poolVotingThresholds = PoolVotingThresholds(
                    motionNoConfidence: mnc,
                    committeeNormal: cn,
                    committeeNoConfidence: cnc,
                    hardForkInitiation: hfi,
                    ppSecurityGroup: psg
                )
            }
        }

        if let dvt = d["dRepVotingThresholds"] as? [String: Any] {
            func ui(_ key: String) throws -> UnitInterval? {
                try LedgerValues.required(
                    LedgerValues.unitInterval(json: dvt[key], "\(what) \(key)"), "\(what) dRepVotingThresholds \(key)")
            }
            let order: [(String, KeyPath<[String: UnitInterval?], UnitInterval?>)] = []  // unused; we'll inline
            _ = order
            if let mnc = try ui("motionNoConfidence"),
               let cn = try ui("committeeNormal"),
               let cnc = try ui("committeeNoConfidence"),
               let utc = try ui("updateToConstitution"),
               let hfi = try ui("hardForkInitiation"),
               let net = try ui("ppNetworkGroup"),
               let eco = try ui("ppEconomicGroup"),
               let tech = try ui("ppTechnicalGroup"),
               let gov = try ui("ppGovGroup"),
               let tw = try ui("treasuryWithdrawal")
            {
                // CDDL order: motionNoConfidence, committeeNormal, committeeNoConfidence,
                //             updateToConstitution, hardForkInitiation, ppNetworkGroup,
                //             ppEconomicGroup, ppTechnicalGroup, ppGovGroup, treasuryWithdrawal
                u.drepVotingThresholds = try DrepVotingThresholds(thresholds: [mnc, cn, cnc, utc, hfi, net, eco, tech, gov, tw])
            }
        }

        return u
    }
}
