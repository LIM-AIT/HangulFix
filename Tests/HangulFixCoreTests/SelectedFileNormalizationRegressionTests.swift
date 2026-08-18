import Darwin
import XCTest
@testable import HangulFixCore

final class SelectedFileNormalizationRegressionTests: XCTestCase {
    private let fileManager = FileManager.default

    func testCanonicalAliasResolvesActualStoredNameThenConvertsAndZips() throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HangulFixSelectedFileRegression-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let nfc = "K사번 채용 발령 인적정보.xlsx".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        XCTAssertFalse(nfd.utf8.elementsEqual(nfc.utf8))

        let nfdPath = rawChildPath(parentPath: root.path, leafName: nfd)
        let nfcAliasPath = rawChildPath(parentPath: root.path, leafName: nfc)
        try writeExactFile(Data("xlsx-fixture".utf8), to: nfdPath)
        XCTAssertTrue(try exactNameExists(nfd, in: root))

        // APFS can resolve an NFC path alias to an entry whose stored bytes are NFD.
        // This mirrors Finder/NSOpenPanel handing the app a canonically equivalent
        // URL spelling rather than the exact directory-entry spelling.
        guard pathExists(nfcAliasPath) else {
            throw XCTSkip("The test filesystem does not resolve canonical Unicode aliases like APFS.")
        }

        let selectedAliasURL = URL(fileURLWithPath: nfcAliasPath)
        let resolvedSelection = try FileSystemEntryResolver.resolve(selectedAliasURL)
        let resolvedSelectionName = (resolvedSelection.path as NSString).lastPathComponent
        XCTAssertTrue(resolvedSelectionName.utf8.elementsEqual(nfd.utf8))

        let normalizer = FileNormalizer()
        let candidates = try normalizer.scan(urls: [resolvedSelection])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].sourceName.utf8.elementsEqual(nfd.utf8))
        XCTAssertTrue(candidates[0].targetName.utf8.elementsEqual(nfc.utf8))

        let result = normalizer.execute(candidates)
        XCTAssertTrue(result.failures.isEmpty, result.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertTrue(try exactNameExists(nfc, in: root))
        XCTAssertFalse(try exactNameExists(nfd, in: root))

        // Selecting the same file again after conversion is the key regression.
        // APFS can still resolve the old NFD alias, but HangulFix must resolve that
        // alias back to the now-stored NFC directory entry and report no candidate.
        guard pathExists(nfdPath) else {
            throw XCTSkip("The test filesystem does not preserve canonical aliases after rename.")
        }

        let staleAliasURL = URL(fileURLWithPath: nfdPath)
        let resolvedAgain = try FileSystemEntryResolver.resolve(staleAliasURL)
        let resolvedAgainName = (resolvedAgain.path as NSString).lastPathComponent
        XCTAssertTrue(resolvedAgainName.utf8.elementsEqual(nfc.utf8))

        let candidatesAgain = try normalizer.scan(urls: [resolvedAgain])
        XCTAssertTrue(
            candidatesAgain.isEmpty,
            "An already-converted NFC file must not be offered for conversion again."
        )

        // ZIP must likewise resolve the stale alias to the actual NFC entry.
        let resolvedAfterConversion = try FileSystemEntryResolver.resolvePath(nfdPath)
        let resolvedAfterName = (resolvedAfterConversion as NSString).lastPathComponent
        XCTAssertTrue(resolvedAfterName.utf8.elementsEqual(nfc.utf8))

        let zipURL = root.appendingPathComponent("attachment.zip")
        let verification = try ZipArchiveService().createVerifiedArchive(
            sourcePath: resolvedAfterConversion,
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

    private func pathExists(_ path: String) -> Bool {
        var info = stat()
        return path.withCString { pointer in
            Darwin.lstat(pointer, &info)
        } == 0
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
