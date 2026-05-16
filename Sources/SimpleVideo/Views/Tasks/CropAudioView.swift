import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct CropAudioView: View {
    let isActive: Bool

    @EnvironmentObject var runner: FFmpegRunner
    @EnvironmentObject private var session: CropAudioSession
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var player: AVPlayer?
    @State private var playbackTime: Double = 0
    @State private var playbackDuration: Double = 0
    @State private var isPlaying = false
    @State private var isPreviewingTrim = false
    @State private var isTrimPreviewPaused = false
    @State private var playbackTimeObserver: Any?
    @State private var playbackError = ""

    private let fineTuneStep = 0.5

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    private var selectedTrimRange: (start: Double, end: Double)? {
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
            "Export: \(formatCropPlaybackTime(session.trimStart)) – \(formatCropPlaybackTime(session.trimEnd)) (\(formatCropPlaybackTime(duration)))",
            "导出：\(formatCropPlaybackTime(session.trimStart)) – \(formatCropPlaybackTime(session.trimEnd))（\(formatCropPlaybackTime(duration))）"
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

    private var playbackRate: Float {
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
                startPlaybackSession(for: session.input, resetTrimRange: session.trimEnd <= 0)
            }
        }
        .onDisappear {
            cleanupPlayback()
        }
        .onChange(of: isActive) { _, active in
            if active {
                if !session.input.isEmpty, player == nil {
                    startPlaybackSession(for: session.input, resetTrimRange: session.trimEnd <= 0)
                }
            } else {
                cleanupPlayback()
            }
        }
        .onChange(of: session.input) { _, newValue in
            session.clearPendingChangesBaseline()
            session.completedOutput = ""
            playbackError = ""
            if isActive {
                startPlaybackSession(for: newValue, resetTrimRange: true)
            } else {
                cleanupPlayback(resetState: true, resetTrimRange: true)
            }
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
                    Text(L.text(
                        language,
                        "Drag S/E to choose the exported section, or drag the playhead to preview a time.",
                        "拖动 S/E 选择导出的片段，也可以拖动播放头预览时间点。"
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)

                    TrimTimelineView(
                        duration: playbackDuration,
                        minimumDuration: minimumDuration,
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
                            Label(trimPreviewButtonTitle, systemImage: trimPreviewButtonSymbol)
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
                                Label(L.text(language, "Previous step", "前一步"), systemImage: "chevron.left")
                            }
                            .buttonRepeatBehavior(.enabled)
                            .pointingHandCursor()

                            Button {
                                nudgeSelectedTrimHandle(bySteps: 1)
                            } label: {
                                Label(L.text(language, "Next step", "后一步"), systemImage: "chevron.right")
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

    private func startPlaybackSession(for path: String, resetTrimRange: Bool) {
        setupPlayback(path: path, resetTrimRange: resetTrimRange)
    }

    private func setupPlayback(path: String, resetTrimRange: Bool, preservePlaybackState: Bool = false) {
        let preservedTime = preservePlaybackState
            ? min(max(playbackTime, 0), max(playbackDuration, 0))
            : 0
        let shouldResumePlayback = preservePlaybackState && isPlaying
        let shouldKeepTrimPreview = preservePlaybackState && isPreviewingTrim
        let shouldKeepTrimPreviewPaused = preservePlaybackState && isTrimPreviewPaused

        cleanupPlayback(resetState: !preservePlaybackState, resetTrimRange: resetTrimRange)

        guard !path.isEmpty else { return }

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .pause
        player = newPlayer
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
                let duration = try await asset.load(.duration)
                let durationSeconds = CMTimeGetSeconds(duration)
                await MainActor.run {
                    guard player === newPlayer else { return }
                    playbackDuration = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : 0
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
                    playbackError = L.text(
                        language,
                        "Could not read audio duration.",
                        "无法读取音频时长。"
                    )
                    runner.log += "WARNING: Could not read audio duration: \(error.localizedDescription)\n"
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
        let maxStart = max(0, session.trimEnd - cropMinimumTrimDuration(for: playbackDuration))
        session.trimStart = min(max(seconds, 0), maxStart)
        seek(to: session.trimStart)
    }

    private func setTrimEnd(_ seconds: Double) {
        guard playbackDuration > 0 else { return }
        let minEnd = min(playbackDuration, session.trimStart + cropMinimumTrimDuration(for: playbackDuration))
        session.trimEnd = min(max(seconds, minEnd), playbackDuration)
        seek(to: session.trimEnd)
    }

    private func resetTrimRange() {
        session.trimStart = 0
        session.trimEnd = playbackDuration
        seek(to: 0)
    }

    private func clampTrimRange(to duration: Double) {
        let minimumDuration = cropMinimumTrimDuration(for: duration)
        session.trimStart = min(max(session.trimStart, 0), max(duration - minimumDuration, 0))
        session.trimEnd = min(max(session.trimEnd, session.trimStart + minimumDuration), duration)
    }

    private func nudgeSelectedTrimHandle(bySteps steps: Int) {
        let offset = Double(steps) * fineTuneStep
        switch session.selectedTrimHandle {
        case .start:
            setTrimStart(session.trimStart + offset)
        case .end:
            setTrimEnd(session.trimEnd + offset)
        }
    }

    private var audioStepSummary: String {
        return L.text(
            language,
            "1 step = 0.5s",
            "1 步 = 0.5 秒"
        )
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

    private func runCropAudio() {
        let hasExactTrim = selectedTrimRange != nil
        let needsReencode = hasExactTrim || session.exportPlaybackRate != .normal
        let outputExtension = normalizedOutputExtension()
        let out = makeOutputPath(
            input: session.input,
            ext: needsReencode ? outputExtension : inputExt(session.input)
        )

        let args: [String]
        if needsReencode {
            var reencodeArgs = ["-i", session.input]
            if let trimRange = selectedTrimRange {
                reencodeArgs += [
                    "-ss", ffmpegTime(trimRange.start),
                    "-t", ffmpegTime(trimRange.end - trimRange.start)
                ]
            }
            reencodeArgs += reencodedAudioOutputArguments(output: out)
            args = reencodeArgs
        } else {
            args = [
                "-i", session.input,
                "-map", "0:a:0",
                "-c", "copy",
                "-y", out
            ]
        }

        runner.run(args: args, inputForDuration: session.input) {
            session.completedOutput = $0
            session.markCurrentStateAsBaseline()
        }
    }

    private func normalizedOutputExtension() -> String {
        let ext = inputExt(session.input).lowercased()
        let supported = ["mp3", "aac", "m4a", "flac", "wav", "ogg", "opus", "wma", "aiff"]
        return supported.contains(ext) ? ext : "m4a"
    }

    private func reencodedAudioOutputArguments(output: String) -> [String] {
        let ext = (output as NSString).pathExtension.lowercased()
        var args = ["-map", "0:a:0"]

        if session.exportPlaybackRate != .normal {
            args += ["-af", cropAudioTempoFilter(for: session.exportPlaybackRate.rawValue)]
        }

        switch ext {
        case "mp3":
            args += ["-c:a", "libmp3lame", "-b:a", "192k"]
        case "aac", "m4a":
            args += ["-c:a", "aac", "-b:a", "192k"]
        case "flac":
            args += ["-c:a", "flac"]
        case "wav":
            args += ["-c:a", "pcm_s16le"]
        case "ogg":
            args += ["-c:a", "libvorbis", "-q:a", "5"]
        case "opus":
            args += ["-c:a", "libopus", "-b:a", "128k"]
        case "wma":
            args += ["-c:a", "wmav2", "-b:a", "192k"]
        case "aiff":
            args += ["-c:a", "pcm_s16be"]
        default:
            args += ["-c:a", "aac", "-b:a", "192k"]
        }

        args += ["-y", output]
        return args
    }
}
