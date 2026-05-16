import SwiftUI
import AppKit

struct CropParameters {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

enum TrimHandleSelection {
    case start, end
}

enum CropPreviewPlaybackMode {
    case original
    case compatibilityProxy
}

enum CropPlaybackRateOption: Double, CaseIterable, Identifiable {
    case half = 0.5
    case threeQuarter = 0.75
    case normal = 1.0
    case oneAndQuarter = 1.25
    case oneAndHalf = 1.5
    case double = 2.0

    var id: Double { rawValue }

    func title(language: AppLanguage) -> String {
        if rawValue == 1.0 {
            return L.text(language, "1.0× (Normal)", "1.0×（正常）")
        }
        return String(format: "%.2gx", rawValue)
    }
}

enum CropPreviewArtifacts {
    private static let proxyPrefix = "simple-video-crop-proxy-"
    private static let previewPrefix = "simple-video-crop-preview-"
    nonisolated(unsafe) private static var trackedPaths: Set<String> = []
    nonisolated private static let lock = NSLock()

    static func register(_ path: String) {
        lock.lock()
        trackedPaths.insert(path)
        lock.unlock()
    }

    static func unregister(_ path: String) {
        lock.lock()
        trackedPaths.remove(path)
        lock.unlock()
    }

    static func cleanupAll() {
        let fm = FileManager.default

        lock.lock()
        let tracked = Array(trackedPaths)
        trackedPaths.removeAll()
        lock.unlock()

        for path in tracked {
            try? fm.removeItem(atPath: path)
        }

        guard let urls = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in urls {
            let name = url.lastPathComponent
            guard name.hasPrefix(proxyPrefix) || name.hasPrefix(previewPrefix) else { continue }
            try? fm.removeItem(at: url)
        }
    }
}

enum CropExportQualityOption: String, CaseIterable, Identifiable {
    case highest
    case balanced
    case smaller

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .highest:
            return L.text(language, "Highest quality", "最高画质")
        case .balanced:
            return L.text(language, "Balanced", "均衡")
        case .smaller:
            return L.text(language, "Smaller file", "更小文件")
        }
    }

    func summary(language: AppLanguage) -> String {
        switch self {
        case .highest:
            return L.text(language, "Slower export, less visible recompression.", "导出更慢，重编码痕迹更少。")
        case .balanced:
            return L.text(language, "Good default quality and speed balance.", "默认推荐，兼顾画质和速度。")
        case .smaller:
            return L.text(language, "Faster to store and share, with more compression.", "体积更小，更适合分享，但压缩更明显。")
        }
    }

    var videoArguments: [String] {
        switch self {
        case .highest:
            return ["-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p"]
        case .balanced:
            return ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]
        case .smaller:
            return ["-c:v", "libx264", "-preset", "medium", "-crf", "24", "-pix_fmt", "yuv420p"]
        }
    }
}

struct CropAspectRatioOption: Identifiable, Hashable {
    let id: String
    let ratio: CGFloat?

    func title(language: AppLanguage) -> String {
        switch id {
        case "free":
            return L.text(language, "Free", "自由")
        case "16:9", "9:16", "1:1", "4:3":
            return id
        default:
            return id
        }
    }
}
