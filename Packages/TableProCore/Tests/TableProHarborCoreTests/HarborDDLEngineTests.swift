import XCTest
@testable import TableProHarborCore

final class HarborDDLEngineTests: XCTestCase {
    private var client: HarborClient!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["HARBOR_TEST_PORT"], let port = Int(portText) else {
            throw XCTSkip("set HARBOR_TEST_PORT (and HARBOR_TEST_TOKEN) to run against a berth")
        }
        client = HarborClient(config: HarborClientConfig(
            host: env["HARBOR_TEST_HOST"] ?? "127.0.0.1",
            port: port,
            token: env["HARBOR_TEST_TOKEN"] ?? ""
        ))
    }

    private func run(_ statements: [String], file: StaticString = #filePath, line: UInt = #line) async {
        for sql in statements {
            do {
                _ = try await client.execute(sql)
            } catch {
                XCTFail("engine rejected:\n  \(sql)\n  \(error)", file: file, line: line)
                return
            }
        }
    }

    private func drop(_ names: [String]) async {
        for name in names { _ = try? await client.execute("DROP TABLE IF EXISTS \(HarborDDL.quote(name))") }
    }

    func testCreateTableWithAutoIncrementAndKeys() async throws {
        await drop(["ddl_child", "ddl_people"])
        _ = try? await client.execute("DROP SEQUENCE IF EXISTS \(HarborDDL.quote("seq_ddl_people_id"))")

        await run(HarborDDL.createTable(
            schema: nil,
            table: "ddl_people",
            columns: [
                .init(name: "id", type: "INTEGER", isNullable: false, isPrimaryKey: true, autoIncrement: true),
                .init(name: "name", type: "VARCHAR", isNullable: false),
                .init(name: "status", type: "VARCHAR", defaultValue: "pending"),
            ],
            indexes: [.init(name: "ix_ddl_people_name", columns: ["name"])]
        ))

        _ = try await client.execute("INSERT INTO ddl_people (name) VALUES ('ada')")
        _ = try await client.execute("INSERT INTO ddl_people (name) VALUES ('grace')")
        let rows = try await client.execute("SELECT count(DISTINCT id) FROM ddl_people")
        XCTAssertEqual(rows.rows.first?.first?.displayText, "2")

        await run(HarborDDL.createTable(
            schema: nil,
            table: "ddl_child",
            columns: [
                .init(name: "id", type: "INTEGER", isNullable: false, isPrimaryKey: true),
                .init(name: "person", type: "INTEGER"),
            ],
            foreignKeys: [.init(
                name: "fk_ddl_child_person", columns: ["person"],
                referencedTable: "ddl_people", referencedColumns: ["id"]
            )]
        ))
        await drop(["ddl_child", "ddl_people"])
        _ = try? await client.execute("DROP SEQUENCE IF EXISTS \(HarborDDL.quote("seq_ddl_people_id"))")
    }

    func testColumnEditOnAnIndexedTable() async throws {
        await drop(["ddl_alter"])
        await run(HarborDDL.createTable(
            schema: nil,
            table: "ddl_alter",
            columns: [
                .init(name: "id", type: "INTEGER", isNullable: false, isPrimaryKey: true),
                .init(name: "a", type: "VARCHAR"),
            ],
            indexes: [.init(name: "ix_ddl_alter_a", columns: ["a"], isUnique: true)]
        ))

        do {
            _ = try await client.execute("ALTER TABLE \"ddl_alter\" RENAME COLUMN \"a\" TO \"b\"")
            XCTFail("expected a dependency error while the index exists")
        } catch {
            XCTAssertTrue("\(error)".contains("epend"), "unexpected error: \(error)")
        }

        let old = HarborDDL.Column(name: "a", type: "VARCHAR")
        var new = old; new.name = "b"; new.type = "BIGINT"; new.isNullable = false
        let statements = try XCTUnwrap(HarborDDL.modifyColumn(
            schema: nil, table: "ddl_alter", old: old, new: new,
            indexes: [.init(name: "ix_ddl_alter_a", columns: ["a"], isUnique: true)]
        ))
        await run(statements)

        let columns = try await client.execute(
            "SELECT column_name FROM duckdb_columns() WHERE table_name = 'ddl_alter' ORDER BY column_name"
        )
        XCTAssertEqual(columns.rows.compactMap { $0.first?.displayText }, ["b", "id"])
        let indexes = try await client.execute(
            "SELECT count(*) FROM duckdb_indexes() WHERE index_name = 'ix_ddl_alter_a'"
        )
        XCTAssertEqual(indexes.rows.first?.first?.displayText, "1")
        await drop(["ddl_alter"])
    }

    func testAddDropRenameTruncateAndComments() async throws {
        await drop(["ddl_misc", "ddl_renamed"])
        await run(HarborDDL.createTable(
            schema: nil,
            table: "ddl_misc",
            columns: [.init(name: "id", type: "INTEGER", isNullable: false, isPrimaryKey: true)]
        ))
        await run(HarborDDL.addColumn(
            schema: nil, table: "ddl_misc",
            column: .init(name: "note", type: "VARCHAR", defaultValue: "none")
        ))
        await run([
            HarborDDL.commentOnTable(schema: nil, table: "ddl_misc", comment: "a table"),
            HarborDDL.commentOnColumn(schema: nil, table: "ddl_misc", column: "note", comment: "a column"),
            HarborDDL.createIndex(.init(name: "ix_ddl_misc_note", columns: ["note"]), schema: nil, table: "ddl_misc"),
            HarborDDL.dropIndex(schema: nil, name: "ix_ddl_misc_note"),
            HarborDDL.dropColumn(schema: nil, table: "ddl_misc", column: "note"),
            HarborDDL.truncate(schema: nil, table: "ddl_misc"),
            HarborDDL.renameTable(schema: nil, from: "ddl_misc", to: "ddl_renamed"),
            HarborDDL.dropObject(schema: nil, name: "ddl_renamed", objectType: "table"),
        ])
    }

    func testAwkwardIdentifiers() async throws {
        await drop(["ddl odd"])
        await run(HarborDDL.createTable(
            schema: nil,
            table: "ddl odd",
            columns: [
                .init(name: "id", type: "INTEGER", isNullable: false, isPrimaryKey: true),
                .init(name: "a b", type: "VARCHAR"),
                .init(name: "é", type: "VARCHAR"),
            ],
            indexes: [.init(name: "ix ddl odd", columns: ["a b"])]
        ))
        let old = HarborDDL.Column(name: "a b", type: "VARCHAR")
        var new = old; new.name = "a c"
        await run(try XCTUnwrap(HarborDDL.modifyColumn(
            schema: nil, table: "ddl odd", old: old, new: new,
            indexes: [.init(name: "ix ddl odd", columns: ["a b"])]
        )))
        await run([HarborDDL.dropObject(schema: nil, name: "ddl odd", objectType: "table")])
    }
}
