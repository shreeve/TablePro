import Foundation
import os
import TableProHarborCore
import TableProPluginKit

final class HarborPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    let config: DriverConnectionConfig
    private let clientConfig: HarborClientConfig
    private let lock = NSLock()
    private var _client: HarborClient?
    private var _serverVersion: String?
    private var _catalog: String
    private var _schema: String
    /// The statement Stop should cancel: the one this driver is streaming for
    /// the editor. Catalog reads mint their own ids and are never cancelled by
    /// the user, so they must not be able to overwrite this.
    private var _streamingQueryID: String?

    static let logger = Logger(subsystem: "com.TablePro", category: "HarborPluginDriver")

    init(config: DriverConnectionConfig) {
        self.config = config
        self.clientConfig = Self.makeClientConfig(config)
        self._catalog = config.database
        self._schema = HarborPlugin.defaultSchemaName
    }

    var capabilities: PluginCapabilities {
        // No .transactions: harbor has leases (POST /sql/sessions/new) that
        // pin a connection, but a one-shot statement does not join one, and
        // claiming transactions the driver does not open would be a lie the
        // editor acts on.
        [.multiSchema, .cancelQuery, .alterTableDDL, .truncateTable, .schemaCompare]
    }

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { lock.withLock { _schema } }
    var serverVersion: String? { lock.withLock { _serverVersion } }

    var client: HarborClient? { lock.withLock { _client } }
    var catalog: String { lock.withLock { _catalog } }

    // MARK: - Lifecycle

    func connect() async throws {
        let client = HarborClient(config: clientConfig)
        lock.withLock { _client = client }

        // /info is the identity probe. On a pre-fleet berth it 404s, which is
        // not a connection failure — fall back to asking DuckDB directly so an
        // older harbor still connects instead of being refused for its age.
        do {
            let info = try await client.info()
            lock.withLock {
                _serverVersion = "harbor \(info.harborVersion) (DuckDB \(info.duckdbVersion))"
            }
            // Deliberately NOT info.databases: that reports the BERTH name,
            // which is an operator's label for the server. The catalog every
            // duckdb_* query filters on comes from the file name, and the two
            // differ constantly — a berth named "tpdemo" serving demo.duckdb
            // has catalog "demo". Trusting /info here filters every catalog
            // query on a database that does not exist, and the sidebar
            // silently comes up empty.
        } catch {
            let result = try await client.execute("SELECT version()")
            let version = result.rows.first?.first?.displayText ?? ""
            lock.withLock { _serverVersion = version.isEmpty ? "harbor" : "harbor (DuckDB \(version))" }
        }

        if catalog.isEmpty {
            let result = try await client.execute(HarborIntrospectionSQL.databases)
            if let first = result.rows.first?.first?.displayText {
                lock.withLock { _catalog = first }
            }
        }
    }

    func disconnect() {
        lock.withLock { _client = nil }
    }

    /// Harbor's own pulse endpoint: authenticated, but it takes neither a
    /// lease nor a DuckDB connection, so polling it cannot starve the pool
    /// the way a `SELECT 1` from every idle tab would.
    func ping() async throws {
        guard let client else { throw HarborError.notConnected }
        try await client.keepalive()
    }

    /// Implemented, because the SDK's default is a silent no-op: the app's
    /// query-timeout setting would otherwise be accepted in preferences and
    /// change nothing at all. Both halves are set — the client's own deadline
    /// and harbor's `timeoutMs` — because a client-side timeout alone stops
    /// the waiting without stopping the work.
    func applyQueryTimeout(_ seconds: Int) async throws {
        guard let client else { return }
        let timeout = HttpQueryTimeout(serverTimeoutSeconds: seconds)
        await client.setTimeouts(
            query: timeout.requestTimeoutInterval,
            serverSeconds: max(seconds, 0)
        )
    }

    /// Implemented, because the SDK's default is a silent no-op: without this
    /// the sidebar would switch schema, nothing would change underneath, and
    /// every subsequent catalog read would quietly answer for `main`.
    func switchSchema(to schema: String) async throws {
        lock.withLock { _schema = schema }
    }

    func cancelQuery() throws {
        guard let client, let queryID = lock.withLock({ _streamingQueryID }) else { return }
        // Detached, and NOT a plain `Task {}`: this is called from the abort
        // handler of a stream that is being torn down, and a child task
        // inherits that cancellation — so the URLSession request carrying the
        // DELETE would be cancelled before it left the process, and harbor
        // would never hear that the user pressed Stop.
        Task.detached { await client.cancel(queryID: queryID) }
    }

    // MARK: - Execution

    func execute(query: String) async throws -> PluginQueryResult {
        guard let client else { throw HarborError.notConnected }
        let start = Date()
        let result = try await client.execute(query)
        return Self.pluginResult(result, executionTime: Date().timeIntervalSince(start))
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let queryID = UUID().uuidString
        lock.withLock { _streamingQueryID = queryID }
        return PluginRowStream.make { continuation, abort in
            let driver = self
            let task = Task {
                defer { driver.lock.withLock { if driver._streamingQueryID == queryID { driver._streamingQueryID = nil } } }
                guard let client = driver.client else {
                    continuation.finish(throwing: HarborError.notConnected)
                    return
                }
                do {
                    var headerSent = false
                    var page: [[PluginCellValue]] = []
                    var columns: [HarborColumn] = []
                    for try await event in client.stream(query, queryID: queryID) {
                        switch event {
                        case .schema(let schema):
                            columns = schema
                            continuation.yield(.header(PluginStreamHeader(
                                columns: schema.map(\.name),
                                columnTypeNames: schema.map(\.duckdbType)
                            )))
                            headerSent = true
                        case .row(let values):
                            page.append(values.enumerated().map {
                                Self.cellValue($1, column: columns.indices.contains($0) ? columns[$0] : nil)
                            })
                            // Batched rather than yielded one at a time: harbor
                            // streams row events, and forwarding each one alone
                            // makes the table redraw per row on a wide result.
                            if page.count >= 512 {
                                continuation.yield(.rows(page))
                                page.removeAll(keepingCapacity: true)
                            }
                        case .end, .error:
                            break
                        }
                    }
                    if !page.isEmpty { continuation.yield(.rows(page)) }
                    if !headerSent {
                        continuation.yield(.header(PluginStreamHeader(columns: [], columnTypeNames: [])))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            abort.onAbort {
                // Tell harbor FIRST, then tear down locally. The old order
                // cancelled the task and only then spawned the DELETE as a
                // child of that cancelled context, so the request was killed
                // before it was sent and the statement ran on to completion on
                // one of harbor's workers with nobody waiting for it.
                if let client = driver.client {
                    Task.detached { await client.cancel(queryID: queryID) }
                }
                task.cancel()
            }
        }
    }

    /// Bind, rather than inherit PluginKit's default — which substitutes each
    /// value into the SQL as a literal and re-parses the result. That default
    /// is the app's whole write path: every grid edit, every filtered read,
    /// every imported row. Harbor takes positional `params` and DuckDB binds
    /// them, so the value never becomes syntax and a cell containing a quote
    /// is data rather than an injection.
    func executeParameterized(
        query: String,
        parameters: [PluginCellValue]
    ) async throws -> PluginQueryResult {
        guard let client else { throw HarborError.notConnected }
        let start = Date()
        let result = try await client.execute(query, params: parameters.map(Self.param))
        return Self.pluginResult(result, executionTime: Date().timeIntervalSince(start))
    }

    static func param(_ value: PluginCellValue) -> HarborParam {
        switch value {
        case .null: return .null
        case .text(let text): return .text(text)
        case .bytes(let data): return .bytes(data)
        }
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        try await boundedQueryFromStream(query: query, rowCap: rowCap)
    }

    // MARK: - Mapping

    /// Needs the column, because one wire shape means two different things.
    ///
    /// Harbor emits a BLOB as a base64 string, which is indistinguishable from
    /// a VARCHAR that happens to look like base64 — only the column's type
    /// tells them apart. Handing a BLOB over as `.text` meant the app's binary
    /// formatter hex-encoded the base64 CHARACTERS, so a four-byte blob
    /// displayed as eight bytes of the wrong value, and an export wrote that
    /// out as if it were the data.
    static func cellValue(_ value: HarborValue, column: HarborColumn?) -> PluginCellValue {
        if value.isNull { return .null }
        if column?.isBlob == true, case .text(let base64) = value,
           let data = Data(base64Encoded: base64) {
            return .bytes(data)
        }
        return .text(value.displayText)
    }

    static func pluginResult(_ result: HarborResultSet, executionTime: TimeInterval) -> PluginQueryResult {
        guard !result.columns.isEmpty else {
            // A write returns no columns. Harbor still reports how many rows it
            // touched, which is the only thing worth showing for a DML result.
            let message = String(
                format: String(localized: "Statement executed: %lld rows"),
                Int64(result.rowCount)
            )
            return PluginQueryResult(
                columns: ["status"],
                columnTypeNames: ["VARCHAR"],
                rows: [[.text(message)]],
                rowsAffected: result.rowCount,
                executionTime: executionTime,
                statusMessage: message
            )
        }
        return PluginQueryResult(
            columns: result.columns.map(\.name),
            columnTypeNames: result.columns.map(\.duckdbType),
            rows: result.rows.map { row in
                row.enumerated().map { cellValue($1, column: result.columns.indices.contains($0) ? result.columns[$0] : nil) }
            },
            rowsAffected: result.rowCount,
            executionTime: executionTime
        )
    }

    private static func makeClientConfig(_ config: DriverConnectionConfig) -> HarborClientConfig {
        let useTLS = config.ssl.isEnabled
        let port = config.port > 0 ? config.port : HarborPlugin.defaultPort
        // The token may arrive in either box: it is a password to the
        // connection form, and a bearer token to harbor. Prefer the dedicated
        // field, so a user who filled both gets the one they meant.
        let field = config.additionalFields["harborToken"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HarborClientConfig(
            host: config.host.isEmpty ? "127.0.0.1" : config.host,
            port: port,
            useTLS: useTLS,
            token: field.isEmpty ? config.password : field,
            database: config.database,
            controlTimeout: HttpQueryTimeout.sessionBootstrapRequestTimeout,
            queryTimeout: HttpQueryTimeout.sessionResourceTimeout,
            serverTimeoutSeconds: 0
        )
    }
}
