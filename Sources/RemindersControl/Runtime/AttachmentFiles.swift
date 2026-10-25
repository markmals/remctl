import CryptoKit
import Foundation

/// Extension Reminders gives a blob of this UTI inside its Files/ container.
let attachmentUTIExtensions: [String: String] = [
    "public.png": ".png",
    "public.jpeg": ".jpg",
    "public.heic": ".heic",
    "public.heif": ".heif",
    "public.gif": ".gif",
    "com.compuserve.gif": ".gif",
    "public.tiff": ".tiff",
    "com.adobe.pdf": ".pdf",
]

let attachmentFallbackExtensions = [".png", ".jpg", ".jpeg", ".heic"]

/// Port of `_candidate_extensions`. The stored filename's suffix first, then the UTI's
/// extension, then the common image extensions — deduplicated, lowercase, dot-prefixed.
public func attachmentCandidateExtensions(filename: String?, uti: String?) -> [String] {
    var exts: [String] = []
    func add(_ ext: String) { if !exts.contains(ext) { exts.append(ext) } }
    if let filename {
        let suffix = (filename as NSString).pathExtension.lowercased()
        if !suffix.isEmpty { add("." + suffix) }
    }
    if let uti, let mapped = attachmentUTIExtensions[uti.trimmingCharacters(in: .whitespaces).lowercased()] {
        add(mapped)
    }
    attachmentFallbackExtensions.forEach(add)
    return exts
}

/// A `ZSHA512SUM` is only usable as a filename when it is exactly 128 hex digits.
public func normalizedAttachmentSHA(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let sum = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard sum.count == 128, sum.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
    return sum
}

/// Maps an attachment row to its verified file inside Reminders' group container.
///
/// Attachment blobs live next to the store, in
/// `<store dir>/../Files/Account-*/Attachments/<ZSHA512SUM><ext>`. A candidate is only
/// reported once its bytes hash back to the row's stored sum, so a stale or replaced file
/// is `resolved: false` rather than a path that lies.
public final class AttachmentFileResolver {
    public typealias FileHasher = (URL) -> String?

    /// Files above this are never hashed: a read command must not stream an arbitrarily
    /// large blob to answer a listing (upstream `MAX_IMAGE_BYTES`).
    public static let maxHashedBytes = 16 * 1024 * 1024

    private struct MemoKey: Hashable {
        let path: String
        let modified: Double
        let size: Int
    }

    private let filesDir: URL
    private let hashFile: FileHasher
    private var cachedDirs: [URL]?
    private var memo: [MemoKey: String?] = [:]

    public init(storeDir: URL, hashFile: @escaping FileHasher = AttachmentFileResolver.sha512Hex) {
        self.filesDir = storeDir.deletingLastPathComponent().appendingPathComponent("Files")
        self.hashFile = hashFile
    }

    /// The verified on-disk path for an attachment row, or nil when the sum is unusable,
    /// no candidate file exists, the file is oversized, or its bytes hash to something else.
    public func resolve(sha512: String?, filename: String?, uti: String?) -> String? {
        guard let sum = normalizedAttachmentSHA(sha512) else { return nil }
        for dir in attachmentDirs() {
            for ext in attachmentCandidateExtensions(filename: filename, uti: uti) {
                let candidate = dir.appendingPathComponent(sum + ext)
                guard let key = memoKey(candidate), key.size <= Self.maxHashedBytes else { continue }
                if digest(of: candidate, key: key) == sum { return candidate.path }
            }
        }
        return nil
    }

    /// `Account-*/Attachments` directories, listed once per process.
    private func attachmentDirs() -> [URL] {
        if let cachedDirs { return cachedDirs }
        let accounts = (try? FileManager.default.contentsOfDirectory(
            at: filesDir, includingPropertiesForKeys: nil)) ?? []
        let dirs = accounts
            .filter { $0.lastPathComponent.hasPrefix("Account-") }
            .map { $0.appendingPathComponent("Attachments") }
            .filter { isDirectory($0) }
            .sorted { $0.path < $1.path }
        cachedDirs = dirs
        return dirs
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func memoKey(_ url: URL) -> MemoKey? {
        guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize else { return nil }
        return MemoKey(path: url.path, modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                       size: size)
    }

    /// Attachment blobs are immutable in practice, so a (path, mtime, size) memo keeps one
    /// listing from hashing the same file once per reminder that references it.
    private func digest(of url: URL, key: MemoKey) -> String? {
        if let cached = memo[key] { return cached }
        let digest = hashFile(url)
        memo[key] = digest
        return digest
    }

    /// Streaming SHA-512 of a file, lowercase hex.
    public static func sha512Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA512()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hexString(hasher.finalize())
    }

    private static func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(128)
        for byte in digest {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
