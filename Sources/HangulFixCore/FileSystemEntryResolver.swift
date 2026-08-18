import Darwin
import Foundation

/// Resolves a file URL/path to the exact Unicode spelling stored in its parent
/// directory. Foundation file URL/path APIs on macOS may present canonically
/// equivalent decomposed strings even when the APFS directory entry is stored as NFC,
/// so directory-entry names are read through POSIX `readdir(3)` instead.
public enum FileSystemEntryResolver {
    public static func resolve(_ url: URL) throws -> URL {
        let resolvedPath = try resolvePath(url.path)

        var info = stat()
        let result = resolvedPath.withCString { pointer in
            Darwin.lstat(pointer, &info)
        }
        guard result == 0 else {
            throw posixError(path: resolvedPath)
        }

        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        return resolvedPath.withCString { pointer in
            NSURL(
                fileURLWithFileSystemRepresentation: pointer,
                isDirectory: isDirectory,
                relativeTo: nil
            ) as URL
        }
    }

    public static func resolvePath(_ path: String) throws -> String {
        guard path != "/" else { return path }

        var target = stat()
        let targetResult = path.withCString { pointer in
            Darwin.lstat(pointer, &target)
        }
        guard targetResult == 0 else {
            throw posixError(path: path)
        }

        let nsPath = path as NSString
        let unresolvedParentPath = nsPath.deletingLastPathComponent.isEmpty
            ? "/"
            : nsPath.deletingLastPathComponent
        let parentPath = try resolvePath(unresolvedParentPath)
        let requestedName = nsPath.lastPathComponent
        let names = try storedNames(in: parentPath)

        var inodeMatches: [String] = []
        for name in names {
            let childPath = rawChildPath(parentPath: parentPath, leafName: name)
            var child = stat()
            let childResult = childPath.withCString { pointer in
                Darwin.lstat(pointer, &child)
            }
            guard childResult == 0 else { continue }
            guard child.st_dev == target.st_dev, child.st_ino == target.st_ino else { continue }

            if name.utf8.elementsEqual(requestedName.utf8) {
                return childPath
            }
            inodeMatches.append(name)
        }

        let requestedNFC = requestedName.precomposedStringWithCanonicalMapping
        if let canonicalMatch = inodeMatches.first(where: {
            $0.precomposedStringWithCanonicalMapping.utf8.elementsEqual(requestedNFC.utf8)
        }) {
            return rawChildPath(parentPath: parentPath, leafName: canonicalMatch)
        }

        if inodeMatches.count == 1, let onlyMatch = inodeMatches.first {
            return rawChildPath(parentPath: parentPath, leafName: onlyMatch)
        }

        throw FileSystemEntryResolverError.cannotResolveStoredName(path)
    }

    /// Returns directory entry names from `readdir(3)` without passing them through
    /// Foundation. For valid macOS filenames, converting the returned UTF-8 C string
    /// to Swift preserves the original UTF-8 code-unit sequence, which lets callers
    /// distinguish NFC from NFD by bytes.
    static func storedNames(in directoryPath: String) throws -> [String] {
        guard let directory = directoryPath.withCString({ Darwin.opendir($0) }) else {
            throw posixError(path: directoryPath)
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []

        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                if errno != 0 {
                    throw posixError(path: directoryPath)
                }
                break
            }

            var nameStorage = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: nameStorage)
            let name = withUnsafePointer(to: &nameStorage) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }

            guard name != ".", name != ".." else { continue }
            names.append(name)
        }

        return names
    }

    private static func rawChildPath(parentPath: String, leafName: String) -> String {
        parentPath == "/" ? "/" + leafName : parentPath + "/" + leafName
    }

    private static func posixError(path: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: String(cString: strerror(code))
            ]
        )
    }
}

public enum FileSystemEntryResolverError: LocalizedError {
    case cannotResolveStoredName(String)

    public var errorDescription: String? {
        switch self {
        case .cannotResolveStoredName(let path):
            return "실제 파일 시스템에 저장된 이름을 확인할 수 없습니다: \(path)"
        }
    }
}
