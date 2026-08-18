import SwiftUI

@main
struct HangulFixApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)
    }
}
