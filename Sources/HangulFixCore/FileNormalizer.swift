import Foundation
import Darwin

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
        var seenPaths = Set<String>()

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

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            for case let child as URL in enumerator {
                appendIfNeeded(child, to: &allURLs, seenPaths: &seenPaths)
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
        let targetURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(targetName)

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
        if itemExists(at: targetURL), !isSameFilesystemObject(sourceURL, targetURL) {
            issue = .conflict(existingPath: targetURL.path)
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
        let sourceURL = candidate.sourceURL
        let parentURL = sourceURL.deletingLastPathComponent()
        let targetURL = parentURL.appendingPathComponent(candidate.targetName)
        let targetPath = rawChildPath(parentURL: parentURL, leafName: candidate.targetName)

        if itemExists(at: targetURL) {
            guard isSameFilesystemObject(sourceURL, targetURL) else {
                throw FileNormalizerError.destinationAlreadyExists(targetURL)
            }

            // APFS is normalization-insensitive. NFC and NFD paths may resolve to
            // the same object, so force the directory entry through a temporary
            // ASCII name before writing the final NFC bytes.
            try renameThroughTemporaryPath(sourceURL: sourceURL, targetPath: targetPath)
        } else {
            try posixRename(from: sourceURL.path, to: targetPath)
        }
    }

    private func renameThroughTemporaryPath(sourceURL: URL, targetPath: String) throws {
        let parentURL = sourceURL.deletingLastPathComponent()
        let temporaryPath = uniqueTemporaryPath(in: parentURL)
        let originalPath = sourceURL.path

        try posixRename(from: originalPath, to: temporaryPath)

        do {
            try posixRename(from: temporaryPath, to: targetPath)
        } catch {
            // Best-effort rollback. Preserve the requested operation's error if
            // rollback also fails.
            try? posixRename(from: temporaryPath, to: originalPath)
            throw error
        }
    }

    /// Build the destination as a plain Swift String instead of a file URL.
    /// Foundation file-URL/path conversion can apply filesystem normalization on
    /// macOS; POSIX rename receives these UTF-8 bytes exactly as constructed.
    private func rawChildPath(parentURL: URL, leafName: String) -> String {
        let parentPath = parentURL.path
        if parentPath == "/" {
            return "/" + leafName
        }
        return parentPath + "/" + leafName
    }

    private func uniqueTemporaryPath(in directory: URL) -> String {
        while true {
            let candidate = rawChildPath(
                parentURL: directory,
                leafName: ".hangulfix-\(UUID().uuidString)"
            )
            if !fileManager.fileExists(atPath: candidate) {
                return candidate
            }
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

    private func itemExists(at url: URL) -> Bool {
        do {
            _ = try fileManager.attributesOfItem(atPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private func isSameFilesystemObject(_ lhs: URL, _ rhs: URL) -> Bool {
        guard
            let lhsValues = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]),
            let rhsValues = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]),
            let lhsIdentifier = lhsValues.fileResourceIdentifier,
            let rhsIdentifier = rhsValues.fileResourceIdentifier
        else {
            return false
        }

        if let left = lhsIdentifier as? AnyHashable,
           let right = rhsIdentifier as? AnyHashable {
            return left == right
        }

        if let left = lhsIdentifier as? NSObject,
           let right = rhsIdentifier as? NSObject {
            return left.isEqual(right)
        }

        return false
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return url
        }
    }

    private func appendIfNeeded(
        _ url: URL,
        to urls: inout [URL],
        seenPaths: inout Set<String>
    ) {
        let path = url.standardizedFileURL.path
        guard seenPaths.insert(path).inserted else { return }
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

        return lhs.sourceURL.path < rhs.sourceURL.path
    }
}

public enum FileNormalizerError: LocalizedError {
    case destinationAlreadyExists(URL)

    public var errorDescription: String? {
        switch self {
        case .destinationAlreadyExists(let url):
            return "같은 이름의 다른 항목이 이미 있습니다: \(url.lastPathComponent)"
        }
    }
}
