import Foundation

/// The one object a driver talks to. Owns nothing but its config and the
/// URLSession; every call is independent, because harbor's one-shot `/sql`
/// needs no connection state to be correct.
public actor HarborClient {
    private var config: HarborClientConfig
    /// The lease every statement is routed through while a transaction is
    /// open. Nil the rest of the time, when one-shot is correct and cheaper.
    private var sessionID: String?
    private let session: URLSession

    public init(config: HarborClientConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // The session-wide value governs the short calls; /sql overrides
            // it per request below. The resource ceiling has to clear the
            // longest query anyone might run, or it caps them all regardless.
            configuration.timeoutIntervalForRequest = config.controlTimeout
            configuration.timeoutIntervalForResource = max(config.queryTimeout, config.controlTimeout)
            // No cache: a berth's answers are live data, and a 200 replayed
            // from a URL cache would be a stale table quietly shown as fresh.
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Requests

    private func request(path: String, method: String, body: Data? = nil) throws -> URLRequest {
        guard let url = config.url(path: path) else {
            throw HarborError.transport("Cannot build a URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = config.queryTimeout
        }
        return request
    }

    private func sqlBody(_ sql: String, params: [HarborParam], queryID: String?) throws -> Data {
        var payload: [String: Any] = ["sql": sql]
        if !params.isEmpty { payload["params"] = params.map { $0.jsonValue } }
        if let sessionID { payload["sessionId"] = sessionID }
        if let queryID { payload["queryId"] = queryID }
        // Give harbor the same deadline the client is holding itself to, so a
        // timeout stops the work instead of merely stopping the waiting.
        if config.serverTimeoutSeconds > 0 { payload["timeoutMs"] = config.serverTimeoutSeconds * 1_000 }
        if !config.database.isEmpty { payload["database"] = config.database }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Execution

    /// Run one statement and collect every row.
    public func execute(
        _ sql: String,
        params: [HarborParam] = [],
        queryID: String = UUID().uuidString
    ) async throws -> HarborResultSet {
        var result = HarborResultSet()
        for try await event in stream(sql, params: params, queryID: queryID) {
            switch event {
            case .schema(let columns): result.columns = columns
            case .row(let values): result.rows.append(values)
            case .end(let rowCount, let timeMs):
                result.rowCount = rowCount
                result.timeMs = timeMs
            case .error(let error): throw error
            }
        }
        return result
    }

    /// Run one statement, yielding events as they arrive off the socket.
    ///
    /// The caller names the query, because the caller is the only one who can
    /// say which query a later cancel means. This used to be a single
    /// `inFlightQueryID` on the actor, which was wrong the moment two
    /// statements overlapped — and they overlap constantly, since the sidebar
    /// fetches tables, schemas and routines with `async let` through this same
    /// client. Whichever finished first cleared the slot, so Stop then
    /// cancelled nothing; whichever started last owned it, so Stop cancelled
    /// the wrong statement. Harbor is careful to refuse a duplicate id rather
    /// than let a cancel be a coin flip, and the client was throwing that
    /// guarantee away on its own side.
    public nonisolated func stream(
        _ sql: String,
        params: [HarborParam] = [],
        queryID: String = UUID().uuidString
    ) -> AsyncThrowingStream<HarborEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.pump(sql, params: params, queryID: queryID, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func pump(
        _ sql: String,
        params: [HarborParam],
        queryID: String,
        into continuation: AsyncThrowingStream<HarborEvent, Error>.Continuation
    ) async throws {
        let request = try request(path: "/sql", method: "POST", body: try sqlBody(sql, params: params, queryID: queryID))
        let (bytes, response) = try await session.bytes(for: request)
        try await Self.check(response, draining: bytes)

        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }
            let event = try JSONDecoder().decode(HarborEvent.self, from: data)
            // An error event is terminal and must surface as a thrown error,
            // not as a value the caller might loop past without noticing.
            if case .error(let error) = event { throw error }
            continuation.yield(event)
        }
    }

    /// Cancel one named statement. Harbor registers the id before it executes,
    /// so this is safe to send the instant the id exists: it cannot arrive too
    /// early and be dropped.
    ///
    /// Cancelling an id that already finished is a no-op on harbor's side, so
    /// callers need not race the completion to decide whether to send it.
    public func cancel(queryID: String) async {
        guard let request = try? request(path: "/sql/queries/\(queryID)", method: "DELETE") else { return }
        _ = try? await session.data(for: request)
    }

    /// Re-arm the deadlines from the app's query-timeout setting. Only the
    /// next statement is affected; one already streaming keeps the deadline it
    /// started under.
    public func setTimeouts(query: TimeInterval, serverSeconds: Int) {
        config.queryTimeout = query
        config.serverTimeoutSeconds = serverSeconds
    }

    // MARK: - Identity and liveness

    public func info() async throws -> HarborInfo {
        let request = try request(path: "/info", method: "GET")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
        return try JSONDecoder().decode(HarborInfo.self, from: data)
    }

    // MARK: - Leases

    /// Pin a connection and route subsequent statements to it.
    @discardableResult
    public func openSession() async throws -> HarborSession {
        let request = try request(path: "/sql/sessions/new", method: "POST", body: Data("{}".utf8))
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
        let opened = try JSONDecoder().decode(HarborSession.self, from: data)
        sessionID = opened.sessionId
        return opened
    }

    /// Give the connection back. Best-effort on the wire but unconditional
    /// locally: the id is cleared either way, because continuing to send a
    /// lease harbor may already have reclaimed would route every later
    /// statement at a session that no longer exists.
    public func releaseSession() async {
        guard let id = sessionID else { return }
        sessionID = nil
        guard let request = try? request(path: "/sql/sessions/\(id)", method: "DELETE") else { return }
        _ = try? await session.data(for: request)
    }

    public var hasSession: Bool { sessionID != nil }

    /// Harbor's own view of the catalog, in one request.
    public func catalog() async throws -> HarborCatalog {
        let request = try request(path: "/catalog", method: "GET")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
        return try JSONDecoder().decode(HarborCatalog.self, from: data)
    }

    /// A cheap authenticated pulse that keeps an idle-exit berth moored
    /// without taking a lease or a DuckDB connection.
    ///
    /// GET, not POST: harbor registers this route as GET only, and a POST is a
    /// 404. Because `ping()` is the one call the 30-second health monitor
    /// makes, getting the verb wrong did not fail a feature — it reported
    /// every healthy berth as unreachable half a minute after connecting, and
    /// the reconnect loop then retried the same wrong verb forever.
    public func keepalive() async throws {
        let request = try request(path: "/keepalive", method: "GET")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
    }

    // MARK: - Failure

    /// Harbor puts the real failure in the BODY of a non-2xx response, as the
    /// same `{"type":"error","code":...,"message":...}` envelope the stream
    /// uses; its wire contract says outright that clients classify on `code`
    /// and never on the HTTP status. It also withholds the 200 until the
    /// statement has prepared, so every parser and binder error takes this
    /// path rather than the stream's.
    ///
    /// Judging by status alone therefore discarded the entire text of every
    /// SQL error in the product — message, line number and DuckDB's "Did you
    /// mean" hint — and replaced it with "Harbor answered HTTP 400".
    private static func status(of response: URLResponse) -> Int? {
        guard let http = response as? HTTPURLResponse else { return nil }
        return (200 ..< 300).contains(http.statusCode) ? nil : http.statusCode
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        guard let code = status(of: response) else { return }
        throw harborError(from: body) ?? fallback(for: code)
    }

    private static func check(
        _ response: URLResponse,
        draining bytes: URLSession.AsyncBytes
    ) async throws {
        guard let code = status(of: response) else { return }
        // Bounded: an error envelope is one short line, and this stream is
        // being abandoned either way — a server that answered non-2xx and then
        // kept writing must not be able to hold the reader here.
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count >= 64 * 1024 { break }
        }
        throw harborError(from: body) ?? fallback(for: code)
    }

    private static func harborError(from body: Data) -> HarborError? {
        guard !body.isEmpty,
              let event = try? JSONDecoder().decode(HarborEvent.self, from: body),
              case .error(let error) = event
        else { return nil }
        return error
    }

    /// Used only when the body was not harbor's envelope — a proxy's error
    /// page, say. Harbor's own codes always come from the body above.
    private static func fallback(for code: Int) -> HarborError {
        switch code {
        case 401, 403:
            return HarborError(
                code: "unauthorized",
                message: "Harbor refused the token. Check the berth's token file."
            )
        case 503:
            return HarborError(code: "unready", message: "The berth is not ready yet.")
        // Harbor's spelling of "the client cancelled this". Named so the UI
        // can stay silent about a stop the user asked for.
        case 499:
            return HarborError(code: "cancelled", message: "Query cancelled.")
        default:
            return HarborError.transport("Harbor answered HTTP \(code)")
        }
    }
}
