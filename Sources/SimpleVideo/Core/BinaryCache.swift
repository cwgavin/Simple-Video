import Foundation

final class BinaryCache: @unchecked Sendable {
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
