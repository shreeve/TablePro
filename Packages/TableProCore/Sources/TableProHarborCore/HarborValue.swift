import Foundation

/// One cell, as harbor put it on the wire.
///
/// Values arrive as raw JSON, so a number is a number and a null is a null —
/// there is no stringly-typed middle ground to undo. The distinction is kept
/// here rather than flattened to text at decode time, because the renderer
/// wants to right-align a number and grey out a NULL, and it cannot recover
/// either fact from `"1"`.
public enum HarborValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(String)
    case text(String)
    /// Lists, structs and maps arrive as nested JSON. They are re-encoded to
    /// their compact JSON text, which is what a table cell can actually show.
    case json(String)
}

extension HarborValue {
    /// Decode one element of a `row` event's `values` array.
    public static func decode(from container: inout UnkeyedDecodingContainer) throws -> HarborValue {
        if try container.decodeNil() { return .null }
        if let value = try? container.decode(Bool.self) { return .bool(value) }
        // Decoded through Decimal, not Double: harbor sends DuckDB's exact
        // numerics (DECIMAL, HUGEINT) and a Double round-trip would quietly
        // round them away before anyone saw the value.
        if let value = try? container.decode(Decimal.self) { return .number("\(value)") }
        if let value = try? container.decode(String.self) { return .text(value) }
        if let value = try? container.decode(HarborJSON.self) { return .json(value.compactText) }
        throw HarborError.protocolViolation("Unreadable cell in row event")
    }

    public var displayText: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .number(let text): return text
        case .text(let text): return text
        case .json(let text): return text
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// Minimal JSON holder, used only to re-encode a nested value as compact text.
struct HarborJSON: Decodable {
    let compactText: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let object = try? container.decode([String: HarborJSON].self) {
            let body = object.keys.sorted().map { key in
                "\(HarborJSON.quote(key)):\(object[key]?.compactText ?? "null")"
            }
            compactText = "{\(body.joined(separator: ","))}"
        } else if let array = try? container.decode([HarborJSON].self) {
            compactText = "[\(array.map(\.compactText).joined(separator: ","))]"
        } else if container.decodeNil() {
            compactText = "null"
        } else if let value = try? container.decode(Bool.self) {
            compactText = value ? "true" : "false"
        } else if let value = try? container.decode(Decimal.self) {
            compactText = "\(value)"
        } else if let value = try? container.decode(String.self) {
            compactText = HarborJSON.quote(value)
        } else {
            compactText = "null"
        }
    }

    static func quote(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
