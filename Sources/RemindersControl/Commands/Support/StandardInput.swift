import Foundation

/// How `import -` reads the piped document. Production reads the process's standard input; tests
/// substitute both seams.
struct StandardInput: Sendable {
    /// Whether stdin is a terminal — then nothing was piped in and reading would block forever.
    var isInteractive: @Sendable () -> Bool
    /// Read standard input to EOF, stopping once more than `limit` bytes have arrived so an
    /// over-long document is rejected instead of buffered whole.
    var read: @Sendable (_ limit: Int) -> Data

    static let standard = StandardInput(
        isInteractive: { isatty(STDIN_FILENO) == 1 },
        read: { limit in
            var data = Data()
            while data.count <= limit {
                let chunk = FileHandle.standardInput.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            return data
        })
}
