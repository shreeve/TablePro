import Foundation

/// The whole catalog, as harbor assembles it.
///
/// One request replaces the obvious shape — list the tables, then ask each one
/// for its columns, then its indexes, then its foreign keys — which is four
/// round trips per table over HTTP and grows with the schema. Harbor already
/// walks its own catalog to build this, so a sidebar refresh costs one call
/// rather than 3N+1.
///
/// It is also version-proof in a way hand-written duckdb_* queries are not:
/// harbor tracks DuckDB's catalog changes behind this shape, so a client does
/// not have to.
public struct HarborCatalog: Decodable, Sendable {
    public let tables: [Table]

    public struct Table: Decodable, Sendable {
        public let name: String
        public let schema: String
        public let columns: [Column]
        public let primaryKey: [String]
        public let uniqueConstraints: [UniqueConstraint]
        public let indexes: [Index]
        public let foreignKeys: [ForeignKey]
    }

    public struct Column: Decodable, Sendable {
        public let name: String
        public let type: String
        public let notNull: Bool
        public let `default`: String?
        public let primary: Bool
    }

    public struct UniqueConstraint: Decodable, Sendable {
        public let columns: [String]
    }

    public struct Index: Decodable, Sendable {
        public let name: String
        public let columns: [String]?
        /// An expression index has no plain column list; harbor reports the
        /// expressions separately so the two are not confused.
        public let expressions: [String]?
        public let unique: Bool?
    }

    /// The wire spells these `refTable`/`refSchema`/`refColumns`. Getting the
    /// names wrong here does not fail the decode — the fields are optional, so
    /// they simply arrive nil and every foreign key silently disappears from
    /// the structure pane. Named explicitly so a rename on either side is a
    /// compile error rather than an empty list.
    public struct ForeignKey: Decodable, Sendable {
        public let columns: [String]?
        public let refTable: String?
        public let refSchema: String?
        public let refColumns: [String]?
    }
}
