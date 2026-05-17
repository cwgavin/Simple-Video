import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct CropVideoView: View {
    let isActive: Bool

    @EnvironmentObject var runner: FFmpegRunner
    @EnvironmentObject private var session: CropVideoSession
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var previewImage: NSImage?
    @State private var previewPixelSize: CGSize = .zero
    @State private var isLoadingPreview = false
    @State private var isDetectingBlackBars = false
    @State private var previewError = ""
    @State private var player: AVPlayer?
    @State private var playbackTime: Double = 0
    @State private var playbackDuration: Double = 0
    @State private var isPlaying = false
    @State private var isPreviewingTrim = false
    @State private var isTrimPreviewPaused = false
    @State private var showingLargeEditor = false
    @State private var playbackTimeObserver: Any?
    @State private var trimFrameDuration: Double?
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
        aspectRatioOptions.first(where: { $0.id == session.selectedAspectRatio }) ?? aspectRatioOptions[0]
    }

    private var selectedTrimRange: (start: Double, end: Double)? {
        guard playbackDuration > minimumTrimDuration(for: playbackDuration) else { return nil }
        let start = min(max(session.trimStart, 0), playbackDuration)
        let end = min(max(session.trimEnd, start), playbackDuration)
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

    private var hasVisualCrop: Bool {
        guard let params = cropParameters else { return false }
        return !isFullFrameCrop(params)
    }

    private var requiresVideoReencode: Bool {
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

    var body: some View {
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
                            Label(L.text(language, "Auto detect black bars", "自动检测黑边"), systemImage: "wand.and.stars")
                        }
                        .disabled(session.input.isEmpty || previewImage == nil || isLoadingPreview || isDetectingBlackBars || runner.isRunning)
                        .pointingHandCursor(enabled: !session.input.isEmpty && previewImage != nil && !isLoadingPreview && !isDetectingBlackBars && !runner.isRunning)
                        Button {
                            showingLargeEditor = true
                        } label: {
                            Label(L.text(language, "Full-screen crop", "全屏裁剪"), systemImage: "arrow.up.left.and.arrow.down.right")
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
                    cropRect: cropRectBinding
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
            if isActive, !session.input.isEmpty, player == nil {
                startPreviewSession(for: session.input, resetTrimRange: session.trimEnd <= 0, preservePlaybackState: true)
            }
            if isActive, !session.input.isEmpty, previewImage == nil, !isLoadingPreview {
                loadPreview(for: session.input)
            }
        }
        .onDisappear {
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
                showingLargeEditor = false
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
        .onChange(of: session.selectedAspectRatio) { _, _ in
            session.cropRect = adjustedCropRect(session.cropRect, for: selectedAspectRatioOption.ratio)
        }
        .onChange(of: playbackTime) { _, newValue in
            session.previewPlaybackTime = max(newValue, 0)
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
        let duration = max(session.trimEnd - session.trimStart, 0)
        return L.text(
            language,
            "Export: \(formatPlaybackTime(session.trimStart)) – \(formatPlaybackTime(session.trimEnd)) (\(formatPlaybackTime(duration)))",
            "导出：\(formatPlaybackTime(session.trimStart)) – \(formatPlaybackTime(session.trimEnd))（\(formatPlaybackTime(duration))）"
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

    private func startPreviewSession(for path: String, resetTrimRange: Bool, preservePlaybackState: Bool = false) {
        cleanupPreviewProxy()
        setupPlayback(
            previewPath: path,
            metadataPath: path,
            resetTrimRange: resetTrimRange,
            preservePlaybackState: preservePlaybackState
        )
        preparePreviewProxyFallback(for: path)
    }

    private func setupPlayback(
        previewPath: String,
        metadataPath: String,
        resetTrimRange: Bool,
        preservePlaybackState: Bool = false
    ) {
        let preservedTime = preservePlaybackState ? max(session.previewPlaybackTime, 0) : 0
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
                        if resetTrimRange || session.trimEnd <= 0 {
                            session.trimStart = 0
                            session.trimEnd = playbackDuration
                        } else {
                            clampTrimRange(to: playbackDuration)
                        }
                        if resetTrimRange {
                            session.markCurrentStateAsBaseline()
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
                    guard session.input == path, proxyGenerationID == requestID else { return }
                    isGeneratingPreviewProxy = false
                }
                return
            }

            await MainActor.run {
                guard session.input == path, proxyGenerationID == requestID else { return }
                isGeneratingPreviewProxy = true
            }

            do {
                let proxyPath = try await Self.generatePreviewProxy(path: path) { process in
                    await MainActor.run {
                        guard session.input == path, proxyGenerationID == requestID else {
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
                    guard session.input == path, proxyGenerationID == requestID else { return false }
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
                    guard session.input == path, proxyGenerationID == requestID else { return }
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
            session.trimStart = 0
            session.trimEnd = 0
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

        let start = min(max(session.trimStart, 0), playbackDuration)
        let end = trimPreviewEnd
        guard end > start else { return false }

        let bounded = min(max(seconds, 0), max(playbackDuration, 0))
        return bounded >= start && bounded <= end
    }

    private var trimPreviewEnd: Double {
        guard playbackDuration > 0, session.trimEnd > 0 else { return playbackDuration }
        return min(max(session.trimEnd, session.trimStart), playbackDuration)
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
        let start = min(max(session.trimStart, 0), playbackDuration)
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

        let start = min(max(session.trimStart, 0), playbackDuration)
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
        let maxStart = max(0, session.trimEnd - minimumTrimDuration(for: playbackDuration))
        session.trimStart = min(max(seconds, 0), maxStart)
        seek(to: session.trimStart)
    }

    private func setTrimEnd(_ seconds: Double) {
        guard playbackDuration > 0 else { return }
        let minEnd = min(playbackDuration, session.trimStart + minimumTrimDuration(for: playbackDuration))
        session.trimEnd = min(max(seconds, minEnd), playbackDuration)
        seek(to: session.trimEnd)
    }

    private func resetTrimRange() {
        session.trimStart = 0
        session.trimEnd = playbackDuration
        seek(to: 0)
    }

    private func nudgeSelectedTrimHandle(byFrames frames: Int) {
        guard let trimFrameDuration, trimFrameDuration.isFinite, trimFrameDuration > 0 else { return }
        let offset = Double(frames) * trimFrameDuration
        switch session.selectedTrimHandle {
        case .start:
            setTrimStart(session.trimStart + offset)
        case .end:
            setTrimEnd(session.trimEnd + offset)
        }
    }

    private func clampTrimRange(to duration: Double) {
        let minimumDuration = minimumTrimDuration(for: duration)
        session.trimStart = min(max(session.trimStart, 0), max(duration - minimumDuration, 0))
        session.trimEnd = min(max(session.trimEnd, session.trimStart + minimumDuration), duration)
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
            let out = makeOutputPath(input: session.input, ext: "mp4")
            if let trimRange = selectedTrimRange {
                var args = ["-i", session.input, "-ss", ffmpegTime(trimRange.start), "-t", ffmpegTime(trimRange.end - trimRange.start)]
                args += reencodedOutputArguments(output: out, cropParameters: hasVisualCrop ? params : nil)
                runner.run(args: args, inputForDuration: session.input) {
                    session.completedOutput = $0
                    session.markCurrentStateAsBaseline()
                }
            } else {
                let args = ["-i", session.input] + reencodedOutputArguments(output: out, cropParameters: hasVisualCrop ? params : nil)
                runner.run(args: args, inputForDuration: session.input) {
                    session.completedOutput = $0
                    session.markCurrentStateAsBaseline()
                }
            }
            return
        }

        let out = makeOutputPath(input: session.input, ext: inputExt(session.input))
        let args: [String]
        if let trimRange = selectedTrimRange {
            args = [
                "-ss", ffmpegTime(trimRange.start),
                "-i", session.input,
                "-t", ffmpegTime(trimRange.end - trimRange.start)
            ] + copyOutputArguments(output: out)
        } else {
            args = ["-i", session.input] + copyOutputArguments(output: out)
        }
        runner.run(args: args, inputForDuration: session.input) {
            session.completedOutput = $0
            session.markCurrentStateAsBaseline()
        }
    }

    private func reencodedOutputArguments(output: String, cropParameters: CropParameters?) -> [String] {
        let hasAudio = FFmpegRunner.hasAudioStream(session.input)
        var args: [String] = ["-map", "0:v:0"]
        if hasAudio {
            args += ["-map", "0:a:0"]
        }

        var videoFilters: [String] = []
        if let cropParameters {
            videoFilters.append("crop=\(cropParameters.width):\(cropParameters.height):\(cropParameters.x):\(cropParameters.y)")
        }
        if session.exportPlaybackRate != .normal {
            let ptsMultiplier = 1.0 / session.exportPlaybackRate.rawValue
            videoFilters.append(String(format: "setpts=%.8f*PTS", ptsMultiplier))
        }
        if !videoFilters.isEmpty {
            args += ["-vf", videoFilters.joined(separator: ",")]
        }
        args += session.exportQuality.videoArguments
        if hasAudio {
            if session.exportPlaybackRate != .normal {
                args += ["-af", audioTempoFilter(for: session.exportPlaybackRate.rawValue)]
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
        let requestedPath = session.input
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
                guard session.input == requestedPath else { return }
                session.selectedAspectRatio = "free"
                session.cropRect = cropRect(from: params)
                runner.progress = 1
                runner.status = L.text(language, "Black bars detected ✓", "黑边检测完成 ✓")
                runner.log += L.text(
                    language,
                    "Detected crop: \(params.width)×\(params.height) at x=\(params.x), y=\(params.y)\n",
                    "检测到裁剪：\(params.width)×\(params.height)，x=\(params.x)，y=\(params.y)\n"
                )
            } catch {
                guard session.input == requestedPath else { return }
                previewError = L.text(language, "Could not detect black bars.", "无法检测黑边。")
                runner.status = L.text(language, "Black-bar detection failed", "黑边检测失败")
                runner.log += "ERROR: \(error.localizedDescription)\n"
            }
            if session.input == requestedPath {
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
                guard session.input == requestedPath else { return }
                guard let image = NSImage(data: data) else {
                    throw NSError(domain: "SimpleVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read preview image"])
                }
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw NSError(domain: "SimpleVideo", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read preview dimensions"])
                }
                previewImage = image
                previewPixelSize = CGSize(width: cgImage.width, height: cgImage.height)
                session.cropRect = adjustedCropRect(session.cropRect, for: selectedAspectRatioOption.ratio)
            } catch {
                guard session.input == requestedPath else { return }
                previewError = L.text(language, "Could not load video preview.", "无法加载视频预览。")
                runner.log = "ERROR: \(error.localizedDescription)\n"
            }
            if session.input == requestedPath {
                isLoadingPreview = false
            }
        }
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
            return session.cropRect
        }
        return clampCropRect(CGRect(
            x: CGFloat(params.x) / previewPixelSize.width,
            y: CGFloat(params.y) / previewPixelSize.height,
            width: CGFloat(params.width) / previewPixelSize.width,
            height: CGFloat(params.height) / previewPixelSize.height
        ))
    }
}
