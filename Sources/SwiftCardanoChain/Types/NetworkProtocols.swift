import Foundation
import SwiftCardanoCore

public protocol NetworkDependable<T>: Codable, Hashable, Sendable {
    associatedtype T: Codable, Hashable, Sendable
    
    var mainnet: T { get }
    var preprod: T? { get }
    var preview: T? { get }
    var guildnet: T? { get }
}

extension NetworkDependable {
    public func forNetwork(_ network: Network) -> T? {
        switch network {
            case .mainnet:
                return mainnet
            case .preprod:
                return preprod
            case .preview:
                return preview
            case .guildnet:
                return guildnet
            default:
                return nil
        }
    }
}
