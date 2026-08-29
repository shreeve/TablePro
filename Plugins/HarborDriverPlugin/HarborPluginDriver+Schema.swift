import Foundation
import TableProHarborCore
import TableProPluginKit

/// Catalog reads. Every one goes through DuckDB's own `duckdb_*` table
/// functions, which is the dividend of speaking harbor rather than pretending
/// to be some other engine: no view has to be emulated, and the type names
/// come back in the spelling DuckDB will accept in DDL.
extension HarborPluginDriver {
    private func rows(_ sql: String) async throws -> [[HarborValue]] {
        guard let client else { throw HarborError.notConnected }
        return try await client.execute(sql).rows
    }

    private static func text(_ row: [HarborValue], _ index: Int) -> String {
        index < row.count ? row[index].displayText : ""
    }

    private static func optionalText(_ row: [HarborValue], _ index: Int) -> String? {
        guard index < row.count, !row[index].isNull else { return nil }
        let value = row[index].displayText
        return value.isEmpty ? nil : value
    }

    private static func flag(_ row: [HarborValue], _ index: Int) -> Bool {
        guard index < row.count else { return false }
        if case .bool(let value) = row[index] { return value }
        return row[index].displayText.lowercased() == "true"
    }

    private static func number(_ row: [HarborValue], _ index: Int) -> Int? {
        guard index < row.count, !row[index].isNull else { return nil }
        return Int(row[index].displayText)
    }

    /// The snapshot entry for one table, when the last fetchTables filled it.
    private func snapshotTable(_ table: String, schema: String) -> HarborCatalog.Table? {
        snapshot?.tables.first { $0.name == table && $0.schema == schema }
    }

    private func resolvedSchema(_ schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return currentSchema ?? "main" }
        return schema
    }

    // MARK: - Namespaces

    func fetchDatabases() async throws -> [String] {
        try await rows(HarborIntrospectionSQL.databases).map { Self.text($0, 0) }
    }

    func fetchSchemas() async throws -> [String] {
        try await rows(HarborIntrospectionSQL.schemas(catalog: catalog)).map { Self.text($0, 0) }
    }

    // MARK: - Objects

    /// Refreshes the /catalog snapshot the per-table reads below serve from,
    /// so expanding a schema costs one request instead of one per table per
    /// aspect. Views are not in /catalog, so they still come from SQL and are
    /// merged in.
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let target = resolvedSchema(schema)
        if let client { snapshot = try? await client.catalog() }
        let sql = HarborIntrospectionSQL.tables(catalog: catalog, schema: target)
        return try await rows(sql).map { row in
            // duckdb_tables().estimated_size is DuckDB's estimate, not a
            // COUNT(*). It is passed through as the row count because that is
            // what the sidebar wants, and paying for an exact count of every
            // table just to fill a sidebar would make expanding a schema slow.
            PluginTableInfo(
                name: Self.text(row, 0),
                type: Self.text(row, 1) == "view" ? "VIEW" : "TABLE",
                rowCount: Self.number(row, 2),
                schema: target,
                comment: Self.optionalText(row, 3)
            )
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let target = resolvedSchema(schema)
        if let entry = snapshotTable(table, schema: target) {
            return entry.columns.map { column in
                PluginColumnInfo(
                    name: column.name,
                    dataType: column.type,
                    isNullable: !column.notNull,
                    isPrimaryKey: column.primary || entry.primaryKey.contains(column.name),
                    defaultValue: column.default,
                    generationExpression: nil,
                    generationKind: nil
                )
            }
        }
        let sql = HarborIntrospectionSQL.columns(catalog: catalog, schema: target, table: table)
        return try await rows(sql).map { row in
            PluginColumnInfo(
                name: Self.text(row, 0),
                dataType: Self.text(row, 1),
                isNullable: Self.flag(row, 2),
                isPrimaryKey: Self.flag(row, 5),
                defaultValue: Self.optionalText(row, 3),
                comment: Self.optionalText(row, 4),
                generationExpression: nil,
                generationKind: nil
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let target = resolvedSchema(schema)
        if let entry = snapshotTable(table, schema: target) {
            // /catalog carries the index COLUMNS, which duckdb_indexes() does
            // not expose as data — the SQL path had to leave them empty rather
            // than parse them back out of the CREATE INDEX text and risk being
            // wrong. Unique constraints appear here too, since to a reader of
            // the structure pane they are the same fact.
            let fromIndexes = entry.indexes.map {
                PluginIndexInfo(
                    name: $0.name,
                    columns: ($0.columns?.isEmpty == false ? $0.columns : $0.expressions) ?? [],
                    isUnique: $0.unique ?? false,
                    isPrimary: false
                )
            }
            let fromUnique = entry.uniqueConstraints.enumerated().map {
                PluginIndexInfo(name: "\(table)_unique_\($0.offset + 1)", columns: $0.element.columns, isUnique: true, isPrimary: false)
            }
            return fromIndexes + fromUnique
        }
        let sql = HarborIntrospectionSQL.indexes(catalog: catalog, schema: target, table: table)
        return try await rows(sql).map { row in
            // duckdb_indexes() reports the CREATE INDEX text but not the
            // column list as data, so the columns are left empty rather than
            // parsed back out of SQL and risked being wrong.
            PluginIndexInfo(
                name: Self.text(row, 0),
                columns: [],
                isUnique: Self.flag(row, 1),
                isPrimary: false
            )
        }
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let target = resolvedSchema(schema)
        let sql = HarborIntrospectionSQL.viewDefinition(catalog: catalog, schema: target, view: view)
        return try await rows(sql).first.map { Self.text($0, 0) } ?? ""
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let target = resolvedSchema(schema)
        if let entry = snapshotTable(table, schema: target) {
            return entry.foreignKeys.flatMap { key -> [PluginForeignKeyInfo] in
                let locals = key.columns ?? []
                let remotes = key.refColumns ?? []
                // Paired by position, and only as far as both lists reach: a
                // half-described key is dropped rather than shown against the
                // wrong column.
                return zip(locals, remotes).map { local, remote in
                    PluginForeignKeyInfo(
                        name: "\(table)_\(local)_fkey",
                        column: local,
                        referencedTable: key.refTable ?? "",
                        referencedColumn: remote,
                        referencedSchema: key.refSchema ?? target
                    )
                }
            }
        }
        let sql = HarborIntrospectionSQL.foreignKeys(catalog: catalog, schema: target, table: table)
        return try await rows(sql).map { row in
            // DuckDB records the reference but enforces no action on it, so
            // NO ACTION is reported rather than a rule that was never stored.
            PluginForeignKeyInfo(
                name: Self.text(row, 0),
                column: Self.text(row, 1),
                referencedTable: Self.text(row, 2),
                referencedColumn: Self.text(row, 3),
                referencedSchema: target
            )
        }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let target = resolvedSchema(schema)
        let sql = HarborIntrospectionSQL.tableDDL(catalog: catalog, schema: target, table: table)
        if let ddl = try await rows(sql).first.map({ Self.text($0, 0) }), !ddl.isEmpty {
            return ddl
        }
        // A view has no row in duckdb_tables(); fall back to its definition so
        // the DDL pane shows something true instead of going blank.
        return try await fetchViewDefinition(view: table, schema: target)
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let count = try await rows(HarborIntrospectionSQL.tableCount(catalog: database))
            .first
            .flatMap { Self.number($0, 0) }
        return PluginDatabaseMetadata(
            name: database,
            tableCount: count,
            sizeBytes: nil,
            isSystemDatabase: database == "system" || database == "temp"
        )
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let target = resolvedSchema(schema)
        let sql = HarborIntrospectionSQL.rowCount(catalog: catalog, schema: target, table: table)
        // An exact COUNT(*) here, unlike the sidebar's estimate: this pane is
        // opened for one table on purpose, so the scan is asked for.
        let exact = try await rows(sql).first.flatMap { Self.number($0, 0) }
        return PluginTableMetadata(
            tableName: table,
            rowCount: exact.map(Int64.init)
        )
    }
}
