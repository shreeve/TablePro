import Foundation

/// Everything needed to reach one berth.
///
/// Harbor speaks plain HTTP/1.1 and is deliberately TLS-free on its own: a
/// remote berth is fronted by Caddy, or reached through SSH. `useTLS` is
/// therefore about the URL the user typed, not about harbor terminating TLS.
public struct HarborClientConfig: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var useTLS: Bool
    /// The bearer token harbor minted for the berth. Empty means unauthenticated,
    /// which only ever works against a berth started without one.
    public var token: String
    /// Which attached catalog to read. Empty asks the berth for its default.
    public var database: String
    /// How long to wait on the SHORT calls — /info, /keepalive, the cancel
    /// DELETE. Never applied to /sql.
    public var controlTimeout: TimeInterval
    /// How long a statement may take. Harbor materialises a result before it
    /// sends the 200, so this covers execution, not just the first byte: a
    /// one-minute cap here does not slow a long query down, it kills it.
    public var queryTimeout: TimeInterval
    /// Passed to harbor as `timeoutMs` so the SERVER stops work too. Without
    /// it a client-side timeout abandons the request and leaves the statement
    /// running on a worker with nobody to receive it. Zero means unlimited.
    public var serverTimeoutSeconds: Int

    public init(
        host: String,
        port: Int,
        useTLS: Bool = false,
        token: String = "",
        database: String = "",
        controlTimeout: TimeInterval = 60,
        queryTimeout: TimeInterval = 3_600,
        serverTimeoutSeconds: Int = 0
    ) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.token = token
        self.database = database
        self.controlTimeout = controlTimeout
        self.queryTimeout = queryTimeout
        self.serverTimeoutSeconds = serverTimeoutSeconds
    }

    public func url(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = useTLS ? "https" : "http"
        components.host = host
        components.port = port
        components.path = path
        return components.url
    }
}
