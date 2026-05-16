import SwiftUI
import AppKit

// MARK: - App entry

final class SimpleVideoAppDelegate: NSObject, NSApplicationDelegate {
    weak var cropSession: CropVideoSession?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard cropSession?.hasPendingChanges == true else {
            return .terminateNow
        }

        let language = AppLanguage.current
        let alert = NSAlert()
        alert.messageText = L.text(
            language,
            "Quit and lose crop changes?",
            "要退出并丢失裁剪修改吗？"
        )
        alert.informativeText = L.text(
            language,
            "The Crop Video page has unsaved changes for the current video. If you quit now, those changes will be lost.",
            "裁剪视频页面当前有尚未保存的修改。现在退出会丢失这些修改。"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L.text(language, "Quit", "退出"))
        alert.addButton(withTitle: L.text(language, "Cancel", "取消"))

        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        FFmpegRunner.terminateAll()
        CropPreviewArtifacts.cleanupAll()
    }
}

@main
struct SimpleVideoApp: App {
    @NSApplicationDelegateAdaptor(SimpleVideoAppDelegate.self) private var appDelegate
    @StateObject private var cropSession = CropVideoSession()

    var body: some Scene {
        WindowGroup("Simple Video") {
            ContentView(cropSession: cropSession)
                .frame(minWidth: 920, minHeight: 580)
                .onAppear {
                    appDelegate.cropSession = cropSession
                }
        }
        .windowResizability(.contentMinSize)
    }
}
