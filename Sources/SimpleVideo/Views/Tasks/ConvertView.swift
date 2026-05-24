import SwiftUI
import UniformTypeIdentifiers

struct ConvertView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var mediaType = "video"
    @State private var input = ""
    @State private var videoFormat = "mp4"
    @State private var audioFormat = "mp3"
    @State private var completedOutput = ""

    private let mediaTypes = ["video", "audio"]
    private let videoFormats = ["mp4", "mov", "mkv", "webm", "avi", "flv", "m4v", "ts"]
    private let audioFormats = ["mp3", "aac", "m4a", "flac", "wav", "ogg", "opus", "wma", "aiff"]

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    private func mediaTypeTitle(_ type: String) -> String {
        switch type {
        case "video": return L.text(language, "Video", "视频")
        case "audio": return L.text(language, "Audio", "音频")
        default: return type
        }
    }

    private var outputFormat: String {
        mediaType == "video" ? videoFormat : audioFormat
    }

    private var inputContentTypes: [UTType] {
        mediaType == "video" ? [.movie, .video, .audiovisualContent] : [.audio, .movie, .audiovisualContent]
    }

    private func videoFFmpegArgs(input: String, output: String) -> [String] {
        switch videoFormat {
        case "mp4", "mov", "m4v":
            return ["-i", input, "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
                    "-y", output]
        case "mkv":
            return ["-i", input, "-c:v", "libx264", "-c:a", "aac", "-y", output]
        case "webm":
            return ["-i", input, "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32",
                    "-c:a", "libopus", "-y", output]
        case "avi":
            return ["-i", input, "-c:v", "mpeg4", "-q:v", "5",
                    "-c:a", "libmp3lame", "-y", output]
        case "flv":
            return ["-i", input, "-c:v", "libx264", "-c:a", "aac", "-ar", "44100",
                    "-y", output]
        case "ts":
            return ["-i", input, "-c:v", "libx264", "-c:a", "aac",
                    "-bsf:v", "h264_mp4toannexb", "-f", "mpegts", "-y", output]
        default:
            return ["-i", input, "-y", output]
        }
    }

    private func audioFFmpegArgs(input: String, output: String) -> [String] {
        switch audioFormat {
        case "mp3":
            return ["-i", input, "-vn", "-c:a", "libmp3lame", "-b:a", "192k", "-y", output]
        case "aac":
            return ["-i", input, "-vn", "-c:a", "aac", "-b:a", "192k", "-y", output]
        case "m4a":
            return ["-i", input, "-vn", "-c:a", "aac", "-b:a", "192k", "-y", output]
        case "flac":
            return ["-i", input, "-vn", "-c:a", "flac", "-y", output]
        case "wav":
            return ["-i", input, "-vn", "-c:a", "pcm_s16le", "-y", output]
        case "ogg":
            return ["-i", input, "-vn", "-c:a", "libvorbis", "-q:a", "5", "-y", output]
        case "opus":
            return ["-i", input, "-vn", "-c:a", "libopus", "-b:a", "128k", "-y", output]
        case "wma":
            return ["-i", input, "-vn", "-c:a", "wmav2", "-b:a", "192k", "-y", output]
        case "aiff":
            return ["-i", input, "-vn", "-c:a", "pcm_s16be", "-y", output]
        default:
            return ["-i", input, "-vn", "-y", output]
        }
    }

    private func runConversion() {
        completedOutput = ""
        let out = makeOutputPath(input: input, ext: outputFormat)
        let args = mediaType == "video"
            ? videoFFmpegArgs(input: input, output: out)
            : audioFFmpegArgs(input: input, output: out)
        runner.run(args: args, inputForDuration: input) { completedOutput = $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            HStack(spacing: 8) {
                Text(L.text(language, "Type:", "类型：")).frame(width: formLabelWidth, alignment: .trailing)
                Picker("type", selection: $mediaType) {
                    ForEach(mediaTypes, id: \.self) { Text(mediaTypeTitle($0)).tag($0) }
                }
                .pointingHandCursor()
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .fixedSize()
                Spacer()
            }
            FilePickerRow(
                label: mediaType == "video"
                    ? L.text(language, "Input video:", "输入视频：")
                    : L.text(language, "Input audio:", "输入音频："),
                path: $input,
                contentTypes: inputContentTypes
            )
            HStack {
                Text(L.text(language, "Output format:", "输出格式：")).frame(width: formLabelWidth, alignment: .trailing)
                Picker("format", selection: mediaType == "video" ? $videoFormat : $audioFormat) {
                    ForEach(mediaType == "video" ? videoFormats : audioFormats, id: \.self) { Text(".\($0)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .pointingHandCursor()
                Spacer()
            }
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty) {
                runConversion()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onChange(of: input) { _, _ in completedOutput = "" }
        .onChange(of: mediaType) { _, _ in
            input = ""
            completedOutput = ""
        }
        .onChange(of: videoFormat) { _, _ in completedOutput = "" }
        .onChange(of: audioFormat) { _, _ in completedOutput = "" }
    }
}
