import Foundation

/// The catalog queries, in DuckDB's own vocabulary.
///
/// DuckDB's namespace is `catalog.schema.table`, and the `duckdb_*` table
/// functions span every attached catalog at once. A predicate on the schema
/// alone therefore matches same-named schemas in other catalogs: with a
/// second database attached, `WHERE schema_name = 'main'` returns both
/// catalogs' `main` tables. Every query here constrains the catalog too.
public enum HarborIntrospectionSQL {
    /// Single-quote a SQL string literal. `''` is the escape, per the standard.
    public static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Double-quote an identifier. `""` is the escape.
    public static func identifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func qualified(catalog: String?, schema: String?, name: String) -> String {
        var parts: [String] = []
        if let catalog, !catalog.isEmpty { parts.append(identifier(catalog)) }
        if let schema, !schema.isEmpty { parts.append(identifier(schema)) }
        parts.append(identifier(name))
        return parts.joined(separator: ".")
    }

    public static let databases = """
        SELECT database_name FROM duckdb_databases()
         WHERE NOT internal ORDER BY database_name
        """

    /// Deliberately does NOT filter on `internal`.
    ///
    /// That flag does not mean what its name suggests: DuckDB reports a user
    /// database's own `main` as internal = true, so filtering on it returns
    /// nothing and the sidebar comes up empty. Constraining to one catalog is
    /// the real filter — every schema in a user's database is the user's.
    /// `pg_catalog` and `information_schema` live in the `system` catalog and
    /// are named in the plugin's `systemSchemaNames` besides.
    public static func schemas(catalog: String) -> String {
        """
        SELECT schema_name FROM duckdb_schemas()
         WHERE database_name = \(literal(catalog))
         ORDER BY schema_name
        """
    }

    /// Tables and views in one pass, so the sidebar can show both without a
    /// second round trip. `estimated_size` is DuckDB's own row estimate; it is
    /// not a COUNT(*) and is not presented as one.
    public static func tables(catalog: String, schema: String) -> String {
        """
        SELECT table_name AS name, 'table' AS kind, estimated_size AS rows, comment
          FROM duckdb_tables()
         WHERE database_name = \(literal(catalog)) AND schema_name = \(literal(schema))
        UNION ALL
        SELECT view_name AS name, 'view' AS kind, NULL AS rows, comment
          FROM duckdb_views()
         WHERE database_name = \(literal(catalog)) AND schema_name = \(literal(schema))
         ORDER BY name
        """
    }

    /// Columns, with the primary-key flag folded in.
    ///
    /// DuckDB reports a PRIMARY KEY as a constraint over a list of column
    /// names, not as a column attribute, so the key set is unnested and joined
    /// back. A composite key therefore marks every one of its columns, which a
    /// scalar `is_primary_key` column could not express.
    public static func columns(catalog: String, schema: String, table: String) -> String {
        """
        WITH pk AS (
          SELECT UNNEST(constraint_column_names) AS column_name
            FROM duckdb_constraints()
           WHERE database_name = \(literal(catalog))
             AND schema_name = \(literal(schema))
             AND table_name = \(literal(table))
             AND constraint_type = 'PRIMARY KEY'
        )
        SELECT c.column_name       AS name,
               c.data_type         AS type,
               c.is_nullable       AS nullable,
               c.column_default    AS default_value,
               c.comment           AS comment,
               (c.column_name IN (SELECT column_name FROM pk)) AS is_primary_key
          FROM duckdb_columns() c
         WHERE c.database_name = \(literal(catalog))
           AND c.schema_name = \(literal(schema))
           AND c.table_name = \(literal(table))
         ORDER BY c.column_index
        """
    }

    public static func indexes(catalog: String, schema: String, table: String) -> String {
        """
        SELECT index_name AS name, is_unique, sql
          FROM duckdb_indexes()
         WHERE database_name = \(literal(catalog))
           AND schema_name = \(literal(schema))
           AND table_name = \(literal(table))
         ORDER BY index_name
        """
    }

    /// A view's SELECT. DuckDB keeps it verbatim, so this is the definition
    /// the user wrote rather than a reconstruction.
    public static func viewDefinition(catalog: String, schema: String, view: String) -> String {
        """
        SELECT sql FROM duckdb_views()
         WHERE database_name = \(literal(catalog))
           AND schema_name = \(literal(schema))
           AND view_name = \(literal(view))
        """
    }

    /// Foreign keys, one row per column pair.
    ///
    /// DuckDB stores a key as two parallel lists — the local columns and the
    /// referenced ones — so both are unnested together. DuckDB zips multiple
    /// UNNESTs in one SELECT positionally, which is what pairs column N with
    /// referenced column N; a cross join would pair every column with every
    /// other and invent relationships that do not exist.
    public static func foreignKeys(catalog: String, schema: String, table: String) -> String {
        """
        SELECT constraint_name                    AS name,
               UNNEST(constraint_column_names)    AS column_name,
               referenced_table                   AS ref_table,
               UNNEST(referenced_column_names)    AS ref_column
          FROM duckdb_constraints()
         WHERE database_name = \(literal(catalog))
           AND schema_name = \(literal(schema))
           AND table_name = \(literal(table))
           AND constraint_type = 'FOREIGN KEY'
        """
    }

    /// DuckDB keeps the CREATE statement for a table, so the DDL shown is the
    /// engine's own text rather than something reassembled from the catalog.
    public static func tableDDL(catalog: String, schema: String, table: String) -> String {
        """
        SELECT sql FROM duckdb_tables()
         WHERE database_name = \(literal(catalog))
           AND schema_name = \(literal(schema))
           AND table_name = \(literal(table))
        """
    }

    public static func tableCount(catalog: String) -> String {
        """
        SELECT count(*) FROM duckdb_tables()
         WHERE database_name = \(literal(catalog))
        """
    }

    public static func rowCount(catalog: String, schema: String, table: String) -> String {
        "SELECT count(*) FROM \(qualified(catalog: catalog, schema: schema, name: table))"
    }
}
