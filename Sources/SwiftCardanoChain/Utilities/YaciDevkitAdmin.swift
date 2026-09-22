import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Reads the genesis documents a Yaci DevKit devnet was started from.
///
/// Yaci Store serves no genesis endpoint, so ``YaciDevkitChainContext`` gets genesis from the
/// DevKit's own admin (cluster) API instead. That API is not part of the Yaci Store OpenAPI
/// specification, so it is not covered by `SwiftYaciAPI`; this protocol is the seam, and tests
/// substitute their own implementation.
public protocol YaciDevkitAdminFetching: Sendable {
    /// The raw JSON of one genesis document.
    /// - Parameter era: `alonzo`, `byron`, `conway` or `shelley`.
    func genesis(era: String) async throws -> Data
}

/// `URLSession`-backed ``YaciDevkitAdminFetching``.
public struct YaciDevkitAdmin: YaciDevkitAdminFetching, @unchecked Sendable {

    /// The port DevKit serves its admin (cluster) API on unless told otherwise.
    public static let defaultPort = 10000

    /// The admin API root, e.g. `http://localhost:10000`.
    public let baseURL: URL

    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Creates an admin client from a URL string.
    /// - Throws: ``CardanoChainError/invalidArgument(_:)`` if the string is not an absolute URL.
    public init(baseURL: String, session: URLSession = .shared) throws {
        var trimmed = Substring(baseURL)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let url = URL(string: String(trimmed)), url.scheme != nil, url.host != nil else {
            throw CardanoChainError.invalidArgument(
                "Invalid Yaci DevKit admin URL: \(baseURL). Expected an absolute URL such as http://localhost:10000."
            )
        }
        self.init(baseURL: url, session: session)
    }

    /// Creates an admin client on ``defaultPort`` of the host serving Yaci Store, which is where
    /// DevKit puts it.
    /// - Throws: ``CardanoChainError/invalidArgument(_:)`` if no admin URL can be derived.
    public init(derivedFromStoreURL storeURL: URL, session: URLSession = .shared) throws {
        guard let scheme = storeURL.scheme, let host = storeURL.host,
            let url = URL(string: "\(scheme)://\(host):\(Self.defaultPort)")
        else {
            throw CardanoChainError.invalidArgument(
                "Cannot derive a Yaci DevKit admin URL from: \(storeURL.absoluteString)"
            )
        }
        self.init(baseURL: url, session: session)
    }

    public func genesis(era: String) async throws -> Data {
        let url = baseURL.appendingPathComponent("/local-cluster/api/admin/devnet/genesis/\(era)")
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CardanoChainError.yaciDevkitError(
                "Failed to reach the Yaci DevKit admin API at \(url.absoluteString): \(error)"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw CardanoChainError.yaciDevkitError("Unexpected non-HTTP response from \(url.absoluteString)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CardanoChainError.yaciDevkitError(
                "GET \(url.path) failed. Status: \(http.statusCode). Body: \(String(decoding: data, as: UTF8.self))"
            )
        }
        return data
    }
}
