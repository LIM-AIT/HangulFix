import XCTest
@testable import HangulFixCore

final class FileNormalizerTests: XCTestCase {
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

    func testExecuteRewritesDirectoryEntryToNFC() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HangulFixTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let nfc = "한글_테스트.txt".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        let sourceURL = root.appendingPathComponent(nfd)
        try Data("HangulFix test\n".utf8).write(to: sourceURL)

        let before = try fileManager.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(before.count, 1)
        XCTAssertFalse(before[0].utf8.elementsEqual(nfc.utf8))

        let normalizer = FileNormalizer()
        let candidates = try normalizer.scan(urls: [root])
        XCTAssertEqual(candidates.count, 1)

        let result = normalizer.execute(candidates)
        XCTAssertTrue(result.failures.isEmpty, result.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(result.succeeded.count, 1)

        let after = try fileManager.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(after[0].utf8.elementsEqual(nfc.utf8))
        XCTAssertFalse(FileNormalizer.needsNFCNormalization(after[0]))
    }
}
