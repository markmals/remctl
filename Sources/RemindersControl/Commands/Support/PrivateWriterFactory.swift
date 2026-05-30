import Foundation

/// Factory for the PrivateWriter the write-command shells use. Production returns a real
/// ReminderKitWriter; tests can override `make` (or, preferred, call a command's core directly
/// with a MockPrivateWriter, bypassing this).
public enum PrivateWriterFactory {
    nonisolated(unsafe) public static var make: () -> PrivateWriter = { ReminderKitWriter() }
}
