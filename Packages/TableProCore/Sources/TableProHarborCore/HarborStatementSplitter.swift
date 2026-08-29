import Foundation

// Harbor answers exactly one statement per request on purpose: duckdb-rs
// executes all but the last statement of a multi-statement string during
// prepare, so accepting several would let an injection into an application's
// SQL run a second statement before a row was ever fetched. The server keeps
// that fence; a client with a real script splits it and sends the parts.
//
// The lexical rules have to be exactly DuckDB's or a semicolon inside a
// string becomes a split point. Each rule below has a counterpart in harbor's
// own lexer and in pilot's, and where the three disagreed it was a bug in
// whichever was simplest: a line comment ends at CR as well as LF, block
// comments nest, E'...' honors backslash escapes where a plain string does
// not, and a dollar quote opens only when the dollar is not inside an
// identifier and the tag is not a digit-led bind parameter.
public enum HarborStatementSplitter {
    public static func split(_ sql: String) -> [String] {
        let bytes = Array(sql.utf8)
        var statements: [String] = []
        var start = 0
        var index = 0

        func appendStatement(endingAt end: Int) {
            guard end > start else { return }
            let text = String(decoding: bytes[start..<end], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isOnlyTrivia(text) else { return }
            statements.append(text)
        }

        while index < bytes.count {
            switch bytes[index] {
            case .dash where byte(bytes, after: index) == .dash:
                index = endOfLineComment(bytes, from: index)
            case .slash where byte(bytes, after: index) == .star:
                index = endOfBlockComment(bytes, from: index)
            case .singleQuote:
                index = endOfSingleQuotedString(bytes, from: index)
            case .doubleQuote:
                index = endOfQuotedIdentifier(bytes, from: index)
            case .dollar:
                if let tag = dollarQuoteTag(bytes, at: index) {
                    index = endOfDollarQuotedString(bytes, from: index, tag: tag)
                } else {
                    index += 1
                }
            case .semicolon:
                appendStatement(endingAt: index)
                index += 1
                start = index
            default:
                index += 1
            }
        }
        appendStatement(endingAt: bytes.count)
        return statements
    }

    private static func byte(_ bytes: [UInt8], after index: Int) -> UInt8? {
        index + 1 < bytes.count ? bytes[index + 1] : nil
    }

    private static func endOfLineComment(_ bytes: [UInt8], from index: Int) -> Int {
        var index = index + 2
        while index < bytes.count, bytes[index] != .newline, bytes[index] != .carriageReturn {
            index += 1
        }
        return index
    }

    private static func endOfBlockComment(_ bytes: [UInt8], from index: Int) -> Int {
        var index = index + 2
        var depth = 1
        while index < bytes.count, depth > 0 {
            if bytes[index] == .slash, byte(bytes, after: index) == .star {
                depth += 1
                index += 2
            } else if bytes[index] == .star, byte(bytes, after: index) == .slash {
                depth -= 1
                index += 2
            } else {
                index += 1
            }
        }
        return index
    }

    private static func endOfSingleQuotedString(_ bytes: [UInt8], from index: Int) -> Int {
        let honorsBackslashEscapes = isEscapeStringQuote(bytes, at: index)
        var index = index + 1
        while index < bytes.count {
            if honorsBackslashEscapes, bytes[index] == .backslash, index + 1 < bytes.count {
                index += 2
                continue
            }
            if bytes[index] == .singleQuote {
                if byte(bytes, after: index) == .singleQuote {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return index
    }

    private static func endOfQuotedIdentifier(_ bytes: [UInt8], from index: Int) -> Int {
        var index = index + 1
        while index < bytes.count {
            if bytes[index] == .doubleQuote {
                if byte(bytes, after: index) == .doubleQuote {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return index
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        byte.isASCIILetter || byte.isASCIIDigit || byte == .underscore || byte == .dollar || byte >= 0x80
    }

    private static func isEscapeStringQuote(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index > 0, bytes[index - 1] == .lowerE || bytes[index - 1] == .upperE else { return false }
        guard index >= 2 else { return true }
        return !isIdentifierByte(bytes[index - 2])
    }

    private static func dollarQuoteTag(_ bytes: [UInt8], at index: Int) -> [UInt8]? {
        if index > 0, isIdentifierByte(bytes[index - 1]) { return nil }
        var end = index + 1
        while end < bytes.count, bytes[end].isASCIILetter || bytes[end].isASCIIDigit || bytes[end] == .underscore {
            end += 1
        }
        guard end < bytes.count, bytes[end] == .dollar else { return nil }
        if end > index + 1, bytes[index + 1].isASCIIDigit { return nil }
        return Array(bytes[index...end])
    }

    private static func endOfDollarQuotedString(_ bytes: [UInt8], from index: Int, tag: [UInt8]) -> Int {
        var index = index + tag.count
        while index + tag.count <= bytes.count {
            if Array(bytes[index..<(index + tag.count)]) == tag { return index + tag.count }
            index += 1
        }
        return bytes.count
    }

    private static func isOnlyTrivia(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let current = bytes[index]
            if current == .space || current == .tab || current == .newline || current == .carriageReturn {
                index += 1
            } else if current == .dash, byte(bytes, after: index) == .dash {
                index = endOfLineComment(bytes, from: index)
            } else if current == .slash, byte(bytes, after: index) == .star {
                index = endOfBlockComment(bytes, from: index)
            } else {
                return false
            }
        }
        return true
    }
}

private extension UInt8 {
    static let dash = UInt8(ascii: "-")
    static let slash = UInt8(ascii: "/")
    static let star = UInt8(ascii: "*")
    static let singleQuote = UInt8(ascii: "'")
    static let doubleQuote = UInt8(ascii: "\"")
    static let dollar = UInt8(ascii: "$")
    static let semicolon = UInt8(ascii: ";")
    static let backslash = UInt8(ascii: "\\")
    static let underscore = UInt8(ascii: "_")
    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let lowerE = UInt8(ascii: "e")
    static let upperE = UInt8(ascii: "E")

    var isASCIILetter: Bool {
        (self >= UInt8(ascii: "a") && self <= UInt8(ascii: "z"))
            || (self >= UInt8(ascii: "A") && self <= UInt8(ascii: "Z"))
    }

    var isASCIIDigit: Bool {
        self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9")
    }
}
