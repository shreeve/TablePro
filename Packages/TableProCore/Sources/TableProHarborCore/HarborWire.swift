import Foundation

/// A column as harbor describes it.
///
/// `duckdbType` is the spelling DuckDB itself reports, so it round-trips: the
/// same text can be handed back in DDL. The nested fields exist because a
/// DuckDB type is a tree, not a name — a LIST has a `child`, a STRUCT has
/// `fields`, an ENUM has its `values`. Keeping the tree is what lets the UI
/// show `STRUCT(a INTEGER, b VARCHAR)` instead of the word STRUCT.
public struct HarborColumn: Decodable, Sendable, Equatable {
    public let name: String
    public let duckdbType: String
    /// False when harbor had to widen the value to put it on the wire — the
    /// column is still readable, but it is no longer exactly what DuckDB holds.
    public let lossless: Bool
    public let values: [String]?

    enum CodingKeys: String, CodingKey {
        case name, duckdbType, lossless, values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unnamed expression column still needs a header to sit under.
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        duckdbType = (try? container.decode(String.self, forKey: .duckdbType)) ?? "VARCHAR"
        lossless = (try? container.decode(Bool.self, forKey: .lossless)) ?? true
        values = try? container.decode([String].self, forKey: .values)
    }

    /// True for a column harbor base64-encodes on the wire. Matched on the
    /// leading type name so BLOB inside a wider spelling still counts.
    public var isBlob: Bool {
        duckdbType.uppercased().hasPrefix("BLOB") || duckdbType.uppercased().hasPrefix("BYTEA")
    }

    public init(name: String, duckdbType: String, lossless: Bool = true, values: [String]? = nil) {
        self.name = name
        self.duckdbType = duckdbType
        self.lossless = lossless
        self.values = values
    }
}

/// One line of harbor's NDJSON response.
///
/// The reply is a stream of events, not one document: `schema` once, then a
/// `row` per row, then `end` — or `error` at any point, including after rows
/// have already been delivered. A decoder that waited for a complete body
/// would give up streaming for nothing, so each line is decoded on arrival.
public enum HarborEvent: Sendable {
    case schema([HarborColumn])
    case row([HarborValue])
    case end(rowCount: Int, timeMs: Int)
    case error(HarborError)

    enum CodingKeys: String, CodingKey {
        case type, columns, values, rowCount, timeMs, code, message
    }
}

extension HarborEvent: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "schema":
            self = .schema((try? container.decode([HarborColumn].self, forKey: .columns)) ?? [])
        case "row":
            var values = try container.nestedUnkeyedContainer(forKey: .values)
            var row: [HarborValue] = []
            if let count = values.count { row.reserveCapacity(count) }
            while !values.isAtEnd {
                row.append(try HarborValue.decode(from: &values))
            }
            self = .row(row)
        case "end":
            self = .end(
                rowCount: (try? container.decode(Int.self, forKey: .rowCount)) ?? 0,
                timeMs: (try? container.decode(Int.self, forKey: .timeMs)) ?? 0
            )
        case "error":
            self = .error(HarborError(
                code: (try? container.decode(String.self, forKey: .code)) ?? "error",
                message: (try? container.decode(String.self, forKey: .message)) ?? "Unknown harbor error"
            ))
        default:
            // Forward compatibility: a berth newer than this plugin may emit
            // event kinds we have no meaning for. Ignoring one is correct;
            // failing the whole query over it is not.
            self = .end(rowCount: 0, timeMs: 0)
        }
    }
}

/// A fully collected result, for the callers that want rows in hand.
public struct HarborResultSet: Sendable {
    public var columns: [HarborColumn]
    public var rows: [[HarborValue]]
    public var rowCount: Int
    public var timeMs: Int

    public init(
        columns: [HarborColumn] = [],
        rows: [[HarborValue]] = [],
        rowCount: Int = 0,
        timeMs: Int = 0
    ) {
        self.columns = columns
        self.rows = rows
        self.rowCount = rowCount
        self.timeMs = timeMs
    }
}

/// `POST /sql/sessions/new` — a lease on one pinned connection.
///
/// Harbor's ordinary /sql is one-shot and picks a pooled connection per
/// request, so a bare BEGIN would open a transaction on one connection and the
/// next statement would run on another. A lease is what makes the two the same
/// connection, and it is the only way to hold a transaction across requests.
///
/// `idleTtlMs` is the one to respect: harbor reclaims a lease left idle that
/// long, so a transaction held open across user think-time can be taken back
/// mid-edit.
public struct HarborSession: Decodable, Sendable {
    public let sessionId: String
    public let ttlMs: Int
    public let idleTtlMs: Int
}

/// `GET /info` — the berth's identity. Its absence (404) is how a client
/// tells a pre-fleet harbor from a current one, so callers treat a failure
/// here as "old server", not "no server".
public struct HarborInfo: Decodable, Sendable {
    public let protocolVersion: Int
    public let name: String
    public let harborVersion: String
    public let duckdbVersion: String
    public let database: String
    public let databases: [String]
}
