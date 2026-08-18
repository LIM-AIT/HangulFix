import XCTest
@testable import HangulFixCore

final class WindowsCompatibilityTests: XCTestCase {
    private let fileManager = FileManager.default

    func testValidKoreanAndAsciiNamesPass() {
        let valid = [
            "한글_문서.txt",
            "Project 2026.xlsx",
            "COM10.txt",
            "LPT10",
            "보고서 (최종).pdf"
        ]

        for name in valid {
            XCTAssertTrue(
                WindowsCompatibilityValidator.problems(in: name).isEmpty,
                "Expected Windows-safe name: \(name)"
            )
        }
    }

    func testForbiddenCharactersAreDetected() {
        let cases: [(String, String)] = [
            ("보고서<최종>.txt", "<"),
            ("시간:기록.txt", ":"),
            ("질문?.txt", "?"),
            ("별표*.txt", "*"),
            ("파이프|문서.txt", "|"),
            ("인용\"문서.txt", "\"")
        ]

        for (name, character) in cases {
            let problems = WindowsCompatibilityValidator.problems(in: name)
            XCTAssertTrue(problems.contains(.forbiddenCharacter(character)), name)
        }
    }

    func testReservedDeviceNamesAreDetectedCaseInsensitivelyWithExtensions() {
        let reserved = [
            "CON", "con.txt", "PRN.pdf", "AUX", "nul.log",
            "COM1", "com9.zip", "LPT1", "lpt9.txt",
            "COM¹.txt", "LPT²"
        ]

        for name in reserved {
            XCTAssertTrue(
                WindowsCompatibilityValidator.problems(in: name).contains { problem in
                    if case .reservedDeviceName = problem { return true }
                    return false
                },
                "Expected reserved Windows device name: \(name)"
            )
        }
    }

    func testTrailingSpacePeriodAndControlCharactersAreDetected() {
        XCTAssertTrue(
            WindowsCompatibilityValidator.problems(in: "보고서 ").contains(.trailingSpaceOrPeriod)
        )
        XCTAssertTrue(
            WindowsCompatibilityValidator.problems(in: "보고서.").contains(.trailingSpaceOrPeriod)
        )
        XCTAssertTrue(
            WindowsCompatibilityValidator.problems(in: "bad\u{0007}name.txt").contains(.controlCharacter(0x07))
        )
    }

    func testRecursiveScanFindsNestedWindowsIncompatibleNames() throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HangulFixWindowsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let nested = root.appendingPathComponent("정상_폴더", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("reserved".utf8).write(to: nested.appendingPathComponent("CON.txt"))
        try Data("forbidden".utf8).write(to: nested.appendingPathComponent("보고서?.txt"))
        try Data("safe".utf8).write(to: nested.appendingPathComponent("정상.txt"))

        let issues = try WindowsCompatibilityValidator().scan(urls: [root])

        XCTAssertEqual(issues.count, 2)
        XCTAssertTrue(issues.contains { $0.name == "CON.txt" })
        XCTAssertTrue(issues.contains { $0.name == "보고서?.txt" })
    }
}
