import Foundation
import TableProHarborCore
import TableProPluginKit

extension HarborPluginDriver {
    private var ddlSchema: String? {
        currentSchema
    }

    private func snapshotEntry(_ table: String) -> HarborCatalog.Table? {
        let schema = ddlSchema ?? "main"
        return snapshot?.tables.first { $0.name == table && $0.schema == schema }
    }

    // The generate family is synchronous, so the indexes an ALTER has to work
    // around can only come from the last catalog snapshot. The schema editor
    // loads a table's structure before offering an edit, which fills it.
    private func knownIndexes(_ table: String) -> [HarborDDL.Index] {
        guard let entry = snapshotEntry(table) else { return [] }
        return entry.indexes.map {
            HarborDDL.Index(name: $0.name, columns: $0.columns ?? [], isUnique: $0.unique ?? false)
        }
    }

    private func expressionIndexNames(_ table: String) -> Set<String> {
        guard let entry = snapshotEntry(table) else { return [] }
        return Set(entry.indexes.filter { ($0.expressions?.isEmpty == false) }.map(\.name))
    }

    private static func column(from definition: PluginColumnDefinition) -> HarborDDL.Column {
        HarborDDL.Column(
            name: definition.name,
            type: definition.dataType,
            isNullable: definition.isNullable,
            defaultValue: definition.defaultValue,
            isPrimaryKey: definition.isPrimaryKey,
            autoIncrement: definition.autoIncrement
        )
    }

    private static func index(from definition: PluginIndexDefinition) -> HarborDDL.Index {
        HarborDDL.Index(name: definition.name, columns: definition.columns, isUnique: definition.isUnique)
    }

    private static func foreignKey(from definition: PluginForeignKeyDefinition) -> HarborDDL.ForeignKey {
        HarborDDL.ForeignKey(
            name: definition.name,
            columns: definition.columns,
            referencedTable: definition.referencedTable,
            referencedColumns: definition.referencedColumns
        )
    }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        let statements = HarborDDL.createTable(
            schema: ddlSchema,
            table: definition.tableName,
            columns: definition.columns.map(Self.column),
            foreignKeys: definition.foreignKeys.map(Self.foreignKey),
            indexes: definition.indexes.map(Self.index)
        )
        return statements.isEmpty ? nil : statements.joined(separator: ";\n")
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        HarborDDL.addColumn(schema: ddlSchema, table: table, column: Self.column(from: column))
            .joined(separator: ";\n")
    }

    func generateModifyColumnSQL(
        table: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        let statements = HarborDDL.modifyColumn(
            schema: ddlSchema,
            table: table,
            old: Self.column(from: oldColumn),
            new: Self.column(from: newColumn),
            indexes: knownIndexes(table),
            expressionIndexNames: expressionIndexNames(table)
        )
        guard let statements, !statements.isEmpty else { return nil }
        return statements.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        HarborDDL.dropColumn(schema: ddlSchema, table: table, column: columnName)
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        HarborDDL.createIndex(Self.index(from: index), schema: ddlSchema, table: table)
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        HarborDDL.dropIndex(schema: ddlSchema, name: indexName)
    }

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        HarborDDL.columnDefinition(Self.column(from: column), inlinePrimaryKey: false)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        guard let tableName else { return nil }
        return HarborDDL.createIndex(Self.index(from: index), schema: ddlSchema, table: tableName)
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        HarborDDL.foreignKeyDefinition(Self.foreignKey(from: fk))
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        [HarborDDL.truncate(schema: schema ?? ddlSchema, table: table)]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        HarborDDL.dropObject(schema: schema ?? ddlSchema, name: name, objectType: objectType)
    }

    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        _ = try await execute(query: HarborDDL.renameTable(
            schema: schema ?? ddlSchema, from: name, to: newName
        ))
    }
}
