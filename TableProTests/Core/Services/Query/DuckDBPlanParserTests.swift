//
//  DuckDBPlanParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DuckDBPlanParser")
struct DuckDBPlanParserTests {
    /// Captured from DuckDB v2.0.0 for
    /// `SELECT p.name, count(*) FROM panels p JOIN panel_items pi ON pi.panel_id = p.id GROUP BY p.name`.
    private let joinPlan = """
    [
        {
            "name": "HASH_GROUP_BY",
            "children": [
                {
                    "name": "HASH_JOIN",
                    "children": [
                        {
                            "name": "SEQ_SCAN",
                            "children": [],
                            "extra_info": {
                                "Table": "\\"medlabs-test\\".main.panel_items",
                                "Type": "Sequential Scan",
                                "Projections": ["panel_id"],
                                "Estimated Cardinality": "74"
                            }
                        },
                        {
                            "name": "SEQ_SCAN",
                            "children": [],
                            "extra_info": {
                                "Table": "\\"medlabs-test\\".main.panels",
                                "Estimated Cardinality": "7"
                            }
                        }
                    ],
                    "extra_info": {
                        "Join Type": "INNER",
                        "Conditions": "panel_id = id",
                        "Estimated Cardinality": "103"
                    }
                }
            ],
            "extra_info": {
                "Groups": "#0",
                "Aggregates": "count_star()",
                "Estimated Cardinality": "6"
            }
        }
    ]
    """

    @Test("Reads the tree, its operations and its cardinalities")
    func parsesTree() {
        let plan = DuckDBPlanParser().parse(rawText: joinPlan)
        #expect(plan?.rootNode.operation == "Hash Group By")
        #expect(plan?.rootNode.estimatedRows == 6)

        let join = plan?.rootNode.children.first
        #expect(join?.operation == "Hash Join")
        #expect(join?.children.count == 2)
        #expect(join?.properties["Join Type"] == "INNER")
        #expect(join?.properties["Conditions"] == "panel_id = id")

        let scan = join?.children.first
        #expect(scan?.operation == "Seq Scan")
        #expect(scan?.relation == "panel_items")
        #expect(scan?.schema == "main")
        #expect(scan?.estimatedRows == 74)
        #expect(scan?.children.isEmpty == true)
    }

    @Test("Keeps the raw text it was given")
    func keepsRawText() {
        #expect(DuckDBPlanParser().parse(rawText: joinPlan)?.rawText == joinPlan)
    }

    @Test("A list-valued property reads as a list, not as a Swift array description")
    func listProperties() {
        let plan = DuckDBPlanParser().parse(rawText: joinPlan)
        let scan = plan?.rootNode.children.first?.children.first
        #expect(scan?.properties["Projections"] == "panel_id")
        #expect(scan?.properties["Table"] == nil)
    }

    @Test("Operation names read the way DuckDB's own render spells them")
    func operationNames() {
        #expect(DuckDBPlanParser.operationName("SEQ_SCAN") == "Seq Scan")
        #expect(DuckDBPlanParser.operationName("TOP_N") == "Top N")
        #expect(DuckDBPlanParser.operationName("ORDER_BY") == "Order By")
        #expect(DuckDBPlanParser.operationName("PROJECTION") == "Projection")
        #expect(DuckDBPlanParser.operationName("UNGROUPED_AGGREGATE") == "Ungrouped Aggregate")
        #expect(DuckDBPlanParser.operationName(nil) == "Unknown")
    }

    @Test("A qualified table splits into schema and relation, quotes and all")
    func qualifiedNames() {
        let full = DuckDBPlanParser.qualifiedName("\"medlabs-test\".main.providers")
        #expect(full?.schema == "main")
        #expect(full?.relation == "providers")

        let pair = DuckDBPlanParser.qualifiedName("main.providers")
        #expect(pair?.schema == "main")
        #expect(pair?.relation == "providers")

        let bare = DuckDBPlanParser.qualifiedName("providers")
        #expect(bare?.schema == nil)
        #expect(bare?.relation == "providers")

        #expect(DuckDBPlanParser.qualifiedName("\"my.db\".main.t")?.relation == "t")
        #expect(DuckDBPlanParser.qualifiedName(nil) == nil)
        #expect(DuckDBPlanParser.qualifiedName("") == nil)
    }

    @Test("Rejects output that is not a plan")
    func rejectsNonPlans() {
        #expect(DuckDBPlanParser().parse(rawText: "{\"result\": \"disabled\"}") == nil)
        #expect(DuckDBPlanParser().parse(rawText: "╭─ Seq Scan ─╮") == nil)
        #expect(DuckDBPlanParser().parse(rawText: "[]") == nil)
        #expect(DuckDBPlanParser().parse(rawText: "[{\"children\": []}]") == nil)
        #expect(DuckDBPlanParser().parse(rawText: "") == nil)
    }

    @Test("Cardinality reads whether DuckDB sends a string or a number")
    func cardinalityTypes() {
        #expect(DuckDBPlanParser.integer("74") == 74)
        #expect(DuckDBPlanParser.integer(74) == 74)
        #expect(DuckDBPlanParser.integer("not a number") == nil)
        #expect(DuckDBPlanParser.integer(nil) == nil)
    }

    @Test("The registry hands duckdbJson to this parser")
    func registryWiring() {
        #expect(ExplainPlanParserRegistry.parser(for: .duckdbJson) is DuckDBPlanParser)
        #expect(ExplainPlanFormatDefaults.format(for: .duckdb) == .duckdbJson)
        #expect(ExplainPlanFormatDefaults.format(for: .duckdbHarbor) == .duckdbJson)
    }
}
