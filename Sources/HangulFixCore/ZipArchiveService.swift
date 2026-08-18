import Darwin
import Foundation

public struct ZipArchiveVerification: Sendable, Equatable {
    public let entryCount: Int
    public let entryNames: [String]

    public init(entryCount: Int, entryNames: [String]) {
        self.entryCount = entryCount
        self.entryNames = entryNames
    }
}

public struct ZipArchiveService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Creates a Windows-oriented ZIP for one already-normalized file or folder.
    /// macOS `ditto` writes UTF-8 filename bytes but does not reliably set ZIP's
    /// language-encoding flag. HangulFix patches that flag in both local and
    /// central headers, verifies the archive byte-for-byte, then atomically
    /// publishes the final ZIP.
    @discardableResult
    public func createVerifiedArchive(
        sourcePath: String,
        destinationURL: URL
    ) throws -> ZipArchiveVerification {
        guard pathExists(sourcePath) else {
            throw ZipArchiveError.sourceMissing(sourcePath)
        }

        let sourceIsDirectory = try verifySourceTreeIsNFC(sourcePath: sourcePath)

        let destinationPath = destinationURL.path
        let parentPath = destinationURL.deletingLastPathComponent().path
        guard pathExists(parentPath) else {
            throw ZipArchiveError.destinationParentMissing(parentPath)
        }

        let temporaryPath = rawChildPath(
            parentPath: parentPath,
            leafName: ".hangulfix-zip-\(UUID().uuidString).zip"
        )
        defer { try? fileManager.removeItem(atPath: temporaryPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")

        var arguments = ["-c", "-k", "--norsrc"]
        if sourceIsDirectory {
            arguments.append("--keepParent")
        }
        arguments.append(sourcePath)
        arguments.append(temporaryPath)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            throw ZipArchiveError.creationFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw ZipArchiveError.creationFailed(
                outputText.isEmpty
                    ? "ditto 종료 코드 \(process.terminationStatus)"
                    : outputText
            )
        }

        try markUTF8FilenameFlags(atPath: temporaryPath)
        let verification = try verifyArchive(atPath: temporaryPath)
        try atomicRename(from: temporaryPath, to: destinationPath)
        return verification
    }

    public func verifyArchive(at url: URL) throws -> ZipArchiveVerification {
        try verifyArchive(atPath: url.path)
    }

    /// Returns whether the source itself is a directory after validating every
    /// filename component without following symbolic links.
    private func verifySourceTreeIsNFC(sourcePath: String) throws -> Bool {
        let sourceName = (sourcePath as NSString).lastPathComponent
        if FileNormalizer.needsNFCNormalization(sourceName) {
            throw ZipArchiveError.sourceContainsNonNFC(sourceName)
        }
        try verifyWindowsName(sourceName, displayPath: sourceName)

        var info = stat()
        let statResult = sourcePath.withCString { pointer in
            Darwin.lstat(pointer, &info)
        }
        guard statResult == 0 else {
            throw posixError(path: sourcePath)
        }

        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        if isDirectory {
            try verifyDirectoryTreeIsNFC(directoryPath: sourcePath, relativePrefix: "")
        }
        return isDirectory
    }

    private func verifyDirectoryTreeIsNFC(
        directoryPath: String,
        relativePrefix: String
    ) throws {
        let names = try fileManager.contentsOfDirectory(atPath: directoryPath)

        for name in names {
            let relativePath = relativePrefix.isEmpty
                ? name
                : relativePrefix + "/" + name

            if FileNormalizer.needsNFCNormalization(name) {
                throw ZipArchiveError.sourceContainsNonNFC(relativePath)
            }
            try verifyWindowsName(name, displayPath: relativePath)

            let childPath = rawChildPath(parentPath: directoryPath, leafName: name)
            var info = stat()
            let result = childPath.withCString { pointer in
                Darwin.lstat(pointer, &info)
            }
            guard result == 0 else {
                throw posixError(path: childPath)
            }

            // Never follow symbolic links while validating the source tree.
            if (info.st_mode & S_IFMT) == S_IFDIR {
                try verifyDirectoryTreeIsNFC(
                    directoryPath: childPath,
                    relativePrefix: relativePath
                )
            }
        }
    }

    private func verifyWindowsName(_ name: String, displayPath: String) throws {
        if let problem = WindowsCompatibilityValidator.problems(in: name).first {
            throw ZipArchiveError.sourceContainsWindowsIncompatible(
                path: displayPath,
                reason: problem.message
            )
        }
    }

    private func markUTF8FilenameFlags(atPath archivePath: String) throws {
        let parsed = try parseCentralDirectory(atPath: archivePath)
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: archivePath))
        defer { try? handle.close() }

        for entry in parsed.entries {
            try validateArchiveEntry(
                name: entry.name,
                rawName: entry.rawName,
                usesUTF8Flag: true,
                requireUTF8Flag: false
            )

            let centralFlags = entry.flags | 0x0800
            try writeUInt16(
                centralFlags,
                to: handle,
                at: parsed.centralOffset + UInt64(entry.centralFlagOffset)
            )

            let localOffset = UInt64(entry.localHeaderOffset)
            try handle.seek(toOffset: localOffset)
            guard let localHeader = try handle.read(upToCount: 30),
                  localHeader.count == 30,
                  try readUInt32(localHeader, at: 0) == 0x0403_4B50 else {
                throw ZipArchiveError.invalidArchive("Local file header가 손상되었습니다: \(entry.name)")
            }

            let localFlags = try readUInt16(localHeader, at: 6)
            let localNameLength = Int(try readUInt16(localHeader, at: 26))
            let localExtraLength = Int(try readUInt16(localHeader, at: 28))
            guard localNameLength == entry.rawName.count else {
                throw ZipArchiveError.invalidArchive("Local/Central filename 길이가 다릅니다: \(entry.name)")
            }

            try handle.seek(toOffset: localOffset + 30)
            guard let localName = try handle.read(upToCount: localNameLength),
                  localName.count == localNameLength,
                  localName == entry.rawName else {
                throw ZipArchiveError.invalidArchive("Local/Central filename bytes가 다릅니다: \(entry.name)")
            }

            let localEnd = localOffset
                + 30
                + UInt64(localNameLength)
                + UInt64(localExtraLength)
            guard localEnd <= parsed.fileSize else {
                throw ZipArchiveError.invalidArchive("Local file header 범위가 올바르지 않습니다: \(entry.name)")
            }

            try writeUInt16(localFlags | 0x0800, to: handle, at: localOffset + 6)
        }

        try handle.synchronize()
    }

    private func verifyArchive(atPath archivePath: String) throws -> ZipArchiveVerification {
        let parsed = try parseCentralDirectory(atPath: archivePath)
        var names: [String] = []
        names.reserveCapacity(parsed.entries.count)

        for entry in parsed.entries {
            try validateArchiveEntry(
                name: entry.name,
                rawName: entry.rawName,
                usesUTF8Flag: (entry.flags & 0x0800) != 0,
                requireUTF8Flag: true
            )
            names.append(entry.name)
        }

        return ZipArchiveVerification(entryCount: names.count, entryNames: names)
    }

    private func parseCentralDirectory(atPath archivePath: String) throws -> ParsedCentralDirectory {
        guard pathExists(archivePath) else {
            throw ZipArchiveError.archiveMissing(archivePath)
        }

        let attributes = try fileManager.attributesOfItem(atPath: archivePath)
        guard let fileSizeNumber = attributes[.size] as? NSNumber else {
            throw ZipArchiveError.invalidArchive("ZIP 파일 크기를 확인할 수 없습니다.")
        }

        let fileSize = fileSizeNumber.uint64Value
        guard fileSize >= 22 else {
            throw ZipArchiveError.invalidArchive("ZIP End of Central Directory가 없습니다.")
        }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: archivePath))
        defer { try? handle.close() }

        let maxEOCDSearch = UInt64(65_535 + 22)
        let tailSize = min(fileSize, maxEOCDSearch)
        try handle.seek(toOffset: fileSize - tailSize)
        guard let tail = try handle.read(upToCount: Int(tailSize)) else {
            throw ZipArchiveError.invalidArchive("ZIP 끝부분을 읽을 수 없습니다.")
        }

        guard let eocdOffset = lastSignatureOffset(
            signature: [0x50, 0x4B, 0x05, 0x06],
            in: tail
        ) else {
            throw ZipArchiveError.invalidArchive("ZIP End of Central Directory를 찾지 못했습니다.")
        }

        let diskNumber = try readUInt16(tail, at: eocdOffset + 4)
        let centralDisk = try readUInt16(tail, at: eocdOffset + 6)
        let entriesOnDisk = try readUInt16(tail, at: eocdOffset + 8)
        let totalEntries = try readUInt16(tail, at: eocdOffset + 10)
        let centralSize32 = try readUInt32(tail, at: eocdOffset + 12)
        let centralOffset32 = try readUInt32(tail, at: eocdOffset + 16)

        guard diskNumber == 0, centralDisk == 0, entriesOnDisk == totalEntries else {
            throw ZipArchiveError.invalidArchive("분할 ZIP은 지원하지 않습니다.")
        }

        guard totalEntries != 0xFFFF,
              centralSize32 != 0xFFFF_FFFF,
              centralOffset32 != 0xFFFF_FFFF else {
            throw ZipArchiveError.unsupportedZip64
        }

        let centralSize = UInt64(centralSize32)
        let centralOffset = UInt64(centralOffset32)
        guard centralOffset <= fileSize,
              centralSize <= fileSize,
              centralOffset + centralSize <= fileSize,
              centralSize <= UInt64(Int.max) else {
            throw ZipArchiveError.invalidArchive("Central Directory 범위가 올바르지 않습니다.")
        }

        try handle.seek(toOffset: centralOffset)
        guard let central = try handle.read(upToCount: Int(centralSize)),
              central.count == Int(centralSize) else {
            throw ZipArchiveError.invalidArchive("Central Directory를 끝까지 읽지 못했습니다.")
        }

        var cursor = 0
        var entries: [ParsedCentralEntry] = []
        entries.reserveCapacity(Int(totalEntries))

        for _ in 0..<Int(totalEntries) {
            guard cursor + 46 <= central.count,
                  try readUInt32(central, at: cursor) == 0x0201_4B50 else {
                throw ZipArchiveError.invalidArchive("Central Directory entry가 손상되었습니다.")
            }

            let flags = try readUInt16(central, at: cursor + 8)
            let nameLength = Int(try readUInt16(central, at: cursor + 28))
            let extraLength = Int(try readUInt16(central, at: cursor + 30))
            let commentLength = Int(try readUInt16(central, at: cursor + 32))
            let localHeaderOffset = try readUInt32(central, at: cursor + 42)
            guard localHeaderOffset != 0xFFFF_FFFF else {
                throw ZipArchiveError.unsupportedZip64
            }

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            let next = nameEnd + extraLength + commentLength

            guard nameEnd <= central.count, next <= central.count else {
                throw ZipArchiveError.invalidArchive("Central Directory filename 범위가 손상되었습니다.")
            }

            let rawName = central.subdata(in: nameStart..<nameEnd)
            guard let name = String(data: rawName, encoding: .utf8) else {
                throw ZipArchiveError.invalidUTF8Entry
            }

            entries.append(
                ParsedCentralEntry(
                    name: name,
                    rawName: rawName,
                    flags: flags,
                    centralFlagOffset: cursor + 8,
                    localHeaderOffset: localHeaderOffset
                )
            )
            cursor = next
        }

        return ParsedCentralDirectory(
            fileSize: fileSize,
            centralOffset: centralOffset,
            entries: entries
        )
    }

    private func validateArchiveEntry(
        name: String,
        rawName: Data,
        usesUTF8Flag: Bool,
        requireUTF8Flag: Bool
    ) throws {
        guard !name.isEmpty, !name.contains("\0") else {
            throw ZipArchiveError.unsafeEntry(name)
        }

        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        if name.hasPrefix("/") || components.contains(where: { $0 == ".." }) {
            throw ZipArchiveError.unsafeEntry(name)
        }

        if name == "__MACOSX" || name.hasPrefix("__MACOSX/") {
            throw ZipArchiveError.macMetadataEntry(name)
        }

        for component in components where !component.isEmpty {
            let componentName = String(component)
            if let problem = WindowsCompatibilityValidator.problems(in: componentName).first {
                throw ZipArchiveError.windowsIncompatibleEntry(
                    name: name,
                    reason: problem.message
                )
            }
        }

        let normalized = name.precomposedStringWithCanonicalMapping
        guard rawName.elementsEqual(normalized.utf8) else {
            throw ZipArchiveError.nonNFCEntry(name)
        }

        let containsNonASCII = rawName.contains { $0 >= 0x80 }
        if requireUTF8Flag && containsNonASCII && !usesUTF8Flag {
            throw ZipArchiveError.unmarkedUTF8Entry(name)
        }
    }

    private func lastSignatureOffset(signature: [UInt8], in data: Data) -> Int? {
        guard data.count >= signature.count else { return nil }

        var index = data.count - signature.count
        while true {
            var matches = true
            for offset in 0..<signature.count where data[index + offset] != signature[offset] {
                matches = false
                break
            }
            if matches { return index }
            if index == 0 { break }
            index -= 1
        }
        return nil
    }

    private func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw ZipArchiveError.invalidArchive("ZIP UInt16 범위 오류")
        }
        return UInt16(data[offset])
            | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw ZipArchiveError.invalidArchive("ZIP UInt32 범위 오류")
        }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func writeUInt16(_ value: UInt16, to handle: FileHandle, at offset: UInt64) throws {
        let data = Data([
            UInt8(value & 0x00FF),
            UInt8((value >> 8) & 0x00FF)
        ])
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }

    private func rawChildPath(parentPath: String, leafName: String) -> String {
        parentPath == "/" ? "/" + leafName : parentPath + "/" + leafName
    }

    private func pathExists(_ path: String) -> Bool {
        var info = stat()
        return path.withCString { pointer in
            Darwin.lstat(pointer, &info)
        } == 0
    }

    private func atomicRename(from sourcePath: String, to destinationPath: String) throws {
        let result = sourcePath.withCString { sourcePointer in
            destinationPath.withCString { destinationPointer in
                Darwin.rename(sourcePointer, destinationPointer)
            }
        }

        guard result == 0 else {
            throw posixError(path: destinationPath)
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

private struct ParsedCentralDirectory {
    let fileSize: UInt64
    let centralOffset: UInt64
    let entries: [ParsedCentralEntry]
}

private struct ParsedCentralEntry {
    let name: String
    let rawName: Data
    let flags: UInt16
    let centralFlagOffset: Int
    let localHeaderOffset: UInt32
}

public enum ZipArchiveError: LocalizedError, Equatable {
    case sourceMissing(String)
    case sourceContainsNonNFC(String)
    case sourceContainsWindowsIncompatible(path: String, reason: String)
    case destinationParentMissing(String)
    case creationFailed(String)
    case archiveMissing(String)
    case invalidArchive(String)
    case unsupportedZip64
    case invalidUTF8Entry
    case nonNFCEntry(String)
    case unmarkedUTF8Entry(String)
    case unsafeEntry(String)
    case macMetadataEntry(String)
    case windowsIncompatibleEntry(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            return "ZIP으로 만들 원본을 찾을 수 없습니다: \(path)"
        case .sourceContainsNonNFC(let path):
            return "ZIP 생성 전에 NFC 변환이 필요한 항목이 남아 있습니다: \(path)"
        case .sourceContainsWindowsIncompatible(let path, let reason):
            return "Windows에서 안전하지 않은 파일명이 있어 ZIP 생성을 중단했습니다: \(path) (\(reason))"
        case .destinationParentMissing(let path):
            return "ZIP 저장 폴더를 찾을 수 없습니다: \(path)"
        case .creationFailed(let reason):
            return "ZIP 생성에 실패했습니다: \(reason)"
        case .archiveMissing(let path):
            return "ZIP 파일을 찾을 수 없습니다: \(path)"
        case .invalidArchive(let reason):
            return "ZIP 구조 검증에 실패했습니다: \(reason)"
        case .unsupportedZip64:
            return "현재 버전에서는 ZIP64 형식 검증을 지원하지 않습니다."
        case .invalidUTF8Entry:
            return "ZIP 내부에 UTF-8로 해석할 수 없는 파일명이 있습니다."
        case .nonNFCEntry(let name):
            return "ZIP 내부 파일명이 NFC가 아닙니다: \(name)"
        case .unmarkedUTF8Entry(let name):
            return "ZIP 내부의 비 ASCII 파일명이 UTF-8로 표시되지 않았습니다: \(name)"
        case .unsafeEntry(let name):
            return "ZIP 내부에 안전하지 않은 경로가 있습니다: \(name)"
        case .macMetadataEntry(let name):
            return "Windows용 ZIP에 macOS 메타데이터 항목이 포함되었습니다: \(name)"
        case .windowsIncompatibleEntry(let name, let reason):
            return "ZIP 내부에 Windows 비호환 파일명이 있습니다: \(name) (\(reason))"
        }
    }
}
