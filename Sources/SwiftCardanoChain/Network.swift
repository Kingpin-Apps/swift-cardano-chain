import Foundation

/// Network ID
public enum Network {
    case mainnet
    case preprod
    case preview
    case guildnet
    case sanchonet
    case custom(Int)
    
    /// Returns the testnet magic for the network
    public var testnetMagic: Int? {
        switch self {
            case .mainnet:
                return nil
            case .preprod:
                return 1
            case .preview:
                return 2
            case .guildnet:
                return 141
            case .sanchonet:
                return 4
            case .custom(let magic):
                return magic
        }
    }
    
    /// Returns the description for the network
    public var description: String {
        switch self {
            case .mainnet:
                return "mainnet"
            case .preprod:
                return "preprod"
            case .preview:
                return "preview"
            case .guildnet:
                return "guildnet"
            case .sanchonet:
                return "sanchonet"
            case .custom(let magic):
                return "custom(\(magic))"
        }
    }
    
    /// Returns the command line arguments for the network
    var arguments: [String] {
        switch self {
        case .mainnet:
            return ["--mainnet"]
        case .preprod:
                return ["--testnet-magic", "\(testnetMagic!)"]
        case .preview:
            return ["--testnet-magic", "\(testnetMagic!)"]
        case .guildnet:
            return ["--testnet-magic", "\(testnetMagic!)"]
        case .sanchonet:
            return ["--testnet-magic", "\(testnetMagic!)"]
        case .custom(let magic):
            return ["--testnet-magic", "\(magic)"]
        }
    }
}
