import Foundation

public enum WindowsNameProblem: Hashable, Sendable {
    case forbiddenCharacter(String)
    case controlCharacter(UInt32)
    case trailingSpaceOrPeriod
    case reservedDeviceName(String)

    public var message: String {
        switch self {
        case .forbiddenCharacter(let character):
            return "Windows에서 사용할 수 없는 문자 ‘\(character)’가 포함되어 있습니다."
        case .controlCharacter(let value):
            return String(format: "Windows에서 사용할 수 없는 제어 문자 U+%04X가 포함되어 있습니다.", value)
        case .trailingSpaceOrPeriod:
            return "Windows 파일명은 공백 또는 마침표로 끝날 수 없습니다."
        case .reservedDeviceName(let name):
            return "Windows 예약 장치 이름 ‘\(name)’은 파일명으로 사용할 수 없습니다."
        }
    }
}

public struct WindowsCompatibilityIssue: Identifiable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let problem: WindowsNameProblem

    public init(path: String, name: String, problem: WindowsNameProblem) {
        self.path = path
        self.name = name
        self.problem = problem
    }

    public var id: String {
        "\(path)|\(problem)"
    }
}

public struct WindowsCompatibilityValidator: Sendable {
    private static let forbiddenScalars: Set<Unicode.Scalar> = Set("<>:\"/\\|?*".unicodeScalars)

    private static let reservedDeviceNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        "COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"
    ]

    public init() {}

    public static func problems(in name: String) -> [WindowsNameProblem] {
        var problems: [WindowsNameProblem] = []
        var seenForbidden = Set<Unicode.Scalar>()
        var seenControl = Set<UInt32>()

        for scalar in name.unicodeScalars {
            if scalar.value <= 0x1F, seenControl.insert(scalar.value).inserted {
                problems.append(.controlCharacter(scalar.value))
            }

            if forbiddenScalars.contains(scalar), seenForbidden.insert(scalar).inserted {
                problems.append(.forbiddenCharacter(String(scalar)))
            }
        }

        if name.last == " " || name.last == "." {
            problems.append(.trailingSpaceOrPeriod)
        }

        let firstComponent = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        let deviceKey = firstComponent.uppercased()
        if reservedDeviceNames.contains(deviceKey) {
            problems.append(.reservedDeviceName(firstComponent))
        }

        return problems
    }

    public func scan(urls: [URL]) throws -> [WindowsCompatibilityIssue] {
        let fileManager = FileManager.default
        let roots = deduplicated(urls)
        var issues: [WindowsCompatibilityIssue] = []
        var seenPaths = Set<Data>()

        for root in roots {
            appendIssues(for: root, into: &issues, seenPaths: &seenPaths)

            let values = try root.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }

            var enumerationFailure: (URL, Error)?
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                options: [.skipsPackageDescendants],
                errorHandler: { url, error in
                    enumerationFailure = (url, error)
                    return false
                }
            ) else {
                throw WindowsCompatibilityError.cannotEnumerate(root.path)
            }

            for case let child as URL in enumerator {
                appendIssues(for: child, into: &issues, seenPaths: &seenPaths)
            }

            if let failure = enumerationFailure {
                throw WindowsCompatibilityError.enumerationFailed(
                    path: failure.0.path,
                    reason: failure.1.localizedDescription
                )
            }
        }

        return issues.sorted { lhs, rhs in
            lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
        }
    }

    private func appendIssues(
        for url: URL,
        into issues: inout [WindowsCompatibilityIssue],
        seenPaths: inout Set<Data>
    ) {
        let path = url.standardizedFileURL.path
        let key = Data(path.utf8)
        guard seenPaths.insert(key).inserted else { return }

        let name = url.lastPathComponent
        for problem in Self.problems(in: name) {
            issues.append(
                WindowsCompatibilityIssue(path: path, name: name, problem: problem)
            )
        }
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<Data>()
        return urls.compactMap { url in
            let key = Data(url.standardizedFileURL.path.utf8)
            guard seen.insert(key).inserted else { return nil }
            return url
        }
    }
}

public enum WindowsCompatibilityError: LocalizedError {
    case cannotEnumerate(String)
    case enumerationFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .cannotEnumerate(let path):
            return "Windows 호환성 검사를 위해 폴더를 읽을 수 없습니다: \(path)"
        case .enumerationFailed(let path, let reason):
            return "Windows 호환성 검사 중 오류가 발생했습니다: \(path) (\(reason))"
        }
    }
}
