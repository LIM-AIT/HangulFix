import Darwin
import XCTest
@testable import HangulFixCore

final class SelectedFileNormalizationRegressionTests: XCTestCase {
    private let fileManager = FileManager.default

    func testDirectlySelectedNFDFileIsDetectedConvertedAndZipped() throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HangulFixSelectedFileRegression-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let nfc = "K사번 채용 발령 인적정보.xlsx".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        XCTAssertFalse(nfd.utf8.elementsEqual(nfc.utf8))

        let sourcePath = rawChildPath(parentPath: root.path, leafName: nfd)
        try writeExactFile(Data("xlsx-fixture".utf8), to: sourcePath)
        XCTAssertTrue(try exactNameExists(nfd, in: root))

        // This is the important regression path: the user selects the file itself,
        // rather than selecting its parent folder and finding it via enumeration.
        let selectedURL = URL(fileURLWithPath: sourcePath)
        let normalizer = FileNormalizer()
        let candidates = try normalizer.scan(urls: [selectedURL])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].sourceName.utf8.elementsEqual(nfd.utf8))
        XCTAssertTrue(candidates[0].targetName.utf8.elementsEqual(nfc.utf8))

        let result = normalizer.execute(candidates)
        XCTAssertTrue(result.failures.isEmpty, result.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertTrue(try exactNameExists(nfc, in: root))
        XCTAssertFalse(try exactNameExists(nfd, in: root))

        let convertedPath = rawChildPath(parentPath: root.path, leafName: nfc)
        let zipURL = root.appendingPathComponent("attachment.zip")
        let verification = try ZipArchiveService().createVerifiedArchive(
            sourcePath: convertedPath,
            destinationURL: zipURL
        )

        XCTAssertEqual(verification.entryCount, 1)
        XCTAssertEqual(verification.entryNames.count, 1)
        XCTAssertTrue(verification.entryNames[0].utf8.elementsEqual(nfc.utf8))
    }

    private func rawChildPath(parentPath: String, leafName: String) -> String {
        parentPath == "/" ? "/" + leafName : parentPath + "/" + leafName
    }

    private func exactNameExists(_ expectedName: String, in directory: URL) throws -> Bool {
        try fileManager.contentsOfDirectory(atPath: directory.path).contains { name in
            name.utf8.elementsEqual(expectedName.utf8)
        }
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
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
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
