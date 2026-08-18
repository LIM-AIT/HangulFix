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
}
