import SwiftUI
import AppKit
import Combine

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

final class CropVideoSession: ObservableObject {
    private struct BaselineState {
        let input: String
        let cropRect: CGRect
        let trimStart: Double
        let trimEnd: Double
    }

    private static let fullFrameCropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    fileprivate static let comparisonTolerance = 0.0001

    @Published var input = ""
    @Published var cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @Published var selectedAspectRatio = "free"
    @Published var completedOutput = ""
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var previewPlaybackTime: Double = 0
    @Published var selectedTrimHandle: TrimHandleSelection = .start
    @Published var exportQuality = CropExportQualityOption.balanced
    @Published var exportPlaybackRate = CropPlaybackRateOption.normal
    private var baselineState: BaselineState?

    var hasPendingChanges: Bool {
        guard !input.isEmpty, let baselineState else { return false }
        let current = currentState()
        return current.input != baselineState.input
            || !current.cropRect.isApproximatelyEqual(to: baselineState.cropRect)
            || abs(current.trimStart - baselineState.trimStart) > Self.comparisonTolerance
            || abs(current.trimEnd - baselineState.trimEnd) > Self.comparisonTolerance
    }

    func resetCropSelection() {
        selectedAspectRatio = "free"
        cropRect = Self.fullFrameCropRect
    }

    func clearPendingChangesBaseline() {
        baselineState = nil
    }

    func markCurrentStateAsBaseline() {
        guard !input.isEmpty else {
            baselineState = nil
            return
        }
        baselineState = currentState()
    }

    private func currentState() -> BaselineState {
        BaselineState(
            input: input,
            cropRect: cropRect,
            trimStart: trimStart,
            trimEnd: trimEnd
        )
    }
}

final class CropAudioSession: ObservableObject {
    private struct BaselineState {
        let input: String
        let trimStart: Double
        let trimEnd: Double
    }

    @Published var input = ""
    @Published var completedOutput = ""
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var previewPlaybackTime: Double = 0
    @Published var selectedTrimHandle: TrimHandleSelection = .start
    @Published var exportPlaybackRate = CropPlaybackRateOption.normal
    private var baselineState: BaselineState?

    var hasPendingChanges: Bool {
        guard !input.isEmpty, let baselineState else { return false }
        let current = currentState()
        return current.input != baselineState.input
            || abs(current.trimStart - baselineState.trimStart) > CropVideoSession.comparisonTolerance
            || abs(current.trimEnd - baselineState.trimEnd) > CropVideoSession.comparisonTolerance
    }

    func clearPendingChangesBaseline() {
        baselineState = nil
    }

    func markCurrentStateAsBaseline() {
        guard !input.isEmpty else {
            baselineState = nil
            return
        }
        baselineState = currentState()
    }

    private func currentState() -> BaselineState {
        BaselineState(
            input: input,
            trimStart: trimStart,
            trimEnd: trimEnd
        )
    }
}

func cropMinimumTrimDuration(for duration: Double) -> Double {
    0.1
}

func formatCropPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let wholeSeconds = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
}

func cropAudioTempoFilter(for rate: Double) -> String {
    guard rate.isFinite, rate > 0 else { return "atempo=1.0" }

    var remaining = rate
    var components: [String] = []

    while remaining > 2.0 {
        components.append("atempo=2.0")
        remaining /= 2.0
    }

    while remaining < 0.5 {
        components.append("atempo=0.5")
        remaining /= 0.5
    }

    if abs(remaining - 1.0) > CropVideoSession.comparisonTolerance || components.isEmpty {
        components.append(String(format: "atempo=%.8f", remaining))
    }

    return components.joined(separator: ",")
}

private extension CGRect {
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat = CropVideoSession.comparisonTolerance) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
