import XCTest
@testable import TableProHarborCore

final class HarborStatementSplitterTests: XCTestCase {
    private func split(_ sql: String) -> [String] { HarborStatementSplitter.split(sql) }

    func testPlainStatements() {
        XCTAssertEqual(split("SELECT 1"), ["SELECT 1"])
        XCTAssertEqual(split("SELECT 1; SELECT 2"), ["SELECT 1", "SELECT 2"])
        XCTAssertEqual(split("SELECT 1;"), ["SELECT 1"])
        XCTAssertEqual(split("  SELECT 1 ;\n\n SELECT 2 ;\n"), ["SELECT 1", "SELECT 2"])
        XCTAssertEqual(split(""), [])
        XCTAssertEqual(split("   \n  "), [])
    }

    func testAlterBatch() {
        let sql = """
        ALTER TABLE "t" RENAME COLUMN "a" TO "b";
        ALTER TABLE "t" ALTER COLUMN "b" TYPE BIGINT;
        ALTER TABLE "t" ALTER COLUMN "b" SET NOT NULL
        """
        XCTAssertEqual(split(sql).count, 3)
        XCTAssertEqual(split(sql)[1], "ALTER TABLE \"t\" ALTER COLUMN \"b\" TYPE BIGINT")
    }

    func testSemicolonInsideAStringIsNotABoundary() {
        XCTAssertEqual(split("SELECT ';'"), ["SELECT ';'"])
        XCTAssertEqual(split("INSERT INTO t VALUES ('a;b'); SELECT 1").count, 2)
        XCTAssertEqual(split("SELECT 'it''s; fine'"), ["SELECT 'it''s; fine'"])
        XCTAssertEqual(split("SELECT \"odd;name\" FROM t"), ["SELECT \"odd;name\" FROM t"])
        XCTAssertEqual(split("SELECT \"a\"\"b;c\" FROM t"), ["SELECT \"a\"\"b;c\" FROM t"])
    }

    func testEscapeStrings() {
        XCTAssertEqual(split(#"SELECT E'\'; DROP TABLE t'"#), [#"SELECT E'\'; DROP TABLE t'"#])
        XCTAssertEqual(split(#"SELECT note'\'; SELECT 2"#).count, 2)
    }

    func testCarriageReturnEndsALineComment() {
        XCTAssertEqual(split("SELECT 1 --c\r; SELECT 2").count, 2)
        XCTAssertEqual(split("SELECT 1 -- c\n; SELECT 2").count, 2)
        XCTAssertEqual(split("SELECT 1; -- trailing note"), ["SELECT 1"])
        XCTAssertEqual(split("-- just a comment"), [])
    }

    func testBlockCommentsNest() {
        XCTAssertEqual(split("SELECT 1 /* a /* b */ c */; SELECT 2").count, 2)
        XCTAssertEqual(split("SELECT 1 /* ; */"), ["SELECT 1 /* ; */"])
        XCTAssertEqual(split("/* only a comment */"), [])
    }

    func testDollarQuoting() {
        XCTAssertEqual(split("SELECT $$a; b$$"), ["SELECT $$a; b$$"])
        XCTAssertEqual(split("SELECT $t$a; b$t$"), ["SELECT $t$a; b$t$"])
        XCTAssertEqual(split("SELECT 1 a$b$c; SELECT 2").count, 2)
        XCTAssertEqual(split("SELECT $1$abc$1$; SELECT 2").count, 2)
    }

    func testUnterminatedStringIsOneFragment() {
        XCTAssertEqual(split("SELECT 'oops; SELECT 2").count, 1)
        XCTAssertEqual(split("SELECT $$oops; SELECT 2").count, 1)
    }

    func testMultibyteContentSurvivesIntact() {
        XCTAssertEqual(split("SELECT 'あ; い'"), ["SELECT 'あ; い'"])
        XCTAssertEqual(split("SELECT 'é'; SELECT '漢'"), ["SELECT 'é'", "SELECT '漢'"])
    }
}
