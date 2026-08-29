import Foundation
import TableProPluginKit

/// DuckDB Harbor: a DuckDB server, reached over HTTP.
///
/// TablePro already ships a DuckDB driver, and this is deliberately not it.
/// That one links libduckdb and opens the file in-process, which is exactly
/// what harbor exists to prevent — one process owns the file, everyone else
/// asks it. Pointing both at one database is how you get "database is
/// locked", so this driver never touches the file and only speaks the wire.
final class HarborPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "DuckDB Harbor Driver"
    static let pluginVersion = "0.1.0"
    static let pluginDescription = "DuckDB over the network, served by a harbor berth"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DuckDBHarbor"
    static let databaseDisplayName = "DuckDB Harbor"
    // Borrowed until the plugin has art of its own; harbor serves DuckDB, so
    // the DuckDB mark is honest about what is on the other end.
    static let iconName = "duckdb-icon"
    static let defaultPort = 9_495
    static let isDownloadable = true

    static let connectionMode: ConnectionMode = .network
    static let requiresAuthentication = false
    static let brandColorHex = "#FFF000"
    static let queryLanguageName = "SQL"
    // DuckDB's placeholder, and what the app emits when it builds a bound
    // statement for this driver.
    static let parameterStyle: ParameterStyle = .questionMark
    static let editorLanguage: EditorLanguage = .sql

    // A berth serves one database. DuckDB can ATTACH more and the wire would
    // carry them, but this driver implements no switchDatabase — and the SDK's
    // default THROWS rather than no-ops, so advertising the capability would
    // put an error in front of the user at the moment they tried it. The form
    // field goes with it: a container the server already decided is not a
    // question worth asking.
    static let supportsDatabaseSwitching = false
    static let hidesBuiltInDatabase = true
    // Schemas are different: DuckDB really has several, and switchSchema is
    // implemented below, so this one is earned.
    static let supportsSchemaSwitching = true
    static let requiresReconnectForDatabaseSwitch = false
    static let databaseGroupingStrategy: GroupingStrategy = .hierarchicalSchema
    static let containerEntityName = "Database"
    static let schemaEntityName = "Schema"
    static let tableEntityName = "Tables"
    static let defaultSchemaName = "main"
    static let systemSchemaNames: [String] = ["information_schema", "pg_catalog"]

    // DuckDB declares foreign keys but does not enforce them the way a
    // transactional store does, and harbor exposes whatever the catalog says.
    static let supportsForeignKeys = true
    // Every flag below is false because the corresponding method is not
    // implemented yet, and the SDK's defaults do not fail alike: renameTable
    // and renameSchema THROW, so the user gets an error dialog, while the
    // generate*SQL family returns nil, so the editor collects a change and
    // then quietly produces no statement. Advertising either is worse than
    // not offering the menu item — one is a broken promise, the other is a
    // silent one. They flip back as each generator lands.
    static let supportsSchemaEditing = false
    static let supportsAddColumn = false
    static let supportsModifyColumn = false
    static let supportsDropColumn = false
    // Still false once the rest land: DuckDB has no ALTER TYPE and no ALTER
    // for a primary key. Those are a table rebuild, not an in-place edit.
    static let supportsModifyPrimaryKey = false
    static let supportsAddIndex = false
    static let supportsDropIndex = false
    static let supportsRenameTable = false
    // Permanently false: DuckDB has no ALTER SCHEMA ... RENAME at all.
    static let supportsRenameSchema = false

    static let supportsSSH = true
    // Harbor is deliberately TLS-free itself: a remote berth is fronted by
    // Caddy or reached through SSH. The toggle describes the URL, not harbor.
    static let supportsSSL = true
    static let supportsHealthMonitor = true
    // Import runs many statements and needs a transaction to be safe. It has
    // one now: ImportDataSinkAdapter calls beginTransaction/rollbackTransaction,
    // and those open a harbor lease rather than firing a bare BEGIN at the
    // pool, so a failure halfway rolls the whole import back.
    static let supportsImport = true
    static let supportsExport = true
    static let supportsReadOnlyMode = true

    static let structureColumnFields: [StructureColumnField] = [
        .name, .type, .nullable, .defaultValue, .comment,
    ]

    static let columnTypesByCategory: [String: [String]] = [
        "Boolean": ["BOOLEAN"],
        "Integer": ["TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT",
                    "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "UHUGEINT"],
        "Floating": ["FLOAT", "DOUBLE", "DECIMAL"],
        "String": ["VARCHAR", "CHAR", "UUID"],
        "Binary": ["BLOB", "BIT"],
        "Date/Time": ["DATE", "TIME", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE",
                      "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS", "INTERVAL"],
        "Complex": ["LIST", "STRUCT", "MAP", "UNION", "ARRAY", "JSON", "ENUM"],
    ]

    // The token is the whole credential. Harbor authenticates a bearer token
    // and has no notion of a user at all, so both built-in identity fields are
    // suppressed rather than left to sit there inviting a value that is read
    // by nothing and silently ignored.
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "harborToken",
            label: String(localized: "Token"),
            placeholder: "Contents of the berth's .token file",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true
        ).withHidesUsername(true),
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "FROM", "WHERE", "GROUP", "BY", "HAVING", "ORDER", "LIMIT", "OFFSET",
            "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "ON", "USING", "NATURAL",
            "AND", "OR", "NOT", "IN", "LIKE", "ILIKE", "SIMILAR", "BETWEEN", "AS", "DISTINCT",
            "UNION", "INTERSECT", "EXCEPT", "WITH", "RECURSIVE", "VALUES", "UNNEST", "LATERAL",
            "INSERT", "INTO", "UPDATE", "SET", "DELETE", "CREATE", "ALTER", "DROP", "ATTACH",
            "DETACH", "COPY", "TABLE", "VIEW", "SCHEMA", "SEQUENCE", "MACRO", "TYPE", "INDEX",
            "IF", "EXISTS", "REPLACE", "COMMENT", "PRAGMA", "INSTALL", "LOAD", "EXPORT",
            "CASE", "WHEN", "THEN", "ELSE", "END", "CAST", "TRY_CAST", "IS", "NULL",
            "TRUE", "FALSE", "ASC", "DESC", "NULLS", "FIRST", "LAST", "OVER", "PARTITION",
            "QUALIFY", "SAMPLE", "USING", "PIVOT", "UNPIVOT", "SUMMARIZE", "DESCRIBE", "EXPLAIN",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CHECK", "DEFAULT", "CONSTRAINT",
            "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION", "RETURNING", "EXCLUDE",
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MIN", "MAX", "LIST", "ARRAY_AGG", "STRING_AGG",
            "ANY_VALUE", "APPROX_COUNT_DISTINCT", "MEDIAN", "QUANTILE", "MODE",
            "COALESCE", "NULLIF", "GREATEST", "LEAST", "IFNULL",
            "LENGTH", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM", "SUBSTRING", "SUBSTR",
            "REPLACE", "REVERSE", "CONCAT", "CONCAT_WS", "SPLIT_PART", "STRING_SPLIT",
            "REGEXP_MATCHES", "REGEXP_REPLACE", "REGEXP_EXTRACT", "REGEXP_FULL_MATCH",
            "STARTS_WITH", "ENDS_WITH", "CONTAINS", "PRINTF", "FORMAT",
            "NOW", "CURRENT_DATE", "CURRENT_TIMESTAMP", "TODAY", "AGE", "EPOCH",
            "DATE_TRUNC", "DATE_PART", "DATE_DIFF", "DATE_ADD", "STRFTIME", "STRPTIME",
            "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE",
            "ABS", "CEIL", "CEILING", "FLOOR", "ROUND", "POWER", "SQRT", "LN", "LOG", "EXP",
            "LIST_VALUE", "LIST_EXTRACT", "LEN", "UNNEST", "STRUCT_PACK", "MAP", "JSON_EXTRACT",
            "READ_CSV", "READ_CSV_AUTO", "READ_PARQUET", "READ_JSON", "READ_JSON_AUTO",
            "GENERATE_SERIES", "RANGE",
        ],
        dataTypes: [
            "BOOLEAN", "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT",
            "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "UHUGEINT",
            "FLOAT", "DOUBLE", "DECIMAL", "VARCHAR", "CHAR", "BLOB", "BIT", "UUID",
            "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL",
            "LIST", "STRUCT", "MAP", "UNION", "ARRAY", "JSON", "ENUM",
        ],
        regexSyntax: .regexpLike,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit,
        offsetFetchOrderBy: "",
        caseSensitivityStyle: .regexFlag
    )

    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "logical", label: "Explain", sqlPrefix: "EXPLAIN"),
        ExplainVariant(id: "analyze", label: "Explain Analyze", sqlPrefix: "EXPLAIN ANALYZE"),
    ]

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        HarborPluginDriver(config: config)
    }
}
