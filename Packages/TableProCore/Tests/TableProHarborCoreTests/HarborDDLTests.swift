import XCTest
@testable import TableProHarborCore

final class HarborDDLTests: XCTestCase {
    func testQuotingIsUnconditional() {
        XCTAssertEqual(HarborDDL.quote("Orders"), "\"Orders\"")
        XCTAssertEqual(HarborDDL.quote("a b"), "\"a b\"")
        XCTAssertEqual(HarborDDL.quote("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(HarborDDL.qualified(schema: "main", name: "t"), "\"main\".\"t\"")
        XCTAssertEqual(HarborDDL.qualified(schema: nil, name: "t"), "\"t\"")
        XCTAssertEqual(HarborDDL.literal("it's"), "'it''s'")
    }

    func testDefaultExpressions() {
        XCTAssertEqual(HarborDDL.defaultExpression("NULL"), "NULL")
        XCTAssertEqual(HarborDDL.defaultExpression("current_timestamp"), "current_timestamp")
        XCTAssertEqual(HarborDDL.defaultExpression("42"), "42")
        XCTAssertEqual(HarborDDL.defaultExpression("1.5"), "1.5")
        XCTAssertEqual(HarborDDL.defaultExpression("'x'"), "'x'")
        XCTAssertEqual(HarborDDL.defaultExpression("nextval('s')"), "nextval('s')")
        XCTAssertEqual(HarborDDL.defaultExpression("pending"), "'pending'")
        XCTAssertEqual(HarborDDL.defaultExpression("it's"), "'it''s'")
    }

    func testAutoIncrementIsASequence() {
        let column = HarborDDL.Column(
            name: "id", type: "INTEGER", isNullable: false, isPrimaryKey: true, autoIncrement: true
        )
        let statements = HarborDDL.createTable(schema: "main", table: "t", columns: [column])
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0], "CREATE SEQUENCE \"main\".\"seq_t_id\"")
        XCTAssertTrue(statements[1].contains("DEFAULT nextval('seq_t_id')"), statements[1])
        XCTAssertTrue(statements[1].contains("PRIMARY KEY"), statements[1])
        XCTAssertFalse(statements.joined().uppercased().contains("SERIAL"))
    }

    func testCreateTableShapes() {
        let a = HarborDDL.Column(name: "a", type: "INTEGER", isNullable: false, isPrimaryKey: true)
        let b = HarborDDL.Column(name: "b", type: "INTEGER", isNullable: false, isPrimaryKey: true)
        let n = HarborDDL.Column(name: "n", type: "VARCHAR", defaultValue: "x")
        let composite = HarborDDL.createTable(schema: nil, table: "t", columns: [a, b, n])
        XCTAssertEqual(composite.count, 1)
        XCTAssertTrue(composite[0].contains("PRIMARY KEY (\"a\", \"b\")"), composite[0])
        XCTAssertTrue(composite[0].contains("\"n\" VARCHAR DEFAULT 'x'"), composite[0])
        let single = HarborDDL.createTable(schema: nil, table: "t", columns: [a, n])
        XCTAssertTrue(single[0].contains("\"a\" INTEGER NOT NULL PRIMARY KEY"), single[0])
    }

    func testForeignKeysAreInlineAndActionless() {
        let fk = HarborDDL.ForeignKey(
            name: "fk_c_p", columns: ["p"], referencedTable: "parent", referencedColumns: ["id"]
        )
        let sql = HarborDDL.foreignKeyDefinition(fk)
        XCTAssertEqual(
            sql,
            "CONSTRAINT \"fk_c_p\" FOREIGN KEY (\"p\") REFERENCES \"parent\" (\"id\")"
        )
        XCTAssertFalse(sql.uppercased().contains("ON DELETE"))
        XCTAssertFalse(sql.uppercased().contains("ON UPDATE"))
    }

    func testSimpleColumnChanges() {
        let old = HarborDDL.Column(name: "a", type: "VARCHAR")
        var renamed = old; renamed.name = "b"
        XCTAssertEqual(
            HarborDDL.modifyColumn(schema: "main", table: "t", old: old, new: renamed),
            ["ALTER TABLE \"main\".\"t\" RENAME COLUMN \"a\" TO \"b\""]
        )
        var retyped = old; retyped.type = "BIGINT"
        var notNull = retyped; notNull.isNullable = false
        let both = HarborDDL.modifyColumn(schema: nil, table: "t", old: old, new: notNull)
        XCTAssertEqual(both?.count, 2)
        XCTAssertTrue(both?[1].hasSuffix("SET NOT NULL") == true)
        XCTAssertEqual(HarborDDL.modifyColumn(schema: nil, table: "t", old: old, new: old), [])
    }

    func testColumnEditRebuildsCoveringIndexes() {
        let old = HarborDDL.Column(name: "a", type: "VARCHAR")
        var new = old; new.name = "b"
        let index = HarborDDL.Index(name: "ix_t_a", columns: ["a"], isUnique: true)
        let other = HarborDDL.Index(name: "ix_t_z", columns: ["z"])
        let statements = HarborDDL.modifyColumn(
            schema: nil, table: "t", old: old, new: new, indexes: [index, other]
        )
        XCTAssertEqual(statements, [
            "DROP INDEX \"ix_t_a\"",
            "ALTER TABLE \"t\" RENAME COLUMN \"a\" TO \"b\"",
            "CREATE UNIQUE INDEX \"ix_t_a\" ON \"t\" (\"b\")",
        ])
        XCTAssertFalse(statements?.contains("DROP INDEX \"ix_t_z\"") == true)
        var retyped = old; retyped.type = "BIGINT"
        let typed = HarborDDL.modifyColumn(
            schema: nil, table: "t", old: old, new: retyped, indexes: [index, other]
        )
        XCTAssertEqual(typed?.filter { $0.hasPrefix("DROP INDEX") }.count, 2)
    }

    func testExpressionIndexRefusesRatherThanGuesses() {
        let old = HarborDDL.Column(name: "a", type: "VARCHAR")
        var new = old; new.type = "BIGINT"
        let expression = HarborDDL.Index(name: "ix_lower", columns: [])
        XCTAssertNil(HarborDDL.modifyColumn(
            schema: nil, table: "t", old: old, new: new,
            indexes: [expression], expressionIndexNames: ["ix_lower"]
        ))
    }

    func testTableOperations() {
        XCTAssertEqual(
            HarborDDL.renameTable(schema: "main", from: "a", to: "b"),
            "ALTER TABLE \"main\".\"a\" RENAME TO \"b\""
        )
        XCTAssertEqual(HarborDDL.truncate(schema: nil, table: "t"), "TRUNCATE \"t\"")
        XCTAssertEqual(HarborDDL.dropObject(schema: "main", name: "v", objectType: "view"),
                       "DROP VIEW \"main\".\"v\"")
        XCTAssertFalse(HarborDDL.dropObject(schema: nil, name: "t", objectType: "table")
            .uppercased().contains("CASCADE"))
        XCTAssertEqual(
            HarborDDL.commentOnColumn(schema: nil, table: "t", column: "a", comment: "hi"),
            "COMMENT ON COLUMN \"t\".\"a\" IS 'hi'"
        )
    }
}
