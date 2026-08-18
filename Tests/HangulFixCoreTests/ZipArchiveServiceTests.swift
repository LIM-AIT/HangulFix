import Darwin
import XCTest
@testable import HangulFixCore

final class ZipArchiveServiceTests: XCTestCase {
    private let fileManager = FileManager.default

    func testCreateVerifiedArchiveAfterNormalizationAndRoundTrip() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: workspace) }

        let rootNFC = "ZIP_프로젝트".precomposedStringWithCanonicalMapping
        let childNFC = "회의_자료".precomposedStringWithCanonicalMapping
        let fileNFC = "최종_문서.txt".precomposedStringWithCanonicalMapping
        let rootNFD = rootNFC.decomposedStringWithCanonicalMapping
        let childNFD = childNFC.decomposedStringWithCanonicalMapping
        let fileNFD = fileNFC.decomposedStringWithCanonicalMapping

        let rootURL = workspace.appendingPathComponent(rootNFD, isDirectory: true)
        let childURL = rootURL.appendingPathComponent(childNFD, isDirectory: true)
        try fileManager.createDirectory(at: childURL, withIntermediateDirectories: true)

        let payload = Data("zip-round-trip".utf8)
        try payload.write(to: childURL.appendingPathComponent(fileNFD))

        let normalizer = FileNormalizer()
        let candidates = try normalizer.scan(urls: [rootURL])
        XCTAssertEqual(candidates.count, 3)

        let execution = normalizer.execute(candidates)
        XCTAssertTrue(execution.failures.isEmpty, execution.failures.map(\.message).joined(separator: "\n"))

        let normalizedRootPath = rawChildPath(parentPath: workspace.path, leafName: rootNFC)
        let archiveURL = workspace.appendingPathComponent("windows-share.zip")
        let verification = try ZipArchiveService().createVerifiedArchive(
            sourcePath: normalizedRootPath,
            destinationURL: archiveURL
        )

        XCTAssertTrue(fileManager.fileExists(atPath: archiveURL.path))
        XCTAssertGreaterThanOrEqual(verification.entryCount, 3)
        XCTAssertTrue(verification.entryNames.allSatisfy {
            !$0.hasPrefix("__MACOSX/") && $0 != "__MACOSX"
        })
        XCTAssertTrue(verification.entryNames.allSatisfy {
            !$0.utf8.elementsEqual($0.decomposedStringWithCanonicalMapping.utf8)
                || $0.utf8.elementsEqual($0.precomposedStringWithCanonicalMapping.utf8)
        })

        let extractURL = workspace.appendingPathComponent("Extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractURL, withIntermediateDirectories: true)
        try runDitto(arguments: ["-x", "-k", "--norsrc", archiveURL.path, extractURL.path])

        XCTAssertTrue(try exactNameExists(rootNFC, in: extractURL))
        let extractedRoot = URL(
            fileURLWithPath: rawChildPath(parentPath: extractURL.path, leafName: rootNFC),
            isDirectory: true
        )
        XCTAssertTrue(try exactNameExists(childNFC, in: extractedRoot))
        let extractedChild = URL(
            fileURLWithPath: rawChildPath(parentPath: extractedRoot.path, leafName: childNFC),
            isDirectory: true
        )
        XCTAssertTrue(try exactNameExists(fileNFC, in: extractedChild))

        let extractedFilePath = rawChildPath(parentPath: extractedChild.path, leafName: fileNFC)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: extractedFilePath)), payload)
    }

    func testArchiveCreationRejectsSourceWithRemainingNFDName() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: workspace) }

        let nfc = "아직_분리.txt".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        try Data("not-ready".utf8).write(to: workspace.appendingPathComponent(nfd))

        let archiveURL = workspace.deletingLastPathComponent()
            .appendingPathComponent("should-not-exist-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: archiveURL) }

        XCTAssertThrowsError(
            try ZipArchiveService().createVerifiedArchive(
                sourcePath: workspace.path,
                destinationURL: archiveURL
            )
        ) { error in
            guard case ZipArchiveError.sourceContainsNonNFC = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertFalse(fileManager.fileExists(atPath: archiveURL.path))
    }

    func testSingleNFCFileCanBeArchivedAndVerified() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: workspace) }

        let fileName = "정상_파일.txt".precomposedStringWithCanonicalMapping
        let sourcePath = rawChildPath(parentPath: workspace.path, leafName: fileName)
        let payload = Data("single-file".utf8)
        try writeExactFile(payload, to: sourcePath)

        let archiveURL = workspace.appendingPathComponent("single.zip")
        let verification = try ZipArchiveService().createVerifiedArchive(
            sourcePath: sourcePath,
            destinationURL: archiveURL
        )

        XCTAssertEqual(verification.entryCount, 1)
        XCTAssertEqual(verification.entryNames, [fileName])
        XCTAssertNoThrow(try ZipArchiveService().verifyArchive(at: archiveURL))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("HangulFixZipTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exactNameExists(_ expectedName: String, in directory: URL) throws -> Bool {
        try fileManager.contentsOfDirectory(atPath: directory.path).contains { name in
            name.utf8.elementsEqual(expectedName.utf8)
        }
    }

    private func rawChildPath(parentPath: String, leafName: String) -> String {
        parentPath == "/" ? "/" + leafName : parentPath + "/" + leafName
    }

    private func writeExactFile(_ data: Data, to path: String) throws {
        let descriptor = path.withCString { pointer in
            Darwin.creat(pointer, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else { throw posixError(path: path) }
        defer { Darwin.close(descriptor) }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0

            while totalWritten < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: totalWritten),
                    rawBuffer.count - totalWritten
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(path: path)
                }
                guard written > 0 else { throw posixError(path: path) }
                totalWritten += written
            }
        }
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
                domain: "HangulFixZipTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: text]
            )
        }
    }

    private func posixError(path: String) -> NSError {
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
