import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - App entry

@main
struct FFmpegGUIApp: App {
    var body: some Scene {
        WindowGroup("FFmpeg GUI") {
            ContentView()
                .frame(minWidth: 920, minHeight: 580)
        }
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Task model

enum FFTask: String, CaseIterable, Identifiable, Hashable {
    case mergeAV = "Merge A/V"
    case convert = "Convert Video"
    case extractAudio = "Extract Audio"
    case removeAudio = "Remove Audio"
    case trim = "Trim"
    case resize = "Resize"
    case compress = "Compress"
    case toGIF = "To GIF"
    case frames = "Frames"

    var id: String { rawValue }
    var title: String { rawValue }

    var icon: String {
        switch self {
        case .mergeAV:      return "plus.square.on.square"
        case .convert:      return "arrow.triangle.2.circlepath"
        case .extractAudio: return "waveform"
        case .removeAudio:  return "speaker.slash"
        case .trim:         return "scissors"
        case .resize:       return "arrow.up.left.and.arrow.down.right"
        case .compress:     return "rectangle.compress.vertical"
        case .toGIF:        return "photo"
        case .frames:       return "square.grid.2x2"
        }
    }
}

// MARK: - FFmpeg runner

@MainActor
final class FFmpegRunner: ObservableObject {
    @Published var log: String = ""
    @Published var progress: Double = 0
    @Published var status: String = "Idle"
    @Published var isRunning: Bool = false

    private var process: Process?
    private var duration: Double = 0
    private var pendingOutput: String = ""
    private var pendingSuccess: ((String) -> Void)?

    static func resolveBinary(_ name: String) -> String {
        // 1) Common fixed paths
        let fixed = [
            "/opt/homebrew/bin/\(name)",
            "/opt/homebrew/opt/\(name)/bin/\(name)",
            "/opt/homebrew/opt/\(name)@7/bin/\(name)",
            "/opt/homebrew/opt/\(name)@6/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/local/opt/\(name)/bin/\(name)",
            "/opt/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for p in fixed where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // 2) Ask the shell — covers any custom install location on the user's PATH
        if let p = whichViaShell(name) { return p }
        // 3) Last resort: return name and let Process fail with a clear message
        return name
    }

    private static func whichViaShell(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -i -l so user's PATH from .zshrc/.zprofile is loaded
        p.arguments = ["-ilc", "command -v \(name)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) {
                return s
            }
        } catch {}
        return nil
    }

    func probeDuration(_ path: String) -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.resolveBinary("ffprobe"))
        p.arguments = ["-v", "error", "-show_entries", "format=duration",
                       "-of", "default=noprint_wrappers=1:nokey=1", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Double(s) ?? 0
        } catch {
            return 0
        }
    }

    func run(args: [String], inputForDuration: String?, onSuccess: ((String) -> Void)? = nil) {
        guard !isRunning else { return }

        // SAFETY GUARD: ensure output (last arg) doesn't match any input (after -i).
        // ffmpeg never writes back to input files itself, but `-y` would clobber any
        // file we accidentally pass as the output. This catches programmer mistakes.
        if let unsafe = unsafeOverlap(args: args) {
            log = ""
            appendLog("⚠️  Refusing to run: output path matches an input file:\n  \(unsafe)\n" +
                      "    This is a safety guard to protect your source files.\n")
            status = "Aborted: output would overwrite input"
            return
        }

        isRunning = true
        progress = 0
        log = ""
        status = "Running…"
        duration = inputForDuration.map { probeDuration($0) } ?? 0
        pendingOutput = (args.last?.hasPrefix("-") == false) ? (args.last ?? "") : ""
        pendingSuccess = onSuccess

        let bin = Self.resolveBinary("ffmpeg")
        let full = ["-hide_banner", "-loglevel", "info", "-progress", "pipe:2"] + args
        appendLog("$ \(bin) \(full.joined(separator: " "))\n")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = full

        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()

        let handle = errPipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                Task { @MainActor in self?.handleStderr(s) }
            }
        }

        p.terminationHandler = { [weak self] proc in
            handle.readabilityHandler = nil
            Task { @MainActor in self?.finished(code: proc.terminationStatus) }
        }

        do {
            try p.run()
            self.process = p
        } catch {
            appendLog("ERROR: \(error.localizedDescription)\n")
            isRunning = false
            status = "Failed to launch ffmpeg"
        }
    }

    func cancel() {
        process?.interrupt()
        appendLog("\n[cancel requested]\n")
    }

    /// Returns the offending input path if the output (last arg) equals any input
    /// (path immediately following a `-i` flag). Comparison is on normalized,
    /// resolved absolute paths so `./foo.mp4` vs `/abs/foo.mp4` is caught.
    private func unsafeOverlap(args: [String]) -> String? {
        guard let outRaw = args.last, !outRaw.hasPrefix("-") else { return nil }
        // Skip output patterns like image2 sequences (contain %d) — they can't
        // collide with a single input path; ffmpeg writes new files.
        if outRaw.contains("%") { return nil }
        let out = canonical(outRaw)
        var inputs: [String] = []
        var it = args.makeIterator()
        while let a = it.next() {
            if a == "-i", let next = it.next() {
                inputs.append(canonical(next))
            }
        }
        for ip in inputs where ip == out {
            return ip
        }
        return nil
    }

    private func canonical(_ p: String) -> String {
        let url = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath()
        return url.path
    }

    private func handleStderr(_ s: String) {
        appendLog(s)
        // Parse "time=HH:MM:SS.xx"
        if let range = s.range(of: #"time=(\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression) {
            let chunk = String(s[range])
            let parts = chunk.replacingOccurrences(of: "time=", with: "").split(separator: ":")
            if parts.count == 3,
               let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) {
                let t = h * 3600 + m * 60 + sec
                if duration > 0 {
                    progress = min(1.0, t / duration)
                    status = String(format: "%.1f%%  (%.1fs / %.1fs)", progress * 100, t, duration)
                } else {
                    status = String(format: "Processed %.1fs", t)
                }
            }
        }
    }

    private func finished(code: Int32) {
        isRunning = false
        process = nil
        if code == 0 {
            progress = 1.0
            status = "Done ✓"
            if !pendingOutput.isEmpty {
                pendingSuccess?(pendingOutput)
            }
        } else {
            status = "ffmpeg exited with code \(code)"
        }
        pendingSuccess = nil
        pendingOutput = ""
    }

    private func appendLog(_ s: String) {
        log.append(s)
        if log.count > 200_000 {
            log = String(log.suffix(150_000))
        }
    }
}

// MARK: - File picker helpers

enum Files {
    static func openFile(types: [String] = []) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if !types.isEmpty {
            panel.allowedFileTypes = types
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func saveFile(suggested: String = "output.mp4") -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Common UI bits

/// Generates an output path next to `input` named purely with a millisecond
/// timestamp so collisions are effectively impossible.
/// Example: /Users/me/Movies/clip.mov + "mp4" → /Users/me/Movies/20260426-001234-567.mp4
func makeOutputPath(input: String, ext: String, suffix: String = "") -> String {
    let url = URL(fileURLWithPath: input)
    let dir = url.deletingLastPathComponent().path
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
    let stamp = fmt.string(from: Date())
    return "\(dir)/\(stamp).\(ext)"
}

func inputExt(_ path: String) -> String {
    let e = (path as NSString).pathExtension
    return e.isEmpty ? "mp4" : e
}

private let formLabelWidth: CGFloat = 160

struct FilePickerRow: View {
    let label: String
    @Binding var path: String
    var save: Bool = false
    var suggested: String = "output.mp4"
    var types: [String] = []

    @State private var isDropTarget = false

    var body: some View {
        HStack {
            Text(label).frame(width: formLabelWidth, alignment: .leading)
            Text(path.isEmpty ? "No file selected — drag a file here or click Browse"
                              : (path as NSString).lastPathComponent)
                .foregroundColor(path.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isDropTarget ? Color.accentColor
                                                   : Color.secondary.opacity(0.3),
                                      lineWidth: isDropTarget ? 1.5 : 1)
                )
                .help(path.isEmpty ? "" : path)
                .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
                    guard let p = providers.first else { return false }
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let u = url {
                            DispatchQueue.main.async { self.path = u.path }
                        }
                    }
                    return true
                }
            Button("Browse…") {
                if let p = save ? Files.saveFile(suggested: suggested)
                                : Files.openFile(types: types) {
                    path = p
                }
            }
        }
    }
}

/// Read-only display showing where the output was written. Only visible after
/// a successful run. Cleared by the parent view whenever an input changes.
struct OutputHintRow: View {
    let path: String
    var body: some View {
        if !path.isEmpty {
            HStack {
                Text("Output →").frame(width: formLabelWidth, alignment: .leading)
                    .foregroundColor(.secondary)
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Tab views

struct ConvertView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @State private var input = ""
    @State private var format = "mp4"
    @State private var completedOutput = ""

    // Common video container/format choices.
    let videoFormats = ["mp4", "mov", "mkv", "webm", "avi", "flv", "m4v", "ts"]

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
        Form {
            FilePickerRow(label: "Input video:", path: $input)
            HStack {
                Text("Output format:").frame(width: formLabelWidth, alignment: .leading)
                Picker("format", selection: $format) {
                    ForEach(videoFormats, id: \.self) { Text(".\($0)").tag($0) }
                }.labelsHidden().frame(width: 200)
                Spacer()
            }
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty) {
                let out = makeOutputPath(input: input, ext: format)
                runner.run(args: ffmpegArgs(input: input, output: out),
                           inputForDuration: input) { completedOutput = $0 }
            }
        }
        .padding()
        .onChange(of: input)  { _, _ in completedOutput = "" }
        .onChange(of: format) { _, _ in completedOutput = "" }
    }
}

struct ExtractAudioView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @State private var input = ""
    @State private var codec = "libmp3lame"
    @State private var completedOutput = ""
    let codecs = ["libmp3lame", "aac", "pcm_s16le", "flac", "copy"]

    private var ext: String {
        switch codec {
        case "libmp3lame": return "mp3"
        case "aac":        return "m4a"
        case "pcm_s16le":  return "wav"
        case "flac":       return "flac"
        default:           return "m4a"
        }
    }

    var body: some View {
        Form {
            FilePickerRow(label: "Input video:", path: $input)
            HStack {
                Text("Audio codec:").frame(width: formLabelWidth, alignment: .leading)
                Picker("codec", selection: $codec) {
                    ForEach(codecs, id: \.self) { Text($0) }
                }.labelsHidden().frame(width: 200)
                Spacer()
            }
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty) {
                let out = makeOutputPath(input: input, ext: ext)
                runner.run(args: ["-i", input, "-vn", "-acodec", codec, "-y", out],
                           inputForDuration: input) { completedOutput = $0 }
            }
        }
        .padding()
        .onChange(of: input) { _, _ in completedOutput = "" }
        .onChange(of: codec) { _, _ in completedOutput = "" }
    }
}

struct RemoveAudioView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @State private var input = ""
    @State private var completedOutput = ""
    var body: some View {
        Form {
            FilePickerRow(label: "Input video:", path: $input)
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty) {
                let out = makeOutputPath(input: input, ext: inputExt(input))
                runner.run(args: ["-i", input, "-c", "copy", "-an", "-y", out],
                           inputForDuration: input) { completedOutput = $0 }
            }
        }
        .padding()
        .onChange(of: input) { _, _ in completedOutput = "" }
    }
}

struct TrimView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @State private var input = ""
    @State private var start = "00:00:00"
    @State private var end = ""
    @State private var completedOutput = ""
    var body: some View {
        Form {
            FilePickerRow(label: "Input:", path: $input)
            LabeledField(label: "Start (HH:MM:SS):", text: $start)
            LabeledField(label: "End (optional):", text: $end)
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty) {
                let out = makeOutputPath(input: input, ext: inputExt(input))
                var args = ["-ss", start, "-i", input]
                if !end.isEmpty { args += ["-to", end] }
                args += ["-c", "copy", "-y", out]
                runner.run(args: args, inputForDuration: input) { completedOutput = $0 }
            }
        }
        .padding()
        .onChange(of: input) { _, _ in completedOutput = "" }
        .onChange(of: start) { _, _ in completedOutput = "" }
        .onChange(of: end)   { _, _ in completedOutput = "" }
    }
}

struct ResizeView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @State private var input = ""
    @State private var width = "1280"
    @State private var height = "-1"
    @State private var completedOutput = ""
    var body: some View {
        Form {
            FilePickerRow(label: "Input video:", path: $input)
            LabeledField(label: "Width (px, -1 auto):", text: $width)
            LabeledField(label: "Height (px, -1 auto):", text: $height)
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty) {
                let out = makeOutputPath(input: input, ext: inputExt(input))
                runner.run(args: ["-i", input, "-vf", "scale=\(width):\(height)",
                                  "-c:a", "copy", "-y", out],
                           inputForDuration: input) { completedOutput = $0 }
            }
        }
        .padding()
        .onChange(of: input)  { _, _ in completedOutput = "" }
        .onChange(of: width)  { _, _ in completedOutput = "" }
        .onChange(of: height) { _, _ in completedOutput = "" }
    }
}

struct CompressView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @State private var input = ""
    @State private var crf: Double = 23
    @State private var preset = "medium"
    @State private var completedOutput = ""
    let presets = ["ultrafast", "superfast", "veryfast", "faster", "fast",
                   "medium", "slow", "slower", "veryslow"]
    var body: some View {
        Form {
            FilePickerRow(label: "Input video:", path: $input)
            HStack {
                Text("CRF: \(Int(crf))").frame(width: formLabelWidth, alignment: .leading)
                Slider(value: $crf, in: 0...51, step: 1).frame(maxWidth: 300)
                Spacer()
            }
            HStack {
                Text("Preset:").frame(width: formLabelWidth, alignment: .leading)
                Picker("preset", selection: $preset) {
                    ForEach(presets, id: \.self) { Text($0) }
                }.labelsHidden().frame(width: 200)
                Spacer()
            }
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty) {
                let out = makeOutputPath(input: input, ext: "mp4")
                runner.run(args: ["-i", input, "-c:v", "libx264",
                                  "-crf", "\(Int(crf))", "-preset", preset,
                                  "-c:a", "aac", "-b:a", "128k", "-y", out],
                           inputForDuration: input) { completedOutput = $0 }
            }
        }
        .padding()
        .onChange(of: input)  { _, _ in completedOutput = "" }
        .onChange(of: crf)    { _, _ in completedOutput = "" }
        .onChange(of: preset) { _, _ in completedOutput = "" }
    }
}

struct GIFView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @State private var input = ""
    @State private var fps = "12"
    @State private var width = "480"
    @State private var completedOutput = ""
    var body: some View {
        Form {
            FilePickerRow(label: "Input video:", path: $input)
            LabeledField(label: "FPS:", text: $fps)
            LabeledField(label: "Width (px):", text: $width)
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty) {
                let out = makeOutputPath(input: input, ext: "gif")
                let vf = "fps=\(fps),scale=\(width):-1:flags=lanczos"
                runner.run(args: ["-i", input, "-vf", vf, "-y", out],
                           inputForDuration: input) { completedOutput = $0 }
            }
        }
        .padding()
        .onChange(of: input) { _, _ in completedOutput = "" }
        .onChange(of: fps)   { _, _ in completedOutput = "" }
        .onChange(of: width) { _, _ in completedOutput = "" }
    }
}

struct FramesView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @State private var input = ""
    @State private var fps = "1"
    @State private var completedOutput = ""
    var body: some View {
        Form {
            FilePickerRow(label: "Input video:", path: $input)
            LabeledField(label: "FPS:", text: $fps)
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty) {
                let url = URL(fileURLWithPath: input)
                let dir = url.deletingLastPathComponent().path
                let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
                let folder = "\(dir)/\(fmt.string(from: Date()))"
                try? FileManager.default.createDirectory(atPath: folder,
                    withIntermediateDirectories: true)
                let pattern = "\(folder)/frame_%04d.png"
                runner.run(args: ["-i", input, "-vf", "fps=\(fps)", "-y", pattern],
                           inputForDuration: input) { _ in completedOutput = folder }
            }
        }
        .padding()
        .onChange(of: input) { _, _ in completedOutput = "" }
        .onChange(of: fps)   { _, _ in completedOutput = "" }
    }
}

struct MergeAVView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @State private var video = ""
    @State private var audio = ""
    @State private var completedOutput = ""
    var body: some View {
        Form {
            FilePickerRow(label: "Video file:", path: $video)
            FilePickerRow(label: "Audio file:", path: $audio)
            OutputHintRow(path: completedOutput)
            RunButton(canRun: !video.isEmpty && !audio.isEmpty) {
                let out = makeOutputPath(input: video, ext: inputExt(video))
                runner.run(args: ["-i", video, "-i", audio,
                                  "-map", "0:v:0", "-map", "1:a:0",
                                  "-c:v", "copy", "-c:a", "aac",
                                  "-shortest", "-y", out],
                           inputForDuration: video) { completedOutput = $0 }
            }
        }
        .padding()
        .onChange(of: video) { _, _ in completedOutput = "" }
        .onChange(of: audio) { _, _ in completedOutput = "" }
    }
}

// MARK: - Reusable UI

struct LabeledField: View {
    let label: String
    @Binding var text: String
    var body: some View {
        HStack {
            Text(label).frame(width: formLabelWidth, alignment: .leading)
            TextField("", text: $text).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
            Spacer()
        }
    }
}

struct RunButton: View {
    @EnvironmentObject var runner: FFmpegRunner
    let canRun: Bool
    let action: () -> Void
    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Label("Run", systemImage: "play.fill")
                    .frame(minWidth: 100)
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canRun || runner.isRunning)
            .buttonStyle(.borderedProminent)
        }.padding(.top, 6)
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var runner = FFmpegRunner()
    @State private var selection: FFTask? = .mergeAV

    @ViewBuilder
    private func detail(for task: FFTask) -> some View {
        switch task {
        case .mergeAV:      MergeAVView()
        case .convert:      ConvertView()
        case .extractAudio: ExtractAudioView()
        case .removeAudio:  RemoveAudioView()
        case .trim:         TrimView()
        case .resize:       ResizeView()
        case .compress:     CompressView()
        case .toGIF:        GIFView()
        case .frames:       FramesView()
        }
    }

    var body: some View {
        NavigationSplitView {
            List(FFTask.allCases, selection: $selection) { task in
                Label(task.title, systemImage: task.icon)
                    .tag(task)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .navigationTitle("FFmpeg GUI")
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if let sel = selection {
                        detail(for: sel)
                    } else {
                        Text("Select a task")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .environmentObject(runner)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: runner.progress)
                    HStack {
                        Text(runner.status).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        if runner.isRunning {
                            Button("Cancel", role: .destructive) { runner.cancel() }
                        }
                        Button("Clear log") { runner.log = "" }
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(runner.log.isEmpty ? "ffmpeg output will appear here…" : runner.log)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(runner.log.isEmpty ? .secondary : .green)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .id("logBottom")
                        }
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(6)
                        .frame(height: 180)
                        .onChange(of: runner.log) { _, _ in
                            proxy.scrollTo("logBottom", anchor: .bottom)
                        }
                    }
                }
                .padding(10)
                .environmentObject(runner)
            }
        }
    }
}
