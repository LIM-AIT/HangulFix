import SwiftUI

@main
struct HangulFixApp: App {
    var body: some Scene {
        WindowGroup {
            HangulFixRootView()
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)
    }
}

private struct HangulFixRootView: View {
    @State private var showingSafeMail = false

    var body: some View {
        ContentView()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSafeMail = true
                    } label: {
                        Label("Outlook 안전 첨부", systemImage: "envelope.badge.shield.half.filled")
                    }
                    .help("ZIP 없이 NFC 한글 파일명을 유지한 Outlook 초안을 만들고 서버 저장 이름을 검증합니다.")
                }
            }
            .sheet(isPresented: $showingSafeMail) {
                SafeMailComposerView()
            }
    }
}
