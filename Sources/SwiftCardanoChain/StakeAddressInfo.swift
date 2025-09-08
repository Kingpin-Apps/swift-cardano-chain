import Foundation

/// Stake address info model class
public struct StakeAddressInfo: Codable, Equatable {
    
    /// Stake address
    public let address: String
    
    /// StakeRegistration deposit
    public let stakeRegistrationDeposit: Int?
    
    /// Reward account balance
    public let rewardAccountBalance: Int
    
    /// Stake delegation pool ID
    public let stakeDelegation: String?
    
    /// Vote delegation ID
    public let voteDelegation: String?
    
    /// Delegate representative ID
    public let delegateRepresentative: String?
    
    /// Custom coding keys to map multiple alias names from JSON
    private enum CodingKeys: String, CodingKey {
        case address
        case stakeRegistrationDeposit
        case rewardAccountBalance
        case stakeDelegation
        case voteDelegation
        case delegateRepresentative
    }
    
    public init(
        address: String,
        rewardAccountBalance: Int,
        delegationDeposit: Int? = nil,
        stakeDelegation: String? = nil,
        voteDelegation: String? = nil,
        delegateRepresentative: String? = nil
    ) {
        self.address = address
        self.rewardAccountBalance = rewardAccountBalance
        self.stakeRegistrationDeposit = delegationDeposit
        self.stakeDelegation = stakeDelegation
        self.voteDelegation = voteDelegation
        self.delegateRepresentative = delegateRepresentative
    }
    
    /// Decoding with multiple alias support
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.address = try container
            .decodeIfPresent(String.self, forKey: .address)!
        self.stakeRegistrationDeposit = try container.decodeIfPresent(Int.self, forKey: .stakeRegistrationDeposit) ?? 0
        self.rewardAccountBalance = try container.decodeIfPresent(Int.self, forKey: .rewardAccountBalance) ?? 0
        self.stakeDelegation = try? container.decodeIfPresent(String.self, forKey: .stakeDelegation)
        self.voteDelegation = try? container.decodeIfPresent(String.self, forKey: .voteDelegation)
        self.delegateRepresentative = try? container.decodeIfPresent(String.self, forKey: .delegateRepresentative)
    }
    
    /// Encoding with multiple alias support
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encodeIfPresent(address, forKey: .address)
        try container.encode(stakeRegistrationDeposit, forKey: .stakeRegistrationDeposit)
        try container.encode(rewardAccountBalance, forKey: .rewardAccountBalance)
        try container.encodeIfPresent(stakeDelegation, forKey: .stakeDelegation)
        try container.encodeIfPresent(voteDelegation, forKey: .voteDelegation)
        try container.encodeIfPresent(delegateRepresentative, forKey: .delegateRepresentative)
    }
}
