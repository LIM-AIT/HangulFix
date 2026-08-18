import Darwin
import Foundation
import HangulFixCore
import UniformTypeIdentifiers

public enum SafeMailAttachmentValidator {
    public static let maxAttachmentSize: Int64 = 150 * 1_048_576
    public static let directUploadThreshold: Int64 = 3 * 1_048_576

    public static func validate(paths: [String]) throws -> [SafeMailAttachment] {
        guard !paths.isEmpty else {
            throw SafeMailError.noAttachments
        }

        return try paths.map(validate(path:))
    }

    public static func validate(path: String) throws -> SafeMailAttachment {
        let resolvedPath: String
        do {
            resolvedPath = try FileSystemEntryResolver.resolvePath(path)
        } catch {
            throw SafeMailError.attachmentMissing(path)
        }

        let name = rawLeafName(resolvedPath)
        guard !name.isEmpty else {
            throw SafeMailError.attachmentMissing(path)
        }

        var info = stat()
        let result = resolvedPath.withCString { pointer in
            Darwin.lstat(pointer, &info)
        }
        guard result == 0 else {
            throw SafeMailError.attachmentMissing(resolvedPath)
        }

        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            throw SafeMailError.folderNotSupported(name)
        case S_IFLNK:
            throw SafeMailError.symbolicLinkNotSupported(name)
        case S_IFREG:
            break
        default:
            throw SafeMailError.attachmentMissing(resolvedPath)
        }

        guard !FileNormalizer.needsNFCNormalization(name) else {
            throw SafeMailError.attachmentNotNFC(name)
        }

        if let problem = WindowsCompatibilityValidator.problems(in: name).first {
            throw SafeMailError.windowsIncompatibleName(name: name, reason: problem.message)
        }

        let size = Int64(info.st_size)
        guard size <= maxAttachmentSize else {
            throw SafeMailError.attachmentTooLarge(name: name, size: size)
        }

        return SafeMailAttachment(
            path: resolvedPath,
            name: name,
            size: size,
            contentType: preferredMIMEType(for: name)
        )
    }

    public static func isPlausibleEmailAddress(_ raw: String) -> Bool {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty,
              !address.contains(where: { $0.isWhitespace }),
              let at = address.firstIndex(of: "@"),
              at != address.startIndex,
              address.index(after: at) != address.endIndex,
              address[address.index(after: at)...].contains(".") else {
            return false
        }
        return true
    }

    private static func rawLeafName(_ path: String) -> String {
        guard path != "/" else { return "/" }
        guard let slash = path.lastIndex(of: "/") else { return path }
        let next = path.index(after: slash)
        return String(path[next...])
    }

    private static func preferredMIMEType(for name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.index(before: name.endIndex) else {
            return "application/octet-stream"
        }
        let ext = String(name[name.index(after: dot)...])
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}
