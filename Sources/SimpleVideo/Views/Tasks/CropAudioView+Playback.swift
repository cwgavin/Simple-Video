import SwiftUI
import AVFoundation

extension CropAudioView {
    var trimPreviewEnd: Double {
        guard playbackDuration > 0, session.trimEnd > 0 else { return playbackDuration }
        return min(max(session.trimEnd, session.trimStart), playbackDuration)
    }

    func startPlaybackSession(
        for path: String,
        resetTrimRange: Bool,
        preservePlaybackState: Bool = false
    ) {
        setupPlayback(
            path: path,
            resetTrimRange: resetTrimRange,
            preservePlaybackState: preservePlaybackState
        )
    }

    func setupPlayback(path: String, resetTrimRange: Bool, preservePlaybackState: Bool = false) {
        let preservedTime = preservePlaybackState ? max(session.previewPlaybackTime, 0) : 0
        let shouldResumePlayback = preservePlaybackState && isPlaying
        let shouldKeepTrimPreview = preservePlaybackState && isPreviewingTrim
        let shouldKeepTrimPreviewPaused = preservePlaybackState && isTrimPreviewPaused

        cleanupPlayback(resetState: !preservePlaybackState, resetTrimRange: resetTrimRange)

        guard !path.isEmpty else { return }

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .pause
        applyPreviewVolume(to: newPlayer)
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

    func cleanupPlayback(resetState: Bool = false, resetTrimRange: Bool = false) {
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

    func togglePlayback() {
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

    func startPlayback(using player: AVPlayer) {
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
    }

    func applyPreviewVolume() {
        guard let player else { return }
        applyPreviewVolume(to: player)
    }

    private func applyPreviewVolume(to player: AVPlayer) {
        let clamped = max(session.exportVolume, 0)
        player.isMuted = clamped <= 0.0001
        player.volume = Float(clamped)
    }

    func seek(to seconds: Double, cancelTrimPreview: Bool = true) {
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

    func scrubPlayback(to seconds: Double) {
        seek(to: seconds, cancelTrimPreview: !shouldPreserveTrimPreview(whenSeekingTo: seconds))
    }

    func shouldPreserveTrimPreview(whenSeekingTo seconds: Double) -> Bool {
        guard isPreviewingTrim else { return false }

        let start = min(max(session.trimStart, 0), playbackDuration)
        let end = trimPreviewEnd
        guard end > start else { return false }

        let bounded = min(max(seconds, 0), max(playbackDuration, 0))
        return bounded >= start && bounded <= end
    }

    func toggleTrimPreview() {
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

    func startTrimPreview() {
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

    func pauseTrimPreview() {
        guard isPreviewingTrim else { return }
        player?.pause()
        isPlaying = false
        isTrimPreviewPaused = true
    }

    func resumeTrimPreview() {
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

    func stopTrimPreview() {
        player?.pause()
        isPlaying = false
        isPreviewingTrim = false
        isTrimPreviewPaused = false
    }

    func setTrimStart(_ seconds: Double) {
        guard playbackDuration > 0 else { return }
        let maxStart = max(0, session.trimEnd - cropMinimumTrimDuration(for: playbackDuration))
        session.trimStart = min(max(seconds, 0), maxStart)
        seek(to: session.trimStart)
    }

    func setTrimEnd(_ seconds: Double) {
        guard playbackDuration > 0 else { return }
        let minEnd = min(playbackDuration, session.trimStart + cropMinimumTrimDuration(for: playbackDuration))
        session.trimEnd = min(max(seconds, minEnd), playbackDuration)
        seek(to: session.trimEnd)
    }

    func resetTrimRange() {
        session.trimStart = 0
        session.trimEnd = playbackDuration
        seek(to: 0)
    }

    func clampTrimRange(to duration: Double) {
        let minimumDuration = cropMinimumTrimDuration(for: duration)
        session.trimStart = min(max(session.trimStart, 0), max(duration - minimumDuration, 0))
        session.trimEnd = min(max(session.trimEnd, session.trimStart + minimumDuration), duration)
    }

    func nudgeSelectedTrimHandle(bySteps steps: Int) {
        let offset = Double(steps) * fineTuneStep
        switch session.selectedTrimHandle {
        case .start:
            setTrimStart(session.trimStart + offset)
        case .end:
            setTrimEnd(session.trimEnd + offset)
        }
    }

    func updatePlaybackTime() {
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
}
