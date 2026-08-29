//
//  DuckDBPlanParser.swift
//  TablePro
//
//  Reads the tree DuckDB returns for EXPLAIN (FORMAT JSON).
//

import Foundation
import os

private let logger = Logger(subsystem: "com.TablePro", category: "DuckDBPlanParser")

/// Parses DuckDB's `EXPLAIN (FORMAT JSON)` output.
///
/// DuckDB's default EXPLAIN is box-drawing art laid out in two dimensions, with a join's two
/// inputs printed side by side rather than one after the other, so it cannot be read a line at a
/// time. The JSON format carries the same tree in a shape that can, which is why the Explain
/// action asks for it by name.
struct DuckDBPlanParser: QueryPlanParser {
    static let maximumInputBytes = 2_000_000

    private static let extractedKeys: Set<String> = ["Table", "Estimated Cardinality"]

    func parse(rawText: String) -> QueryPlan? {
        guard rawText.utf8.count <= Self.maximumInputBytes else {
            logger.debug("DuckDB EXPLAIN plan exceeds parser input limit")
            return nil
        }
        guard let data = rawText.data(using: .utf8), let root = Self.rootNode(in: data) else {
            logger.debug("Failed to parse DuckDB EXPLAIN JSON")
            return nil
        }

        var plan = QueryPlan(
            rootNode: parseNode(root), planningTime: nil, executionTime: nil, rawText: rawText
        )
        plan.computeCostFractions()
        return plan
    }

    /// DuckDB wraps a plan in an array. Anything else is either a different statement's output or
    /// one of the bare objects it returns instead of a plan, such as `{"result": "disabled"}` when
    /// EXPLAIN ANALYZE runs without profiling on.
    private static func rootNode(in data: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let nodes = json as? [[String: Any]],
              let first = nodes.first,
              first["name"] is String
        else { return nil }
        return first
    }

    private func parseNode(_ dict: [String: Any]) -> QueryPlanNode {
        let info = dict["extra_info"] as? [String: Any] ?? [:]
        let children = (dict["children"] as? [[String: Any]] ?? []).map { parseNode($0) }
        let table = Self.qualifiedName(info["Table"])

        var properties: [String: String] = [:]
        for (key, value) in info where !Self.extractedKeys.contains(key) {
            properties[key] = Self.describe(value)
        }

        return QueryPlanNode(
            operation: Self.operationName(dict["name"] as? String),
            relation: table?.relation,
            schema: table?.schema,
            alias: nil,
            estimatedStartupCost: nil,
            estimatedTotalCost: nil,
            estimatedRows: Self.integer(info["Estimated Cardinality"]),
            estimatedWidth: nil,
            actualStartupTime: nil,
            actualTotalTime: nil,
            actualRows: nil,
            actualLoops: nil,
            properties: properties,
            children: children
        )
    }

    /// `HASH_JOIN` becomes `Hash Join`, which is what DuckDB's own box render calls it.
    static func operationName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Unknown" }
        let words = raw.split(separator: "_").map { word -> String in
            let lower = word.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return words.isEmpty ? raw : words.joined(separator: " ")
    }

    /// A scan reports its table as `"db".schema.table`, with any part optionally quoted. The last
    /// component is the table and the one before it the schema; the catalog name is left in the
    /// properties rather than shown as a schema the sidebar does not have.
    static func qualifiedName(_ raw: Any?) -> (schema: String?, relation: String)? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            switch character {
            case "\"":
                quoted.toggle()
            case "." where !quoted:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        parts = parts.filter { !$0.isEmpty }
        guard let relation = parts.last else { return nil }
        return (parts.count >= 2 ? parts[parts.count - 2] : nil, relation)
    }

    /// Cardinality arrives as a string in every plan seen, but DuckDB is free to send the number.
    static func integer(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let text = raw as? String { return Int(text) }
        return nil
    }

    /// A property is a string or a list of them; anything else keeps its default description.
    static func describe(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let list = value as? [String] { return list.joined(separator: ", ") }
        return "\(value)"
    }
}
