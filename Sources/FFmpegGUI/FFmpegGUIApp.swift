import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

// MARK: - Task model

enum FFTask: String, CaseIterable, Identifiable, Hashable {
    case mergeAV = "Merge A/V"
    case concat = "Concatenate"
    case split = "Split by Timestamps"
    case cutRange = "Remove Time Range"
    case convert = "Convert Video"
    case convertAudio = "Convert Audio"
    case transcribe = "Transcribe"
    case settings = "Settings"

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch language {
        case .english:
            return rawValue
        case .simplifiedChinese:
            switch self {
            case .mergeAV:      return "合并音视频"
            case .concat:       return "拼接文件"
            case .split:        return "按时间戳分割"
            case .cutRange:     return "移除时间段"
            case .convert:      return "转换视频"
            case .convertAudio: return "转换音频"
            case .transcribe:   return "语音转文字"
            case .settings:     return "设置"
            }
        }
    }

    var icon: String {
        switch self {
        case .mergeAV:       return "plus.square.on.square"
        case .concat:        return "text.line.first.and.arrowtriangle.forward"
        case .split:         return "scissors"
        case .cutRange:      return "timeline.selection"
        case .convert:       return "arrow.triangle.2.circlepath"
        case .convertAudio:  return "waveform"
        case .transcribe:    return "text.bubble"
        case .settings:      return "gearshape"
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .english
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

enum L {
    static func text(_ language: AppLanguage, _ english: String, _ simplifiedChinese: String) -> String {
        switch language {
        case .english: return english
        case .simplifiedChinese: return simplifiedChinese
        }
    }

    static func selectTask(_ language: AppLanguage) -> String {
        switch language {
        case .english: return "Select a task"
        case .simplifiedChinese: return "选择一个功能"
        }
    }

    static func cancel(_ language: AppLanguage) -> String {
        switch language {
        case .english: return "Cancel"
        case .simplifiedChinese: return "取消"
        }
    }

    static func clearLog(_ language: AppLanguage) -> String {
        switch language {
        case .english: return "Clear log"
        case .simplifiedChinese: return "清空日志"
        }
    }

    static func logPlaceholder(_ language: AppLanguage) -> String {
        switch language {
        case .english: return "ffmpeg output will appear here…"
        case .simplifiedChinese: return "ffmpeg 输出会显示在这里…"
        }
    }

    static func fileCount(_ language: AppLanguage, _ count: Int) -> String {
        switch language {
        case .english: return "\(count) file\(count == 1 ? "" : "s") added"
        case .simplifiedChinese: return "已添加 \(count) 个文件"
        }
    }
}

// MARK: - FFmpeg runner

@MainActor
final class FFmpegRunner: ObservableObject {
    @Published var log: String = ""
    @Published var progress: Double = 0
    @Published var status: String = L.text(.current, "Idle", "空闲")
    @Published var isRunning: Bool = false

    private var process: Process?
    private var duration: Double = 0
    private var pendingOutput: String = ""
    private var pendingSuccess: ((String) -> Void)?
    private var stderrBuffer: Data = Data()

    /// All subprocesses launched by the app, for cleanup on quit.
    nonisolated(unsafe) private static var trackedProcesses: [Int32: Process] = [:]
    nonisolated private static let processLock = NSLock()

    nonisolated static func trackProcess(_ p: Process) {
        processLock.lock()
        trackedProcesses[p.processIdentifier] = p
        processLock.unlock()
    }

    nonisolated static func untrackProcess(_ p: Process) {
        processLock.lock()
        trackedProcesses.removeValue(forKey: p.processIdentifier)
        processLock.unlock()
    }

    /// Terminate all running subprocesses. Called on app quit.
    nonisolated static func terminateAll() {
        processLock.lock()
        let procs = trackedProcesses.values.filter { $0.isRunning }
        processLock.unlock()
        for p in procs { p.terminate() }
    }

    nonisolated private static let binaryCache = BinaryCache()

    nonisolated static func resolveBinary(_ name: String) -> String {
        binaryCache.resolve(name)
    }

    nonisolated static func resolveWhisperModel(_ name: String) -> String? {
        binaryCache.resolveWhisperModel(name)
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

    nonisolated static func hasAudioStream(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: resolveBinary("ffprobe"))
        p.arguments = [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries", "stream=codec_type",
            "-of", "default=noprint_wrappers=1:nokey=1",
            path
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !s.isEmpty
        } catch {
            return false
        }
    }

    func run(args: [String], inputForDuration: String?, onSuccess: ((String) -> Void)? = nil) {
        guard !isRunning else { return }

        // SAFETY GUARD: ensure output (last arg) doesn't match any input (after -i).
        // ffmpeg never writes back to input files itself, but `-y` would clobber any
        // file we accidentally pass as the output. This catches programmer mistakes.
        if let unsafe = unsafeOverlap(args: args) {
            log = ""
            appendLog(L.text(.current,
                             "⚠️  Refusing to run: output path matches an input file:\n  \(unsafe)\n    This is a safety guard to protect your source files.\n",
                             "⚠️  拒绝运行：输出路径与输入文件相同：\n  \(unsafe)\n    这是用于保护源文件的安全检查。\n"))
            status = L.text(.current, "Aborted: output would overwrite input", "已中止：输出会覆盖输入文件")
            return
        }

        isRunning = true
        progress = 0
        log = ""
        status = L.text(.current, "Running…", "正在运行…")
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
            FFmpegRunner.untrackProcess(proc)
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
            Self.trackProcess(p)
            self.process = p
        } catch {
            appendLog("ERROR: \(error.localizedDescription)\n")
            isRunning = false
            status = L.text(.current, "Failed to launch ffmpeg", "启动 ffmpeg 失败")
        }
    }

    func cancel() {
        process?.interrupt()
        appendLog("\n[cancel requested]\n")
    }

    func attachProcess(_ process: Process) {
        self.process = process
    }

    func clearAttachedProcess(_ process: Process? = nil) {
        guard let current = self.process else { return }
        guard process == nil || current.processIdentifier == process?.processIdentifier else { return }
        self.process = nil
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
            status = L.text(.current, "Done ✓", "完成 ✓")
            if !pendingOutput.isEmpty {
                pendingSuccess?(pendingOutput)
            }
        } else {
            status = L.text(.current, "ffmpeg exited with code \(code)", "ffmpeg 退出，代码 \(code)")
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
        for p in bundledExecutableCandidates(for: name) where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
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

    func resolveWhisperModel(_ name: String) -> String? {
        for filename in WhisperModelCatalog.filenames(for: name) {
            for dir in WhisperModelCatalog.modelSearchDirectories() {
                let path = URL(fileURLWithPath: dir, isDirectory: true)
                    .appendingPathComponent(filename).path
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
            for root in Self.resourceRoots() {
                let path = root.appendingPathComponent("whisper-models/\(filename)").path
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    private static func bundledExecutableCandidates(for name: String) -> [String] {
        let aliases: [String]
        switch name {
        case "whisper":
            aliases = ["whisper-cli", "whisper"]
        default:
            aliases = [name]
        }

        return resourceRoots().flatMap { root in
            aliases.map { root.appendingPathComponent("bin/\($0)").path }
        }
    }

    private static func resourceRoots() -> [URL] {
        var roots: [URL] = []
        let fm = FileManager.default

        func add(_ url: URL?) {
            guard let url else { return }
            let std = url.standardizedFileURL
            guard fm.fileExists(atPath: std.path) else { return }
            guard !roots.contains(where: { $0.path == std.path }) else { return }
            roots.append(std)
        }

        add(Bundle.main.resourceURL)
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        add(cwd.appendingPathComponent("Resources", isDirectory: true))

        return roots
    }

}

private struct WhisperModelInfo: Identifiable, Hashable {
    let id: String
    let displayName: String
    let filename: String
    let sizeDescription: String
    let downloadURL: URL
}

private enum WhisperModelCatalog {
    static let models: [WhisperModelInfo] = [
        model(id: "tiny", displayName: "Tiny", filename: "ggml-tiny.bin", size: "~75 MB"),
        model(id: "base", displayName: "Base", filename: "ggml-base.bin", size: "~142 MB"),
        model(id: "small", displayName: "Small", filename: "ggml-small.bin", size: "~466 MB"),
        model(id: "medium", displayName: "Medium", filename: "ggml-medium.bin", size: "~1.5 GB"),
        model(id: "large", displayName: "Large v3", filename: "ggml-large-v3.bin", size: "~2.9 GB"),
    ]

    static func info(for id: String) -> WhisperModelInfo {
        models.first(where: { $0.id == id }) ?? models[1]
    }

    static func filenames(for id: String) -> [String] {
        let selected = info(for: id).filename
        switch id {
        case "tiny":
            return [selected, "ggml-tiny.en.bin"]
        case "base":
            return [selected, "ggml-base.en.bin"]
        case "small":
            return [selected, "ggml-small.en.bin"]
        case "medium":
            return [selected, "ggml-medium.en.bin"]
        case "large":
            return [selected, "ggml-large-v3-turbo.bin", "ggml-large-v2.bin", "ggml-large.bin"]
        default:
            return [selected]
        }
    }

    static func modelDirectory(create: Bool) throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory,
                              in: .userDomainMask,
                              appropriateFor: nil,
                              create: true)
        let dir = base
            .appendingPathComponent("Simple Video", isDirectory: true)
            .appendingPathComponent("whisper-models", isDirectory: true)
        if create {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func modelSearchDirectories() -> [String] {
        let env = ProcessInfo.processInfo.environment
        return [
            try? modelDirectory(create: false).path,
            env["SIMPLE_VIDEO_WHISPER_MODEL_DIR"],
            env["WHISPER_MODEL_DIR"]
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
    }

    static func downloadedModelURL(for info: WhisperModelInfo) throws -> URL {
        try modelDirectory(create: true).appendingPathComponent(info.filename)
    }

    static func downloadedModelURLs(for id: String) -> [URL] {
        guard let dir = try? modelDirectory(create: false) else { return [] }
        return filenames(for: id)
            .map { dir.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var modelDirectoryDisplayPath: String {
        let path = (try? modelDirectory(create: false).path)
            ?? "~/Library/Application Support/Simple Video/whisper-models"
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func model(id: String, displayName: String, filename: String, size: String) -> WhisperModelInfo {
        WhisperModelInfo(
            id: id,
            displayName: displayName,
            filename: filename,
            sizeDescription: size,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
        )
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: @MainActor (Double) -> Void
    private let completion: @MainActor (Result<URL, Error>) -> Void
    private var downloadedURL: URL?
    private var responseError: Error?

    init(
        progressHandler: @escaping @MainActor (Double) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        self.progressHandler = progressHandler
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in progressHandler(progress) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            responseError = URLError(.badServerResponse)
            return
        }

        let stableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simple-video-model-\(UUID().uuidString).bin")
        do {
            try FileManager.default.moveItem(at: location, to: stableURL)
            downloadedURL = stableURL
        } catch {
            responseError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        session.finishTasksAndInvalidate()
        Task { @MainActor in
            if let error {
                completion(.failure(error))
            } else if let responseError {
                completion(.failure(responseError))
            } else if let downloadedURL {
                completion(.success(downloadedURL))
            } else {
                completion(.failure(URLError(.badServerResponse)))
            }
        }
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

func makeOutputDirectory(input: String, label: String) -> String {
    let url = URL(fileURLWithPath: input)
    let dir = url.deletingLastPathComponent().path
    let baseName = url.deletingPathExtension().lastPathComponent
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
    let stamp = fmt.string(from: Date())
    return "\(dir)/\(baseName)-\(label)-\(stamp)"
}

func inputExt(_ path: String) -> String {
    let e = (path as NSString).pathExtension
    return e.isEmpty ? "mp4" : e
}

func parseTimestamp(_ raw: String) -> Double? {
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return nil }

    var values: [Double] = []
    for part in parts {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed), value >= 0 else { return nil }
        values.append(value)
    }

    switch values.count {
    case 1:
        return values[0]
    case 2:
        guard values[1] < 60 else { return nil }
        return values[0] * 60 + values[1]
    case 3:
        guard values[1] < 60, values[2] < 60 else { return nil }
        return values[0] * 3600 + values[1] * 60 + values[2]
    default:
        return nil
    }
}

enum TimestampParseResult {
    case success([Double])
    case failure(String)
}

func parseTimestampList(_ raw: String) -> TimestampParseResult {
    let tokens = raw
        .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard !tokens.isEmpty else {
        return .failure("Enter at least one timestamp.")
    }

    var seconds: [Double] = []
    for token in tokens {
        guard let value = parseTimestamp(token), value > 0 else {
            return .failure("Invalid timestamp: \(token)")
        }
        seconds.append(value)
    }

    let sorted = seconds.sorted()
    guard sorted == seconds else {
        return .failure("Timestamps must be in ascending order.")
    }
    guard Set(seconds).count == seconds.count else {
        return .failure("Timestamps must be unique.")
    }

    return .success(seconds)
}

func ffmpegTimestampList(_ seconds: [Double]) -> String {
    seconds
        .map { value in
            let text = String(format: "%.3f", value)
            return text.replacingOccurrences(of: #"(\.\d*?[1-9])0+$|\.0+$"#,
                                             with: "$1",
                                             options: .regularExpression)
        }
        .joined(separator: ",")
}

func ffmpegTime(_ seconds: Double) -> String {
    ffmpegTimestampList([seconds])
}

private let formLabelWidth: CGFloat = 100

struct FilePickerRow: View {
    let label: String
    @Binding var path: String
    var contentTypes: [UTType] = []

    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var isDropTarget = false

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

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
                    Text(L.text(language,
                                "No file selected — drag a file here or click Browse",
                                "未选择文件 — 可拖入文件或点击浏览"))
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
            Button(L.text(language, "Browse…", "浏览…")) { browse() }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Always-visible output row. The label is always shown; the path and
/// Reveal button only appear after a successful run.
struct OutputHintRow: View {
    let path: String
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    var body: some View {
        HStack {
            Text(L.text(language, "Output →", "输出 →")).frame(width: formLabelWidth, alignment: .trailing)
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
                .help(L.text(language, "Reveal in Finder", "在 Finder 中显示"))
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

// MARK: - Transcribe

struct TranscribeView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var inputPath = ""
    @State private var model = "base"
    @State private var language = ""
    @State private var transcript = ""
    @State private var isTranscribing = false
    @State private var isDownloadingModel = false
    @State private var downloadProgress: Double = 0
    @State private var modelStatusVersion = 0

    private var selectedModel: WhisperModelInfo {
        WhisperModelCatalog.info(for: model)
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    private func modelDisplayName(_ model: WhisperModelInfo) -> String {
        switch appLanguage {
        case .english:
            return model.displayName
        case .simplifiedChinese:
            switch model.id {
            case "tiny": return "Tiny（微型）"
            case "base": return "Base（基础）"
            case "small": return "Small（小型）"
            case "medium": return "Medium（中型）"
            case "large": return "Large v3（大型）"
            default: return model.displayName
            }
        }
    }

    private var selectedModelPath: String? {
        _ = modelStatusVersion
        return FFmpegRunner.resolveWhisperModel(model)
    }

    private var selectedDownloadedModelURLs: [URL] {
        _ = modelStatusVersion
        return WhisperModelCatalog.downloadedModelURLs(for: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FilePickerRow(label: L.text(appLanguage, "Input:", "输入："), path: $inputPath,
                           contentTypes: [.movie, .video, .audio])

            HStack(spacing: 0) {
                Text(L.text(appLanguage, "Model:", "模型：")).frame(width: formLabelWidth, alignment: .trailing)
                Picker("model", selection: $model) {
                    ForEach(WhisperModelCatalog.models) { model in
                        Text("\(modelDisplayName(model)) (\(model.sizeDescription))").tag(model.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .padding(.leading, 6)
                Spacer()
            }

            HStack(alignment: .top) {
                Text(L.text(appLanguage, "Model file:", "模型文件：")).frame(width: formLabelWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    if selectedModelPath != nil {
                        Label(selectedDownloadedModelURLs.isEmpty
                              ? L.text(appLanguage, "Available", "可用")
                              : L.text(appLanguage, "Downloaded", "已下载"),
                              systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        if !selectedDownloadedModelURLs.isEmpty {
                            HStack(spacing: 8) {
                                Button(role: .destructive, action: deleteSelectedModel) {
                                    Label(L.text(appLanguage, "Delete \(selectedModel.displayName)", "删除 \(modelDisplayName(selectedModel))"), systemImage: "trash")
                                }
                                .disabled(isDownloadingModel || isTranscribing || runner.isRunning)
                                Text(L.text(appLanguage,
                                            "Removes it from \(WhisperModelCatalog.modelDirectoryDisplayPath)",
                                            "从 \(WhisperModelCatalog.modelDirectoryDisplayPath) 中移除"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text(L.text(appLanguage,
                                        "This model is coming from the app bundle or an external model directory.",
                                        "此模型来自应用包或外部模型目录。"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(L.text(appLanguage,
                                    "Required before transcription. Saved to \(WhisperModelCatalog.modelDirectoryDisplayPath)",
                                    "转写前需要先下载。保存到 \(WhisperModelCatalog.modelDirectoryDisplayPath)"))
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Button(action: downloadSelectedModel) {
                            Label(isDownloadingModel
                                  ? L.text(appLanguage, "Downloading \(selectedModel.displayName)…", "正在下载 \(modelDisplayName(selectedModel))…")
                                  : L.text(appLanguage, "Download \(selectedModel.displayName)", "下载 \(modelDisplayName(selectedModel))"),
                                  systemImage: "arrow.down.circle")
                        }
                        .disabled(isDownloadingModel || runner.isRunning)
                        if isDownloadingModel {
                            ProgressView(value: downloadProgress)
                                .frame(maxWidth: 320)
                            Text("\(Int(downloadProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
            }

            HStack {
                Text(L.text(appLanguage, "Language:", "语言：")).frame(width: formLabelWidth, alignment: .trailing)
                TextField(L.text(appLanguage, "auto-detect", "自动检测"), text: $language)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Text(L.text(appLanguage, "e.g. en, zh, ja", "例如 en、zh、ja")).foregroundColor(.secondary).font(.caption)
                Spacer()
            }

            HStack {
                Spacer()
                Button(action: transcribe) {
                    Label(L.text(appLanguage, "Transcribe", "转写"), systemImage: "text.bubble")
                        .frame(minWidth: 100)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(inputPath.isEmpty || selectedModelPath == nil || isDownloadingModel || isTranscribing || runner.isRunning)
                .buttonStyle(.borderedProminent)
            }.padding(.top, 6)

            if !transcript.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L.text(appLanguage, "Transcript:", "转写结果：")).font(.headline)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transcript, forType: .string)
                        } label: {
                            Label(L.text(appLanguage, "Copy", "复制"), systemImage: "doc.on.doc")
                        }
                    }
                    ScrollView {
                        Text(transcript)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .frame(maxHeight: 250)
                }
            }
        }
        .padding()
    }

    private func transcribe() {
        let whisperBin = FFmpegRunner.resolveBinary("whisper")
        let ffmpegBin = FFmpegRunner.resolveBinary("ffmpeg")
        let selectedModel = model
        let languageCode = language.trimmingCharacters(in: .whitespacesAndNewlines)

        if !FileManager.default.isExecutableFile(atPath: whisperBin) {
            runner.log = ""
            runner.status = L.text(appLanguage, "whisper not found", "找不到 whisper")
            runner.log = L.text(
                appLanguage,
                "⚠️  Could not find a bundled whisper.cpp CLI.\n\nExpected one of these inside the app bundle or project Resources:\n  Resources/bin/whisper-cli\n  Resources/bin/whisper\n",
                "⚠️  找不到内置的 whisper.cpp 命令行工具。\n\n应用包或项目 Resources 中需要包含：\n  Resources/bin/whisper-cli\n  Resources/bin/whisper\n"
            )
            return
        }
        if !FileManager.default.isExecutableFile(atPath: ffmpegBin) {
            runner.log = ""
            runner.status = L.text(appLanguage, "ffmpeg not found", "找不到 ffmpeg")
            runner.log = L.text(
                appLanguage,
                "⚠️  Could not find ffmpeg.\n\nBundle it at Resources/bin/ffmpeg or install it system-wide.",
                "⚠️  找不到 ffmpeg。\n\n请将它打包到 Resources/bin/ffmpeg，或在系统中安装。"
            )
            return
        }
        guard let modelPath = FFmpegRunner.resolveWhisperModel(selectedModel) else {
            runner.log = ""
            runner.status = L.text(appLanguage, "model not found", "找不到模型")
            runner.log = L.text(
                appLanguage,
                "⚠️  Could not find the selected whisper.cpp model.\n\nClick Download Model first. Models are saved to:\n  \(WhisperModelCatalog.modelDirectoryDisplayPath)\n",
                "⚠️  找不到所选的 whisper.cpp 模型。\n\n请先点击下载模型。模型会保存到：\n  \(WhisperModelCatalog.modelDirectoryDisplayPath)\n"
            )
            return
        }

        isTranscribing = true
        transcript = ""
        runner.progress = 0
        runner.log = ""
        runner.status = L.text(appLanguage, "Preparing audio…", "正在准备音频…")
        runner.isRunning = true

        let tmpDir = NSTemporaryDirectory() + "simple-video-whisper-\(ProcessInfo.processInfo.globallyUniqueString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        let wavPath = (tmpDir as NSString).appendingPathComponent("input.wav")
        let outputPrefix = (tmpDir as NSString).appendingPathComponent("transcript")

        runLoggedProcess(
            executable: ffmpegBin,
            arguments: [
                "-hide_banner", "-loglevel", "info", "-y",
                "-i", inputPath,
                "-map", "0:a:0?",
                "-vn",
                "-ac", "1",
                "-ar", "16000",
                "-c:a", "pcm_s16le",
                wavPath
            ],
            launchFailureStatus: L.text(appLanguage, "Failed to launch ffmpeg", "启动 ffmpeg 失败"),
            cleanupPath: tmpDir
        ) { status in
            guard status == 0 else {
                finishTranscription(tmpDir: tmpDir, status: L.text(appLanguage, "ffmpeg exited with code \(status)", "ffmpeg 退出，代码 \(status)"))
                return
            }

            runner.progress = 0.2
            runner.status = L.text(appLanguage, "Transcribing…", "正在转写…")

            var args = ["-m", modelPath, "-f", wavPath, "-otxt", "-of", outputPrefix]
            args += ["-l", languageCode.isEmpty ? "auto" : languageCode]

            runLoggedProcess(
                executable: whisperBin,
                arguments: args,
                launchFailureStatus: L.text(appLanguage, "Failed to launch whisper.cpp", "启动 whisper.cpp 失败"),
                cleanupPath: tmpDir
            ) { whisperStatus in
                guard whisperStatus == 0 else {
                    finishTranscription(tmpDir: tmpDir, status: L.text(appLanguage, "whisper.cpp exited with code \(whisperStatus)", "whisper.cpp 退出，代码 \(whisperStatus)"))
                    return
                }

                let txtPath = outputPrefix + ".txt"
                if let content = try? String(contentsOfFile: txtPath, encoding: .utf8) {
                    transcript = content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                finishTranscription(tmpDir: tmpDir, status: L.text(appLanguage, "Done ✓", "完成 ✓"), progress: 1.0)
            }
        }
    }

    private func runLoggedProcess(
        executable: String,
        arguments: [String],
        launchFailureStatus: String,
        cleanupPath: String,
        onExit: @escaping @MainActor (Int32) -> Void
    ) {
        runner.log += "$ \(executable) \(arguments.joined(separator: " "))\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stderr = Pipe()
        let stdout = Pipe()
        process.standardError = stderr
        process.standardOutput = stdout

        let append: @MainActor (Data) -> Void = { data in
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            runner.log += text
        }

        let stderrHandle = stderr.fileHandleForReading
        stderrHandle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { return }
            Task { @MainActor in append(data) }
        }

        let stdoutHandle = stdout.fileHandleForReading
        stdoutHandle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { return }
            Task { @MainActor in append(data) }
        }

        process.terminationHandler = { proc in
            FFmpegRunner.untrackProcess(proc)
            stderrHandle.readabilityHandler = nil
            stdoutHandle.readabilityHandler = nil
            let tailErr = stderrHandle.readDataToEndOfFile()
            let tailOut = stdoutHandle.readDataToEndOfFile()

            Task { @MainActor in
                append(tailErr)
                append(tailOut)
                runner.clearAttachedProcess(proc)
                onExit(proc.terminationStatus)
            }
        }

        do {
            try process.run()
            FFmpegRunner.trackProcess(process)
            runner.attachProcess(process)
        } catch {
            runner.log += "ERROR: \(error.localizedDescription)\n"
            finishTranscription(tmpDir: cleanupPath, status: launchFailureStatus)
        }
    }

    private func finishTranscription(tmpDir: String, status: String, progress: Double = 0) {
        runner.progress = progress
        runner.status = status
        runner.isRunning = false
        runner.clearAttachedProcess()
        isTranscribing = false
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func downloadSelectedModel() {
        let info = selectedModel
        isDownloadingModel = true
        downloadProgress = 0
        runner.log = L.text(appLanguage,
                            "Downloading \(info.displayName) model from:\n\(info.downloadURL.absoluteString)\n",
                            "正在从以下地址下载 \(modelDisplayName(info)) 模型：\n\(info.downloadURL.absoluteString)\n")
        runner.status = L.text(appLanguage, "Downloading \(info.displayName) model…", "正在下载 \(modelDisplayName(info)) 模型…")
        runner.progress = 0

        Task {
            do {
                let destination = try WhisperModelCatalog.downloadedModelURL(for: info)
                let temporaryURL = try await downloadFile(from: info.downloadURL) { progress in
                    downloadProgress = progress
                    runner.progress = progress
                    runner.status = L.text(appLanguage,
                                           "Downloading \(info.displayName) model \(Int(progress * 100))%",
                                           "正在下载 \(modelDisplayName(info)) 模型 \(Int(progress * 100))%")
                }

                let fm = FileManager.default
                do {
                    _ = try fm.replaceItemAt(destination, withItemAt: temporaryURL, backupItemName: nil, options: [])
                } catch {
                    guard !fm.fileExists(atPath: destination.path) else { throw error }
                    try fm.moveItem(at: temporaryURL, to: destination)
                }

                modelStatusVersion += 1
                downloadProgress = 1
                runner.progress = 1
                runner.status = L.text(appLanguage, "Model downloaded ✓", "模型已下载 ✓")
                runner.log += L.text(appLanguage, "Saved model to:\n\(destination.path)\n", "模型已保存到：\n\(destination.path)\n")
            } catch {
                runner.status = L.text(appLanguage, "Model download failed", "模型下载失败")
                runner.log += "ERROR: \(error.localizedDescription)\n"
            }
            isDownloadingModel = false
        }
    }

    private func deleteSelectedModel() {
        let info = selectedModel
        let urls = selectedDownloadedModelURLs
        guard !urls.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = L.text(appLanguage, "Delete \(info.displayName) model?", "删除 \(modelDisplayName(info)) 模型？")
        alert.informativeText = L.text(
            appLanguage,
            "This removes the downloaded model from:\n\(WhisperModelCatalog.modelDirectoryDisplayPath)\n\nYou can download it again later.",
            "这会从以下位置移除已下载的模型：\n\(WhisperModelCatalog.modelDirectoryDisplayPath)\n\n之后可以重新下载。"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L.text(appLanguage, "Delete", "删除"))
        alert.addButton(withTitle: L.text(appLanguage, "Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            for url in urls {
                try FileManager.default.removeItem(at: url)
            }
            modelStatusVersion += 1
            runner.progress = 0
            runner.status = L.text(appLanguage, "Model deleted", "模型已删除")
            runner.log = L.text(appLanguage, "Deleted \(info.displayName) model:\n", "已删除 \(modelDisplayName(info)) 模型：\n") +
                urls.map { $0.path }.joined(separator: "\n") + "\n"
        } catch {
            runner.status = L.text(appLanguage, "Model delete failed", "模型删除失败")
            runner.log = "ERROR: \(error.localizedDescription)\n"
        }
    }

    private func downloadFile(
        from url: URL,
        progressHandler: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        final class DownloadBox {
            var delegate: ModelDownloadDelegate?
            var session: URLSession?
            var task: URLSessionDownloadTask?
        }

        let box = DownloadBox()
        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let delegate = ModelDownloadDelegate(
                progressHandler: progressHandler,
                completion: { result in
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(with: result)
                    box.delegate = nil
                    box.session = nil
                    box.task = nil
                }
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            box.delegate = delegate
            box.session = session
            box.task = task
            task.resume()
        }
    }
}

struct RunButton: View {
    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    let canRun: Bool
    let action: () -> Void

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Label(L.text(language, "Run", "运行"), systemImage: "play.fill")
                    .frame(minWidth: 100)
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canRun || runner.isRunning)
            .buttonStyle(.borderedProminent)
        }.padding(.top, 6)
    }
}

struct SettingsView: View {
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    private func licenseLink(_ title: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.up.right.square")
                    .imageScale(.small)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(language == .english ? "Settings" : "设置")
                .font(.largeTitle)
                .fontWeight(.semibold)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(language == .english ? "Language:" : "语言：")
                            .frame(width: formLabelWidth, alignment: .trailing)
                        Picker("", selection: $appLanguageRaw) {
                            ForEach(AppLanguage.allCases) { option in
                                Text(option.displayName).tag(option.rawValue)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text(language == .english
                         ? "Changes apply immediately to supported interface text."
                         : "更改会立即应用到已支持的界面文字。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } label: {
                Label(language == .english ? "General" : "通用", systemImage: "gearshape")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Simple Video")
                        .font(.headline)
                    Text("© 2026 Gavin Cheng. All rights reserved.")
                    Text(language == .english
                         ? "Powered by FFmpeg and whisper.cpp."
                         : "由 FFmpeg 和 whisper.cpp 提供支持。")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } label: {
                Label(language == .english ? "Copyright" : "版权信息", systemImage: "info.circle")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(language == .english
                         ? "This app bundles and runs third-party command-line tools. They remain under their own licenses."
                         : "本应用打包并调用第三方命令行工具。这些组件仍遵循其各自的许可证。")
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        licenseLink("FFmpeg", "https://ffmpeg.org/")
                        licenseLink(language == .english ? "FFmpeg legal / license information" : "FFmpeg 法律与许可信息",
                                    "https://ffmpeg.org/legal.html")
                        licenseLink(language == .english ? "FFmpeg source code" : "FFmpeg 源代码",
                                    "https://ffmpeg.org/download.html")
                        licenseLink("whisper.cpp (MIT)", "https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE")
                        licenseLink(language == .english ? "Whisper model files" : "Whisper 模型文件",
                                    "https://huggingface.co/ggerganov/whisper.cpp")
                        licenseLink(language == .english ? "OpenAI Whisper license" : "OpenAI Whisper 许可证",
                                    "https://github.com/openai/whisper/blob/main/LICENSE")
                    }

                    Text(language == .english
                         ? "FFmpeg may include codecs/libraries with different licenses depending on the bundled build."
                         : "根据打包的 FFmpeg 构建方式，其中的编解码器和库可能使用不同许可证。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } label: {
                Label(language == .english ? "Third-party Licenses" : "第三方许可", systemImage: "doc.text")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var runner = FFmpegRunner()
    @State private var selection: FFTask? = .mergeAV
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    @ViewBuilder
    private func detail(for task: FFTask) -> some View {
        switch task {
        case .mergeAV:      MergeAVView()
        case .concat:       ConcatView()
        case .split:        SplitByTimestampsView()
        case .cutRange:     CutRangeView()
        case .convert:      ConvertView()
        case .convertAudio: ConvertAudioView()
        case .transcribe:   TranscribeView()
        case .settings:     SettingsView()
        }
    }

    var body: some View {
        NavigationSplitView {
            List(FFTask.allCases, selection: $selection) { task in
                Label(task.title(language: appLanguage), systemImage: task.icon)
                    .tag(task)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .navigationTitle("Simple Video")
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if let sel = selection {
                        GeometryReader { geo in
                            ScrollView {
                                detail(for: sel)
                                    .frame(minHeight: geo.size.height)
                            }
                        }
                    } else {
                        Text(L.selectTask(appLanguage))
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
                            Button(L.cancel(appLanguage), role: .destructive) { runner.cancel() }
                        }
                        Button(L.clearLog(appLanguage)) { runner.log = "" }
                            .disabled(runner.log.isEmpty)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(runner.log.isEmpty ? L.logPlaceholder(appLanguage) : runner.log)
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
