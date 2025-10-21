import Foundation
import SwiftCardanoCore
import SystemPackage

public struct AddressInfo: Codable, CustomStringConvertible {
    var addressFile: FilePath?
    var name: String?
    var adaHandle: String?
    var address: Address?
    var base16: String?
    var encoding: String?
    var era: String?
    var type: AddressType?
    var totalAmount: Int?
    var totalAssetCount: Int?
    var date: Date
    var used: Bool
    var utxos: [UTxO]
    var stakeAddressInfo: [StakeAddressInfo]
    
    enum AddressType: String, Codable {
        case payment
        case stake
    }
    
    init(
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
    
    public var description: String {
        return address?.description ?? adaHandle ?? name ?? "Unnamed Address"
    }
}
