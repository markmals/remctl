import Foundation

/// Factory for the RemindersWriter the write-command shells use. Production returns a real
/// EventKitWriter; tests can override `make` (or, preferred, call a command's core directly
/// with a MockWriter, bypassing this).
public enum WriterFactory {
    nonisolated(unsafe) public static var make: () -> RemindersWriter = { EventKitWriter() }
}
