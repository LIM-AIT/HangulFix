import Darwin
import XCTest
@testable import HangulFixMail

final class SafeMailAttachmentValidatorTests: XCTestCase {
    private let fileManager = FileManager.default

    func testNFCFileIsAcceptedWithExactStoredName() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }

        let name = "K사번 채용 발령 인적정보.xlsx".precomposedStringWithCanonicalMapping
        let path = rawChildPath(parentPath: root.path, leafName: name)
        try writeExactFile(Data("xlsx".utf8), to: path)

        let attachment = try SafeMailAttachmentValidator.validate(path: path)

        XCTAssertTrue(attachment.name.utf8.elementsEqual(name.utf8))
        XCTAssertTrue(attachment.path.utf8.elementsEqual(path.utf8))
        XCTAssertEqual(attachment.size, 4)
        XCTAssertEqual(
            attachment.contentType,
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )
    }

    func testNFDFileIsRejectedBeforeGraphUpload() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }

        let nfc = "한글 파일.xlsx".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        XCTAssertFalse(nfd.utf8.elementsEqual(nfc.utf8))

        let path = rawChildPath(parentPath: root.path, leafName: nfd)
        try writeExactFile(Data("xlsx".utf8), to: path)

        XCTAssertThrowsError(try SafeMailAttachmentValidator.validate(path: path)) { error in
            guard case SafeMailError.attachmentNotNFC(let rejectedName) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(rejectedName.utf8.elementsEqual(nfd.utf8))
        }
    }

    func testFolderIsRejectedForDirectMailAttachment() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }

        let folder = root.appendingPathComponent("폴더".precomposedStringWithCanonicalMapping, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)

        XCTAssertThrowsError(try SafeMailAttachmentValidator.validate(path: folder.path)) { error in
            guard case SafeMailError.folderNotSupported = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFileOver150MBIsRejected() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }

        let name = "large.bin"
        let path = rawChildPath(parentPath: root.path, leafName: name)
        try writeExactFile(Data([0]), to: path)

        let oversized = SafeMailAttachmentValidator.maxAttachmentSize + 1
        let result = path.withCString { pointer in
            Darwin.truncate(pointer, off_t(oversized))
        }
        XCTAssertEqual(result, 0)

        XCTAssertThrowsError(try SafeMailAttachmentValidator.validate(path: path)) { error in
            guard case SafeMailError.attachmentTooLarge(let rejectedName, let size) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(rejectedName, name)
            XCTAssertEqual(size, oversized)
        }
    }

    private func makeRoot() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HangulFixSafeMail-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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
            guard let base = rawBuffer.baseAddress else { return }
            var writtenTotal = 0
            while writtenTotal < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: writtenTotal),
                    rawBuffer.count - writtenTotal
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(path: path)
                }
                guard written > 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                writtenTotal += written
            }
        }
    }

    private func posixError(path: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}
