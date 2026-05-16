import SwiftUI
import AppKit

// MARK: - App entry

final class SimpleVideoAppDelegate: NSObject, NSApplicationDelegate {
    weak var cropSession: CropVideoSession?
    weak var cropAudioSession: CropAudioSession?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasPendingVideoChanges = cropSession?.hasPendingChanges == true
        let hasPendingAudioChanges = cropAudioSession?.hasPendingChanges == true

        guard hasPendingVideoChanges || hasPendingAudioChanges else {
            return .terminateNow
        }

        let language = AppLanguage.current
        let alert = NSAlert()
        alert.messageText = L.text(
            language,
            hasPendingVideoChanges && hasPendingAudioChanges
                ? "Quit and lose crop changes?"
                : (hasPendingVideoChanges ? "Quit and lose video crop changes?" : "Quit and lose audio crop changes?"),
            hasPendingVideoChanges && hasPendingAudioChanges
                ? "要退出并丢失裁剪修改吗？"
                : (hasPendingVideoChanges ? "要退出并丢失视频裁剪修改吗？" : "要退出并丢失音频裁剪修改吗？")
        )
        alert.informativeText = L.text(
            language,
            hasPendingVideoChanges && hasPendingAudioChanges
                ? "The Crop Video and Crop Audio pages have unsaved changes. If you quit now, those changes will be lost."
                : (hasPendingVideoChanges
                    ? "The Crop Video page has unsaved changes for the current video. If you quit now, those changes will be lost."
                    : "The Crop Audio page has unsaved changes for the current audio. If you quit now, those changes will be lost."),
            hasPendingVideoChanges && hasPendingAudioChanges
                ? "裁剪视频和裁剪音频页面当前都有尚未保存的修改。现在退出会丢失这些修改。"
                : (hasPendingVideoChanges
                    ? "裁剪视频页面当前有尚未保存的修改。现在退出会丢失这些修改。"
                    : "裁剪音频页面当前有尚未保存的修改。现在退出会丢失这些修改。")
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
    @StateObject private var cropAudioSession = CropAudioSession()

    var body: some Scene {
        WindowGroup("Simple Video") {
            ContentView(cropSession: cropSession, cropAudioSession: cropAudioSession)
                .frame(minWidth: 920, minHeight: 580)
                .onAppear {
                    appDelegate.cropSession = cropSession
                    appDelegate.cropAudioSession = cropAudioSession
                }
        }
        .windowResizability(.contentMinSize)
    }
}
