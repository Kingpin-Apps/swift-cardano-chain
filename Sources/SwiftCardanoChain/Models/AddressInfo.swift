import Foundation
import SwiftCardanoCore
import SystemPackage

public struct AddressInfo: Codable, CustomStringConvertible {
    public var addressFile: FilePath?
    public var name: String?
    public var adaHandle: String?
    public var address: Address?
    public var base16: String?
    public var encoding: String?
    public var totalAmount: Int?
    public var totalAssetCount: Int?
    public var date: Date
    public var used: Bool
    public var utxos: [UTxO]
    public var stakeAddressInfo: [StakeAddressInfo]

    /// Derived from `address` — always reflects the current address value.
    public var type: AddressType? {
        guard let address, let bech32 = try? address.toBech32() else { return nil }
        if bech32.hasPrefix("addr") { return .payment }
        if bech32.hasPrefix("stake") { return .stake }
        return nil
    }

    /// Derived from `address` — always reflects the current address value.
    public var era: AddressEra? {
        guard let address else { return nil }
        return AddressEra(fromAddress: address)
    }
    
    public enum AddressType: String, Codable {
        case payment
        case stake
        
        /// Initialize from bech32 prefix
        public init?(fromAddressBech32 address: String) {
            if address.lowercased().hasPrefix("stake") {
                self = .stake
            } else if address.lowercased().hasPrefix("addr") {
                self = .payment
            } else {
                return nil
            }
        }
        
        /// Human-readable description
        public var description: String {
            switch self {
                case .payment:
                    return "Payment"
                case .stake:
                    return "Stake"
            }
        }
    }
    
    public enum AddressEra: String, Codable {
        case byron
        case shelley
        
        /// Initialize from bech32 prefix
        public init(fromAddress address: Address) {
            switch address.addressType {
                case .byron:
                    self = .byron
                default:
                    self = .shelley
            }
        }
        
        /// Human-readable description
        public var description: String {
            switch self {
                case .byron:
                    return "Byron"
                case .shelley:
                    return "Shelley"
            }
        }
    }
    
    // MARK: Initializers
    
    /// Convenience initializer from address string
    public init(fromAddressString addressString: String, name: String? = nil) throws {
        let parsedAddress = try Address(from: .string(addressString))
        try self.init(name: name, address: parsedAddress)
    }
    
    /// Convenience initializer from file path
    public init(fromFile filePath: FilePath, name: String? = nil) throws {
        let addressFromFile = try Address.load(from: filePath.string)
        try self.init(addressFile: filePath, name: name, address: addressFromFile)
    }
    
    /// Convenience initializer from ada handle
    public init(fromAdaHandle handle: String, name: String? = nil) throws {
        try self.init(name: name, adaHandle: handle)
    }
    
    public init(
        addressFile: FilePath? = nil,
        name: String? = nil,
        adaHandle: String? = nil,
        address: Address? = nil,
        base16: String? = nil,
        encoding: String? = nil,
        totalAmount: Int? = nil,
        totalAssetCount: Int? = nil,
        date: Date = Date(),
        used: Bool = false,
        utxos: [UTxO] = [],
        stakeAddressInfo: [StakeAddressInfo] = []
    ) throws {
        self.addressFile = addressFile
        self.name = name
        self.adaHandle = adaHandle
        self.address = address
        self.base16 = base16
        self.encoding = encoding
        self.totalAmount = totalAmount
        self.totalAssetCount = totalAssetCount
        self.date = date
        self.used = used
        self.utxos = utxos
        self.stakeAddressInfo = stakeAddressInfo

        // Validate presence of at least one identifier
        if self.address == nil && self.addressFile == nil && self.adaHandle == nil {
            throw CardanoChainError.invalidArgument("AddressInfo needs an address, AdaHandle or a path to the address file")
        }

        // If addressFile provided and address is nil, load address from file
        if let addressFilePath = self.addressFile, self.address == nil {
            self.address = try Address.load(from: addressFilePath.string)
        }

        // If name not provided, default to file stem or adaHandle or "Unnamed Address"
        if self.name == nil {
            if let addressFilePath = self.addressFile {
                if let filename = addressFilePath.lastComponent?.string {
                    self.name = filename.components(separatedBy: ".").first ?? "Unnamed Address"
                } else {
                    self.name = self.adaHandle ?? "Unnamed Address"
                }
            } else {
                self.name = self.adaHandle ?? "Unnamed Address"
            }
        }

        // Validate adaHandle if present
        if let handle = self.adaHandle {
            self.adaHandle = try checkAdaHandleFormat(handle)
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case addressFile, name, adaHandle, address, base16, encoding
        case era, type
        case totalAmount, totalAssetCount, date, used, utxos, stakeAddressInfo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.addressFile = try container.decodeIfPresent(FilePath.self, forKey: .addressFile)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.adaHandle = try container.decodeIfPresent(String.self, forKey: .adaHandle)
        self.address = try container.decodeIfPresent(Address.self, forKey: .address)
        self.base16 = try container.decodeIfPresent(String.self, forKey: .base16)
        self.encoding = try container.decodeIfPresent(String.self, forKey: .encoding)
        self.totalAmount = try container.decodeIfPresent(Int.self, forKey: .totalAmount)
        self.totalAssetCount = try container.decodeIfPresent(Int.self, forKey: .totalAssetCount)
        self.date = try container.decode(Date.self, forKey: .date)
        self.used = try container.decode(Bool.self, forKey: .used)
        self.utxos = try container.decode([UTxO].self, forKey: .utxos)
        self.stakeAddressInfo = try container.decode([StakeAddressInfo].self, forKey: .stakeAddressInfo)
        // `type` and `era` are derived from `address`; ignored on decode.
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(addressFile, forKey: .addressFile)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(adaHandle, forKey: .adaHandle)
        try container.encodeIfPresent(address, forKey: .address)
        try container.encodeIfPresent(base16, forKey: .base16)
        try container.encodeIfPresent(encoding, forKey: .encoding)
        try container.encodeIfPresent(era, forKey: .era)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(totalAmount, forKey: .totalAmount)
        try container.encodeIfPresent(totalAssetCount, forKey: .totalAssetCount)
        try container.encode(date, forKey: .date)
        try container.encode(used, forKey: .used)
        try container.encode(utxos, forKey: .utxos)
        try container.encode(stakeAddressInfo, forKey: .stakeAddressInfo)
    }
    
    public mutating func checkAdaHandle(network: Network) async throws {
        if let handle = adaHandle {
            self.address = try await resolveAdahandle(
                handle: handle,
                network: network
            )
        }
    }
    
    public var description: String {
        return address?.description ?? adaHandle ?? name ?? "Unnamed Address"
    }
}
