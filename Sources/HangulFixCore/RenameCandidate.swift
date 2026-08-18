import Foundation

public enum FileItemKind: String, Sendable, Hashable {
    case file
    case directory
    case symbolicLink
    case other

    public var systemImage: String {
        switch self {
        case .file:
            return "doc"
        case .directory:
            return "folder"
        case .symbolicLink:
            return "link"
        case .other:
            return "questionmark.square"
        }
    }
}

public enum RenameIssue: Sendable, Hashable {
    case conflict(existingPath: String)

    public var message: String {
        switch self {
        case .conflict:
            return "같은 이름의 다른 항목이 이미 존재합니다."
        }
    }
}

public struct RenameCandidate: Identifiable, Sendable, Hashable {
    public let id: UUID

    /// Exact path spelling used for filesystem operations. Do not derive this back
    /// from `URL.path` on macOS: Foundation may expose a canonically equivalent
    /// spelling that differs from the actual APFS directory-entry bytes.
    public let sourcePath: String
    public let targetPath: String

    public let sourceName: String
    public let targetName: String
    public let kind: FileItemKind
    public let depth: Int
    public let issue: RenameIssue?

    /// URLs are retained for UI / Foundation interoperability only. Core rename
    /// logic must use `sourcePath` / `targetPath` instead.
    public var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    public var targetURL: URL { URL(fileURLWithPath: targetPath) }

    public init(
        id: UUID = UUID(),
        sourcePath: String,
        targetPath: String,
        sourceName: String,
        targetName: String,
        kind: FileItemKind,
        depth: Int,
        issue: RenameIssue? = nil
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.sourceName = sourceName
        self.targetName = targetName
        self.kind = kind
        self.depth = depth
        self.issue = issue
    }

    /// Compatibility initializer used by tests and callers that already have URLs.
    /// New core code should prefer the raw-path initializer above.
    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        targetURL: URL,
        sourceName: String,
        targetName: String,
        kind: FileItemKind,
        depth: Int,
        issue: RenameIssue? = nil
    ) {
        self.init(
            id: id,
            sourcePath: sourceURL.path,
            targetPath: targetURL.path,
            sourceName: sourceName,
            targetName: targetName,
            kind: kind,
            depth: depth,
            issue: issue
        )
    }

    public var isBlocked: Bool {
        issue != nil
    }

    public var parentPath: String {
        let parent = (sourcePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}

public struct RenameFailure: Sendable, Hashable {
    public let candidate: RenameCandidate
    public let message: String

    public init(candidate: RenameCandidate, message: String) {
        self.candidate = candidate
        self.message = message
    }
}

public struct RenameExecutionResult: Sendable {
    /// Items that remain converted when execution returns. This is empty when a
    /// runtime failure occurs and every earlier rename was rolled back successfully.
    public let succeeded: [RenameCandidate]
    public let failures: [RenameFailure]
    public let rolledBackCount: Int

    public init(
        succeeded: [RenameCandidate],
        failures: [RenameFailure],
        rolledBackCount: Int = 0
    ) {
        self.succeeded = succeeded
        self.failures = failures
        self.rolledBackCount = rolledBackCount
    }
}

public struct RenameUndoResult: Sendable {
    /// Items that remain restored to their original names when undo returns.
    /// A successful undo contains every requested candidate here.
    public let undone: [RenameCandidate]
    public let failures: [RenameFailure]

    /// If undo fails after restoring earlier items, HangulFix attempts to put those
    /// items back into the converted state. This count records successful re-applies.
    public let reappliedCount: Int

    public init(
        undone: [RenameCandidate],
        failures: [RenameFailure],
        reappliedCount: Int = 0
    ) {
        self.undone = undone
        self.failures = failures
        self.reappliedCount = reappliedCount
    }
}
