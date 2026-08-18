import Darwin
import Foundation

public struct FileNormalizer {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public static func normalizedNFC(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// Swift String equality treats canonically equivalent Unicode strings as equal.
    /// Filename normalization must therefore compare the actual UTF-8 representation.
    public static func needsNFCNormalization(_ name: String) -> Bool {
        let normalized = normalizedNFC(name)
        return !name.utf8.elementsEqual(normalized.utf8)
    }

    public func scan(urls: [URL]) throws -> [RenameCandidate] {
        let roots = deduplicated(urls)
        var allURLs: [URL] = []
        var seenPaths = Set<Data>()

        for root in roots {
            appendIfNeeded(root, to: &allURLs, seenPaths: &seenPaths)

            let values = try root.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }

            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isPackageKey,
                .fileResourceIdentifierKey
            ]

            var enumerationFailure: (URL, Error)?
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { url, error in
                    enumerationFailure = (url, error)
                    return false
                }
            ) else {
                throw FileNormalizerError.cannotEnumerate(root)
            }

            for case let child as URL in enumerator {
                appendIfNeeded(child, to: &allURLs, seenPaths: &seenPaths)
            }

            if let failure = enumerationFailure {
                throw FileNormalizerError.enumerationFailed(
                    path: failure.0.path,
                    reason: failure.1.localizedDescription
                )
            }
        }

        var candidates = try allURLs.compactMap(makeCandidate(for:))
        candidates.sort(by: executionOrder)
        return candidates
    }

    public func execute(_ candidates: [RenameCandidate]) -> RenameExecutionResult {
        let ordered = candidates.sorted(by: executionOrder)
        var succeeded: [RenameCandidate] = []
        var failures: [RenameFailure] = []

        for candidate in ordered {
            if let issue = candidate.issue {
                failures.append(RenameFailure(candidate: candidate, message: issue.message))
                continue
            }

            do {
                try rename(candidate)
                succeeded.append(candidate)
            } catch {
                failures.append(
                    RenameFailure(candidate: candidate, message: error.localizedDescription)
                )
            }
        }

        return RenameExecutionResult(succeeded: succeeded, failures: failures)
    }

    private func makeCandidate(for sourceURL: URL) throws -> RenameCandidate? {
        let sourceName = sourceURL.lastPathComponent
        guard Self.needsNFCNormalization(sourceName) else { return nil }

        let targetName = Self.normalizedNFC(sourceName)
        let parentURL = sourceURL.deletingLastPathComponent()
        let targetPath = rawChildPath(parentPath: parentURL.path, leafName: targetName)
        let targetURL = URL(fileURLWithPath: targetPath)

        let values = try sourceURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])

        let kind: FileItemKind
        if values.isSymbolicLink == true {
            kind = .symbolicLink
        } else if values.isDirectory == true {
            kind = .directory
        } else if values.isRegularFile == true {
            kind = .file
        } else {
            kind = .other
        }

        var issue: RenameIssue?
        if pathExists(targetPath), !isSameFilesystemObject(sourceURL.path, targetPath) {
            issue = .conflict(existingPath: targetPath)
        }

        return RenameCandidate(
            sourceURL: sourceURL,
            targetURL: targetURL,
            sourceName: sourceName,
            targetName: targetName,
            kind: kind,
            depth: sourceURL.pathComponents.count,
            issue: issue
        )
    }

    private func rename(_ candidate: RenameCandidate) throws {
        let sourcePath = candidate.sourceURL.path
        let parentPath = candidate.sourceURL.deletingLastPathComponent().path
        let targetPath = rawChildPath(parentPath: parentPath, leafName: candidate.targetName)

        if pathExists(targetPath) {
            guard isSameFilesystemObject(sourcePath, targetPath) else {
                throw FileNormalizerError.destinationAlreadyExists(targetPath)
            }

            // APFS is normalization-insensitive. NFC and NFD paths may resolve to
            // the same object, so force the directory entry through a temporary
            // ASCII name before writing the final NFC bytes.
            try renameThroughTemporaryPath(
                sourcePath: sourcePath,
                parentPath: parentPath,
                targetPath: targetPath,
                targetName: candidate.targetName
            )
        } else {
            try posixRename(from: sourcePath, to: targetPath)
            do {
                try verifyStoredName(parentPath: parentPath, expectedName: candidate.targetName)
            } catch {
                try? posixRename(from: targetPath, to: sourcePath)
                throw error
            }
        }
    }

    private func renameThroughTemporaryPath(
        sourcePath: String,
        parentPath: String,
        targetPath: String,
        targetName: String
    ) throws {
        let temporaryPath = uniqueTemporaryPath(in: parentPath)
        try posixRename(from: sourcePath, to: temporaryPath)

        do {
            try posixRename(from: temporaryPath, to: targetPath)
            do {
                try verifyStoredName(parentPath: parentPath, expectedName: targetName)
            } catch {
                try? posixRename(from: targetPath, to: sourcePath)
                throw error
            }
        } catch {
            if pathExists(temporaryPath) {
                try? posixRename(from: temporaryPath, to: sourcePath)
            }
            throw error
        }
    }

    /// Build a destination path as a plain Swift String. POSIX rename receives the
    /// UTF-8 bytes exactly as constructed instead of letting file-URL conversion
    /// decide the Unicode representation.
    private func rawChildPath(parentPath: String, leafName: String) -> String {
        if parentPath == "/" {
            return "/" + leafName
        }
        return parentPath + "/" + leafName
    }

    private func uniqueTemporaryPath(in parentPath: String) -> String {
        while true {
            let candidate = rawChildPath(
                parentPath: parentPath,
                leafName: ".hangulfix-\(UUID().uuidString)"
            )
            if !pathExists(candidate) {
                return candidate
            }
        }
    }

    private func verifyStoredName(parentPath: String, expectedName: String) throws {
        let entries = try fileManager.contentsOfDirectory(atPath: parentPath)
        let foundExactBytes = entries.contains { entry in
            entry.utf8.elementsEqual(expectedName.utf8)
        }

        guard foundExactBytes else {
            throw FileNormalizerError.persistedNameMismatch(expectedName)
        }
    }

    private func posixRename(from sourcePath: String, to destinationPath: String) throws {
        let result = sourcePath.withCString { sourcePointer in
            destinationPath.withCString { destinationPointer in
                Darwin.rename(sourcePointer, destinationPointer)
            }
        }

        guard result == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSFilePathErrorKey: destinationPath,
                    NSLocalizedDescriptionKey: String(cString: strerror(code))
                ]
            )
        }
    }

    /// Uses lstat so broken symbolic links are still treated as filesystem items.
    private func pathExists(_ path: String) -> Bool {
        var info = stat()
        return path.withCString { pointer in
            Darwin.lstat(pointer, &info)
        } == 0
    }

    private func isSameFilesystemObject(_ lhsPath: String, _ rhsPath: String) -> Bool {
        var lhs = stat()
        var rhs = stat()

        let lhsResult = lhsPath.withCString { pointer in
            Darwin.lstat(pointer, &lhs)
        }
        let rhsResult = rhsPath.withCString { pointer in
            Darwin.lstat(pointer, &rhs)
        }

        guard lhsResult == 0, rhsResult == 0 else { return false }
        return lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private func rawPathKey(_ url: URL) -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<Data>()
        return urls.compactMap { url in
            guard seen.insert(rawPathKey(url)).inserted else { return nil }
            return url
        }
    }

    private func appendIfNeeded(
        _ url: URL,
        to urls: inout [URL],
        seenPaths: inout Set<Data>
    ) {
        guard seenPaths.insert(rawPathKey(url)).inserted else { return }
        urls.append(url)
    }

    private func executionOrder(_ lhs: RenameCandidate, _ rhs: RenameCandidate) -> Bool {
        if lhs.depth != rhs.depth {
            return lhs.depth > rhs.depth
        }

        // At the same depth, files first and directories later. This keeps parent
        // directory paths valid for as long as possible during recursive renames.
        if lhs.kind == .directory, rhs.kind != .directory {
            return false
        }
        if lhs.kind != .directory, rhs.kind == .directory {
            return true
        }

        return lhs.sourceURL.path.utf8.lexicographicallyPrecedes(rhs.sourceURL.path.utf8)
    }
}

public enum FileNormalizerError: LocalizedError {
    case destinationAlreadyExists(String)
    case persistedNameMismatch(String)
    case cannotEnumerate(URL)
    case enumerationFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .destinationAlreadyExists(let path):
            return "같은 이름의 다른 항목이 이미 있습니다: \(URL(fileURLWithPath: path).lastPathComponent)"
        case .persistedNameMismatch(let name):
            return "파일 시스템에 NFC 이름이 정확히 저장되지 않았습니다: \(name)"
        case .cannotEnumerate(let url):
            return "폴더를 읽을 수 없습니다: \(url.path)"
        case .enumerationFailed(let path, let reason):
            return "폴더 검사 중 오류가 발생했습니다: \(path) (\(reason))"
        }
    }
}
