import Foundation

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
