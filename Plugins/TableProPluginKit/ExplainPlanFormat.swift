import Foundation

/// The shape of the text a database returns for an EXPLAIN variant. String-based rather than an
/// enum so a plugin can name a format the app does not know yet without a PluginKit release.
public struct ExplainPlanFormat: Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public extension ExplainPlanFormat {
    /// Output the app has no structured parser for. Rendered as text.
    static let plainText = ExplainPlanFormat(rawValue: "plainText")

    static let postgresJson = ExplainPlanFormat(rawValue: "postgresJson")
    static let mysqlComposite = ExplainPlanFormat(rawValue: "mysqlComposite")
    static let sqliteQueryPlan = ExplainPlanFormat(rawValue: "sqliteQueryPlan")
    static let cockroachText = ExplainPlanFormat(rawValue: "cockroachText")
    static let indentedText = ExplainPlanFormat(rawValue: "indentedText")
    static let damengText = ExplainPlanFormat(rawValue: "damengText")
    static let duckdbJson = ExplainPlanFormat(rawValue: "duckdbJson")

    /// DuckDB's default EXPLAIN: box-drawing art laid out in two dimensions, with a join's two
    /// inputs printed side by side. Deliberately has no parser, and is named rather than left as
    /// plainText so the viewer can tell "nothing was ever going to parse this" from "a parser ran
    /// and failed", and show the raw output without claiming a failure.
    static let duckdbBoxTree = ExplainPlanFormat(rawValue: "duckdbBoxTree")
}
