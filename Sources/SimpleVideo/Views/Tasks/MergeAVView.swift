import SwiftUI
import UniformTypeIdentifiers

struct MergeAVView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var video = ""
    @State private var audio = ""
    @State private var completedOutput = ""

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            FilePickerRow(label: L.text(language, "Video file:", "视频文件："), path: $video, contentTypes: [.movie, .audiovisualContent])
            FilePickerRow(label: L.text(language, "Audio file:", "音频文件："), path: $audio, contentTypes: [.audio, .movie, .audiovisualContent])
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !video.isEmpty && !audio.isEmpty) {
                completedOutput = ""
                guard let out = makeOutputPath(input: video, ext: inputExt(video)) else { return }
                runner.run(args: ["-i", video, "-i", audio,
                                  "-map", "0:v:0", "-map", "1:a:0",
                                  "-c:v", "copy", "-c:a", "aac",
                                  "-shortest", "-y", out],
                           inputForDuration: video) { completedOutput = $0 }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onChange(of: video) { _, _ in completedOutput = "" }
        .onChange(of: audio) { _, _ in completedOutput = "" }
    }
}
