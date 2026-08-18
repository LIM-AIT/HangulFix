import XCTest
@testable import HangulFixCore

final class WindowsZipSafetyTests: XCTestCase {
    private let fileManager = FileManager.default

    func testZipCreationRejectsReservedWindowsDeviceName() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("SafeRoot", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("reserved".utf8).write(to: source.appendingPathComponent("CON.txt"))

        let destination = workspace.appendingPathComponent("blocked.zip")

        XCTAssertThrowsError(
            try ZipArchiveService().createVerifiedArchive(
                sourcePath: source.path,
                destinationURL: destination
            )
        ) { error in
            guard case ZipArchiveError.sourceContainsWindowsIncompatible(let path, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.contains("CON.txt"))
        }

        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
    }

    func testZipCreationRejectsForbiddenWindowsCharacter() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("SafeRoot", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("forbidden".utf8).write(to: source.appendingPathComponent("report?.txt"))

        let destination = workspace.appendingPathComponent("blocked.zip")

        XCTAssertThrowsError(
            try ZipArchiveService().createVerifiedArchive(
                sourcePath: source.path,
                destinationURL: destination
            )
        ) { error in
            guard case ZipArchiveError.sourceContainsWindowsIncompatible(let path, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.contains("report?.txt"))
            XCTAssertTrue(reason.contains("?"))
        }

        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
    }

    func testExistingUnsafeArchiveIsRejectedByCentralDirectoryVerification() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("SafeRoot", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("unsafe".utf8).write(to: source.appendingPathComponent("AUX.txt"))

        let archive = workspace.appendingPathComponent("unsafe.zip")
        try runDitto(arguments: [
            "-c", "-k", "--norsrc", "--keepParent",
            source.path,
            archive.path
        ])

        XCTAssertThrowsError(try ZipArchiveService().verifyArchive(at: archive)) { error in
            guard case ZipArchiveError.windowsIncompatibleEntry(let name, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(name.contains("AUX.txt"))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("HangulFixWindowsZipTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runDitto(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "HangulFixWindowsZipTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: text]
            )
        }
    }
}
