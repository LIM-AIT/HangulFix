import Foundation
import HangulFixCore

@MainActor
final class HangulFixViewModel: ObservableObject {
    @Published private(set) var selectedURLs: [URL] = []
    @Published private(set) var candidates: [RenameCandidate] = []
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = "파일 또는 폴더를 선택하세요."
    @Published private(set) var lastFailures: [RenameFailure] = []
    @Published private(set) var lastSuccessCount = 0
    @Published private(set) var lastUndoCount = 0

    private var lastSucceededCandidates: [RenameCandidate] = []

    var blockedCount: Int {
        candidates.filter(\.isBlocked).count
    }

    var canExecute: Bool {
        !isBusy && !candidates.isEmpty && blockedCount == 0
    }

    var canUndo: Bool {
        !isBusy && !lastSucceededCandidates.isEmpty && lastFailures.isEmpty
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
            statusText = "파일 또는 폴더를 선택하세요."
            return
        }

        let roots = selectedURLs
        isBusy = true
        resetLastOperationState()
        statusText = "한글 파일명을 검사하는 중…"

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FileNormalizer().scan(urls: roots)
                }.value

                candidates = result
                let blocked = result.filter(\.isBlocked).count

                if result.isEmpty {
                    statusText = "변환할 파일명이 없습니다. 이미 NFC 형식입니다."
                } else if blocked > 0 {
                    statusText = "\(result.count)개 중 \(blocked)개에서 이름 충돌이 발견되었습니다."
                } else {
                    statusText = "\(result.count)개의 파일/폴더 이름을 Windows 호환 NFC로 변환할 수 있습니다."
                }
            } catch {
                candidates = []
                statusText = "검사 실패: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    func execute() {
        guard canExecute else { return }

        let items = candidates
        isBusy = true
        resetLastOperationState()
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
                statusText = "완료: \(result.succeeded.count)개의 이름을 NFC로 변환하고 실제 저장 상태까지 확인했습니다."
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

    func undoLastConversion() {
        guard canUndo else { return }

        let items = lastSucceededCandidates
        isBusy = true
        lastFailures = []
        lastUndoCount = 0
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

    private func resetLastOperationState() {
        lastFailures = []
        lastSuccessCount = 0
        lastUndoCount = 0
        lastSucceededCandidates = []
    }
}
