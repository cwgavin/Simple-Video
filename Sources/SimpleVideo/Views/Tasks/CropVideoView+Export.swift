import SwiftUI

extension CropVideoView {
    private var isDefaultExportVolume: Bool {
        abs(session.exportVolume - 1.0) <= 0.0001
    }

    private func audioExportFilters() -> [String] {
        var filters: [String] = []
        if session.exportPlaybackRate != .normal {
            filters.append(audioTempoFilter(for: session.exportPlaybackRate.rawValue))
        }
        if !isDefaultExportVolume {
            filters.append(audioVolumeFilter(for: session.exportVolume))
        }
        return filters
    }

    func runCrop() {
        guard let params = cropParameters else { return }
        session.completedOutput = ""
        let hasAudio = FFmpegRunner.hasAudioStream(session.input)
        let needsAudioVolumeAdjustment = hasAudio && !isDefaultExportVolume

        if let trimRange = selectedTrimRange, session.trimRangeMode == .removeSelection {
            let out = makeOutputPath(input: session.input, ext: "mp4")
            let args = removeSelectedRangeArguments(
                trimRange: trimRange,
                output: out,
                cropParameters: hasVisualCrop ? params : nil
            )
            runner.run(args: args, inputForDuration: session.input) {
                session.completedOutput = $0
                session.markCurrentStateAsBaseline()
            }
            return
        }

        if requiresVideoReencode || needsAudioVolumeAdjustment {
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

    func removeSelectedRangeArguments(
        trimRange: (start: Double, end: Double),
        output: String,
        cropParameters: CropParameters?
    ) -> [String] {
        let hasAudio = FFmpegRunner.hasAudioStream(session.input)
        let start = trimRange.start
        let end = trimRange.end

        if start <= 0.001 {
            var args = ["-ss", ffmpegTime(end), "-i", session.input]
            args += reencodedOutputArguments(output: output, cropParameters: cropParameters)
            return args
        }

        if playbackDuration > 0, end >= playbackDuration - 0.001 {
            var args = ["-i", session.input, "-t", ffmpegTime(start)]
            args += reencodedOutputArguments(output: output, cropParameters: cropParameters)
            return args
        }

        var filterParts: [String] = [
            "[0:v]split=2[v0][v1]",
            "[v0]trim=start=0:end=\(ffmpegTime(start)),setpts=PTS-STARTPTS[v0t]",
            "[v1]trim=start=\(ffmpegTime(end)),setpts=PTS-STARTPTS[v1t]",
            "[v0t][v1t]concat=n=2:v=1:a=0[vbase]"
        ]

        var videoOutputLabel = "vbase"
        var videoPostFilters: [String] = []
        if let cropParameters {
            videoPostFilters.append("crop=\(cropParameters.width):\(cropParameters.height):\(cropParameters.x):\(cropParameters.y)")
        }
        if session.exportPlaybackRate != .normal {
            let ptsMultiplier = 1.0 / session.exportPlaybackRate.rawValue
            videoPostFilters.append(String(format: "setpts=%.8f*PTS", ptsMultiplier))
        }
        if !videoPostFilters.isEmpty {
            filterParts.append("[vbase]\(videoPostFilters.joined(separator: ","))[vout]")
            videoOutputLabel = "vout"
        }

        var audioOutputLabel: String?
        if hasAudio {
            filterParts += [
                "[0:a]asplit=2[a0][a1]",
                "[a0]atrim=start=0:end=\(ffmpegTime(start)),asetpts=PTS-STARTPTS[a0t]",
                "[a1]atrim=start=\(ffmpegTime(end)),asetpts=PTS-STARTPTS[a1t]",
                "[a0t][a1t]concat=n=2:v=0:a=1[abase]"
            ]

            let exportFilters = audioExportFilters()
            if !exportFilters.isEmpty {
                filterParts.append("[abase]\(exportFilters.joined(separator: ","))[aout]")
                audioOutputLabel = "aout"
            } else {
                audioOutputLabel = "abase"
            }
        }

        var args = ["-i", session.input, "-filter_complex", filterParts.joined(separator: ";"), "-map", "[\(videoOutputLabel)]"]
        if let audioOutputLabel {
            args += ["-map", "[\(audioOutputLabel)]", "-c:a", "aac", "-b:a", "192k"]
        }
        args += session.exportQuality.videoArguments
        args += ["-movflags", "+faststart", "-y", output]
        return args
    }

    func reencodedOutputArguments(output: String, cropParameters: CropParameters?) -> [String] {
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
            let exportFilters = audioExportFilters()
            if !exportFilters.isEmpty {
                args += ["-af", exportFilters.joined(separator: ",")]
            }
            args += ["-c:a", "aac", "-b:a", "192k"]
        }
        args += ["-movflags", "+faststart", "-y", output]
        return args
    }

    func copyOutputArguments(output: String) -> [String] {
        var args = ["-map", "0", "-c", "copy"]
        let ext = (output as NSString).pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) {
            args += ["-movflags", "+faststart"]
        }
        args += ["-y", output]
        return args
    }

    func audioTempoFilter(for rate: Double) -> String {
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

    func audioVolumeFilter(for volume: Double) -> String {
        String(format: "volume=%.8f", max(volume, 0))
    }
}
