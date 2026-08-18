import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let finderServiceProvider = FinderServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = finderServiceProvider
        NSUpdateDynamicServices()
    }
}

@main
struct HangulFixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)
    }
}
