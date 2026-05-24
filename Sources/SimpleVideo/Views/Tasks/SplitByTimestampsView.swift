import SwiftUI
import UniformTypeIdentifiers

struct SplitByTimestampsView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var input = ""
    @State private var timestamps = ""
    @State private var completedOutput = ""

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FilePickerRow(label: L.text(language, "Input video:", "输入视频："), path: $input, contentTypes: [.movie, .video, .audiovisualContent])

            HStack(alignment: .top) {
                Text(L.text(language, "Timestamps:", "时间戳：")).frame(width: formLabelWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $timestamps)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor))
                        )
                    Text(L.text(language,
                                "One split point per line, or separate with commas. Example: 00:00:10, 00:00:35.5, 00:01:12",
                                "每行一个分割点，也可以用逗号分隔。例如：00:00:10, 00:00:35.5, 00:01:12"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(L.text(language,
                                "The original video is kept. New clips are written into a timestamped folder next to it.",
                                "原视频会保留不变。新片段会写入原文件旁边带时间戳的文件夹。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty && !timestamps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                runSplit()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .onChange(of: input) { _, _ in completedOutput = "" }
        .onChange(of: timestamps) { _, _ in completedOutput = "" }
    }

    private func runSplit() {
        completedOutput = ""
        let parsed: [Double]
        switch parseTimestampList(timestamps) {
        case .success(let values):
            parsed = values
        case .failure(let message):
            runner.log = "⚠️  \(localizedTimestampError(message))\n"
            runner.status = L.text(language, "Invalid timestamps", "时间戳无效")
            return
        }

        guard let outputDirectory = makeOutputDirectory(input: input, label: "segments") else { return }
        do {
            try FileManager.default.createDirectory(
                atPath: outputDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            runner.log = "ERROR: \(error.localizedDescription)\n"
            runner.status = L.text(language, "Failed to create output folder", "创建输出文件夹失败")
            return
        }

        let ext = inputExt(input)
        let outputPattern = (outputDirectory as NSString).appendingPathComponent("segment-%03d.\(ext)")

        runner.run(
            args: [
                "-i", input,
                "-map", "0",
                "-c", "copy",
                "-f", "segment",
                "-segment_times", ffmpegTimestampList(parsed),
                "-reset_timestamps", "1",
                "-y", outputPattern
            ],
            inputForDuration: input
        ) { _ in
            completedOutput = outputDirectory
        }
    }

    private func localizedTimestampError(_ message: String) -> String {
        guard language == .simplifiedChinese else { return message }
        if message == "Enter at least one timestamp." {
            return "请至少输入一个时间戳。"
        }
        if message.hasPrefix("Invalid timestamp: ") {
            return "时间戳无效：" + message.replacingOccurrences(of: "Invalid timestamp: ", with: "")
        }
        if message == "Timestamps must be in ascending order." {
            return "时间戳必须按升序排列。"
        }
        if message == "Timestamps must be unique." {
            return "时间戳不能重复。"
        }
        return message
    }
}
