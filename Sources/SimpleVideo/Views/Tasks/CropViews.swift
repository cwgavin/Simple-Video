import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct CropParameters {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private enum CropHandle {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

private enum TrimHandleSelection {
    case start, end
}

private enum CropPreviewPlaybackMode {
    case original
    case compatibilityProxy
}

private enum CropPlaybackRateOption: Double, CaseIterable, Identifiable {
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

private enum CropExportQualityOption: String, CaseIterable, Identifiable {
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

private struct CropAspectRatioOption: Identifiable, Hashable {
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

private final class CropPlayerPreviewNSView: NSView {
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func setPlayer(_ player: AVPlayer?) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }
}

private struct CropPlayerPreviewView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> CropPlayerPreviewNSView {
        let view = CropPlayerPreviewNSView()
        view.setPlayer(player)
        return view
    }

    func updateNSView(_ nsView: CropPlayerPreviewNSView, context: Context) {
        nsView.setPlayer(player)
    }

    static func dismantleNSView(_ nsView: CropPlayerPreviewNSView, coordinator: ()) {
        nsView.setPlayer(nil)
    }
}

private struct TrimTimelineView: View {
    let duration: Double
    let minimumDuration: Double
    let startHandleLabel: String
    let endHandleLabel: String
    let formatTime: (Double) -> String
    let selectedHandle: TrimHandleSelection
    @Binding var start: Double
    @Binding var end: Double
    @Binding var playhead: Double
    let onSeek: (Double) -> Void
    let onSetStart: (Double) -> Void
    let onSetEnd: (Double) -> Void
    let onSelectStart: () -> Void
    let onSelectEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let startX = xPosition(for: start, width: width)
            let endX = xPosition(for: end, width: width)
            let playheadX = xPosition(for: playhead, width: width)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .separatorColor).opacity(0.35))
                    .frame(height: 14)
                    .offset(y: 20)
                    .gesture(playheadDragGesture(width: width))

                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(endX - startX, 1), height: 14)
                    .offset(x: startX, y: 20)
                    .gesture(playheadDragGesture(width: width))

                excludedRegion(width: startX)
                    .offset(y: 20)
                excludedRegion(width: max(width - endX, 0))
                    .offset(x: endX, y: 20)

                timeHandle(label: startHandleLabel, isSelected: selectedHandle == .start)
                    .position(x: startX, y: 27)
                    .onTapGesture {
                        onSelectStart()
                    }
                    .gesture(startDragGesture(width: width))

                timeHandle(label: endHandleLabel, isSelected: selectedHandle == .end)
                    .position(x: endX, y: 27)
                    .onTapGesture {
                        onSelectEnd()
                    }
                    .gesture(endDragGesture(width: width))

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 34)
                    .shadow(radius: 1)
                    .position(x: playheadX, y: 27)
                    .gesture(playheadDragGesture(width: width))

                HStack {
                    Text(formatTime(start))
                    Spacer()
                    Text(formatTime(playhead))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(formatTime(end))
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .offset(y: 48)
            }
        }
        .frame(height: 72)
    }

    private func excludedRegion(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.35))
            .frame(width: max(width, 0), height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func timeHandle(label: String, isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.75))
            .frame(width: 18, height: 32)
            .overlay {
                Text(label)
                    .font(.caption2.bold())
                    .foregroundColor(.white)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.white : Color.white.opacity(0.7), lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? Color.accentColor.opacity(0.35) : .clear, radius: 3)
    }

    private func startDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelectStart()
                let next = min(max(time(for: value.location.x, width: width), 0), max(end - minimumDuration, 0))
                onSetStart(next)
            }
    }

    private func endDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelectEnd()
                let next = min(max(time(for: value.location.x, width: width), start + minimumDuration), duration)
                onSetEnd(next)
            }
    }

    private func playheadDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let next = min(max(time(for: value.location.x, width: width), 0), duration)
                onSeek(next)
            }
    }

    private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return min(max(CGFloat(time / duration) * width, 0), width)
    }

    private func time(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }
}

struct CropEditorView: View {
    let image: NSImage?
    let player: AVPlayer?
    let imagePixelSize: CGSize
    let fixedAspectRatio: CGFloat?
    @Binding var cropRect: CGRect

    @State private var dragStart: CGRect?
    @State private var resizeStart: CGRect?

    private var imageAspect: CGFloat {
        guard imagePixelSize.height > 0 else { return 1 }
        return imagePixelSize.width / imagePixelSize.height
    }

    var body: some View {
        GeometryReader { geo in
            let displayRect = fittedImageRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.86)

                if player != nil {
                    CropPlayerPreviewView(player: player)
                        .frame(width: displayRect.width, height: displayRect.height)
                        .position(x: displayRect.midX, y: displayRect.midY)
                        .allowsHitTesting(false)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: displayRect.width, height: displayRect.height)
                        .position(x: displayRect.midX, y: displayRect.midY)
                }

                if displayRect.width > 0, displayRect.height > 0 {
                    overlayMask(displayRect: displayRect)
                    cropBox(displayRect: displayRect)
                }
            }
        }
        .frame(minHeight: 320)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fittedImageRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let containerAspect = size.width / size.height
        let fittedSize: CGSize
        if containerAspect > imageAspect {
            let height = size.height
            fittedSize = CGSize(width: height * imageAspect, height: height)
        } else {
            let width = size.width
            fittedSize = CGSize(width: width, height: width / imageAspect)
        }
        return CGRect(
            x: (size.width - fittedSize.width) / 2,
            y: (size.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func displayedCropRect(in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + cropRect.minX * imageRect.width,
            y: imageRect.minY + cropRect.minY * imageRect.height,
            width: cropRect.width * imageRect.width,
            height: cropRect.height * imageRect.height
        )
    }

    private func overlayMask(displayRect: CGRect) -> some View {
        let crop = displayedCropRect(in: displayRect)
        return Path { path in
            path.addRect(displayRect)
            path.addRect(crop)
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
    }

    private func cropBox(displayRect: CGRect) -> some View {
        let crop = displayedCropRect(in: displayRect)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.08))
                .frame(width: crop.width, height: crop.height)
                .position(x: crop.midX, y: crop.midY)
                .gesture(moveGesture(displayRect: displayRect))

            handle(.topLeft, at: CGPoint(x: crop.minX, y: crop.minY), displayRect: displayRect)
            handle(.top, at: CGPoint(x: crop.midX, y: crop.minY), displayRect: displayRect)
            handle(.topRight, at: CGPoint(x: crop.maxX, y: crop.minY), displayRect: displayRect)
            handle(.right, at: CGPoint(x: crop.maxX, y: crop.midY), displayRect: displayRect)
            handle(.bottomRight, at: CGPoint(x: crop.maxX, y: crop.maxY), displayRect: displayRect)
            handle(.bottom, at: CGPoint(x: crop.midX, y: crop.maxY), displayRect: displayRect)
            handle(.bottomLeft, at: CGPoint(x: crop.minX, y: crop.maxY), displayRect: displayRect)
            handle(.left, at: CGPoint(x: crop.minX, y: crop.midY), displayRect: displayRect)
        }
    }

    private func handle(_ handle: CropHandle, at point: CGPoint, displayRect: CGRect) -> some View {
        handleShape(handle)
            .position(point)
            .gesture(resizeGesture(handle, displayRect: displayRect))
    }

    @ViewBuilder
    private func handleShape(_ handle: CropHandle) -> some View {
        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            Circle()
                .fill(Color.accentColor)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
        case .top, .bottom:
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor)
                .frame(width: 32, height: 8)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1))
        case .left, .right:
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor)
                .frame(width: 8, height: 32)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1))
        }
    }

    private func moveGesture(displayRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = cropRect }
                guard let start = dragStart else { return }
                let dx = value.translation.width / max(displayRect.width, 1)
                let dy = value.translation.height / max(displayRect.height, 1)
                cropRect = clampedMovingCropRect(CGRect(
                    x: start.minX + dx,
                    y: start.minY + dy,
                    width: start.width,
                    height: start.height
                ))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ handle: CropHandle, displayRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStart == nil { resizeStart = cropRect }
                guard let start = resizeStart else { return }
                let dx = value.translation.width / max(displayRect.width, 1)
                let dy = value.translation.height / max(displayRect.height, 1)
                var next = start

                switch handle {
                case .topLeft:
                    next.origin.x += dx
                    next.origin.y += dy
                    next.size.width -= dx
                    next.size.height -= dy
                case .top:
                    next.origin.y += dy
                    next.size.height -= dy
                case .topRight:
                    next.origin.y += dy
                    next.size.width += dx
                    next.size.height -= dy
                case .right:
                    next.size.width += dx
                case .bottomRight:
                    next.size.width += dx
                    next.size.height += dy
                case .bottom:
                    next.size.height += dy
                case .bottomLeft:
                    next.origin.x += dx
                    next.size.width -= dx
                    next.size.height += dy
                case .left:
                    next.origin.x += dx
                    next.size.width -= dx
                }

                if let fixedAspectRatio {
                    cropRect = aspectLockedCropRect(proposed: next, anchorFor: handle, aspectRatio: normalizedAspectRatio(for: fixedAspectRatio))
                } else {
                    cropRect = clampedMovingCropRect(next)
                }
            }
            .onEnded { _ in resizeStart = nil }
    }

    private func normalizedAspectRatio(for pixelAspectRatio: CGFloat) -> CGFloat {
        guard imageAspect > 0 else { return pixelAspectRatio }
        return pixelAspectRatio / imageAspect
    }

    private func clampedMovingCropRect(_ rect: CGRect) -> CGRect {
        let minSize: CGFloat = 0.03
        let width = min(max(rect.width, minSize), 1)
        let height = min(max(rect.height, minSize), 1)
        let x = min(max(rect.minX, 0), 1 - width)
        let y = min(max(rect.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func aspectLockedCropRect(proposed: CGRect, anchorFor handle: CropHandle, aspectRatio: CGFloat) -> CGRect {
        guard let start = resizeStart, aspectRatio > 0 else {
            return clampedMovingCropRect(proposed)
        }

        if !isCorner(handle) {
            return aspectLockedEdgeCropRect(proposed: proposed, edge: handle, aspectRatio: aspectRatio)
        }

        let minSize: CGFloat = 0.03
        let anchor: CGPoint
        let maxWidth: CGFloat
        let maxHeight: CGFloat

        switch handle {
        case .topLeft:
            anchor = CGPoint(x: start.maxX, y: start.maxY)
            maxWidth = anchor.x
            maxHeight = anchor.y
        case .topRight:
            anchor = CGPoint(x: start.minX, y: start.maxY)
            maxWidth = 1 - anchor.x
            maxHeight = anchor.y
        case .bottomLeft:
            anchor = CGPoint(x: start.maxX, y: start.minY)
            maxWidth = anchor.x
            maxHeight = 1 - anchor.y
        case .bottomRight:
            anchor = CGPoint(x: start.minX, y: start.minY)
            maxWidth = 1 - anchor.x
            maxHeight = 1 - anchor.y
        default:
            return clampedMovingCropRect(proposed)
        }

        let proposedWidth = max(minSize, abs(proposed.width))
        let proposedHeight = max(minSize, abs(proposed.height))
        var width: CGFloat
        var height: CGFloat

        if proposedWidth / proposedHeight > aspectRatio {
            height = proposedHeight
            width = height * aspectRatio
        } else {
            width = proposedWidth
            height = width / aspectRatio
        }

        width = min(max(width, minSize), maxWidth, maxHeight * aspectRatio)
        height = width / aspectRatio
        if height > maxHeight {
            height = maxHeight
            width = height * aspectRatio
        }

        switch handle {
        case .topLeft:
            return CGRect(x: anchor.x - width, y: anchor.y - height, width: width, height: height)
        case .topRight:
            return CGRect(x: anchor.x, y: anchor.y - height, width: width, height: height)
        case .bottomLeft:
            return CGRect(x: anchor.x - width, y: anchor.y, width: width, height: height)
        case .bottomRight:
            return CGRect(x: anchor.x, y: anchor.y, width: width, height: height)
        default:
            return clampedMovingCropRect(proposed)
        }
    }

    private func isCorner(_ handle: CropHandle) -> Bool {
        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            return true
        default:
            return false
        }
    }

    private func aspectLockedEdgeCropRect(proposed: CGRect, edge: CropHandle, aspectRatio: CGFloat) -> CGRect {
        guard let start = resizeStart else { return clampedMovingCropRect(proposed) }

        let minSize: CGFloat = 0.03
        var width: CGFloat
        var height: CGFloat
        var center = CGPoint(x: start.midX, y: start.midY)

        switch edge {
        case .left:
            width = max(minSize, start.maxX - proposed.minX)
            height = width / aspectRatio
            center.x = start.maxX - width / 2
        case .right:
            width = max(minSize, proposed.maxX - start.minX)
            height = width / aspectRatio
            center.x = start.minX + width / 2
        case .top:
            height = max(minSize, start.maxY - proposed.minY)
            width = height * aspectRatio
            center.y = start.maxY - height / 2
        case .bottom:
            height = max(minSize, proposed.maxY - start.minY)
            width = height * aspectRatio
            center.y = start.minY + height / 2
        default:
            return clampedMovingCropRect(proposed)
        }

        width = min(width, 1)
        height = min(height, 1)
        if width / aspectRatio > 1 {
            width = aspectRatio
            height = 1
        }
        if height * aspectRatio > 1 {
            height = 1 / aspectRatio
            width = 1
        }

        return clampedMovingCropRect(CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        ))
    }
}

struct CropVideoView: View {
    let isActive: Bool

    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var input = ""
    @State private var previewImage: NSImage?
    @State private var previewPixelSize: CGSize = .zero
    @State private var cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var selectedAspectRatio = "free"
    @State private var isLoadingPreview = false
    @State private var isDetectingBlackBars = false
    @State private var previewError = ""
    @State private var completedOutput = ""
    @State private var player: AVPlayer?
    @State private var playbackTime: Double = 0
    @State private var playbackDuration: Double = 0
    @State private var isPlaying = false
    @State private var isPreviewingTrim = false
    @State private var isTrimPreviewPaused = false
    @State private var showingLargeEditor = false
    @State private var playbackTimeObserver: Any?
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var selectedTrimHandle: TrimHandleSelection = .start
    @State private var trimFrameDuration: Double?
    @State private var exportQuality = CropExportQualityOption.balanced
    @State private var exportPlaybackRate = CropPlaybackRateOption.normal
    @State private var previewPlaybackMode: CropPreviewPlaybackMode = .original
    @State private var previewProxyPath: String?
    @State private var isGeneratingPreviewProxy = false
    @State private var proxyGenerationTask: Task<Void, Never>?
    @State private var proxyGenerationProcess: Process?
    @State private var proxyGenerationID: UInt = 0

    private let aspectRatioOptions = [
        CropAspectRatioOption(id: "free", ratio: nil),
        CropAspectRatioOption(id: "16:9", ratio: 16.0 / 9.0),
        CropAspectRatioOption(id: "9:16", ratio: 9.0 / 16.0),
        CropAspectRatioOption(id: "1:1", ratio: 1.0),
        CropAspectRatioOption(id: "4:3", ratio: 4.0 / 3.0),
    ]

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    private var selectedAspectRatioOption: CropAspectRatioOption {
        aspectRatioOptions.first(where: { $0.id == selectedAspectRatio }) ?? aspectRatioOptions[0]
    }

    private var selectedTrimRange: (start: Double, end: Double)? {
        guard playbackDuration > minimumTrimDuration(for: playbackDuration) else { return nil }
        let start = min(max(trimStart, 0), playbackDuration)
        let end = min(max(trimEnd, start), playbackDuration)
        guard end > start else { return nil }
        if start <= 0.001, end >= playbackDuration - 0.001 {
            return nil
        }
        return (start, end)
    }

    private var cropParameters: CropParameters? {
        guard previewPixelSize.width >= 2, previewPixelSize.height >= 2 else { return nil }
        let pixelWidth = Int(previewPixelSize.width.rounded(.down))
        let pixelHeight = Int(previewPixelSize.height.rounded(.down))

        var x = evenInt(cropRect.minX * CGFloat(pixelWidth))
        var y = evenInt(cropRect.minY * CGFloat(pixelHeight))
        var width = max(2, evenInt(cropRect.width * CGFloat(pixelWidth)))
        var height = max(2, evenInt(cropRect.height * CGFloat(pixelHeight)))

        if x + width > pixelWidth { width = max(2, evenInt(CGFloat(pixelWidth - x))) }
        if y + height > pixelHeight { height = max(2, evenInt(CGFloat(pixelHeight - y))) }
        if x + width > pixelWidth { x = max(0, evenInt(CGFloat(pixelWidth - width))) }
        if y + height > pixelHeight { y = max(0, evenInt(CGFloat(pixelHeight - height))) }

        return CropParameters(x: x, y: y, width: width, height: height)
    }

    private var isUsingPreviewProxy: Bool {
        previewPlaybackMode == .compatibilityProxy
    }

    private var hasVisualCrop: Bool {
        guard let params = cropParameters else { return false }
        return !isFullFrameCrop(params)
    }

    private var requiresVideoReencode: Bool {
        hasVisualCrop || selectedTrimRange != nil || exportPlaybackRate != .normal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FilePickerRow(label: L.text(language, "Input video:", "输入视频："), path: $input, contentTypes: [.movie, .video, .audiovisualContent])

            HStack {
                Text(L.text(language, "Aspect ratio:", "裁剪比例："))
                    .frame(width: formLabelWidth, alignment: .trailing)
                Picker("aspect-ratio", selection: $selectedAspectRatio) {
                    ForEach(aspectRatioOptions) { option in
                        Text(option.title(language: language)).tag(option.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }

            HStack(alignment: .top) {
                Text(L.text(language, "Crop area:", "裁剪区域："))
                    .frame(width: formLabelWidth, alignment: .trailing)

                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        if previewImage != nil {
                            CropEditorView(
                                image: previewImage,
                                player: player,
                                imagePixelSize: previewPixelSize,
                                fixedAspectRatio: selectedAspectRatioOption.ratio,
                                cropRect: $cropRect
                            )
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .textBackgroundColor))
                                .overlay {
                                    if isLoadingPreview {
                                        ProgressView(L.text(language, "Loading preview…", "正在加载预览…"))
                                    } else {
                                        Text(input.isEmpty
                                             ? L.text(language, "Choose a video to preview the crop area.", "请选择视频以预览裁剪区域。")
                                             : L.text(language, "Preview unavailable.", "无法显示预览。"))
                                        .foregroundColor(.secondary)
                                    }
                                }
                                .frame(minHeight: 320)
                        }
                    }
                    .frame(minHeight: 320)

                    playbackControls

                    if isGeneratingPreviewProxy {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(L.text(
                                language,
                                "Preparing a compatibility preview for this video…",
                                "正在为这个视频准备兼容预览…"
                            ))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    } else if isUsingPreviewProxy {
                        Text(L.text(
                            language,
                            "Using a temporary compatibility preview. Export still uses the original video.",
                            "当前使用临时兼容预览，最终导出仍然使用原始视频。"
                        ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    if !previewError.isEmpty {
                        Text(previewError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    HStack {
                        if let params = cropParameters {
                            Text(L.text(
                                language,
                                "Crop: \(params.width)×\(params.height) at x=\(params.x), y=\(params.y)",
                                "裁剪：\(params.width)×\(params.height)，x=\(params.x)，y=\(params.y)"
                            ))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            detectBlackBars()
                        } label: {
                            Label(L.text(language, "Auto detect black bars", "自动检测黑边"), systemImage: "wand.and.stars")
                        }
                        .disabled(input.isEmpty || previewImage == nil || isLoadingPreview || isDetectingBlackBars || runner.isRunning)
                        .pointingHandCursor(enabled: !input.isEmpty && previewImage != nil && !isLoadingPreview && !isDetectingBlackBars && !runner.isRunning)
                        Button {
                            showingLargeEditor = true
                        } label: {
                            Label(L.text(language, "Full-screen crop", "全屏裁剪"), systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .disabled(previewImage == nil)
                        .pointingHandCursor(enabled: previewImage != nil)
                        Button(L.text(language, "Reset crop", "重置裁剪")) {
                            selectedAspectRatio = "free"
                            cropRect = defaultCropRect()
                        }
                        .disabled(previewImage == nil || isDetectingBlackBars)
                        .pointingHandCursor(enabled: previewImage != nil && !isDetectingBlackBars)
                    }
                    if isDetectingBlackBars {
                        ProgressView(L.text(language, "Detecting black bars…", "正在检测黑边…"))
                            .controlSize(.small)
                    }
                }
            }

            HStack(alignment: .top) {
                Text(L.text(language, "Time range:", "时间范围："))
                    .frame(width: formLabelWidth, alignment: .trailing)
                trimControls
            }

            HStack(alignment: .top) {
                Text(L.text(language, "Export mode:", "导出方式："))
                    .frame(width: formLabelWidth, alignment: .trailing)
                exportControls
            }

            OutputHintRow(path: completedOutput)
            RunButton(canRun: !input.isEmpty && previewImage != nil && cropParameters != nil && !isLoadingPreview) {
                runCrop()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .padding(.trailing, 8)
        .sheet(isPresented: $showingLargeEditor) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L.text(language, "Crop area", "裁剪区域"))
                        .font(.headline)
                    Spacer()
                    Button(L.text(language, "Done", "完成")) {
                        showingLargeEditor = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .pointingHandCursor()
                }
                CropEditorView(
                    image: previewImage,
                    player: player,
                    imagePixelSize: previewPixelSize,
                    fixedAspectRatio: selectedAspectRatioOption.ratio,
                    cropRect: $cropRect
                )
                .frame(minWidth: 1000, minHeight: 620)
                playbackControls
                trimControls
            }
            .padding()
            .padding(.trailing, 8)
            .frame(minWidth: 1080, minHeight: 740)
        }
        .onAppear {
            if isActive, !input.isEmpty, player == nil {
                startPreviewSession(for: input, resetTrimRange: trimEnd <= 0)
            }
        }
        .onDisappear {
            cleanupPreviewSession()
        }
        .onChange(of: isActive) { _, active in
            if active {
                if !input.isEmpty, player == nil {
                    startPreviewSession(for: input, resetTrimRange: trimEnd <= 0)
                }
                if !input.isEmpty, previewImage == nil, !isLoadingPreview {
                    loadPreview(for: input)
                }
            } else {
                showingLargeEditor = false
                cleanupPreviewSession()
            }
        }
        .onChange(of: input) { _, newValue in
            completedOutput = ""
            previewImage = nil
            previewPixelSize = .zero
            selectedAspectRatio = "free"
            cropRect = defaultCropRect()
            previewError = ""
            isDetectingBlackBars = false
            showingLargeEditor = false
            if isActive {
                startPreviewSession(for: newValue, resetTrimRange: true)
            } else {
                cleanupPreviewSession(resetState: true, resetTrimRange: true)
            }
            if isActive, !newValue.isEmpty {
                loadPreview(for: newValue)
            }
        }
        .onChange(of: selectedAspectRatio) { _, _ in
            cropRect = adjustedCropRect(cropRect, for: selectedAspectRatioOption.ratio)
        }
    }

    @ViewBuilder
    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if player == nil {
                Text(L.text(language, "Choose a video to adjust the export range.", "请选择视频以调整导出范围。"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if playbackDuration <= 0 {
                Text(L.text(language, "Loading video duration…", "正在读取视频时长…"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if trimEnd <= 0 {
                Text(L.text(language, "Loading video duration…", "正在读取视频时长…"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                let minimumDuration = minimumTrimDuration(for: playbackDuration)
                if playbackDuration <= minimumDuration {
                    Text(L.text(language, "This video is too short to trim by time.", "这个视频太短，无法按时间裁剪。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(L.text(
                        language,
                        "Drag S/E to choose the exported section. Drag the white playhead to preview a frame, or preview the selected range.",
                        "拖动 S/E 选择导出的片段，拖动白色播放头预览画面，也可以预览选中的片段。"
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)

                    TrimTimelineView(
                        duration: playbackDuration,
                        minimumDuration: minimumDuration,
                        startHandleLabel: "S",
                        endHandleLabel: "E",
                        formatTime: formatPlaybackTime,
                        selectedHandle: selectedTrimHandle,
                        start: $trimStart,
                        end: $trimEnd,
                        playhead: $playbackTime,
                        onSeek: scrubPlayback(to:),
                        onSetStart: setTrimStart(_:),
                        onSetEnd: setTrimEnd(_:),
                        onSelectStart: { selectedTrimHandle = .start },
                        onSelectEnd: { selectedTrimHandle = .end }
                    )

                    HStack {
                        Button(L.text(language, "Set start to playhead", "设为当前开始")) {
                            setTrimStart(playbackTime)
                        }
                        .keyboardShortcut("[", modifiers: .command)
                        .pointingHandCursor()
                        Button(L.text(language, "Set end to playhead", "设为当前结束")) {
                            setTrimEnd(playbackTime)
                        }
                        .keyboardShortcut("]", modifiers: .command)
                        .pointingHandCursor()
                        Button(L.text(language, "Reset range", "重置范围")) {
                            resetTrimRange()
                        }
                        .pointingHandCursor()
                        Button {
                            toggleTrimPreview()
                        } label: {
                            Label(
                                trimPreviewButtonTitle,
                                systemImage: trimPreviewButtonSymbol
                            )
                        }
                        .pointingHandCursor()
                        Button {
                            stopTrimPreview()
                        } label: {
                            Label(L.text(language, "Stop preview", "停止预览"), systemImage: "stop.fill")
                        }
                        .disabled(!canStopTrimPreview)
                        .pointingHandCursor(enabled: canStopTrimPreview)
                        Spacer()
                        Text(trimRangeSummary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.text(
                            language,
                            "Fine-tune S or E one frame at a time here after choosing which handle to adjust.",
                            "在这里先选择要调整的 S 或 E，再按帧微调，这样更容易精确对齐。"
                        ))
                        .font(.caption)
                        .foregroundColor(.secondary)

                        HStack {
                        Picker(
                            L.text(language, "Adjust handle", "调整端点"),
                            selection: $selectedTrimHandle
                        ) {
                            Text("S").tag(TrimHandleSelection.start)
                            Text("E").tag(TrimHandleSelection.end)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 90)

                        Button {
                            nudgeSelectedTrimHandle(byFrames: -1)
                        } label: {
                            Label(L.text(language, "Previous frame", "前一帧"), systemImage: "chevron.left")
                        }
                        .buttonRepeatBehavior(.enabled)
                        .disabled(trimFrameDuration == nil)
                        .pointingHandCursor(enabled: trimFrameDuration != nil)

                        Button {
                            nudgeSelectedTrimHandle(byFrames: 1)
                        } label: {
                            Label(L.text(language, "Next frame", "后一帧"), systemImage: "chevron.right")
                        }
                        .buttonRepeatBehavior(.enabled)
                        .disabled(trimFrameDuration == nil)
                        .pointingHandCursor(enabled: trimFrameDuration != nil)

                        Spacer()
                        Text(frameStepSummary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trimRangeSummary: String {
        let duration = max(trimEnd - trimStart, 0)
        return L.text(
            language,
            "Export: \(formatPlaybackTime(trimStart)) – \(formatPlaybackTime(trimEnd)) (\(formatPlaybackTime(duration)))",
            "导出：\(formatPlaybackTime(trimStart)) – \(formatPlaybackTime(trimEnd))（\(formatPlaybackTime(duration))）"
        )
    }

    private var frameStepSummary: String {
        guard let trimFrameDuration, trimFrameDuration.isFinite, trimFrameDuration > 0 else {
            return L.text(language, "Frame step unavailable", "暂时无法读取单帧步进")
        }

        let fps = 1.0 / trimFrameDuration
        return L.text(
            language,
            String(format: "1 frame = %.4fs (%.2f fps)", trimFrameDuration, fps),
            String(format: "1 帧 = %.4f 秒（%.2f fps）", trimFrameDuration, fps)
        )
    }

    private var trimPreviewButtonTitle: String {
        if isPreviewingTrim {
            return isTrimPreviewPaused
            ? L.text(language, "Resume preview", "继续预览")
            : L.text(language, "Pause preview", "暂停预览")
        }
        return L.text(language, "Preview range", "预览片段")
    }

    private var trimPreviewButtonSymbol: String {
        if isPreviewingTrim {
            return isTrimPreviewPaused ? "play.rectangle" : "pause.rectangle"
        }
        return "play.rectangle"
    }

    private var canStopTrimPreview: Bool {
        isPreviewingTrim
    }

    private var playbackRate: Float {
        Float(exportPlaybackRate.rawValue)
    }

    @ViewBuilder
    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(
                    L.text(language, "Playback rate", "播放倍率"),
                    selection: $exportPlaybackRate
                ) {
                    ForEach(CropPlaybackRateOption.allCases) { option in
                        Text(option.title(language: language)).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }

            Text(L.text(
                language,
                "Preview playback uses this rate, and the exported video keeps the same playback speed.",
                "预览播放会使用这个倍率，导出视频也会保持相同的播放速度。"
            ))
            .font(.caption)
            .foregroundColor(.secondary)

            if hasVisualCrop {
                HStack {
                    Picker(
                        L.text(language, "Export quality", "导出画质"),
                        selection: $exportQuality
                    ) {
                        ForEach(CropExportQualityOption.allCases) { option in
                            Text(option.title(language: language)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }

                Text(exportQuality.summary(language: language))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if selectedTrimRange != nil {
                HStack {
                    Picker(
                        L.text(language, "Export quality", "导出画质"),
                        selection: $exportQuality
                    ) {
                        ForEach(CropExportQualityOption.allCases) { option in
                            Text(option.title(language: language)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    }

                    Text(exportQuality.summary(language: language))
                        .font(.caption)
                        .foregroundColor(.secondary)
            } else if exportPlaybackRate != .normal {
                HStack {
                    Picker(
                        L.text(language, "Export quality", "导出画质"),
                        selection: $exportQuality
                    ) {
                        ForEach(CropExportQualityOption.allCases) { option in
                            Text(option.title(language: language)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }

                Text(exportQuality.summary(language: language))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playbackControlsDisabled: Bool {
        playbackDuration <= 0 || isGeneratingPreviewProxy
    }

    @ViewBuilder
    private var playbackControls: some View {
        if player != nil {
            HStack(spacing: 8) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .disabled(playbackDuration <= 0)
                .pointingHandCursor(enabled: !playbackControlsDisabled)

                Text(L.text(language, "Preview playhead:", "预览播放头："))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Slider(
                    value: Binding(
                        get: { playbackTime },
                        set: scrubPlayback(to:)
                    ),
                    in: 0...max(playbackDuration, 0.01)
                )
                .disabled(playbackDuration <= 0)

                Text("\(formatPlaybackTime(playbackTime)) / \(formatPlaybackTime(playbackDuration))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)
            }
            .disabled(playbackControlsDisabled)
        }
    }

    private func startPreviewSession(for path: String, resetTrimRange: Bool) {
        cleanupPreviewProxy()
        setupPlayback(previewPath: path, metadataPath: path, resetTrimRange: resetTrimRange)
        preparePreviewProxyFallback(for: path)
    }

    private func setupPlayback(
        previewPath: String,
        metadataPath: String,
        resetTrimRange: Bool,
        preservePlaybackState: Bool = false
    ) {
        let preservedTime = preservePlaybackState
            ? min(max(playbackTime, 0), max(playbackDuration, 0))
            : 0
        let shouldResumePlayback = preservePlaybackState && isPlaying
        let shouldKeepTrimPreview = preservePlaybackState && isPreviewingTrim
        let shouldKeepTrimPreviewPaused = preservePlaybackState && isTrimPreviewPaused

        cleanupPlayback(resetState: !preservePlaybackState, resetTrimRange: resetTrimRange)

        guard !previewPath.isEmpty, !metadataPath.isEmpty else {
            return
        }

        let previewAsset = AVURLAsset(url: URL(fileURLWithPath: previewPath))
        let item = AVPlayerItem(asset: previewAsset)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .pause
        player = newPlayer
        trimFrameDuration = nil
        previewPlaybackMode = previewPath == metadataPath ? .original : .compatibilityProxy
        playbackTime = preservedTime
        isPreviewingTrim = shouldKeepTrimPreview
        isTrimPreviewPaused = shouldKeepTrimPreviewPaused

        playbackTimeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak newPlayer] time in
            guard let observedPlayer = newPlayer else { return }
            let currentSeconds = CMTimeGetSeconds(time)
            if currentSeconds.isFinite {
                playbackTime = min(max(currentSeconds, 0), max(playbackDuration, currentSeconds))
                if isPreviewingTrim, playbackTime >= trimPreviewEnd - 0.03 {
                    observedPlayer.pause()
                    seek(to: trimPreviewEnd, cancelTrimPreview: false)
                    isPlaying = false
                    isPreviewingTrim = false
                    isTrimPreviewPaused = false
                    return
                }
            }
            isPlaying = observedPlayer.timeControlStatus == .playing
        }

        if preservedTime > 0 {
            newPlayer.seek(
                to: CMTime(seconds: preservedTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { finished in
                DispatchQueue.main.async {
                    guard finished, self.player === newPlayer else { return }
                    self.playbackTime = preservedTime
                    if shouldResumePlayback {
                        self.startPlayback(using: newPlayer)
                    }
                }
            }
        } else if shouldResumePlayback {
            startPlayback(using: newPlayer)
        }

        Task {
            do {
                let metadataAsset = AVURLAsset(url: URL(fileURLWithPath: metadataPath))
                let duration = try await metadataAsset.load(.duration)
                let frameDuration = try await loadFrameDuration(from: metadataAsset)
                let durationSeconds = CMTimeGetSeconds(duration)
                await MainActor.run {
                    guard player === newPlayer else { return }
                    playbackDuration = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : 0
                    trimFrameDuration = frameDuration
                    if playbackDuration > 0 {
                        if resetTrimRange || trimEnd <= 0 {
                            trimStart = 0
                            trimEnd = playbackDuration
                        } else {
                            clampTrimRange(to: playbackDuration)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    guard player === newPlayer else { return }
                    runner.log += "WARNING: Could not read video duration: \(error.localizedDescription)\n"
                }
            }
        }
    }

    private func preparePreviewProxyFallback(for path: String) {
        proxyGenerationTask?.cancel()
        proxyGenerationTask = nil

        guard !path.isEmpty else {
            isGeneratingPreviewProxy = false
            return
        }

        proxyGenerationID &+= 1
        let requestID = proxyGenerationID

        proxyGenerationTask = Task {
            defer {
                Task { @MainActor in
                    guard proxyGenerationID == requestID else { return }
                    proxyGenerationTask = nil
                }
            }

            let requiresProxy = await Self.requiresPreviewProxy(path: path)
            guard !Task.isCancelled else { return }

            if !requiresProxy {
                await MainActor.run {
                    guard input == path, proxyGenerationID == requestID else { return }
                    isGeneratingPreviewProxy = false
                }
                return
            }

            await MainActor.run {
                guard input == path, proxyGenerationID == requestID else { return }
                isGeneratingPreviewProxy = true
            }

            do {
                let proxyPath = try await Self.generatePreviewProxy(path: path) { process in
                    await MainActor.run {
                        guard input == path, proxyGenerationID == requestID else {
                            return false
                        }
                        proxyGenerationProcess = process
                        return true
                    }
                }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(atPath: proxyPath)
                    return
                }

                let shouldAdopt = await MainActor.run { () -> Bool in
                    guard input == path, proxyGenerationID == requestID else { return false }
                    previewProxyPath = proxyPath
                    CropPreviewArtifacts.register(proxyPath)
                    proxyGenerationProcess = nil
                    isGeneratingPreviewProxy = false
                    return true
                }
                guard shouldAdopt else {
                    try? FileManager.default.removeItem(atPath: proxyPath)
                    return
                }

                await MainActor.run {
                    setupPlayback(
                        previewPath: proxyPath,
                        metadataPath: path,
                        resetTrimRange: false,
                        preservePlaybackState: true
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard input == path, proxyGenerationID == requestID else { return }
                    proxyGenerationProcess = nil
                    isGeneratingPreviewProxy = false
                    runner.log += "WARNING: Could not create a compatibility preview: \(error.localizedDescription)\n"
                }
            }
        }
    }

    private func cleanupPlayback(resetState: Bool = false, resetTrimRange: Bool = false) {
        if let playbackTimeObserver, let player {
            player.removeTimeObserver(playbackTimeObserver)
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playbackTimeObserver = nil
        isPlaying = false
        isPreviewingTrim = false
        isTrimPreviewPaused = false

        if resetState {
            playbackTime = 0
            playbackDuration = 0
        }
        if resetTrimRange {
            trimStart = 0
            trimEnd = 0
        }
    }

    private func cleanupPreviewProxy() {
        proxyGenerationID &+= 1
        proxyGenerationTask?.cancel()
        proxyGenerationTask = nil

        if let process = proxyGenerationProcess, process.isRunning {
            process.terminate()
        }
        proxyGenerationProcess = nil

        if let previewProxyPath {
            CropPreviewArtifacts.unregister(previewProxyPath)
            try? FileManager.default.removeItem(atPath: previewProxyPath)
        }
        previewProxyPath = nil
        previewPlaybackMode = .original
        isGeneratingPreviewProxy = false
    }

    private func cleanupPreviewSession(resetState: Bool = false, resetTrimRange: Bool = false) {
        cleanupPlayback(resetState: resetState, resetTrimRange: resetTrimRange)
        cleanupPreviewProxy()
    }

    private func togglePlayback() {
        guard let player else { return }
        updatePlaybackTime()
        if isPlaying {
            player.pause()
            isPlaying = false
            if isPreviewingTrim {
                isTrimPreviewPaused = true
            } else {
                isPreviewingTrim = false
            }
        } else {
            if isPreviewingTrim {
                resumeTrimPreview()
                return
            }
            if playbackDuration > 0, playbackTime >= playbackDuration - 0.05 {
                seek(to: 0)
            }
            isPreviewingTrim = false
            isTrimPreviewPaused = false
            startPlayback(using: player)
        }
    }

    private func startPlayback(using player: AVPlayer) {
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
    }

    private func seek(to seconds: Double, cancelTrimPreview: Bool = true) {
        let bounded = min(max(seconds, 0), max(playbackDuration, 0))
        playbackTime = bounded
        if cancelTrimPreview {
            isPreviewingTrim = false
            isTrimPreviewPaused = false
        }
        guard let player else { return }

        // Use zero tolerance so manual scrubbing lands on the requested frame
        // instead of snapping to the nearest sync frame.
        player.currentItem?.cancelPendingSeeks()
        player.seek(
            to: CMTime(seconds: bounded, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { finished in
            guard finished else { return }
            let actualSeconds = CMTimeGetSeconds(player.currentTime())
            guard actualSeconds.isFinite else { return }
            Task { @MainActor in
                guard self.player === player else { return }
                self.playbackTime = min(max(actualSeconds, 0), max(self.playbackDuration, actualSeconds))
            }
        }
    }

    private func scrubPlayback(to seconds: Double) {
        seek(to: seconds, cancelTrimPreview: !shouldPreserveTrimPreview(whenSeekingTo: seconds))
    }

    private func shouldPreserveTrimPreview(whenSeekingTo seconds: Double) -> Bool {
        guard isPreviewingTrim else { return false }

        let start = min(max(trimStart, 0), playbackDuration)
        let end = trimPreviewEnd
        guard end > start else { return false }

        let bounded = min(max(seconds, 0), max(playbackDuration, 0))
        return bounded >= start && bounded <= end
    }

    private var trimPreviewEnd: Double {
        guard playbackDuration > 0, trimEnd > 0 else { return playbackDuration }
        return min(max(trimEnd, trimStart), playbackDuration)
    }

    private func toggleTrimPreview() {
        if isPreviewingTrim {
            if isTrimPreviewPaused {
                resumeTrimPreview()
            } else {
                pauseTrimPreview()
            }
        } else {
            startTrimPreview()
        }
    }

    private func startTrimPreview() {
        guard let player, playbackDuration > 0 else { return }
        let start = min(max(trimStart, 0), playbackDuration)
        let end = trimPreviewEnd
        guard end > start else { return }

        player.pause()
        isPlaying = false
        isPreviewingTrim = false
        isTrimPreviewPaused = false
        player.seek(
            to: CMTime(seconds: start, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { finished in
            DispatchQueue.main.async {
                guard finished, self.player === player else { return }
                self.playbackTime = start
                self.isPreviewingTrim = true
                self.isTrimPreviewPaused = false
                self.startPlayback(using: player)
            }
        }
    }

    private func pauseTrimPreview() {
        guard isPreviewingTrim else { return }
        player?.pause()
        isPlaying = false
        isTrimPreviewPaused = true
    }

    private func resumeTrimPreview() {
        guard let player, isPreviewingTrim else { return }

        let start = min(max(trimStart, 0), playbackDuration)
        let end = trimPreviewEnd
        guard end > start else { return }

        if playbackTime < start || playbackTime >= end - 0.03 {
            seek(to: start, cancelTrimPreview: false)
        }
        isTrimPreviewPaused = false
        startPlayback(using: player)
    }

    private func stopTrimPreview() {
        player?.pause()
        isPlaying = false
        isPreviewingTrim = false
        isTrimPreviewPaused = false
    }

    private func setTrimStart(_ seconds: Double) {
        guard playbackDuration > 0 else { return }
        let maxStart = max(0, trimEnd - minimumTrimDuration(for: playbackDuration))
        trimStart = min(max(seconds, 0), maxStart)
        seek(to: trimStart)
    }

    private func setTrimEnd(_ seconds: Double) {
        guard playbackDuration > 0 else { return }
        let minEnd = min(playbackDuration, trimStart + minimumTrimDuration(for: playbackDuration))
        trimEnd = min(max(seconds, minEnd), playbackDuration)
        seek(to: trimEnd)
    }

    private func resetTrimRange() {
        trimStart = 0
        trimEnd = playbackDuration
        seek(to: 0)
    }

    private func nudgeSelectedTrimHandle(byFrames frames: Int) {
        guard let trimFrameDuration, trimFrameDuration.isFinite, trimFrameDuration > 0 else { return }
        let offset = Double(frames) * trimFrameDuration
        switch selectedTrimHandle {
        case .start:
            setTrimStart(trimStart + offset)
        case .end:
            setTrimEnd(trimEnd + offset)
        }
    }

    private func clampTrimRange(to duration: Double) {
        let minimumDuration = minimumTrimDuration(for: duration)
        trimStart = min(max(trimStart, 0), max(duration - minimumDuration, 0))
        trimEnd = min(max(trimEnd, trimStart + minimumDuration), duration)
    }

    private func minimumTrimDuration(for duration: Double) -> Double {
        0.1
    }

    private func loadFrameDuration(from asset: AVURLAsset) async throws -> Double? {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return nil }

        let nominalFrameRate = try await track.load(.nominalFrameRate)
        if nominalFrameRate.isFinite, nominalFrameRate > 0 {
            return 1.0 / Double(nominalFrameRate)
        }

        let minimumFrameDuration = try await track.load(.minFrameDuration)
        let seconds = CMTimeGetSeconds(minimumFrameDuration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private func updatePlaybackTime() {
        guard let player else {
            isPlaying = false
            return
        }

        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        if currentSeconds.isFinite {
            playbackTime = min(max(currentSeconds, 0), max(playbackDuration, currentSeconds))
        }

        isPlaying = player.timeControlStatus == .playing
        if playbackDuration > 0, playbackTime >= playbackDuration - 0.05, player.timeControlStatus != .playing {
            isPlaying = false
        }
    }

    private func formatPlaybackTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let wholeSeconds = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }

    private func runCrop() {
        guard let params = cropParameters else { return }

        if requiresVideoReencode {
            let out = makeOutputPath(input: input, ext: "mp4")
            if let trimRange = selectedTrimRange {
                var args = ["-i", input, "-ss", ffmpegTime(trimRange.start), "-t", ffmpegTime(trimRange.end - trimRange.start)]
                args += reencodedOutputArguments(output: out, cropParameters: hasVisualCrop ? params : nil)
                runner.run(args: args, inputForDuration: input) { completedOutput = $0 }
            } else {
                let args = ["-i", input] + reencodedOutputArguments(output: out, cropParameters: hasVisualCrop ? params : nil)
                runner.run(args: args, inputForDuration: input) { completedOutput = $0 }
            }
            return
        }

        let out = makeOutputPath(input: input, ext: inputExt(input))
        let args: [String]
        if let trimRange = selectedTrimRange {
            args = [
                "-ss", ffmpegTime(trimRange.start),
                "-i", input,
                "-t", ffmpegTime(trimRange.end - trimRange.start)
            ] + copyOutputArguments(output: out)
        } else {
            args = ["-i", input] + copyOutputArguments(output: out)
        }
        runner.run(args: args, inputForDuration: input) { completedOutput = $0 }
    }

    private func reencodedOutputArguments(output: String, cropParameters: CropParameters?) -> [String] {
        let hasAudio = FFmpegRunner.hasAudioStream(input)
        var args: [String] = ["-map", "0:v:0"]
        if hasAudio {
            args += ["-map", "0:a:0"]
        }

        var videoFilters: [String] = []
        if let cropParameters {
            videoFilters.append("crop=\(cropParameters.width):\(cropParameters.height):\(cropParameters.x):\(cropParameters.y)")
        }
        if exportPlaybackRate != .normal {
            let ptsMultiplier = 1.0 / exportPlaybackRate.rawValue
            videoFilters.append(String(format: "setpts=%.8f*PTS", ptsMultiplier))
        }
        if !videoFilters.isEmpty {
            args += ["-vf", videoFilters.joined(separator: ",")]
        }
        args += exportQuality.videoArguments
        if hasAudio {
            if exportPlaybackRate != .normal {
                args += ["-af", audioTempoFilter(for: exportPlaybackRate.rawValue)]
            }
            args += ["-c:a", "aac", "-b:a", "192k"]
        }
        args += ["-movflags", "+faststart", "-y", output]
        return args
    }

    private func copyOutputArguments(output: String) -> [String] {
        var args = ["-map", "0", "-c", "copy"]
        let ext = (output as NSString).pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) {
            args += ["-movflags", "+faststart"]
        }
        args += ["-y", output]
        return args
    }

    private func isFullFrameCrop(_ params: CropParameters) -> Bool {
        let pixelWidth = Int(previewPixelSize.width.rounded(.down))
        let pixelHeight = Int(previewPixelSize.height.rounded(.down))
        guard pixelWidth > 0, pixelHeight > 0 else { return false }

        return abs(params.x) <= 1
            && abs(params.y) <= 1
            && abs(params.width - pixelWidth) <= 2
            && abs(params.height - pixelHeight) <= 2
    }

    private func audioTempoFilter(for rate: Double) -> String {
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

        if abs(remaining - 1.0) > 0.0001 || components.isEmpty {
            components.append(String(format: "atempo=%.8f", remaining))
        }

        return components.joined(separator: ",")
    }

    private func detectBlackBars() {
        let requestedPath = input
        guard !requestedPath.isEmpty, previewPixelSize.width > 0, previewPixelSize.height > 0 else { return }

        isDetectingBlackBars = true
        previewError = ""
        runner.progress = 0
        runner.status = L.text(language, "Detecting black bars…", "正在检测黑边…")
        runner.log = L.text(
            language,
            "Detecting black bars with FFmpeg cropdetect…\n",
            "正在使用 FFmpeg cropdetect 检测黑边…\n"
        )

        Task {
            do {
                let params = try await Self.detectCropParameters(path: requestedPath)
                guard input == requestedPath else { return }
                selectedAspectRatio = "free"
                cropRect = cropRect(from: params)
                runner.progress = 1
                runner.status = L.text(language, "Black bars detected ✓", "黑边检测完成 ✓")
                runner.log += L.text(
                    language,
                    "Detected crop: \(params.width)×\(params.height) at x=\(params.x), y=\(params.y)\n",
                    "检测到裁剪：\(params.width)×\(params.height)，x=\(params.x)，y=\(params.y)\n"
                )
            } catch {
                guard input == requestedPath else { return }
                previewError = L.text(language, "Could not detect black bars.", "无法检测黑边。")
                runner.status = L.text(language, "Black-bar detection failed", "黑边检测失败")
                runner.log += "ERROR: \(error.localizedDescription)\n"
            }
            if input == requestedPath {
                isDetectingBlackBars = false
            }
        }
    }

    private func loadPreview(for path: String) {
        let requestedPath = path
        isLoadingPreview = true
        previewError = ""

        Task {
            do {
                let data = try await Self.generatePreviewFrame(path: requestedPath)
                guard input == requestedPath else { return }
                guard let image = NSImage(data: data) else {
                    throw NSError(domain: "SimpleVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read preview image"])
                }
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw NSError(domain: "SimpleVideo", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read preview dimensions"])
                }
                previewImage = image
                previewPixelSize = CGSize(width: cgImage.width, height: cgImage.height)
                cropRect = adjustedCropRect(cropRect, for: selectedAspectRatioOption.ratio)
            } catch {
                guard input == requestedPath else { return }
                previewError = L.text(language, "Could not load video preview.", "无法加载视频预览。")
                runner.log = "ERROR: \(error.localizedDescription)\n"
            }
            if input == requestedPath {
                isLoadingPreview = false
            }
        }
    }

    private static func generatePreviewFrame(path: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("simple-video-crop-preview-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: output) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: FFmpegRunner.resolveBinary("ffmpeg"))
            process.arguments = [
                "-hide_banner", "-loglevel", "error", "-y",
                "-i", path,
                "-frames:v", "1",
                output.path
            ]
            process.standardOutput = Pipe()
            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(domain: "SimpleVideo", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "ffmpeg failed to create preview"
                ])
            }

            return try Data(contentsOf: output)
        }.value
    }

    private static func requiresPreviewProxy(path: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let sampleTimes = [0.0, 0.1, 1.0, 2.0]
            let url = URL(fileURLWithPath: path)

            for seconds in sampleTimes {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .positiveInfinity
                generator.requestedTimeToleranceAfter = .positiveInfinity

                if (try? generator.copyCGImage(
                    at: CMTime(seconds: seconds, preferredTimescale: 600),
                    actualTime: nil
                )) != nil {
                    return false
                }
            }

            return true
        }.value
    }

    private static func generatePreviewProxy(
        path: String,
        onStart: @escaping @Sendable (Process) async -> Bool
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("simple-video-crop-proxy-\(UUID().uuidString).mp4")
            var shouldKeepOutput = false
            defer {
                if !shouldKeepOutput {
                    try? FileManager.default.removeItem(at: output)
                }
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: FFmpegRunner.resolveBinary("ffmpeg"))
            process.arguments = [
                "-hide_banner", "-loglevel", "error", "-y",
                "-i", path,
                "-map", "0:v:0",
                "-map", "0:a?",
                "-vf", "scale=if(gte(iw\\,ih)\\,min(1280\\,iw)\\,-2):if(gte(iw\\,ih)\\,-2\\,min(1280\\,ih))",
                "-c:v", "libx264",
                "-preset", "ultrafast",
                "-crf", "23",
                "-c:a", "aac",
                "-b:a", "128k",
                "-pix_fmt", "yuv420p",
                "-movflags", "+faststart",
                output.path
            ]
            process.standardOutput = Pipe()
            let errorPipe = Pipe()
            process.standardError = errorPipe

            guard await onStart(process) else {
                throw CancellationError()
            }

            try Task.checkCancellation()
            try process.run()
            FFmpegRunner.trackProcess(process)
            defer { FFmpegRunner.untrackProcess(process) }
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(domain: "SimpleVideo", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: message?.isEmpty == false
                        ? message!
                        : "ffmpeg failed to create a compatibility preview"
                ])
            }

            shouldKeepOutput = true
            return output.path
        }.value
    }

    private static func detectCropParameters(path: String) async throws -> CropParameters {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: FFmpegRunner.resolveBinary("ffmpeg"))
            process.arguments = [
                "-hide_banner",
                "-i", path,
                "-vf", "cropdetect=limit=24:round=2:reset=0",
                "-frames:v", "180",
                "-f", "null",
                "-"
            ]
            process.standardOutput = Pipe()
            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let crops = parseCropDetectOutput(output)

            if process.terminationStatus != 0 {
                throw NSError(domain: "SimpleVideo", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: output.trimmingCharacters(in: .whitespacesAndNewlines)
                ])
            }

            guard let crop = bestCrop(from: crops) else {
                throw NSError(domain: "SimpleVideo", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "ffmpeg cropdetect did not report a crop rectangle"
                ])
            }

            return crop
        }.value
    }

    nonisolated private static func parseCropDetectOutput(_ output: String) -> [CropParameters] {
        let pattern = #"crop=(\d+):(\d+):(\d+):(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.matches(in: output, range: nsRange).compactMap { match in
            guard match.numberOfRanges == 5,
                  let width = intCapture(match, 1, in: output),
                  let height = intCapture(match, 2, in: output),
                  let x = intCapture(match, 3, in: output),
                  let y = intCapture(match, 4, in: output),
                  width > 0, height > 0 else {
                return nil
            }
            return CropParameters(x: x, y: y, width: width, height: height)
        }
    }

    nonisolated private static func intCapture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> Int? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return Int(text[range])
    }

    nonisolated private static func bestCrop(from crops: [CropParameters]) -> CropParameters? {
        guard !crops.isEmpty else { return nil }

        struct Candidate {
            var params: CropParameters
            var count: Int
            var lastIndex: Int
        }

        var candidates: [String: Candidate] = [:]
        for (index, crop) in crops.enumerated() {
            let key = "\(crop.width):\(crop.height):\(crop.x):\(crop.y)"
            if var candidate = candidates[key] {
                candidate.count += 1
                candidate.lastIndex = index
                candidates[key] = candidate
            } else {
                candidates[key] = Candidate(params: crop, count: 1, lastIndex: index)
            }
        }

        return candidates.values
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.lastIndex > $1.lastIndex
            }
            .first?.params
    }

    private func evenInt(_ value: CGFloat) -> Int {
        let integer = max(0, Int(value.rounded(.down)))
        return integer - (integer % 2)
    }

    private func defaultCropRect() -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func adjustedCropRect(_ rect: CGRect, for pixelAspectRatio: CGFloat?) -> CGRect {
        guard let pixelAspectRatio, pixelAspectRatio > 0,
              previewPixelSize.width > 0, previewPixelSize.height > 0 else {
            return clampCropRect(rect)
        }

        let normalizedAspect = pixelAspectRatio / (previewPixelSize.width / previewPixelSize.height)
        var width = min(rect.width, 0.96)
        var height = width / normalizedAspect

        if height > 0.96 {
            height = min(rect.height, 0.96)
            width = height * normalizedAspect
        }

        if width > 0.96 {
            width = 0.96
            height = width / normalizedAspect
        }
        if height > 0.96 {
            height = 0.96
            width = height * normalizedAspect
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        return clampCropRect(CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        ))
    }

    private func clampCropRect(_ rect: CGRect) -> CGRect {
        let minSize: CGFloat = 0.03
        let width = min(max(rect.width, minSize), 1)
        let height = min(max(rect.height, minSize), 1)
        let x = min(max(rect.minX, 0), 1 - width)
        let y = min(max(rect.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func cropRect(from params: CropParameters) -> CGRect {
        guard previewPixelSize.width > 0, previewPixelSize.height > 0 else {
            return cropRect
        }
        return clampCropRect(CGRect(
            x: CGFloat(params.x) / previewPixelSize.width,
            y: CGFloat(params.y) / previewPixelSize.height,
            width: CGFloat(params.width) / previewPixelSize.width,
            height: CGFloat(params.height) / previewPixelSize.height
        ))
    }
}
