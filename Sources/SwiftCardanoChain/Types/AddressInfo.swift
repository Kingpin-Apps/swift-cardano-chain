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
    public var era: String?
    public var type: AddressType?
    public var totalAmount: Int?
    public var totalAssetCount: Int?
    public var date: Date
    public var used: Bool
    public var utxos: [UTxO]
    public var stakeAddressInfo: [StakeAddressInfo]
    
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
        era: String? = nil,
        type: AddressType? = nil,
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
        self.era = era
        self.type = type
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
        
        // Infer address type from address string
        if let addr = self.address,
            let bech32 = try? addr.toBech32() {
            
            if bech32.hasPrefix("addr") {
                self.type = .payment
            } else if bech32.hasPrefix("stake") {
                self.type = .stake
            }
            
        }
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
