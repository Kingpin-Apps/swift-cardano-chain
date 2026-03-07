import Foundation

/// Information about the Key Evolving Signature (KES) period for a stake pool's operational certificate.
///
/// KES is a cryptographic mechanism used in Cardano to limit the damage from a compromised key.
/// Each operational certificate has a KES period that defines when it was issued and how long it remains valid.
/// This struct contains information useful for stake pool operators to monitor certificate rotation requirements.
///
/// ## Example
/// ```swift
/// let kesInfo = try await chainContext.kesPeriodInfo(
///     pool: try PoolOperator(from: "pool1..."),
///     opCert: myOperationalCertificate
/// )
/// 
/// if let onChain = kesInfo.onChainOpCertCount,
///    let onDisk = kesInfo.onDiskOpCertCount {
///     if onDisk > onChain {
///         print("Ready to rotate operational certificate")
///     }
/// }
/// ```
public struct KESPeriodInfo: Codable {
    /// The operational certificate counter currently registered on-chain.
    /// A value of -1 indicates the pool has never minted a block.
    public var onChainOpCertCount: Int?
    
    /// The operational certificate counter from the local certificate file.
    /// This should be greater than `onChainOpCertCount` when rotating certificates.
    public var onDiskOpCertCount: Int?
    
    /// The expected next operational certificate counter (onChainOpCertCount + 1).
    /// Use this value when generating a new operational certificate.
    public var nextChainOpCertCount: Int?
    
    /// The KES period at which the on-disk operational certificate was issued.
    /// Used to calculate remaining KES periods before certificate expiration.
    public var onDiskKESStart: Int?
    
    public init(
        onChainOpCertCount: Int? = nil,
        onDiskOpCertCount: Int? = nil,
        nextChainOpCertCount: Int? = nil,
        onDiskKESStart: Int? = nil
    ) {
        self.onChainOpCertCount = onChainOpCertCount
        self.onDiskOpCertCount = onDiskOpCertCount
        self.nextChainOpCertCount = nextChainOpCertCount
        self.onDiskKESStart = onDiskKESStart
    }
}
