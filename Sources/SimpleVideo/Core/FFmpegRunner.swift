import SwiftUI
import Foundation

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

    private func unsafeOverlap(args: [String]) -> String? {
        guard let outRaw = args.last, !outRaw.hasPrefix("-") else { return nil }
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

    private func handleStderr(_ data: Data) {
        stderrBuffer.append(data)
        var decoded = ""
        var consumed = 0
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
        if log.count > 200_000 {
            let head = log.prefix(20_000)
            let tail = log.suffix(130_000)
            log = head + "\n…[log truncated]…\n" + tail
        }
    }
}
