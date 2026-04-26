import SwiftUI
import AppKit
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
    case concat = "Concatenate"
    case convert = "Convert Video"
    case convertAudio = "Convert Audio"

    var id: String { rawValue }
    var title: String { rawValue }

    var icon: String {
        switch self {
        case .mergeAV:       return "plus.square.on.square"
        case .concat:        return "text.line.first.and.arrowtriangle.forward"
        case .convert:       return "arrow.triangle.2.circlepath"
        case .convertAudio:  return "waveform"
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
    private var stderrBuffer: Data = Data()

    nonisolated private static let binaryCache = BinaryCache()

    nonisolated static func resolveBinary(_ name: String) -> String {
        binaryCache.resolve(name)
    }

    /// Probes media duration via ffprobe. Safe to call off the main actor —
    /// blocks the calling thread until ffprobe returns.
    nonisolated static func probeDuration(_ path: String) -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: resolveBinary("ffprobe"))
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
        pendingOutput = (args.last?.hasPrefix("-") == false) ? (args.last ?? "") : ""
        pendingSuccess = onSuccess

        let bin = Self.resolveBinary("ffmpeg")
        let full = ["-hide_banner", "-loglevel", "info", "-progress", "pipe:2"] + args
        appendLog("$ \(bin) \(full.joined(separator: " "))\n")

        // Probe duration off the main actor so the UI doesn't stall on slow disks.
        if let path = inputForDuration {
            Task.detached(priority: .userInitiated) {
                let d = FFmpegRunner.probeDuration(path)
                await MainActor.run { self.duration = d }
            }
        } else {
            duration = 0
        }

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
            Task { @MainActor in self?.handleStderr(data) }
        }

        p.terminationHandler = { [weak self] proc in
            // Drain anything left in the pipe so the final ffmpeg summary
            // (and any error tail) is visible in the log.
            handle.readabilityHandler = nil
            let tail = handle.readDataToEndOfFile()
            Task { @MainActor in
                if !tail.isEmpty { self?.handleStderr(tail) }
                self?.finished(code: proc.terminationStatus)
            }
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

    /// Accumulate raw bytes so a multi-byte UTF-8 character split across pipe
    /// reads doesn't corrupt the log. Decode whatever forms a valid prefix.
    private func handleStderr(_ data: Data) {
        stderrBuffer.append(data)
        var decoded = ""
        var consumed = 0
        // Try the whole buffer first; on failure trim trailing bytes that may
        // be a partial multi-byte sequence (UTF-8 sequences are at most 4 bytes).
        for trim in 0..<min(4, stderrBuffer.count) {
            let slice = stderrBuffer.prefix(stderrBuffer.count - trim)
            if let s = String(data: slice, encoding: .utf8) {
                decoded = s
                consumed = slice.count
                break
            }
        }
        if consumed > 0 {
            stderrBuffer.removeFirst(consumed)
            appendLog(decoded)
            parseProgress(decoded)
        }
    }

    private func parseProgress(_ s: String) {
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
        stderrBuffer.removeAll(keepingCapacity: false)
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
        // Keep both head (command line, codec init) and tail (recent activity);
        // drop the middle so users keep diagnostic context on long runs.
        if log.count > 200_000 {
            let head = log.prefix(20_000)
            let tail = log.suffix(130_000)
            log = head + "\n…[log truncated]…\n" + tail
        }
    }
}

/// Thread-safe cache of resolved tool paths so we don't spawn a shell on
/// every Run. Resolution is performed once per binary name per app launch.
private final class BinaryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    func resolve(_ name: String) -> String {
        lock.lock()
        if let hit = cache[name] { lock.unlock(); return hit }
        lock.unlock()

        let resolved = Self.lookup(name)

        lock.lock()
        cache[name] = resolved
        lock.unlock()
        return resolved
    }

    private static func lookup(_ name: String) -> String {
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
        if let p = whichViaShell(name) { return p }
        return name
    }

    /// Use a non-interactive `/bin/sh` so we don't pay the cost of sourcing
    /// the user's full zsh init (oh-my-zsh, plugins, etc.) on app launch.
    /// We pre-augment PATH with the standard Homebrew/MacPorts locations so
    /// `command -v` finds tools installed there even without user PATH.
    private static func whichViaShell(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let path = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin"
        p.environment = ["PATH": path]
        p.arguments = ["-c", "command -v \(name)"]
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
}

// MARK: - File picker helpers

enum Files {
    static func openFile(contentTypes: [UTType] = []) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if !contentTypes.isEmpty {
            panel.allowedContentTypes = contentTypes
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Common UI bits

/// Generates an output path next to `input` named with a millisecond timestamp
/// so collisions are effectively impossible.
/// Example: `/Users/me/Movies/clip.mov`, ext `mp4`
///       → `/Users/me/Movies/20260426-001234-567.mp4`
func makeOutputPath(input: String, ext: String) -> String {
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

private let formLabelWidth: CGFloat = 100

struct FilePickerRow: View {
    let label: String
    @Binding var path: String
    var contentTypes: [UTType] = []

    @State private var isDropTarget = false

    private var displayName: String {
        path.isEmpty ? "" : (path as NSString).lastPathComponent
    }

    private func browse() {
        if let p = Files.openFile(contentTypes: contentTypes) {
            path = p
        }
    }

    var body: some View {
        HStack {
            Text(label).frame(width: formLabelWidth, alignment: .trailing)
            ZStack(alignment: .leading) {
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { browse() }
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor))
                    )
                    .help(path.isEmpty ? "" : path)

                if displayName.isEmpty {
                    Text("No file selected — drag a file here or click Browse")
                        .foregroundColor(.secondary)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isDropTarget ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let u = url, u.isFileURL else { return }
                    if !contentTypes.isEmpty {
                        let values = try? u.resourceValues(forKeys: [.contentTypeKey])
                        guard let ct = values?.contentType,
                              contentTypes.contains(where: { ct.conforms(to: $0) }) else {
                            return
                        }
                    }
                    DispatchQueue.main.async { self.path = u.path }
                }
                return true
            }
            Button("Browse…") { browse() }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Always-visible output row. The label is always shown; the path and
/// Reveal button only appear after a successful run.
struct OutputHintRow: View {
    let path: String
    var body: some View {
        HStack {
            Text("Output →").frame(width: formLabelWidth, alignment: .trailing)
                .foregroundColor(.secondary)
            if path.isEmpty {
                Spacer()
            } else {
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
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            FilePickerRow(label: "Input video:", path: $input, contentTypes: [.movie, .audiovisualContent])
            HStack {
                Text("Output format:").frame(width: formLabelWidth, alignment: .trailing)
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
    @State private var input = ""
    @State private var format = "mp3"
    @State private var completedOutput = ""

    let audioFormats = ["mp3", "aac", "m4a", "flac", "wav", "ogg", "opus", "wma", "aiff"]

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
            FilePickerRow(label: "Input audio:", path: $input, contentTypes: [.audio, .movie, .audiovisualContent])
            HStack {
                Text("Output format:").frame(width: formLabelWidth, alignment: .trailing)
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
    @State private var video = ""
    @State private var audio = ""
    @State private var completedOutput = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            FilePickerRow(label: "Video file:", path: $video, contentTypes: [.movie, .audiovisualContent])
            FilePickerRow(label: "Audio file:", path: $audio, contentTypes: [.audio, .movie, .audiovisualContent])
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
    @State private var files: [String] = []
    @State private var completedOutput = ""

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        if panel.runModal() == .OK {
            files.append(contentsOf: panel.urls.map(\.path))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Videos:").frame(width: formLabelWidth, alignment: .trailing)
                Text("\(files.count) file\(files.count == 1 ? "" : "s") added")
                    .foregroundColor(.secondary)
                Spacer()
                Button("Add Files…") { addFiles() }
                Button("Clear") { files.removeAll(); completedOutput = "" }
                    .disabled(files.isEmpty)
            }

            if !files.isEmpty {
                HStack(alignment: .top) {
                    Spacer().frame(width: formLabelWidth)
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
                    .cornerRadius(6)
                }
            }

            OutputHintRow(path: completedOutput)
            RunButton(canRun: files.count >= 2) {
                // Write a temporary concat list file for ffmpeg's concat demuxer.
                let tmp = NSTemporaryDirectory() + "ffmpeg-gui-concat-\(ProcessInfo.processInfo.globallyUniqueString).txt"
                let listing = files.map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
                    .joined(separator: "\n")
                try? listing.write(toFile: tmp, atomically: true, encoding: .utf8)

                let out = makeOutputPath(input: files[0], ext: inputExt(files[0]))
                runner.run(
                    args: ["-f", "concat", "-safe", "0", "-i", tmp,
                           "-c", "copy", "-y", out],
                    inputForDuration: nil
                ) { completedOutput = $0; try? FileManager.default.removeItem(atPath: tmp) }
            }
        }
        .padding()
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
        case .concat:       ConcatView()
        case .convert:      ConvertView()
        case .convertAudio: ConvertAudioView()
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
