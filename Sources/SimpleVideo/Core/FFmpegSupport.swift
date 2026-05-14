import SwiftUI
import Foundation

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

struct WhisperModelInfo: Identifiable, Hashable {
    let id: String
    let displayName: String
    let filename: String
    let sizeDescription: String
    let downloadURL: URL
}

enum WhisperModelCatalog {
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

final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
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
