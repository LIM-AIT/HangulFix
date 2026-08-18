import Darwin
import Foundation

/// Resolves a file URL/path to the spelling that is actually stored in its parent
/// directory. This matters on APFS because canonically equivalent NFD/NFC path
/// strings can resolve to the same filesystem object even when only one byte
/// spelling is stored in the directory entry.
public enum FileSystemEntryResolver {
    public static func resolve(_ url: URL) throws -> URL {
        URL(fileURLWithPath: try resolvePath(url.path))
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
        let names = try FileManager.default.contentsOfDirectory(atPath: parentPath)

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
