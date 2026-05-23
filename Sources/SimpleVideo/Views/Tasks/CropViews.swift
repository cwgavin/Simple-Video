import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

enum CropVideoPresentation {
    case embedded
    case standaloneEditor
}

struct CropVideoView: View {
    let isActive: Bool
    let presentation: CropVideoPresentation

    @EnvironmentObject var runner: FFmpegRunner
    @EnvironmentObject var session: CropVideoSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appLanguage") var appLanguageRaw = AppLanguage.english.rawValue
    @State var previewImage: NSImage?
    @State var previewPixelSize: CGSize = .zero
    @State var isLoadingPreview = false
    @State var isDetectingBlackBars = false
    @State var previewError = ""
    @State var player: AVPlayer?
    @State var playbackTime: Double = 0
    @State var playbackDuration: Double = 0
    @State var isPlaying = false
    @State var isPreviewingTrim = false
    @State var isTrimPreviewPaused = false
    @State var playbackTimeObserver: Any?
    @State var trimFrameDuration: Double?
    @State var previewPlaybackMode: CropPreviewPlaybackMode = .original
    @State var previewProxyPath: String?
    @State var isGeneratingPreviewProxy = false
    @State var proxyGenerationTask: Task<Void, Never>?
    @State var proxyGenerationProcess: Process?
    @State var proxyGenerationID: UInt = 0

    let aspectRatioOptions = [
        CropAspectRatioOption(id: "free", ratio: nil),
        CropAspectRatioOption(id: "16:9", ratio: 16.0 / 9.0),
        CropAspectRatioOption(id: "9:16", ratio: 9.0 / 16.0),
        CropAspectRatioOption(id: "1:1", ratio: 1.0),
        CropAspectRatioOption(id: "4:3", ratio: 4.0 / 3.0),
    ]

    var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    var selectedAspectRatioOption: CropAspectRatioOption {
        aspectRatioOptions.first(where: { $0.id == session.selectedAspectRatio }) ?? aspectRatioOptions[0]
    }

    var selectedTrimRange: (start: Double, end: Double)? {
        guard playbackDuration > minimumTrimDuration(for: playbackDuration) else { return nil }
        let start = min(max(session.trimStart, 0), playbackDuration)
        let end = min(max(session.trimEnd, start), playbackDuration)
        guard end > start else { return nil }
        if start <= 0.001, end >= playbackDuration - 0.001 {
            return nil
        }
        return (start, end)
    }

    var cropParameters: CropParameters? {
        guard previewPixelSize.width >= 2, previewPixelSize.height >= 2 else { return nil }
        let pixelWidth = Int(previewPixelSize.width.rounded(.down))
        let pixelHeight = Int(previewPixelSize.height.rounded(.down))

        var x = evenInt(session.cropRect.minX * CGFloat(pixelWidth))
        var y = evenInt(session.cropRect.minY * CGFloat(pixelHeight))
        var width = max(2, evenInt(session.cropRect.width * CGFloat(pixelWidth)))
        var height = max(2, evenInt(session.cropRect.height * CGFloat(pixelHeight)))

        if x + width > pixelWidth { width = max(2, evenInt(CGFloat(pixelWidth - x))) }
        if y + height > pixelHeight { height = max(2, evenInt(CGFloat(pixelHeight - y))) }
        if x + width > pixelWidth { x = max(0, evenInt(CGFloat(pixelWidth - width))) }
        if y + height > pixelHeight { y = max(0, evenInt(CGFloat(pixelHeight - height))) }

        return CropParameters(x: x, y: y, width: width, height: height)
    }

    private var isUsingPreviewProxy: Bool {
        previewPlaybackMode == .compatibilityProxy
    }

    var hasVisualCrop: Bool {
        guard let params = cropParameters else { return false }
        return !isFullFrameCrop(params)
    }

    var requiresVideoReencode: Bool {
        hasVisualCrop || selectedTrimRange != nil || session.exportPlaybackRate != .normal
    }

    private var inputBinding: Binding<String> {
        Binding(
            get: { session.input },
            set: { session.input = $0 }
        )
    }

    private var cropRectBinding: Binding<CGRect> {
        Binding(
            get: { session.cropRect },
            set: { session.cropRect = $0 }
        )
    }

    private var selectedAspectRatioBinding: Binding<String> {
        Binding(
            get: { session.selectedAspectRatio },
            set: { session.selectedAspectRatio = $0 }
        )
    }

    private var trimStartBinding: Binding<Double> {
        Binding(
            get: { session.trimStart },
            set: { session.trimStart = $0 }
        )
    }

    private var trimEndBinding: Binding<Double> {
        Binding(
            get: { session.trimEnd },
            set: { session.trimEnd = $0 }
        )
    }

    private var selectedTrimHandleBinding: Binding<TrimHandleSelection> {
        Binding(
            get: { session.selectedTrimHandle },
            set: { session.selectedTrimHandle = $0 }
        )
    }

    private var trimRangeModeBinding: Binding<CropTrimRangeMode> {
        Binding(
            get: { session.trimRangeMode },
            set: { session.trimRangeMode = $0 }
        )
    }

    private var exportQualityBinding: Binding<CropExportQualityOption> {
        Binding(
            get: { session.exportQuality },
            set: { session.exportQuality = $0 }
        )
    }

    private var exportPlaybackRateBinding: Binding<CropPlaybackRateOption> {
        Binding(
            get: { session.exportPlaybackRate },
            set: { session.exportPlaybackRate = $0 }
        )
    }

    private struct WindowFullscreenActivator: NSViewRepresentable {
        let activationID: UInt

        final class Coordinator {
            var lastActivatedID: UInt?
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async {
                activateWindow(from: view, coordinator: context.coordinator)
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            DispatchQueue.main.async {
                activateWindow(from: nsView, coordinator: context.coordinator)
            }
        }

        private func activateWindow(from view: NSView, coordinator: Coordinator) {
            guard coordinator.lastActivatedID != activationID, let window = view.window else { return }
            coordinator.lastActivatedID = activationID
            window.collectionBehavior.insert(.fullScreenPrimary)
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }

    private var standaloneEditorBody: some View {
        GeometryReader { geo in
            let editorMinHeight = max(620, geo.size.height - 120)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L.text(language, "Crop area", "裁剪区域"))
                            .font(.headline)
                        Spacer()
                        Button(L.text(language, "Done", "完成")) {
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                        .pointingHandCursor()
                    }
                    CropEditorView(
                        image: previewImage,
                        player: player,
                        imagePixelSize: previewPixelSize,
                        fixedAspectRatio: selectedAspectRatioOption.ratio,
                        cropRect: cropRectBinding
                    )
                    .frame(maxWidth: .infinity, minHeight: editorMinHeight)
                    playbackControls
                    trimControls
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(minHeight: geo.size.height, alignment: .topLeading)
                .padding()
                .padding(.trailing, 8)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WindowFullscreenActivator(activationID: session.standaloneEditorActivationID))
        }
    }

    var body: some View {
        Group {
            if presentation == .standaloneEditor {
                standaloneEditorBody
            } else {
                embeddedBody
            }
        }
        .onAppear {
            if isActive, !session.input.isEmpty, player == nil {
                startPreviewSession(for: session.input, resetTrimRange: session.trimEnd <= 0, preservePlaybackState: true)
            }
            if isActive, !session.input.isEmpty, previewImage == nil, !isLoadingPreview {
                loadPreview(for: session.input)
            }
        }
        .onDisappear {
            if presentation == .standaloneEditor {
                session.isShowingStandaloneEditor = false
            }
            session.previewPlaybackTime = playbackTime
            cleanupPreviewSession()
        }
        .onChange(of: isActive) { _, active in
            if active {
                if !session.input.isEmpty, player == nil {
                    startPreviewSession(for: session.input, resetTrimRange: session.trimEnd <= 0, preservePlaybackState: true)
                }
                if !session.input.isEmpty, previewImage == nil, !isLoadingPreview {
                    loadPreview(for: session.input)
                }
            } else {
                session.previewPlaybackTime = playbackTime
                cleanupPreviewSession()
            }
        }
        .onChange(of: session.input) { _, newValue in
            session.clearPendingChangesBaseline()
            session.completedOutput = ""
            session.previewPlaybackTime = 0
            previewImage = nil
            previewPixelSize = .zero
            session.resetCropSelection()
            session.trimRangeMode = .exportSelection
            previewError = ""
            isDetectingBlackBars = false
            if isActive {
                startPreviewSession(for: newValue, resetTrimRange: true)
            } else {
                cleanupPreviewSession(resetState: true, resetTrimRange: true)
            }
            if isActive, !newValue.isEmpty {
                loadPreview(for: newValue)
            }
        }
        .onChange(of: session.selectedAspectRatio) { _, _ in
            session.cropRect = adjustedCropRect(session.cropRect, for: selectedAspectRatioOption.ratio)
        }
        .onChange(of: playbackTime) { _, newValue in
            session.previewPlaybackTime = max(newValue, 0)
        }
    }

    private var embeddedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            FilePickerRow(label: L.text(language, "Input video:", "输入视频："), path: inputBinding, contentTypes: [.movie, .video, .audiovisualContent])

            HStack {
                Text(L.text(language, "Aspect ratio:", "裁剪比例："))
                    .frame(width: formLabelWidth, alignment: .trailing)
                Picker("aspect-ratio", selection: selectedAspectRatioBinding) {
                    ForEach(aspectRatioOptions) { option in
                        Text(option.title(language: language)).tag(option.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .pointingHandCursor()
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
                                cropRect: cropRectBinding
                            )
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .textBackgroundColor))
                                .overlay {
                                    if isLoadingPreview {
                                        ProgressView(L.text(language, "Loading preview…", "正在加载预览…"))
                                    } else {
                                        Text(session.input.isEmpty
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
                            IconButtonLabel(L.text(language, "Auto detect black bars", "自动检测黑边"), systemImage: "wand.and.stars")
                        }
                        .disabled(session.input.isEmpty || previewImage == nil || isLoadingPreview || isDetectingBlackBars || runner.isRunning)
                        .pointingHandCursor(enabled: !session.input.isEmpty && previewImage != nil && !isLoadingPreview && !isDetectingBlackBars && !runner.isRunning)
                        Button {
                            session.standaloneEditorActivationID &+= 1
                            session.isShowingStandaloneEditor = true
                            openWindow(id: "fullscreen-crop")
                        } label: {
                            IconButtonLabel(L.text(language, "Full-screen crop", "全屏裁剪"), systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .disabled(previewImage == nil)
                        .pointingHandCursor(enabled: previewImage != nil)
                        Button(L.text(language, "Reset crop", "重置裁剪")) {
                            session.resetCropSelection()
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

            OutputHintRow(path: session.completedOutput)
            RunButton(canRun: !session.input.isEmpty && previewImage != nil && cropParameters != nil && !isLoadingPreview) {
                runCrop()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .padding(.trailing, 8)
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
            } else if session.trimEnd <= 0 {
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
                    HStack {
                        Spacer(minLength: 0)
                        rangeActionPicker
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    TrimTimelineView(
                        duration: playbackDuration,
                        minimumDuration: minimumDuration,
                        tintColor: session.trimRangeMode.timelineTint,
                        startHandleLabel: "S",
                        endHandleLabel: "E",
                        formatTime: formatPlaybackTime,
                        selectedHandle: session.selectedTrimHandle,
                        start: trimStartBinding,
                        end: trimEndBinding,
                        playhead: $playbackTime,
                        onSeek: scrubPlayback(to:),
                        onSetStart: setTrimStart(_:),
                        onSetEnd: setTrimEnd(_:),
                        onSelectStart: { session.selectedTrimHandle = .start },
                        onSelectEnd: { session.selectedTrimHandle = .end }
                    )

                    HStack {
                        Button(L.text(language, "Set S to playhead", "设为当前开始")) {
                            setTrimStart(playbackTime)
                        }
                        .keyboardShortcut("[", modifiers: .command)
                        .pointingHandCursor()
                        Button(L.text(language, "Set E to playhead", "设为当前结束")) {
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
                            IconButtonLabel(
                                trimPreviewButtonTitle,
                                systemImage: trimPreviewButtonSymbol
                            )
                        }
                        .pointingHandCursor()
                        Button {
                            stopTrimPreview()
                        } label: {
                            IconButtonLabel(L.text(language, "Stop preview", "停止预览"), systemImage: "stop.fill")
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
                            "Fine-tune S or E one frame at a time after choosing which handle to adjust. Press and hold for continuous adjustment.",
                            "选择要调整的 S 或 E，再按帧微调，这样更容易精确对齐。按住按钮可连续微调。"
                        ))
                        .font(.caption)
                        .foregroundColor(.secondary)

                        HStack {
                        Picker(
                            L.text(language, "Adjust handle", "调整端点"),
                            selection: selectedTrimHandleBinding
                        ) {
                            Text("S").tag(TrimHandleSelection.start)
                            Text("E").tag(TrimHandleSelection.end)
                        }
                        .pointingHandCursor()
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 90)

                        Button {
                            nudgeSelectedTrimHandle(byFrames: -1)
                        } label: {
                            IconButtonLabel(L.text(language, "Previous frame", "前一帧"), systemImage: "chevron.left")
                        }
                        .buttonRepeatBehavior(.enabled)
                        .disabled(trimFrameDuration == nil)
                        .pointingHandCursor(enabled: trimFrameDuration != nil)

                        Button {
                            nudgeSelectedTrimHandle(byFrames: 1)
                        } label: {
                            IconButtonLabel(L.text(language, "Next frame", "后一帧"), systemImage: "chevron.right")
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

    private var rangeActionPicker: some View {
        Picker(
            L.text(language, "Range action", "范围操作"),
            selection: trimRangeModeBinding
        ) {
            ForEach(CropTrimRangeMode.allCases) { mode in
                Text(mode.title(language: language)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .pointingHandCursor()
        .frame(width: 320, alignment: .trailing)
    }

    private var trimRangeSummary: String {
        let duration = max(session.trimEnd - session.trimStart, 0)
        return L.text(
            language,
            "\(session.trimRangeMode.shortTitle(language: language)): \(formatPlaybackTime(session.trimStart)) – \(formatPlaybackTime(session.trimEnd)) (\(formatPlaybackTime(duration)))",
            "\(session.trimRangeMode.shortTitle(language: language))：\(formatPlaybackTime(session.trimStart)) – \(formatPlaybackTime(session.trimEnd))（\(formatPlaybackTime(duration))）"
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

    var playbackRate: Float {
        Float(session.exportPlaybackRate.rawValue)
    }

    @ViewBuilder
    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(
                    L.text(language, "Playback rate", "播放倍率"),
                    selection: exportPlaybackRateBinding
                ) {
                    ForEach(CropPlaybackRateOption.allCases) { option in
                        Text(option.title(language: language)).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .pointingHandCursor()
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
                        selection: exportQualityBinding
                    ) {
                        ForEach(CropExportQualityOption.allCases) { option in
                            Text(option.title(language: language)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .pointingHandCursor()
                    Spacer()
                }

                Text(session.exportQuality.summary(language: language))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if selectedTrimRange != nil {
                HStack {
                    Picker(
                        L.text(language, "Export quality", "导出画质"),
                        selection: exportQualityBinding
                    ) {
                        ForEach(CropExportQualityOption.allCases) { option in
                            Text(option.title(language: language)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .pointingHandCursor()
                    Spacer()
                    }

                    Text(session.exportQuality.summary(language: language))
                        .font(.caption)
                        .foregroundColor(.secondary)
            } else if session.exportPlaybackRate != .normal {
                HStack {
                    Picker(
                        L.text(language, "Export quality", "导出画质"),
                        selection: exportQualityBinding
                    ) {
                        ForEach(CropExportQualityOption.allCases) { option in
                            Text(option.title(language: language)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .pointingHandCursor()
                    Spacer()
                }

                Text(session.exportQuality.summary(language: language))
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
                .keyboardShortcut(.space, modifiers: [])
                .disabled(playbackDuration <= 0)
                .pointingHandCursor(enabled: !playbackControlsDisabled)

                Slider(
                    value: Binding(
                        get: { playbackTime },
                        set: scrubPlayback(to:)
                    ),
                    in: 0...max(playbackDuration, 0.01)
                )
                .disabled(playbackDuration <= 0)
                .pointingHandCursor()

                Text("\(formatPlaybackTime(playbackTime)) / \(formatPlaybackTime(playbackDuration))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)
            }
            .disabled(playbackControlsDisabled)
        }
    }

    private func formatPlaybackTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let wholeSeconds = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }
}
