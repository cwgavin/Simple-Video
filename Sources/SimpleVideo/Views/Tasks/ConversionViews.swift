import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Tab views

struct ConvertView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var input = ""
    @State private var format = "mp4"
    @State private var completedOutput = ""

    // Common video container/format choices.
    let videoFormats = ["mp4", "mov", "mkv", "webm", "avi", "flv", "m4v", "ts"]

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    /// Returns ffmpeg args for the chosen output format. Each branch picks
    /// codecs the chosen container actually supports, so output plays in QuickTime/VLC.
    private func ffmpegArgs(input: String, output: String) -> [String] {
        switch format {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            FilePickerRow(label: L.text(language, "Input video:", "输入视频："), path: $input, contentTypes: [.movie, .audiovisualContent])
            HStack {
                Text(L.text(language, "Output format:", "输出格式：")).frame(width: formLabelWidth, alignment: .trailing)
                Picker("format", selection: $format) {
                    ForEach(videoFormats, id: \.self) { Text(".\($0)").tag($0) }
                }.labelsHidden().fixedSize()
                Spacer()
            }
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty) {
                let out = makeOutputPath(input: input, ext: format)
                runner.run(args: ffmpegArgs(input: input, output: out),
                           inputForDuration: input) { completedOutput = $0 }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onChange(of: input)  { _, _ in completedOutput = "" }
        .onChange(of: format) { _, _ in completedOutput = "" }
    }
}


struct ConvertAudioView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var input = ""
    @State private var format = "mp3"
    @State private var completedOutput = ""

    let audioFormats = ["mp3", "aac", "m4a", "flac", "wav", "ogg", "opus", "wma", "aiff"]

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    private func ffmpegArgs(input: String, output: String) -> [String] {
        switch format {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            FilePickerRow(label: L.text(language, "Input audio:", "输入音频："), path: $input, contentTypes: [.audio, .movie, .audiovisualContent])
            HStack {
                Text(L.text(language, "Output format:", "输出格式：")).frame(width: formLabelWidth, alignment: .trailing)
                Picker("format", selection: $format) {
                    ForEach(audioFormats, id: \.self) { Text(".\($0)").tag($0) }
                }.labelsHidden().fixedSize()
                Spacer()
            }
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty) {
                let out = makeOutputPath(input: input, ext: format)
                runner.run(args: ffmpegArgs(input: input, output: out),
                           inputForDuration: input) { completedOutput = $0 }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onChange(of: input)  { _, _ in completedOutput = "" }
        .onChange(of: format) { _, _ in completedOutput = "" }
    }
}

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
                let out = makeOutputPath(input: video, ext: inputExt(video))
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

// MARK: - Reusable UI

struct ConcatView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var mediaType = "video"
    @State private var files: [String] = []
    @State private var completedOutput = ""
    @State private var isDropTarget = false

    private let mediaTypes = ["video", "audio"]

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

    private var contentTypes: [UTType] {
        mediaType == "video"
            ? [.movie, .video]
            : [.audio]
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = contentTypes
        if panel.runModal() == .OK {
            files.append(contentsOf: panel.urls.map(\.path))
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let allowed = contentTypes
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let u = url, u.isFileURL else { return }
                let values = try? u.resourceValues(forKeys: [.contentTypeKey])
                guard let ct = values?.contentType,
                      allowed.contains(where: { ct.conforms(to: $0) }) else { return }
                DispatchQueue.main.async { files.append(u.path) }
            }
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L.text(language, "Type:", "类型：")).frame(width: formLabelWidth, alignment: .trailing)
                Picker("type", selection: $mediaType) {
                    ForEach(mediaTypes, id: \.self) { Text(mediaTypeTitle($0)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .fixedSize()
                Spacer()
            }
            HStack {
                Text(L.text(language, "Files:", "文件：")).frame(width: formLabelWidth, alignment: .trailing)
                Text(L.fileCount(language, files.count))
                    .foregroundColor(.secondary)
                Spacer()
                Button(L.text(language, "Add Files…", "添加文件…")) { addFiles() }
                Button(L.text(language, "Clear", "清空")) { files.removeAll(); completedOutput = "" }
                    .disabled(files.isEmpty)
            }

            HStack(alignment: .top) {
                Spacer().frame(width: formLabelWidth)
                Group {
                    if files.isEmpty {
                        VStack {
                            Spacer()
                            Text(L.text(language, "Drop files here or double-click to add", "将文件拖到这里，或双击添加"))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        List {
                            ForEach(Array(files.enumerated()), id: \.offset) { i, file in
                                HStack {
                                    Text("\(i + 1).")
                                        .foregroundColor(.secondary)
                                        .frame(width: 24, alignment: .trailing)
                                    Text((file as NSString).lastPathComponent)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(file)
                                    Spacer()
                                    Button {
                                        files.remove(at: i)
                                        completedOutput = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .onMove { from, to in
                                files.move(fromOffsets: from, toOffset: to)
                                completedOutput = ""
                            }
                        }
                        .frame(maxHeight: 160)
                    }
                }
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isDropTarget ? Color.accentColor : Color.secondary.opacity(files.isEmpty ? 0.3 : 0),
                                      style: files.isEmpty && !isDropTarget ? StrokeStyle(lineWidth: 1, dash: [5]) : StrokeStyle(lineWidth: 1.5))
                )
                .onTapGesture(count: 2) { addFiles() }
                .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget, perform: handleDrop)
            }

            OutputHintRow(path: completedOutput)
            RunButton(canRun: files.count >= 2) {
                let exts = Set(files.map { inputExt($0).lowercased() })
                let mixed = exts.count > 1

                if mixed {
                    let alert = NSAlert()
                    alert.messageText = L.text(language, "Mixed formats detected", "检测到不同格式")
                    alert.informativeText = L.text(
                        language,
                        "The selected files have different formats (\(exts.sorted().joined(separator: ", "))). They will be re-encoded to a common format, which is slower than stream copy.",
                        "所选文件格式不同（\(exts.sorted().joined(separator: ", "))）。它们会被重新编码为统一格式，这会比直接复制流更慢。"
                    )
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: L.text(language, "Re-encode & Continue", "重新编码并继续"))
                    alert.addButton(withTitle: L.text(language, "Cancel", "取消"))
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }

                if mixed {
                    // Use the concat *filter* for mixed formats — the concat
                    // demuxer can't handle heterogeneous codecs/sample-rates.
                    var args: [String] = []
                    for f in files { args += ["-i", f] }

                    let n = files.count
                    if mediaType == "video" {
                        let inputs = (0..<n).map { "[\($0):v][\($0):a]" }.joined()
                        let filter = "\(inputs)concat=n=\(n):v=1:a=1[outv][outa]"
                        let out = makeOutputPath(input: files[0], ext: "mp4")
                        args += ["-filter_complex", filter,
                                 "-map", "[outv]", "-map", "[outa]",
                                 "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                                 "-c:a", "aac", "-b:a", "192k", "-y", out]
                    } else {
                        let inputs = (0..<n).map { "[\($0):a]" }.joined()
                        let filter = "\(inputs)concat=n=\(n):v=0:a=1[outa]"
                        let out = makeOutputPath(input: files[0], ext: "m4a")
                        args += ["-filter_complex", filter,
                                 "-map", "[outa]",
                                 "-c:a", "aac", "-b:a", "192k", "-y", out]
                    }

                    runner.run(args: args, inputForDuration: nil) { completedOutput = $0 }
                } else {
                    // Same format — use the concat demuxer with stream copy (fast).
                    let tmp = NSTemporaryDirectory() + "simple-video-concat-\(ProcessInfo.processInfo.globallyUniqueString).txt"
                    let listing = files.map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
                        .joined(separator: "\n")
                    try? listing.write(toFile: tmp, atomically: true, encoding: .utf8)

                    let out = makeOutputPath(input: files[0], ext: inputExt(files[0]))
                    runner.run(
                        args: ["-f", "concat", "-safe", "0", "-i", tmp,
                               "-c", "copy", "-y", out],
                        inputForDuration: nil
                    ) {
                        completedOutput = $0
                        try? FileManager.default.removeItem(atPath: tmp)
                    }
                }
            }
        }
        .padding()
        .onChange(of: mediaType) { _, _ in files.removeAll(); completedOutput = "" }
    }
}

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
        let parsed: [Double]
        switch parseTimestampList(timestamps) {
        case .success(let values):
            parsed = values
        case .failure(let message):
            runner.log = "⚠️  \(localizedTimestampError(message))\n"
            runner.status = L.text(language, "Invalid timestamps", "时间戳无效")
            return
        }

        let outputDirectory = makeOutputDirectory(input: input, label: "segments")
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

struct CutRangeView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var input = ""
    @State private var startTimestamp = ""
    @State private var endTimestamp = ""
    @State private var completedOutput = ""

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FilePickerRow(label: L.text(language, "Input video:", "输入视频："), path: $input, contentTypes: [.movie, .video, .audiovisualContent])

            HStack {
                Text(L.text(language, "Start:", "开始：")).frame(width: formLabelWidth, alignment: .trailing)
                TextField("00:00:10", text: $startTimestamp)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 180)
                Spacer()
            }

            HStack {
                Text(L.text(language, "End:", "结束：")).frame(width: formLabelWidth, alignment: .trailing)
                TextField("00:00:20", text: $endTimestamp)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 180)
                Spacer()
            }

            HStack(alignment: .top) {
                Spacer().frame(width: formLabelWidth)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.text(language,
                                "The section between the two timestamps is removed and the remaining parts are joined into one new video.",
                                "两个时间戳之间的片段会被移除，剩余部分会合并为一个新视频。"))
                    Text(L.text(language, "The original video is kept unchanged.", "原视频会保持不变。"))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty && !startTimestamp.isEmpty && !endTimestamp.isEmpty) {
                runCutRange()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .onChange(of: input) { _, _ in completedOutput = "" }
        .onChange(of: startTimestamp) { _, _ in completedOutput = "" }
        .onChange(of: endTimestamp) { _, _ in completedOutput = "" }
    }

    private func runCutRange() {
        let start: Double
        let end: Double

        guard let parsedStart = parseTimestamp(startTimestamp.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            runner.log = "⚠️  \(L.text(language, "Invalid start timestamp.", "开始时间戳无效。"))\n"
            runner.status = L.text(language, "Invalid timestamps", "时间戳无效")
            return
        }
        guard let parsedEnd = parseTimestamp(endTimestamp.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            runner.log = "⚠️  \(L.text(language, "Invalid end timestamp.", "结束时间戳无效。"))\n"
            runner.status = L.text(language, "Invalid timestamps", "时间戳无效")
            return
        }

        start = parsedStart
        end = parsedEnd

        guard end > start else {
            runner.log = "⚠️  \(L.text(language, "End timestamp must be greater than start timestamp.", "结束时间戳必须大于开始时间戳。"))\n"
            runner.status = L.text(language, "Invalid timestamps", "时间戳无效")
            return
        }

        let duration = FFmpegRunner.probeDuration(input)
        if duration > 0 {
            guard start < duration else {
                runner.log = "⚠️  \(L.text(language, "Start timestamp must be inside the video duration.", "开始时间戳必须在视频时长范围内。"))\n"
                runner.status = L.text(language, "Invalid timestamps", "时间戳无效")
                return
            }
            guard end <= duration else {
                runner.log = "⚠️  \(L.text(language, "End timestamp must be inside the video duration.", "结束时间戳必须在视频时长范围内。"))\n"
                runner.status = L.text(language, "Invalid timestamps", "时间戳无效")
                return
            }
            guard !(start == 0 && end == duration) else {
                runner.log = "⚠️  \(L.text(language, "The selected range removes the entire video.", "所选范围会移除整个视频。"))\n"
                runner.status = L.text(language, "Invalid timestamps", "时间戳无效")
                return
            }
        }

        let hasAudio = FFmpegRunner.hasAudioStream(input)
        let startText = ffmpegTime(start)
        let endText = ffmpegTime(end)

        let videoFilter = "[0:v]select='lt(t,\(startText))+gte(t,\(endText))',setpts=N/FRAME_RATE/TB[v]"
        let audioFilter = "[0:a]aselect='lt(t,\(startText))+gte(t,\(endText))',asetpts=N/SR/TB[a]"
        let filterComplex = hasAudio ? "\(videoFilter);\(audioFilter)" : videoFilter

        let out = makeOutputPath(input: input, ext: inputExt(input))
        var args = ["-i", input, "-filter_complex", filterComplex, "-map", "[v]"]
        if hasAudio {
            args += ["-map", "[a]"]
        }
        args += ["-y", out]

        runner.run(args: args, inputForDuration: input) { completedOutput = $0 }
    }
}
