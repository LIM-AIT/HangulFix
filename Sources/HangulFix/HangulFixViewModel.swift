import Foundation
import HangulFixCore

@MainActor
final class HangulFixViewModel: ObservableObject {
    @Published private(set) var selectedURLs: [URL] = []
    @Published private(set) var candidates: [RenameCandidate] = []
    @Published private(set) var windowsCompatibilityIssues: [WindowsCompatibilityIssue] = []
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = "파일 또는 폴더를 선택하세요."
    @Published private(set) var lastFailures: [RenameFailure] = []
    @Published private(set) var lastSuccessCount = 0
    @Published private(set) var lastUndoCount = 0
    @Published private(set) var lastZipURL: URL?
    @Published private(set) var lastZipEntryCount = 0
    @Published private(set) var zipErrorText: String?

    private var lastSucceededCandidates: [RenameCandidate] = []
    private var archiveSourcePath: String?

    var blockedCount: Int {
        candidates.filter(\.isBlocked).count
    }

    var canExecute: Bool {
        !isBusy && !candidates.isEmpty && blockedCount == 0
    }

    var canUndo: Bool {
        !isBusy && !lastSucceededCandidates.isEmpty && lastFailures.isEmpty
    }

    var canCreateZip: Bool {
        !isBusy
            && archiveSourcePath != nil
            && candidates.isEmpty
            && lastFailures.isEmpty
            && windowsCompatibilityIssues.isEmpty
    }

    var hasOperationError: Bool {
        !lastFailures.isEmpty
            || zipErrorText != nil
            || blockedCount > 0
            || !windowsCompatibilityIssues.isEmpty
    }

    var suggestedZipName: String {
        guard let archiveSourcePath else { return "HangulFix.zip" }
        let name = (archiveSourcePath as NSString).lastPathComponent
        return name.isEmpty ? "HangulFix.zip" : name + ".zip"
    }

    func addURLs(_ urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }

        resetLastOperationState()

        var known = Set(selectedURLs.map { Data($0.standardizedFileURL.path.utf8) })
        for url in urls {
            let key = Data(url.standardizedFileURL.path.utf8)
            guard known.insert(key).inserted else { continue }
            selectedURLs.append(url)
        }

        refreshPreview()
    }

    func clear() {
        guard !isBusy else { return }
        selectedURLs = []
        candidates = []
        resetLastOperationState()
        statusText = "파일 또는 폴더를 선택하세요."
    }

    func refreshPreview() {
        guard !isBusy else { return }
        guard !selectedURLs.isEmpty else {
            candidates = []
            windowsCompatibilityIssues = []
            archiveSourcePath = nil
            statusText = "파일 또는 폴더를 선택하세요."
            return
        }

        let roots = selectedURLs
        isBusy = true
        resetLastOperationState()
        statusText = "한글 파일명과 Windows 호환성을 검사하는 중…"

        Task {
            do {
                let scanResult = try await Task.detached(priority: .userInitiated) {
                    let resolvedRoots = try roots.map { try FileSystemEntryResolver.resolve($0) }
                    let renameCandidates = try FileNormalizer().scan(urls: resolvedRoots)
                    let windowsIssues = try WindowsCompatibilityValidator().scan(urls: resolvedRoots)
                    return (resolvedRoots, renameCandidates, windowsIssues)
                }.value

                selectedURLs = scanResult.0
                candidates = scanResult.1
                windowsCompatibilityIssues = scanResult.2

                let blocked = scanResult.1.filter(\.isBlocked).count
                let windowsIssueCount = scanResult.2.count

                if scanResult.1.isEmpty {
                    archiveSourcePath = singleRootPath(from: scanResult.0)

                    if windowsIssueCount > 0 {
                        statusText = "NFC 변환 대상은 없지만 Windows 비호환 파일명 \(windowsIssueCount)개가 발견되었습니다. ZIP 저장은 차단됩니다."
                    } else if archiveSourcePath != nil {
                        statusText = "변환할 파일명이 없습니다. 이미 NFC이며 Windows 파일명 검사도 통과해 ZIP으로 저장할 수 있습니다."
                    } else {
                        statusText = "변환할 파일명이 없습니다. 이미 NFC이며 Windows 파일명 검사도 통과했습니다."
                    }
                } else if blocked > 0 {
                    statusText = "\(scanResult.1.count)개 중 \(blocked)개에서 이름 충돌이 발견되었습니다."
                } else if windowsIssueCount > 0 {
                    statusText = "NFC 변환 대상 \(scanResult.1.count)개와 Windows 비호환 파일명 \(windowsIssueCount)개가 발견되었습니다."
                } else {
                    statusText = "\(scanResult.1.count)개의 이름을 Windows 호환 NFC로 변환할 수 있으며 Windows 파일명 검사도 통과했습니다."
                }
            } catch {
                candidates = []
                windowsCompatibilityIssues = []
                archiveSourcePath = nil
                statusText = "검사 실패: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    func execute() {
        guard canExecute else { return }

        let items = candidates
        let roots = selectedURLs
        isBusy = true
        resetLastOperationState(clearWindowsIssues: false)
        statusText = "파일명을 변환하는 중…"

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FileNormalizer().execute(items)
            }.value

            lastFailures = result.failures
            candidates = []
            selectedURLs = []

            if result.failures.isEmpty {
                lastSucceededCandidates = result.succeeded
                lastSuccessCount = result.succeeded.count
                archiveSourcePath = resolvedConvertedRootPath(
                    roots: roots,
                    candidates: items
                )

                if !windowsCompatibilityIssues.isEmpty {
                    statusText = "NFC 변환 완료: \(result.succeeded.count)개를 확인했습니다. Windows 비호환 이름 \(windowsCompatibilityIssues.count)개가 있어 ZIP 저장은 차단됩니다."
                } else if archiveSourcePath != nil {
                    statusText = "완료: \(result.succeeded.count)개의 이름을 NFC로 변환하고 Windows 파일명 검사까지 통과했습니다. ZIP 저장도 가능합니다."
                } else {
                    statusText = "완료: \(result.succeeded.count)개의 이름을 NFC로 변환하고 실제 저장 상태까지 확인했습니다."
                }
            } else if result.rolledBackCount > 0, result.succeeded.isEmpty {
                statusText = "변환 중 오류로 작업을 중단했고, 이전 \(result.rolledBackCount)개 변경을 원래 이름으로 되돌렸습니다. 실패 항목을 확인해 주세요."
            } else if result.rolledBackCount > 0 {
                statusText = "변환 중 오류로 작업을 중단했습니다. \(result.rolledBackCount)개는 되돌렸지만 \(result.succeeded.count)개는 롤백하지 못했습니다. 실패 항목을 확인해 주세요."
            } else {
                statusText = "\(result.succeeded.count)개 성공, \(result.failures.count)개 실패했습니다. 실패 항목을 확인한 뒤 다시 선택해 주세요."
            }

            isBusy = false
        }
    }

    func createZip(at destinationURL: URL) {
        guard canCreateZip, let sourcePath = archiveSourcePath else { return }

        isBusy = true
        zipErrorText = nil
        lastZipURL = nil
        lastZipEntryCount = 0
        statusText = "Windows용 ZIP을 만들고 내부 파일명을 검증하는 중…"

        Task {
            do {
                let verification = try await Task.detached(priority: .userInitiated) {
                    let resolvedSourcePath = try FileSystemEntryResolver.resolvePath(sourcePath)
                    return try ZipArchiveService().createVerifiedArchive(
                        sourcePath: resolvedSourcePath,
                        destinationURL: destinationURL
                    )
                }.value

                lastZipURL = destinationURL
                lastZipEntryCount = verification.entryCount
                statusText = "ZIP 완료: 내부 \(verification.entryCount)개 entry가 UTF-8 NFC 및 Windows 파일명 규칙을 통과했습니다."
            } catch {
                zipErrorText = error.localizedDescription
                statusText = "ZIP 생성 실패: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    func undoLastConversion() {
        guard canUndo else { return }

        let items = lastSucceededCandidates
        isBusy = true
        lastFailures = []
        lastUndoCount = 0
        archiveSourcePath = nil
        zipErrorText = nil
        windowsCompatibilityIssues = []
        statusText = "마지막 변환을 원래 파일명으로 되돌리는 중…"

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FileNormalizer().undo(items)
            }.value

            lastFailures = result.failures
            lastSuccessCount = 0
            lastSucceededCandidates = []
            candidates = []
            selectedURLs = []

            if result.failures.isEmpty {
                lastUndoCount = result.undone.count
                statusText = "실행 취소 완료: \(result.undone.count)개의 이름을 변환 전 상태로 복원했습니다."
            } else if result.reappliedCount > 0, result.undone.isEmpty {
                statusText = "실행 취소 중 오류가 발생해 작업을 중단했고, 이미 되돌린 \(result.reappliedCount)개 항목은 다시 NFC 상태로 복구했습니다."
            } else if result.reappliedCount > 0 {
                statusText = "실행 취소 중 오류가 발생했습니다. 일부 항목은 원래 이름으로 남아 있을 수 있으니 실패 목록을 확인해 주세요."
            } else {
                statusText = "실행 취소에 실패했습니다. 실패 항목을 확인한 뒤 다시 검사해 주세요."
            }

            isBusy = false
        }
    }

    private func singleRootPath(from roots: [URL]) -> String? {
        guard roots.count == 1 else { return nil }
        return roots[0].path
    }

    private func resolvedConvertedRootPath(
        roots: [URL],
        candidates: [RenameCandidate]
    ) -> String? {
        guard roots.count == 1 else { return nil }

        let rootPath = roots[0].path
        let rootKey = Data(rootPath.utf8)

        guard let rootCandidate = candidates.first(where: {
            Data($0.sourceURL.path.utf8) == rootKey
        }) else {
            return rootPath
        }

        let parentPath = rootCandidate.sourceURL.deletingLastPathComponent().path
        return parentPath == "/"
            ? "/" + rootCandidate.targetName
            : parentPath + "/" + rootCandidate.targetName
    }

    private func resetLastOperationState(clearWindowsIssues: Bool = true) {
        lastFailures = []
        lastSuccessCount = 0
        lastUndoCount = 0
        lastSucceededCandidates = []
        archiveSourcePath = nil
        lastZipURL = nil
        lastZipEntryCount = 0
        zipErrorText = nil
        if clearWindowsIssues {
            windowsCompatibilityIssues = []
        }
    }
}
