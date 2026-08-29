//
//  ERDiagramColumnTypeLabelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ERDiagramColumnTypeLabel")
struct ERDiagramColumnTypeLabelTests {
    private func label(_ type: String, max: Int = 18) -> String {
        ERDiagramColumnTypeLabel.label(for: type, maxCharacters: max)
    }

    @Test("An enum shows its name, never its values")
    func enumsLoseTheirValues() {
        #expect(label("ENUM('super', 'admin', 'staff', 'patient')") == "ENUM")
        #expect(label("enum('a','b')") == "enum")
        #expect(label("SET('read','write')") == "SET")
        #expect(!label("ENUM('super', 'admin')").contains("super"))
    }

    @Test("A sized type keeps the size that explains it")
    func sizedTypesKeepTheirArguments() {
        #expect(label("VARCHAR(255)") == "VARCHAR(255)")
        #expect(label("DECIMAL(10,2)") == "DECIMAL(10,2)")
        #expect(label("TIMESTAMP") == "TIMESTAMP")
        #expect(label("INTEGER") == "INTEGER")
    }

    @Test("A long type still truncates so it fits the node")
    func longTypesTruncate() {
        #expect(label("DECIMAL(10,2)", max: 6) == "DECIMA\u{2026}")
        #expect(label("VARCHAR", max: 7) == "VARCHAR")
    }

    @Test("An enum short enough to print is not truncated after collapsing")
    func collapsedEnumIsNotTruncated() {
        #expect(label("ENUM('super', 'admin', 'staff')", max: 6) == "ENUM")
    }

    @Test("A named type with no arguments is left alone")
    func namedTypesAreUntouched() {
        #expect(label("user_role") == "user_role")
        #expect(label("") == "")
    }
}
