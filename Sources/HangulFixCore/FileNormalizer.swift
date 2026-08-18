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

    /// Executes the batch as an all-or-nothing operation as far as the filesystem
    /// allows. Preflight issues stop the batch before the first rename. If a runtime
    /// failure happens after earlier items were converted, those earlier changes are
    /// rolled back in reverse execution order so nested directory paths stay valid.
    public func execute(_ candidates: [RenameCandidate]) -> RenameExecutionResult {
        let ordered = candidates.sorted(by: executionOrder)

        let preflightFailures = ordered.compactMap { candidate -> RenameFailure? in
            guard let issue = candidate.issue else { return nil }
            return RenameFailure(candidate: candidate, message: issue.message)
        }

        guard preflightFailures.isEmpty else {
            return RenameExecutionResult(succeeded: [], failures: preflightFailures)
        }

        var succeeded: [RenameCandidate] = []

        for candidate in ordered {
            do {
                try rename(candidate)
                succeeded.append(candidate)
            } catch {
                var failures = [
                    RenameFailure(candidate: candidate, message: error.localizedDescription)
                ]
                var remainingConverted = Set(succeeded.map(\.id))
                var rolledBackCount = 0

                for previous in succeeded.reversed() {
                    do {
                        try rollback(previous)
                        remainingConverted.remove(previous.id)
                        rolledBackCount += 1
                    } catch {
                        failures.append(
                            RenameFailure(
                                candidate: previous,
                                message: "롤백 실패: \(error.localizedDescription)"
                            )
                        )
                    }
                }

                let stillConverted = succeeded.filter { remainingConverted.contains($0.id) }
                return RenameExecutionResult(
                    succeeded: stillConverted,
                    failures: failures,
                    rolledBackCount: rolledBackCount
                )
            }
        }

        return RenameExecutionResult(succeeded: succeeded, failures: [])
    }

    /// Restores a previously successful conversion to the exact original filename
    /// bytes. Parents are restored before their descendants so nested paths become
    /// valid again. If undo fails midway, already-restored items are converted again
    /// in the opposite order to avoid leaving a partially undone batch when possible.
    public func undo(_ candidates: [RenameCandidate]) -> RenameUndoResult {
        let undoOrder = candidates.sorted(by: executionOrder).reversed()
        var undone: [RenameCandidate] = []

        for candidate in undoOrder {
            do {
                try rollback(candidate)
                undone.append(candidate)
            } catch {
                var failures = [
                    RenameFailure(
                        candidate: candidate,
                        message: "실행 취소 실패: \(error.localizedDescription)"
                    )
                ]
                var remainingUndone = Set(undone.map(\.id))
                var reappliedCount = 0

                // `undone` is shallowest-first. Re-applying in reverse restores the
                // original conversion order (deepest-first), which keeps parent paths valid.
                for previous in undone.reversed() {
                    do {
                        try rename(previous)
                        remainingUndone.remove(previous.id)
                        reappliedCount += 1
                    } catch {
                        failures.append(
                            RenameFailure(
                                candidate: previous,
                                message: "실행 취소 복구 실패: \(error.localizedDescription)"
                            )
                        )
                    }
                }

                let stillUndone = undone.filter { remainingUndone.contains($0.id) }
                return RenameUndoResult(
                    undone: stillUndone,
                    failures: failures,
                    reappliedCount: reappliedCount
                )
            }
        }

        return RenameUndoResult(undone: undone, failures: [])
    }

    private func makeCandidate(for sourceURL: URL) throws -> RenameCandidate? {
        // `URL.lastPathComponent` can present a canonically normalized spelling for
        // file URLs on macOS. Use the path string's leaf component instead so a
        // directly selected NFD file is checked with the same bytes that ZIP preflight
        // sees and the actual directory-entry spelling is not hidden from the scan.
        let sourceName = (sourceURL.path as NSString).lastPathComponent
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

    private func rollback(_ candidate: RenameCandidate) throws {
        let originalPath = candidate.sourceURL.path
        let parentPath = candidate.sourceURL.deletingLastPathComponent().path
        let convertedPath = rawChildPath(parentPath: parentPath, leafName: candidate.targetName)

        if pathExists(convertedPath) {
            if pathExists(originalPath) {
                guard isSameFilesystemObject(convertedPath, originalPath) else {
                    throw FileNormalizerError.rollbackDestinationOccupied(originalPath)
                }

                // On APFS the original NFD spelling can resolve to the same inode as
                // the current NFC spelling. Force the directory entry back through
                // an ASCII temporary name so the original bytes are restored.
                try renameThroughTemporaryPath(
                    sourcePath: convertedPath,
                    parentPath: parentPath,
                    targetPath: originalPath,
                    targetName: candidate.sourceName
                )
            } else {
                try posixRename(from: convertedPath, to: originalPath)
                do {
                    try verifyStoredName(parentPath: parentPath, expectedName: candidate.sourceName)
                } catch {
                    try? posixRename(from: originalPath, to: convertedPath)
                    throw error
                }
            }
            return
        }

        if pathExists(originalPath) {
            try verifyStoredName(parentPath: parentPath, expectedName: candidate.sourceName)
            return
        }

        throw FileNormalizerError.rollbackSourceMissing(convertedPath)
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
    case rollbackDestinationOccupied(String)
    case rollbackSourceMissing(String)

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
        case .rollbackDestinationOccupied(let path):
            return "원래 이름으로 되돌릴 수 없습니다. 다른 항목이 경로를 사용 중입니다: \(path)"
        case .rollbackSourceMissing(let path):
            return "롤백할 변환 결과를 찾을 수 없습니다: \(path)"
        }
    }
}
