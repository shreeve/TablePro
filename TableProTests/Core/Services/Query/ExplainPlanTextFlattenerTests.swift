//
//  ExplainPlanTextFlattenerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("ExplainPlanTextFlattener")
struct ExplainPlanTextFlattenerTests {
    @Test("Joins a single-column plan with newlines")
    func singleColumn() {
        let rows: [[PluginCellValue]] = [[.text("Limit")], [.text("  Sort")]]
        #expect(ExplainPlanTextFlattener.flatten(columns: ["QUERY PLAN"], rows: rows) == "Limit\n  Sort")
    }

    @Test("Joins an ordinary multi-column plan with tabs")
    func multiColumn() {
        let rows: [[PluginCellValue]] = [[.text("1"), .text("SCAN t")]]
        #expect(ExplainPlanTextFlattener.flatten(columns: ["id", "detail"], rows: rows) == "1\tSCAN t")
    }

    @Test("Drops DuckDB's explain_key so the plan keeps its own first line")
    func duckDBKeyColumnIsDropped() {
        let rows: [[PluginCellValue]] = [[.text("physical_plan"), .text("╭─ Top N ─╮\n│ Top: 5 │")]]
        let text = ExplainPlanTextFlattener.flatten(columns: ["explain_key", "explain_value"], rows: rows)
        #expect(text == "╭─ Top N ─╮\n│ Top: 5 │")
        #expect(!text.contains("physical_plan"))
    }

    @Test("Matches DuckDB's column names regardless of case")
    func duckDBColumnNamesAreCaseInsensitive() {
        #expect(ExplainPlanTextFlattener.planValueColumn(in: ["EXPLAIN_KEY", "Explain_Value"]) == 1)
    }

    @Test("A two-column result that is not DuckDB's pair keeps every column")
    func otherPairsAreNotTreatedAsDuckDB() {
        #expect(ExplainPlanTextFlattener.planValueColumn(in: ["id", "detail"]) == nil)
        #expect(ExplainPlanTextFlattener.planValueColumn(in: ["explain_value", "explain_key"]) == nil)
        #expect(ExplainPlanTextFlattener.planValueColumn(in: ["explain_key"]) == nil)
    }

    @Test("A labelled pair counts as one plan, an ordinary pair does not")
    func carriesSinglePlan() {
        #expect(ExplainPlanTextFlattener.carriesSinglePlan(columns: ["QUERY PLAN"]))
        #expect(ExplainPlanTextFlattener.carriesSinglePlan(columns: ["explain_key", "explain_value"]))
        #expect(!ExplainPlanTextFlattener.carriesSinglePlan(columns: ["id", "detail"]))
    }

    @Test("A short row does not read past its own end")
    func shortRowIsTolerated() {
        let rows: [[PluginCellValue]] = [[.text("physical_plan")]]
        #expect(ExplainPlanTextFlattener.flatten(columns: ["explain_key", "explain_value"], rows: rows).isEmpty)
    }
}
