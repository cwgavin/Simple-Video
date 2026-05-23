import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct CropAudioView: View {
    let isActive: Bool

    @EnvironmentObject var runner: FFmpegRunner
    @EnvironmentObject var session: CropAudioSession
    @AppStorage("appLanguage") var appLanguageRaw = AppLanguage.english.rawValue
    @State var player: AVPlayer?
    @State var playbackTime: Double = 0
    @State var playbackDuration: Double = 0
    @State var isPlaying = false
    @State var isPreviewingTrim = false
    @State var isTrimPreviewPaused = false
    @State var playbackTimeObserver: Any?
    @State var playbackError = ""

    let fineTuneStep = 0.5

    var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    var selectedTrimRange: (start: Double, end: Double)? {
        guard playbackDuration > cropMinimumTrimDuration(for: playbackDuration) else { return nil }
        let start = min(max(session.trimStart, 0), playbackDuration)
        let end = min(max(session.trimEnd, start), playbackDuration)
        guard end > start else { return nil }
        if start <= 0.001, end >= playbackDuration - 0.001 {
            return nil
        }
        return (start, end)
    }

    private var inputBinding: Binding<String> {
        Binding(
            get: { session.input },
            set: { session.input = $0 }
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

    private var exportPlaybackRateBinding: Binding<CropPlaybackRateOption> {
        Binding(
            get: { session.exportPlaybackRate },
            set: { session.exportPlaybackRate = $0 }
        )
    }

    private var trimRangeSummary: String {
        let duration = max(session.trimEnd - session.trimStart, 0)
        return L.text(
            language,
            "\(session.trimRangeMode.shortTitle(language: language)): \(formatCropPlaybackTime(session.trimStart)) – \(formatCropPlaybackTime(session.trimEnd)) (\(formatCropPlaybackTime(duration)))",
            "\(session.trimRangeMode.shortTitle(language: language))：\(formatCropPlaybackTime(session.trimStart)) – \(formatCropPlaybackTime(session.trimEnd))（\(formatCropPlaybackTime(duration))）"
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

    private var playbackControlsDisabled: Bool {
        playbackDuration <= 0
    }

    var playbackRate: Float {
        Float(session.exportPlaybackRate.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FilePickerRow(
                label: L.text(language, "Input audio:", "输入音频："),
                path: inputBinding,
                contentTypes: [.audio]
            )

            HStack(alignment: .top) {
                Text(L.text(language, "Playback:", "播放："))
                    .frame(width: formLabelWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: 8) {
                    playbackControls

                    if !playbackError.isEmpty {
                        Text(playbackError)
                            .font(.caption)
                            .foregroundColor(.red)
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
            RunButton(canRun: !session.input.isEmpty && playbackDuration > 0) {
                runCropAudio()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .onAppear {
            if isActive, !session.input.isEmpty, player == nil {
                startPlaybackSession(
                    for: session.input,
                    resetTrimRange: session.trimEnd <= 0,
                    preservePlaybackState: true
                )
            }
        }
        .onDisappear {
            session.previewPlaybackTime = playbackTime
            cleanupPlayback()
        }
        .onChange(of: isActive) { _, active in
            if active {
                if !session.input.isEmpty, player == nil {
                    startPlaybackSession(
                        for: session.input,
                        resetTrimRange: session.trimEnd <= 0,
                        preservePlaybackState: true
                    )
                }
            } else {
                session.previewPlaybackTime = playbackTime
                cleanupPlayback()
            }
        }
        .onChange(of: session.input) { _, newValue in
            session.clearPendingChangesBaseline()
            session.completedOutput = ""
            session.previewPlaybackTime = 0
            session.trimRangeMode = .exportSelection
            playbackError = ""
            if isActive {
                startPlaybackSession(for: newValue, resetTrimRange: true)
            } else {
                cleanupPlayback(resetState: true, resetTrimRange: true)
            }
        }
        .onChange(of: playbackTime) { _, newValue in
            session.previewPlaybackTime = max(newValue, 0)
        }
    }

    @ViewBuilder
    private var playbackControls: some View {
        if player == nil {
            Text(L.text(language, "Choose an audio file to preview playback.", "请选择音频文件以预览播放。"))
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
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

                Text("\(formatCropPlaybackTime(playbackTime)) / \(formatCropPlaybackTime(playbackDuration))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)
            }
            .disabled(playbackControlsDisabled)
        }
    }

    @ViewBuilder
    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if player == nil {
                Text(L.text(language, "Choose an audio file to adjust the export range.", "请选择音频文件以调整导出范围。"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if playbackDuration <= 0 || session.trimEnd <= 0 {
                Text(L.text(language, "Loading audio duration…", "正在读取音频时长…"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                let minimumDuration = cropMinimumTrimDuration(for: playbackDuration)

                if playbackDuration <= minimumDuration {
                    Text(L.text(language, "This audio is too short to trim by time.", "这个音频太短，无法按时间裁剪。"))
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
                        formatTime: formatCropPlaybackTime,
                        selectedHandle: session.selectedTrimHandle,
                        start: trimStartBinding,
                        end: trimEndBinding,
                        playhead: Binding(
                            get: { playbackTime },
                            set: { playbackTime = $0 }
                        ),
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
                            IconButtonLabel(trimPreviewButtonTitle, systemImage: trimPreviewButtonSymbol)
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
                            "Fine-tune S or E by 0.5 seconds at a time after choosing which handle to adjust. Press and hold for continuous adjustment.",
                            "选择要调整的 S 或 E，再按 0.5 秒步进微调。按住按钮可连续调整。"
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
                                nudgeSelectedTrimHandle(bySteps: -1)
                            } label: {
                                IconButtonLabel(L.text(language, "Previous step", "前一步"), systemImage: "chevron.left")
                            }
                            .buttonRepeatBehavior(.enabled)
                            .pointingHandCursor()

                            Button {
                                nudgeSelectedTrimHandle(bySteps: 1)
                            } label: {
                                IconButtonLabel(L.text(language, "Next step", "后一步"), systemImage: "chevron.right")
                            }
                            .buttonRepeatBehavior(.enabled)
                            .pointingHandCursor()

                            Spacer()
                            Text(audioStepSummary)
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
                "Preview playback uses this rate, and exported audio keeps the same playback speed.",
                "预览播放会使用这个倍率，导出音频也会保持相同的播放速度。"
            ))
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var audioStepSummary: String {
        return L.text(
            language,
            "1 step = 0.5s",
            "1 步 = 0.5 秒"
        )
    }

}
