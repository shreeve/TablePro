//
//  PluginMetadataRegistry+DuckDBDefaults.swift
//  TablePro
//
//  Curated snapshots for the two DuckDB engines: the embedded file driver and the Harbor
//  berth that serves one over HTTP. They are kept together, and out of the general registry
//  defaults, because they share a dialect, a column type set and an EXPLAIN story.
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    func duckdbFamilyDefaults(
        dialect: SQLDialectDescriptor,
        columnTypes: [String: [String]]
    ) -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("DuckDB", PluginMetadataSnapshot(
                displayName: "DuckDB", iconName: "duckdb-icon", defaultPort: 9_494,
                requiresAuthentication: false, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "duckdb", parameterStyle: .dollar,
                navigationModel: .standard,
                explainVariants: [
                    ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .duckdbBoxTree),
                    ExplainVariant(
                        id: "explain-json",
                        label: "EXPLAIN (JSON)",
                        sqlPrefix: "EXPLAIN (FORMAT JSON)",
                        format: .duckdbJson
                    ),
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: false, urlSchemes: ["duckdb", "quack"],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#FFD900",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: false,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: true,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsRenameColumn: true,
                    supportsConnectionPooling: false,
                    localFilePathField: .additionalField("duckdbFilePath")
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "main",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["system", "temp"],
                    systemSchemaNames: [],
                    fileExtensions: ["duckdb", "ddb", "parquet", "csv", "tsv", "json", "ndjson"],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: dialect,
                    statementCompletions: [],
                    columnTypesByCategory: columnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: Self.duckdbConnectionFields,
                    category: .analytical,
                    tagline: String(localized: "Embedded and remote analytical SQL"),
                    hidesBuiltInPassword: true,
                    hidesBuiltInDatabase: true
                )
            )),
            ("DuckDBHarbor", PluginMetadataSnapshot(
                displayName: "DuckDB Harbor", iconName: "duckdb-icon", defaultPort: 9_495,
                requiresAuthentication: false, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: false, primaryUrlScheme: "duckdbharbor", parameterStyle: .questionMark,
                navigationModel: .standard,
                explainVariants: [
                    ExplainVariant(id: "logical", label: "Explain", sqlPrefix: "EXPLAIN", format: .duckdbBoxTree),
                    ExplainVariant(
                        id: "json",
                        label: "Explain (JSON)",
                        sqlPrefix: "EXPLAIN (FORMAT JSON)",
                        format: .duckdbJson
                    ),
                    ExplainVariant(id: "analyze", label: "Explain Analyze", sqlPrefix: "EXPLAIN ANALYZE"),
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [],
                postConnectActions: [],
                brandColorHex: "#FFF000",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsRenameColumn: true,
                    supportsConnectionPooling: true,
                    localFilePathField: .none
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "main",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["system", "temp"],
                    systemSchemaNames: ["information_schema", "pg_catalog"],
                    fileExtensions: [],
                    databaseGroupingStrategy: .hierarchicalSchema,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: dialect,
                    statementCompletions: [],
                    columnTypesByCategory: columnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: Self.harborConnectionFields,
                    category: .analytical,
                    tagline: String(localized: "Analytical SQL over the network"),
                    hidesBuiltInPassword: true,
                    hidesBuiltInDatabase: true
                )
            )),
        ]
    }
}
