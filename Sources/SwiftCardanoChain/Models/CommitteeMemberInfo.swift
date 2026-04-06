import SwiftCardanoCore

public enum CommitteeMemberStatus: Codable, Sendable {
    case active
    case expired
    case unrecognized
}

public struct CommitteeMemberInfo: Codable, CustomStringConvertible, Equatable, Sendable {
    
    public let coldCredential: CommitteeColdCredential
    public let hotCredential: CommitteeHotCredential?
    public let expiration: EpochNumber?
    public var status: CommitteeMemberStatus?
    
    public var description: String {
        return coldCredential.description
    }
}
