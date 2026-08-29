import Foundation

/// One bound value, on its way to harbor.
///
/// Binding matters more here than convenience: without it the app's default
/// path interpolates literals straight into the SQL text, so every grid edit,
/// filtered read and imported row becomes string concatenation against a
/// database the user may not own.
public enum HarborParam: Sendable, Equatable {
    case null
    case text(String)
    case bytes(Data)

    /// Harbor's `params` carry no binary type — its json_to_duckdb maps a JSON
    /// string to VARCHAR, a number to BIGINT/DOUBLE, null to NULL, and nothing
    /// to BLOB. DuckDB's VARCHAR-to-BLOB cast does read `\xHH` escapes, so
    /// bytes travel as that and land as real bytes in a BLOB column; verified
    /// round-tripping two bytes in and base64 back out.
    var jsonValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .text(let value):
            return value
        case .bytes(let data):
            return data.map { String(format: "\\x%02x", $0) }.joined()
        }
    }
}
