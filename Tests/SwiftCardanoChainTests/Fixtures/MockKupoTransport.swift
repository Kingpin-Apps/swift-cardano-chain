import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Serves canned Kupo JSON by path, and records every request path.
///
/// A route matches on the path alone; its required query flags must also be
/// present, whether sent bare (`?unspent`, as Kupo reads them) or with a value.
final class KupoMockTransport: ClientTransport, @unchecked Sendable {
    struct Route {
        var flags: Set<String> = []
        var body: String
    }

    private let lock = NSLock()
    private var _paths: [String] = []
    let routes: [String: Route]

    init(routes: [String: Route]) {
        self.routes = routes
    }

    var paths: [String] {
        lock.withLock { _paths }
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let full = (request.path ?? "").removingPercentEncoding ?? ""
        lock.withLock { _paths.append(full) }
        let parts = full.split(separator: "?", maxSplits: 1).map(String.init)
        let flags = Set(
            (parts.count > 1 ? parts[1] : "").split(separator: "&")
                .compactMap { $0.split(separator: "=").first.map(String.init) }
        )
        let body: String
        if let route = routes[parts[0]], route.flags.isSubset(of: flags) {
            body = route.body
        } else {
            // Kupo answers an unknown pattern with no matches, and an unknown
            // datum or script with null.
            body = parts[0].hasPrefix("/matches/") ? "[]" : "null"
        }
        return (
            HTTPResponse(status: .ok, headerFields: [.contentType: "application/json;charset=utf-8"]),
            HTTPBody(body)
        )
    }
}
