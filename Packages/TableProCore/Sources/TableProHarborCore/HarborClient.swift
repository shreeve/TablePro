import Foundation

/// The one object a driver talks to. Owns nothing but its config and the
/// URLSession; every call is independent, because harbor's one-shot `/sql`
/// needs no connection state to be correct.
public actor HarborClient {
    private let config: HarborClientConfig
    private let session: URLSession
    /// The query id of the statement currently in flight, so a cancel can
    /// name it. Harbor registers the id BEFORE executing, which is what makes
    /// `DELETE /sql/queries/<id>` safe to send the instant we have the id —
    /// it cannot arrive too early and be dropped.
    private var inFlightQueryID: String?

    public init(config: HarborClientConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = config.timeoutSeconds
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
        }
        return request
    }

    private func sqlBody(_ sql: String, queryID: String?) throws -> Data {
        var payload: [String: Any] = ["sql": sql]
        if let queryID { payload["queryId"] = queryID }
        if !config.database.isEmpty { payload["database"] = config.database }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Execution

    /// Run one statement and collect every row.
    public func execute(_ sql: String) async throws -> HarborResultSet {
        var result = HarborResultSet()
        for try await event in stream(sql) {
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
    public nonisolated func stream(_ sql: String) -> AsyncThrowingStream<HarborEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.pump(sql, into: continuation)
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
        into continuation: AsyncThrowingStream<HarborEvent, Error>.Continuation
    ) async throws {
        let queryID = UUID().uuidString
        inFlightQueryID = queryID
        defer { inFlightQueryID = nil }

        let request = try request(path: "/sql", method: "POST", body: try sqlBody(sql, queryID: queryID))
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

    /// Ask harbor to cancel whatever this client is running. Safe to call
    /// when nothing is in flight — it simply does nothing.
    public func cancel() async {
        guard let queryID = inFlightQueryID else { return }
        guard let request = try? request(path: "/sql/queries/\(queryID)", method: "DELETE") else { return }
        _ = try? await session.data(for: request)
    }

    // MARK: - Identity and liveness

    public func info() async throws -> HarborInfo {
        let request = try request(path: "/info", method: "GET")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
        return try JSONDecoder().decode(HarborInfo.self, from: data)
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
