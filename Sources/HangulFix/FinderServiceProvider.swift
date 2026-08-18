import AppKit
import Foundation

@MainActor
final class FinderServiceBridge {
    static let shared = FinderServiceBridge()
    static let didReceiveURLs = Notification.Name("HangulFixFinderServiceDidReceiveURLs")

    private var pendingURLs: [URL] = []

    private init() {}

    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        pendingURLs = urls
        NotificationCenter.default.post(name: Self.didReceiveURLs, object: nil)

        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
    }

    func consumePendingURLs() -> [URL] {
        let urls = pendingURLs
        pendingURLs = []
        return urls
    }
}

final class FinderServiceProvider: NSObject {
    @objc(openInHangulFix:userData:error:)
    func openInHangulFix(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []

        let urls = objects.compactMap { object -> URL? in
            guard let nsURL = object as? NSURL else { return nil }
            let url = nsURL as URL
            guard url.isFileURL else { return nil }
            return url.standardizedFileURL
        }

        guard !urls.isEmpty else {
            error.pointee = "Finder에서 파일 또는 폴더를 선택한 뒤 다시 실행해 주세요." as NSString
            return
        }

        Task { @MainActor in
            FinderServiceBridge.shared.enqueue(urls)
        }
    }
}
