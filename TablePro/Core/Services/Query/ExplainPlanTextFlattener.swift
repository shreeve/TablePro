//
//  ExplainPlanTextFlattener.swift
//  TablePro
//
//  Turns EXPLAIN result rows into the single block of text the plan parsers read. One rule for
//  every entry point, so the Explain action and a hand-typed statement produce identical text.
//

import Foundation
import TableProPluginKit

enum ExplainPlanTextFlattener {
    static func flatten(columns: [String], rows: [[PluginCellValue]]) -> String {
        guard let valueColumn = planValueColumn(in: columns) else {
            return rows
                .map { row in row.compactMap { $0.asText }.joined(separator: "\t") }
                .joined(separator: "\n")
        }
        return rows
            .map { row in valueColumn < row.count ? (row[valueColumn].asText ?? "") : "" }
            .joined(separator: "\n")
    }

    /// DuckDB labels its EXPLAIN output rather than returning it bare: `explain_key` names the
    /// plan and `explain_value` holds the whole of it. Joining the two writes "physical_plan"
    /// onto the plan's own first line, which corrupts the render and defeats every parser.
    static func planValueColumn(in columns: [String]) -> Int? {
        guard columns.count == 2,
              columns[0].lowercased() == "explain_key",
              columns[1].lowercased() == "explain_value"
        else { return nil }
        return 1
    }

    /// Whether the result carries a single plan, however many columns it took to deliver it.
    static func carriesSinglePlan(columns: [String]) -> Bool {
        columns.count == 1 || planValueColumn(in: columns) != nil
    }
}
