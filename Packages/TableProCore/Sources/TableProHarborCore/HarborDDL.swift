import Foundation

// Every form here was run against DuckDB v2 through a berth before it was
// written down. The engine differs from ordinary SQL in four ways that are
// not guessable: there is no SERIAL type, a FOREIGN KEY can only be declared
// with the table and never carries ON DELETE or ON UPDATE, there is no DROP
// CONSTRAINT at all, and any index on a table blocks every ALTER COLUMN on
// it. Nothing here generates a statement the engine refuses.
public enum HarborDDL {
    public struct Column: Sendable, Equatable {
        public var name: String
        public var type: String
        public var isNullable: Bool
        public var defaultValue: String?
        public var isPrimaryKey: Bool
        public var autoIncrement: Bool

        public init(
            name: String,
            type: String,
            isNullable: Bool = true,
            defaultValue: String? = nil,
            isPrimaryKey: Bool = false,
            autoIncrement: Bool = false
        ) {
            self.name = name
            self.type = type
            self.isNullable = isNullable
            self.defaultValue = defaultValue
            self.isPrimaryKey = isPrimaryKey
            self.autoIncrement = autoIncrement
        }
    }

    public struct Index: Sendable, Equatable {
        public var name: String
        public var columns: [String]
        public var isUnique: Bool

        public init(name: String, columns: [String], isUnique: Bool = false) {
            self.name = name
            self.columns = columns
            self.isUnique = isUnique
        }
    }

    public struct ForeignKey: Sendable, Equatable {
        public var name: String
        public var columns: [String]
        public var referencedTable: String
        public var referencedColumns: [String]

        public init(name: String, columns: [String], referencedTable: String, referencedColumns: [String]) {
            self.name = name
            self.columns = columns
            self.referencedTable = referencedTable
            self.referencedColumns = referencedColumns
        }
    }

    // Always quoted, never conditionally: an unquoted identifier is folded to
    // lower case, so quoting only when it looks necessary renames Orders to
    // orders the first time someone alters it.
    public static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    public static func literal(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    public static func qualified(schema: String?, name: String) -> String {
        guard let schema, !schema.isEmpty else { return quote(name) }
        return "\(quote(schema)).\(quote(name))"
    }

    public static func defaultExpression(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let upper = trimmed.uppercased()
        let keywords: Set<String> = [
            "NULL", "TRUE", "FALSE", "CURRENT_TIMESTAMP", "CURRENT_DATE",
            "CURRENT_TIME", "NOW()", "TODAY()",
        ]
        if keywords.contains(upper) { return trimmed }
        if trimmed.hasPrefix("'") { return trimmed }
        if Int64(trimmed) != nil || Double(trimmed) != nil { return trimmed }
        // A function call such as nextval('s') or gen_random_uuid() is an
        // expression, not a string that happens to contain parentheses.
        if trimmed.hasSuffix(")"), trimmed.contains("(") { return trimmed }
        return literal(trimmed)
    }

    public static func columnDefinition(_ column: Column, inlinePrimaryKey: Bool, sequence: String? = nil) -> String {
        var def = "\(quote(column.name)) \(column.type)"
        if !column.isNullable || column.isPrimaryKey {
            def += " NOT NULL"
        }
        if let sequence {
            def += " DEFAULT nextval(\(literal(sequence)))"
        } else if let value = column.defaultValue, !value.isEmpty {
            def += " DEFAULT \(defaultExpression(value))"
        }
        if inlinePrimaryKey, column.isPrimaryKey {
            def += " PRIMARY KEY"
        }
        return def
    }

    // DuckDB has no SERIAL, so an auto-incrementing column is a sequence plus
    // a DEFAULT that draws from it. The caller creates the sequence, because
    // that is a separate statement.
    public static func sequenceName(table: String, column: String) -> String {
        "seq_\(table)_\(column)"
    }

    public static func createTable(
        schema: String?,
        table: String,
        columns: [Column],
        foreignKeys: [ForeignKey] = [],
        indexes: [Index] = []
    ) -> [String] {
        guard !columns.isEmpty else { return [] }
        let target = qualified(schema: schema, name: table)
        var statements: [String] = []
        var sequences: [String: String] = [:]

        for column in columns where column.autoIncrement {
            let name = sequenceName(table: table, column: column.name)
            sequences[column.name] = name
            statements.append("CREATE SEQUENCE \(qualified(schema: schema, name: name))")
        }

        let primaryKeys = columns.filter(\.isPrimaryKey)
        let inline = primaryKeys.count == 1
        var parts = columns.map {
            columnDefinition($0, inlinePrimaryKey: inline, sequence: sequences[$0.name])
        }
        if primaryKeys.count > 1 {
            parts.append("PRIMARY KEY (\(primaryKeys.map { quote($0.name) }.joined(separator: ", ")))")
        }
        parts.append(contentsOf: foreignKeys.map(foreignKeyDefinition))
        statements.append("CREATE TABLE \(target) (\n  " + parts.joined(separator: ",\n  ") + "\n)")
        statements.append(contentsOf: indexes.map { createIndex($0, schema: schema, table: table) })
        return statements
    }

    // Declared with the table or not at all, and never with a referential
    // action: DuckDB rejects ON DELETE and ON UPDATE outright rather than
    // ignoring them.
    public static func foreignKeyDefinition(_ fk: ForeignKey) -> String {
        let columns = fk.columns.map(quote).joined(separator: ", ")
        let referenced = fk.referencedColumns.map(quote).joined(separator: ", ")
        return "CONSTRAINT \(quote(fk.name)) FOREIGN KEY (\(columns)) "
            + "REFERENCES \(quote(fk.referencedTable)) (\(referenced))"
    }

    public static func renameTable(schema: String?, from oldName: String, to newName: String) -> String {
        "ALTER TABLE \(qualified(schema: schema, name: oldName)) RENAME TO \(quote(newName))"
    }

    public static func truncate(schema: String?, table: String) -> String {
        "TRUNCATE \(qualified(schema: schema, name: table))"
    }

    // No CASCADE: DuckDB refuses to drop an object another one depends on,
    // and offering a cascade it does not have makes the failure look like ours.
    public static func dropObject(schema: String?, name: String, objectType: String) -> String {
        let kind = objectType.uppercased()
        let known = ["TABLE", "VIEW", "SEQUENCE", "SCHEMA", "INDEX", "MACRO", "TYPE"]
        let keyword = known.contains(kind) ? kind : "TABLE"
        return "DROP \(keyword) \(qualified(schema: schema, name: name))"
    }

    public static func addColumn(schema: String?, table: String, column: Column) -> [String] {
        var statements: [String] = []
        var sequence: String?
        if column.autoIncrement {
            let name = sequenceName(table: table, column: column.name)
            sequence = name
            statements.append("CREATE SEQUENCE \(qualified(schema: schema, name: name))")
        }
        let target = qualified(schema: schema, name: table)
        statements.append("ALTER TABLE \(target) ADD COLUMN "
            + columnDefinition(column, inlinePrimaryKey: false, sequence: sequence))
        return statements
    }

    public static func dropColumn(schema: String?, table: String, column: String) -> String {
        "ALTER TABLE \(qualified(schema: schema, name: table)) DROP COLUMN \(quote(column))"
    }

    // DuckDB refuses ALTER COLUMN on any table that has an index, and the
    // error names the table rather than the index, so it reads like a bug in
    // the tool. Since most real tables are indexed, the bare ALTER would mean
    // column editing almost never works: the covering indexes come down first
    // and go back afterwards, carrying the new column name.
    //
    // Returns nil when an affected index cannot be rebuilt faithfully. An
    // expression index has no column list to rebuild from, and harbor reports
    // its text separately precisely so it is never mistaken for one.
    /// The drop, the alter and the rebuild must run as separate auto-committed statements.
    /// Wrapping them in one transaction cannot work: DuckDB keeps the index dependency visible
    /// until the drop commits, so the alter fails with the same Catalog Error the drop was meant
    /// to clear (measured on v2.0.0-alpha38195; the aborted transaction rolls back atomically).
    /// The cost is that an alter that fails on its own, such as a lossy cast, leaves the index
    /// dropped; the caller is the one in a position to recreate it.
    public static func modifyColumn(
        schema: String?,
        table: String,
        old: Column,
        new: Column,
        indexes: [Index] = [],
        expressionIndexNames: Set<String> = []
    ) -> [String]? {
        let target = qualified(schema: schema, name: table)
        var changes: [String] = []

        if old.name != new.name {
            changes.append("ALTER TABLE \(target) RENAME COLUMN \(quote(old.name)) TO \(quote(new.name))")
        }
        let column = quote(new.name)
        if old.type.uppercased() != new.type.uppercased() {
            changes.append("ALTER TABLE \(target) ALTER COLUMN \(column) TYPE \(new.type)")
        }
        if old.isNullable != new.isNullable {
            changes.append("ALTER TABLE \(target) ALTER COLUMN \(column) "
                + (new.isNullable ? "DROP NOT NULL" : "SET NOT NULL"))
        }
        if old.defaultValue != new.defaultValue {
            if let value = new.defaultValue, !value.isEmpty {
                changes.append("ALTER TABLE \(target) ALTER COLUMN \(column) SET DEFAULT \(defaultExpression(value))")
            } else {
                changes.append("ALTER TABLE \(target) ALTER COLUMN \(column) DROP DEFAULT")
            }
        }
        guard !changes.isEmpty else { return [] }

        let typeChanged = old.type.uppercased() != new.type.uppercased()
        let affected = indexes.filter { index in
            typeChanged || index.columns.contains(old.name) || index.columns.contains(new.name)
        }
        if affected.contains(where: { expressionIndexNames.contains($0.name) }) {
            return nil
        }
        guard !affected.isEmpty else { return changes }

        let rebuilt = affected.map { index -> Index in
            guard old.name != new.name else { return index }
            var copy = index
            copy.columns = index.columns.map { $0 == old.name ? new.name : $0 }
            return copy
        }
        return affected.map { dropIndex(schema: schema, name: $0.name) }
            + changes
            + rebuilt.map { createIndex($0, schema: schema, table: table) }
    }

    public static func createIndex(_ index: Index, schema: String?, table: String) -> String {
        let columns = index.columns.map(quote).joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        return "CREATE \(unique)INDEX \(quote(index.name)) "
            + "ON \(qualified(schema: schema, name: table)) (\(columns))"
    }

    public static func dropIndex(schema: String?, name: String) -> String {
        "DROP INDEX \(qualified(schema: schema, name: name))"
    }

    public static func commentOnTable(schema: String?, table: String, comment: String?) -> String {
        let text = comment.map(literal) ?? "NULL"
        return "COMMENT ON TABLE \(qualified(schema: schema, name: table)) IS \(text)"
    }

    public static func commentOnColumn(schema: String?, table: String, column: String, comment: String?) -> String {
        let text = comment.map(literal) ?? "NULL"
        return "COMMENT ON COLUMN \(qualified(schema: schema, name: table)).\(quote(column)) IS \(text)"
    }
}
