import SwiftUI
import AppKit

// MARK: - App entry

@main
struct FFmpegGUIApp: App {
    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in FFmpegRunner.terminateAll() }
    }

    var body: some Scene {
        WindowGroup("Simple Video") {
            ContentView()
                .frame(minWidth: 920, minHeight: 580)
        }
        .windowResizability(.contentMinSize)
    }
}
