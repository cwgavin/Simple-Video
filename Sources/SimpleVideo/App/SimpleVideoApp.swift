import SwiftUI
import AppKit

// MARK: - App entry

@main
struct SimpleVideoApp: App {
    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            FFmpegRunner.terminateAll()
            CropPreviewArtifacts.cleanupAll()
        }
    }

    var body: some Scene {
        WindowGroup("Simple Video") {
            ContentView()
                .frame(minWidth: 920, minHeight: 580)
        }
        .windowResizability(.contentMinSize)
    }
}
