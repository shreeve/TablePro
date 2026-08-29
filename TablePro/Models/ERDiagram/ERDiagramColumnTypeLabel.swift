//
//  ERDiagramColumnTypeLabel.swift
//  TablePro
//
//  The type text a diagram node prints beside a column name.
//

import Foundation

enum ERDiagramColumnTypeLabel {
    /// A set-valued type spells its whole vocabulary into its own name, so it grows without bound
    /// and reads as a truncated fragment of one value at diagram scale. Every other parenthesised
    /// type says something short and worth keeping (`VARCHAR(255)`, `DECIMAL(10,2)`), so only
    /// these lose their arguments.
    private static let setValuedTypes: Set<String> = ["ENUM", "SET"]

    static func label(for dataType: String, maxCharacters: Int) -> String {
        let collapsed = collapsingSetValues(dataType)
        guard (collapsed as NSString).length > maxCharacters else { return collapsed }
        return String(collapsed.prefix(maxCharacters)) + "\u{2026}"
    }

    private static func collapsingSetValues(_ dataType: String) -> String {
        guard let parenthesis = dataType.firstIndex(of: "(") else { return dataType }
        let base = dataType[dataType.startIndex..<parenthesis].trimmingCharacters(in: .whitespaces)
        guard setValuedTypes.contains(base.uppercased()) else { return dataType }
        return base
    }
}
