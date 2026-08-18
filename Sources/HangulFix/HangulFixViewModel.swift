import Foundation
import HangulFixCore

@MainActor
final class HangulFixViewModel: ObservableObject {
    @Published private(set) var selectedURLs: [URL] = []
    @Published private(set) var candidates: [RenameCandidate] = []
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = "파일 또는 폴더를 선택하세요."
    @Published private(set) var lastFailures: [RenameFailure] = []

    var blockedCount: Int {
        candidates.filter(\.isBlocked).count
    }

    var canExecute: Bool {
        !isBusy && !candidates.isEmpty && blockedCount == 0
    }

    func addURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        var known = Set(selectedURLs.map { $0.standardizedFileURL.path })
        for url in urls where known.insert(url.standardizedFileURL.path).inserted {
            selectedURLs.append(url)
        }

        refreshPreview()
    }

    func clear() {
        selectedURLs = []
        candidates = []
        lastFailures = []
        statusText = "파일 또는 폴더를 선택하세요."
    }

    func refreshPreview() {
        guard !selectedURLs.isEmpty else {
            candidates = []
            statusText = "파일 또는 폴더를 선택하세요."
            return
        }

        let roots = selectedURLs
        isBusy = true
        lastFailures = []
        statusText = "한글 파일명을 검사하는 중…"

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FileNormalizer().scan(urls: roots)
                }.value

                candidates = result
                if result.isEmpty {
                    statusText = "변환할 파일명이 없습니다. 이미 NFC 형식입니다."
                } else if blockedCount > 0 {
                    statusText = "\(result.count)개 중 \(blockedCount)개에서 이름 충돌이 발견되었습니다."
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
        lastFailures = []
        statusText = "파일명을 변환하는 중…"

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FileNormalizer().execute(items)
            }.value

            lastFailures = result.failures

            if result.failures.isEmpty {
                statusText = "완료: \(result.succeeded.count)개의 이름을 NFC로 변환했습니다."
                selectedURLs = []
                candidates = []
            } else {
                statusText = "\(result.succeeded.count)개 성공, \(result.failures.count)개 실패했습니다."
                // Re-scan any paths that still exist so the user can retry safely.
                selectedURLs = selectedURLs.filter {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                refreshPreview()
            }

            isBusy = false
        }
    }
}
