import BigInt
import Foundation
import SwiftCardanoCore
import UTxORPC

/// Turns UTxO RPC v1beta messages into SwiftCardanoCore values.
///
/// Every number from the wire is range-checked: a value that does not fit the
/// ledger type it maps to throws ``CardanoChainError/valueError(_:)`` rather
/// than trapping or being clamped.
enum UTxORPCMapping {

    // MARK: - Numbers

    /// A UTxO RPC `BigInt` as an arbitrary-precision integer. `big_u_int` holds
    /// big-endian magnitude bytes and `big_n_int` holds `n` for the value `-1 - n`.
    static func bigInt(_ value: Utxorpc_V1beta_Cardano_BigInt) -> BigInt {
        switch value.bigInt {
        case .int(let int)?: return BigInt(int)
        case .bigUInt(let bytes)?: return BigInt(BigUInt(bytes))
        case .bigNInt(let bytes)?: return -1 - BigInt(BigUInt(bytes))
        case nil: return 0
        }
    }

    /// A UTxO RPC `BigInt` as a lovelace amount.
    static func coin(_ value: Utxorpc_V1beta_Cardano_BigInt, _ what: @autoclosure () -> String) throws -> Coin {
        let int = bigInt(value)
        guard let coin = Coin(exactly: int) else {
            throw CardanoChainError.valueError("\(what()): \(int) is not a lovelace amount")
        }
        return coin
    }

    /// The numerator and denominator of a rational, checked to be a
    /// non-negative fraction.
    private static func fraction(
        _ value: Utxorpc_V1beta_Cardano_RationalNumber, _ what: String
    ) throws -> (UInt64, UInt64) {
        guard value.denominator > 0 else {
            throw CardanoChainError.valueError("\(what): \(value.numerator)/\(value.denominator) has no positive denominator")
        }
        guard let numerator = UInt64(exactly: value.numerator) else {
            throw CardanoChainError.valueError("\(what): \(value.numerator)/\(value.denominator) is negative")
        }
        return (numerator, UInt64(value.denominator))
    }

    static func unitInterval(
        _ value: Utxorpc_V1beta_Cardano_RationalNumber, _ what: @autoclosure () -> String
    ) throws -> UnitInterval {
        let what = what()
        let (numerator, denominator) = try fraction(value, what)
        guard numerator <= denominator else {
            throw CardanoChainError.valueError("\(what): \(numerator)/\(denominator) is above one, so not a unit interval")
        }
        return UnitInterval(numerator: numerator, denominator: denominator)
    }

    static func nonNegativeInterval(
        _ value: Utxorpc_V1beta_Cardano_RationalNumber, _ what: @autoclosure () -> String
    ) throws -> NonNegativeInterval {
        let (numerator, denominator) = try fraction(value, what())
        return NonNegativeInterval(numerator: numerator, denominator: denominator)
    }

    // MARK: - Protocol parameters

    /// Protocol parameters from `ReadParams`.
    ///
    /// The voting thresholds arrive as lists in CIP-1694 order, the ledger's
    /// own order. UTxO RPC does not carry the reference-script size limits, so
    /// those stay `nil`.
    static func protocolParameters(_ p: Utxorpc_V1beta_Cardano_PParams) throws -> ProtocolParameters {
        func units(_ u: Utxorpc_V1beta_Cardano_ExUnits) -> ProtocolParametersExecutionUnits {
            ProtocolParametersExecutionUnits(memory: u.memory, steps: u.steps)
        }

        let pool = p.poolVotingThresholds.thresholds
        guard pool.count == 5 else {
            throw CardanoChainError.valueError("UTxO RPC pool voting thresholds: expected 5, got \(pool.count)")
        }
        func poolAt(_ i: Int) throws -> UnitInterval { try unitInterval(pool[i], "UTxO RPC pool voting threshold \(i)") }

        let drep = p.drepVotingThresholds.thresholds
        guard drep.count == 10 else {
            throw CardanoChainError.valueError("UTxO RPC DRep voting thresholds: expected 10, got \(drep.count)")
        }
        func drepAt(_ i: Int) throws -> UnitInterval { try unitInterval(drep[i], "UTxO RPC DRep voting threshold \(i)") }

        return ProtocolParameters(
            collateralPercentage: try p.collateralPercentage.checked("UTxO RPC collateralPercentage"),
            committeeMaxTermLength: try p.committeeTermLimit.checked("UTxO RPC committeeTermLimit"),
            committeeMinSize: try p.minCommitteeSize.checked("UTxO RPC minCommitteeSize"),
            costModels: ProtocolParametersCostModels(
                PlutusV1: p.costModels.plutusV1.values,
                PlutusV2: p.costModels.plutusV2.values,
                PlutusV3: p.costModels.plutusV3.values
            ),
            dRepActivity: try p.drepInactivityPeriod.checked("UTxO RPC drepInactivityPeriod"),
            dRepDeposit: try coin(p.drepDeposit, "UTxO RPC drepDeposit"),
            dRepVotingThresholds: DRepVotingThresholds(
                committeeNoConfidence: try drepAt(2),
                committeeNormal: try drepAt(1),
                hardForkInitiation: try drepAt(4),
                motionNoConfidence: try drepAt(0),
                ppEconomicGroup: try drepAt(6),
                ppGovGroup: try drepAt(8),
                ppNetworkGroup: try drepAt(5),
                ppTechnicalGroup: try drepAt(7),
                treasuryWithdrawal: try drepAt(9),
                updateToConstitution: try drepAt(3)
            ),
            executionUnitPrices: ExecutionUnitPrices(
                priceMemory: try nonNegativeInterval(p.prices.memory, "UTxO RPC prices.memory"),
                priceSteps: try nonNegativeInterval(p.prices.steps, "UTxO RPC prices.steps")
            ),
            govActionDeposit: try coin(p.governanceActionDeposit, "UTxO RPC governanceActionDeposit"),
            govActionLifetime: try p.governanceActionValidityPeriod.checked("UTxO RPC governanceActionValidityPeriod"),
            maxBlockBodySize: try p.maxBlockBodySize.checked("UTxO RPC maxBlockBodySize"),
            maxBlockExecutionUnits: units(p.maxExecutionUnitsPerBlock),
            maxBlockHeaderSize: try p.maxBlockHeaderSize.checked("UTxO RPC maxBlockHeaderSize"),
            maxCollateralInputs: try p.maxCollateralInputs.checked("UTxO RPC maxCollateralInputs"),
            maxTxExecutionUnits: units(p.maxExecutionUnitsPerTransaction),
            maxTxSize: try p.maxTxSize.checked("UTxO RPC maxTxSize"),
            maxValueSize: try p.maxValueSize.checked("UTxO RPC maxValueSize"),
            minFeeRefScriptCostPerByte: p.hasMinFeeScriptRefCostPerByte
                ? try nonNegativeInterval(p.minFeeScriptRefCostPerByte, "UTxO RPC minFeeScriptRefCostPerByte")
                : nil,
            minPoolCost: try coin(p.minPoolCost, "UTxO RPC minPoolCost"),
            monetaryExpansion: try unitInterval(p.monetaryExpansion, "UTxO RPC monetaryExpansion"),
            poolPledgeInfluence: try nonNegativeInterval(p.poolInfluence, "UTxO RPC poolInfluence"),
            poolRetireMaxEpoch: try p.poolRetirementEpochBound.checked("UTxO RPC poolRetirementEpochBound"),
            poolVotingThresholds: ProtocolParametersPoolVotingThresholds(
                committeeNoConfidence: try poolAt(2),
                committeeNormal: try poolAt(1),
                hardForkInitiation: try poolAt(3),
                motionNoConfidence: try poolAt(0),
                ppSecurityGroup: try poolAt(4)
            ),
            protocolVersion: ProtocolParametersProtocolVersion(
                major: p.protocolVersion.major, minor: p.protocolVersion.minor
            ),
            stakeAddressDeposit: try coin(p.stakeKeyDeposit, "UTxO RPC stakeKeyDeposit"),
            stakePoolDeposit: try coin(p.poolDeposit, "UTxO RPC poolDeposit"),
            stakePoolTargetNum: try p.desiredNumberOfPools.checked("UTxO RPC desiredNumberOfPools"),
            treasuryCut: try unitInterval(p.treasuryExpansion, "UTxO RPC treasuryExpansion"),
            txFeeFixed: try coin(p.minFeeConstant, "UTxO RPC minFeeConstant"),
            txFeePerByte: try coin(p.minFeeCoefficient, "UTxO RPC minFeeCoefficient"),
            utxoCostPerByte: try coin(p.coinsPerUtxoByte, "UTxO RPC coinsPerUtxoByte")
        )
    }

    // MARK: - Genesis

    /// The Shelley genesis parameters from `ReadGenesis`. `system_start` is ISO 8601.
    static func genesisParameters(_ g: Utxorpc_V1beta_Cardano_Genesis) throws -> GenesisParameters {
        GenesisParameters(
            activeSlotsCoefficient: try unitInterval(g.activeSlotsCoeff, "UTxO RPC genesis activeSlotsCoeff"),
            epochLength: UInt64(g.epochLength),
            maxKesEvolutions: UInt64(g.maxKesEvolutions),
            maxLovelaceSupply: try coin(g.maxLovelaceSupply, "UTxO RPC genesis maxLovelaceSupply"),
            networkId: g.networkID,
            networkMagic: g.networkMagic,
            securityParam: UInt64(g.securityParam),
            slotLength: try slotLengthSeconds(g.slotLength),
            slotsPerKesPeriod: UInt64(g.slotsPerKesPeriod),
            systemStart: try systemStart(g.systemStart),
            updateQuorum: UInt64(g.updateQuorum)
        )
    }

    /// The genesis slot length in seconds, exactly: a 200 ms slot is 0.2, not 0.
    ///
    /// The spec gives `slot_length` no unit and servers disagree: cardano-node
    /// sends milliseconds (1000 on mainnet), Dolos the genesis file's whole
    /// seconds (1). A Shelley slot lasts well under 100 seconds, so 100 or more
    /// is milliseconds and anything less is seconds.
    static func slotLengthSeconds(_ raw: UInt32) throws -> Decimal {
        guard raw > 0 else {
            throw CardanoChainError.valueError("UTxO RPC genesis slot length is 0")
        }
        return raw >= 100 ? Decimal(raw) / 1000 : Decimal(raw)
    }

    /// The genesis start time.
    ///
    /// - Throws: When it does not parse: the start time anchors every slot
    ///   and epoch computed from it, so "now" is no substitute.
    static func systemStart(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        throw CardanoChainError.valueError("UTxO RPC genesis systemStart \(text) is not an ISO 8601 date")
    }

    // MARK: - UTxOs

    /// A transaction input as a UTxO RPC output reference.
    static func txoRef(_ input: TransactionInput) -> Utxorpc_V1beta_Query_TxoRef {
        .with {
            $0.hash = input.transactionId.payload
            $0.index = UInt32(input.index)
        }
    }

    /// A UTxO from its reference and the output's own CBOR (`native_bytes`).
    ///
    /// The CBOR is decoded rather than the parsed `cardano` output, so datums,
    /// scripts and assets come through exactly as the ledger holds them.
    static func utxo(_ item: Utxorpc_V1beta_Query_AnyUtxoData) throws -> UTxO {
        let ref = item.txoRef
        let reference = "\(ref.hash.toHex)#\(ref.index)"
        guard let index = UInt16(exactly: ref.index) else {
            throw CardanoChainError.valueError("UTxO RPC output index of \(reference) is out of range")
        }
        guard ref.hash.count == 32 else {
            throw CardanoChainError.valueError("UTxO RPC transaction id of \(reference) is not a 32-byte hash")
        }
        let transactionId = TransactionId(payload: ref.hash)
        guard !item.nativeBytes.isEmpty else {
            throw CardanoChainError.valueError("UTxO RPC returned no output CBOR (native_bytes) for \(reference)")
        }
        let output: TransactionOutput
        do {
            output = try TransactionOutput.fromCBOR(data: item.nativeBytes)
        } catch {
            throw CardanoChainError.valueError("UTxO RPC output CBOR of \(reference) did not decode: \(error)")
        }
        return UTxO(input: TransactionInput(transactionId: transactionId, index: index), output: output)
    }

    // MARK: - Evaluation

    /// The redeemer tag a UTxO RPC purpose names.
    static func redeemerTag(_ purpose: Utxorpc_V1beta_Cardano_RedeemerPurpose) -> RedeemerTag? {
        switch purpose {
        case .spend: return .spend
        case .mint: return .mint
        case .cert: return .cert
        case .reward: return .reward
        case .vote: return .voting
        case .propose: return .proposing
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    /// The execution units of each redeemer, keyed `<tag>:<index>` the way the
    /// transaction builder looks them up (``RedeemerTag/description()``).
    ///
    /// - Throws: ``CardanoChainError/transactionFailed(_:)`` listing every
    ///   error when evaluation reported any: a script that failed, or a
    ///   transaction-level error such as a balance mismatch.
    static func executionUnits(_ report: Utxorpc_V1beta_Cardano_TxEval) throws -> [String: ExecutionUnits] {
        guard report.errors.isEmpty else {
            let messages = report.errors.map { error -> String in
                guard error.hasPurpose, let tag = redeemerTag(error.purpose) else { return error.msg }
                return "\(tag.description()):\(error.index): \(error.msg)"
            }
            throw CardanoChainError.transactionFailed(
                "Transaction evaluation failed: \(messages.joined(separator: "; "))")
        }
        var units: [String: ExecutionUnits] = [:]
        for redeemer in report.redeemers {
            guard let tag = redeemerTag(redeemer.purpose) else {
                throw CardanoChainError.valueError("UTxO RPC evaluation returned a redeemer with no purpose")
            }
            let key = "\(tag.description()):\(redeemer.index)"
            units[key] = ExecutionUnits(
                mem: try redeemer.exUnits.memory.checked("UTxO RPC evaluation \(key) memory"),
                steps: try redeemer.exUnits.steps.checked("UTxO RPC evaluation \(key) steps")
            )
        }
        return units
    }
}
