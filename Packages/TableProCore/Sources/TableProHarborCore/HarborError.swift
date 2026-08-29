import Foundation

/// A failure that came back from harbor, or from the attempt to reach it.
///
/// Harbor names its failures: the NDJSON error event carries a `code`
/// (`sql_error`, `cancelled`, `unready`, ...) alongside the human message.
/// The code is kept because callers branch on it — a cancelled statement is
/// not a broken one — while the message is what a person reads.
public struct HarborError: LocalizedError, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    /// `true` when the statement was cancelled rather than failed, so the UI
    /// can stay quiet instead of reporting an error the user caused.
    public var isCancellation: Bool { code == "cancelled" }

    public static let notConnected = HarborError(
        code: "not_connected",
        message: "Not connected to harbor"
    )

    public static func transport(_ message: String) -> HarborError {
        HarborError(code: "transport", message: message)
    }

    public static func protocolViolation(_ message: String) -> HarborError {
        HarborError(code: "protocol", message: message)
    }
}
