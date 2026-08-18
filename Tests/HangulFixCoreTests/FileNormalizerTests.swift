import Darwin
import XCTest
@testable import HangulFixCore

final class FileNormalizerTests: XCTestCase {
    private let fileManager = FileManager.default

    func testDecomposedHangulNeedsNormalization() {
        let nfc = "한글_문서.pdf"
        let nfd = nfc.decomposedStringWithCanonicalMapping

        XCTAssertFalse(nfd.utf8.elementsEqual(nfc.utf8))
        XCTAssertTrue(FileNormalizer.needsNFCNormalization(nfd))
    }

    func testNFCNameDoesNotNeedNormalization() {
        let nfc = "한글_문서.pdf".precomposedStringWithCanonicalMapping
        XCTAssertFalse(FileNormalizer.needsNFCNormalization(nfc))
    }

    func testNormalizationProducesNFCBytes() {
        let expected = "회의록_최종.docx".precomposedStringWithCanonicalMapping
        let nfd = expected.decomposedStringWithCanonicalMapping
        let actual = FileNormalizer.normalizedNFC(nfd)

        XCTAssertEqual(Array(actual.utf8), Array(expected.utf8))
    }

    func testExecuteRewritesDirectoryEntryToNFCAndPreservesContents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let nfc = "한글_테스트.txt".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        let sourceURL = root.appendingPathComponent(nfd)
        let payload = Data("HangulFix test\n".utf8)
        try payload.write(to: sourceURL)

        let normalizer = FileNormalizer()
        let candidates = try normalizer.scan(urls: [root])
        XCTAssertEqual(candidates.count, 1)

        let result = normalizer.execute(candidates)
        XCTAssertTrue(result.failures.isEmpty, result.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(result.succeeded.count, 1)

        let names = try fileManager.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.utf8.elementsEqual(nfc.utf8) })
        XCTAssertFalse(names.contains { $0.utf8.elementsEqual(nfd.utf8) })

        let finalURL = root.appendingPathComponent(nfc)
        XCTAssertEqual(try Data(contentsOf: finalURL), payload)
        XCTAssertFalse(names.contains { $0.hasPrefix(".hangulfix-") })
    }

    func testNestedDirectoryAndFileAreNormalizedDeepestFirst() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: workspace) }

        let rootNFC = "프로젝트_자료".precomposedStringWithCanonicalMapping
        let childNFC = "회의_문서".precomposedStringWithCanonicalMapping
        let fileNFC = "최종_회의록.txt".precomposedStringWithCanonicalMapping

        let rootNFD = rootNFC.decomposedStringWithCanonicalMapping
        let childNFD = childNFC.decomposedStringWithCanonicalMapping
        let fileNFD = fileNFC.decomposedStringWithCanonicalMapping

        let rootURL = workspace.appendingPathComponent(rootNFD, isDirectory: true)
        let childURL = rootURL.appendingPathComponent(childNFD, isDirectory: true)
        try fileManager.createDirectory(at: childURL, withIntermediateDirectories: true)

        let payload = Data("nested-content".utf8)
        try payload.write(to: childURL.appendingPathComponent(fileNFD))

        let normalizer = FileNormalizer()
        let candidates = try normalizer.scan(urls: [rootURL])
        XCTAssertEqual(candidates.count, 3)

        let result = normalizer.execute(candidates)
        XCTAssertTrue(result.failures.isEmpty, result.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(result.succeeded.count, 3)

        XCTAssertTrue(try exactNameExists(rootNFC, in: workspace))

        let normalizedRoot = workspace.appendingPathComponent(rootNFC, isDirectory: true)
        XCTAssertTrue(try exactNameExists(childNFC, in: normalizedRoot))

        let normalizedChild = normalizedRoot.appendingPathComponent(childNFC, isDirectory: true)
        XCTAssertTrue(try exactNameExists(fileNFC, in: normalizedChild))
        XCTAssertEqual(try Data(contentsOf: normalizedChild.appendingPathComponent(fileNFC)), payload)
    }

    func testAlreadyNFCFilesAreNotTouched() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let nfc = "이미_정상.txt".precomposedStringWithCanonicalMapping
        let filePath = rawChildPath(parentPath: root.path, leafName: nfc)
        let fileURL = URL(fileURLWithPath: filePath)
        let payload = Data("keep-me".utf8)

        // Foundation URL-based file creation can decompose a filename on macOS.
        // Create the directory entry through POSIX so this test genuinely starts
        // with NFC UTF-8 bytes on disk.
        try writeExactFile(payload, to: filePath)
        XCTAssertTrue(try exactNameExists(nfc, in: root))

        let before = try fileManager.attributesOfItem(atPath: filePath)
        let candidates = try FileNormalizer().scan(urls: [root])
        let after = try fileManager.attributesOfItem(atPath: filePath)

        XCTAssertTrue(candidates.isEmpty)
        XCTAssertTrue(try exactNameExists(nfc, in: root))
        XCTAssertEqual(try Data(contentsOf: fileURL), payload)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
    }

    func testOverlappingSelectionsDoNotDuplicateCandidates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let nfc = "중복_선택.txt".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        let fileURL = root.appendingPathComponent(nfd)
        try Data().write(to: fileURL)

        let candidates = try FileNormalizer().scan(urls: [root, fileURL, root])
        XCTAssertEqual(candidates.count, 1)
    }

    func testBatchNormalization() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let expectedNames = (0..<64).map { index in
            "문서_\(index)_최종.txt".precomposedStringWithCanonicalMapping
        }

        for name in expectedNames {
            let nfd = name.decomposedStringWithCanonicalMapping
            try Data("item".utf8).write(to: root.appendingPathComponent(nfd))
        }

        let normalizer = FileNormalizer()
        let candidates = try normalizer.scan(urls: [root])
        XCTAssertEqual(candidates.count, expectedNames.count)

        let result = normalizer.execute(candidates)
        XCTAssertTrue(result.failures.isEmpty, result.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(result.succeeded.count, expectedNames.count)

        let actualNames = try fileManager.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(actualNames.count, expectedNames.count)

        for expected in expectedNames {
            XCTAssertTrue(actualNames.contains { $0.utf8.elementsEqual(expected.utf8) })
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("HangulFixTests-\(UUID().uuidString)", isDirectory: true)
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

        guard descriptor >= 0 else {
            throw posixError(path: path)
        }
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

                guard written > 0 else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EIO),
                        userInfo: [NSFilePathErrorKey: path]
                    )
                }

                totalWritten += written
            }
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
