import SwiftUI

extension CropAudioView {
    func runCropAudio() {
        let hasExactTrim = selectedTrimRange != nil
        let needsReencode = hasExactTrim || session.exportPlaybackRate != .normal
        let outputExtension = normalizedOutputExtension()
        let out = makeOutputPath(
            input: session.input,
            ext: needsReencode ? outputExtension : inputExt(session.input)
        )

        let args: [String]
        if needsReencode {
            if let trimRange = selectedTrimRange, session.trimRangeMode == .removeSelection {
                args = removeSelectedRangeArguments(trimRange: trimRange, output: out)
            } else {
                var reencodeArgs = ["-i", session.input]
                if let trimRange = selectedTrimRange {
                    reencodeArgs += [
                        "-ss", ffmpegTime(trimRange.start),
                        "-t", ffmpegTime(trimRange.end - trimRange.start)
                    ]
                }
                reencodeArgs += reencodedAudioOutputArguments(output: out)
                args = reencodeArgs
            }
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

    func removeSelectedRangeArguments(trimRange: (start: Double, end: Double), output: String) -> [String] {
        let start = trimRange.start
        let end = trimRange.end

        if start <= 0.001 {
            var args = ["-ss", ffmpegTime(end), "-i", session.input]
            args += reencodedAudioOutputArguments(output: output)
            return args
        }

        if playbackDuration > 0, end >= playbackDuration - 0.001 {
            var args = ["-i", session.input, "-t", ffmpegTime(start)]
            args += reencodedAudioOutputArguments(output: output)
            return args
        }

        var filterParts = [
            "[0:a]asplit=2[a0][a1]",
            "[a0]atrim=start=0:end=\(ffmpegTime(start)),asetpts=PTS-STARTPTS[a0t]",
            "[a1]atrim=start=\(ffmpegTime(end)),asetpts=PTS-STARTPTS[a1t]",
            "[a0t][a1t]concat=n=2:v=0:a=1[abase]"
        ]

        var outputLabel = "abase"
        if session.exportPlaybackRate != .normal {
            filterParts.append("[abase]\(cropAudioTempoFilter(for: session.exportPlaybackRate.rawValue))[aout]")
            outputLabel = "aout"
        }

        var args = ["-i", session.input, "-filter_complex", filterParts.joined(separator: ";"), "-map", "[\(outputLabel)]"]
        args += reencodedAudioEncodingArguments(for: output)
        args += ["-y", output]
        return args
    }

    func normalizedOutputExtension() -> String {
        let ext = inputExt(session.input).lowercased()
        let supported = ["mp3", "aac", "m4a", "flac", "wav", "ogg", "opus", "wma", "aiff"]
        return supported.contains(ext) ? ext : "m4a"
    }

    func reencodedAudioOutputArguments(output: String) -> [String] {
        var args = ["-map", "0:a:0"]

        if session.exportPlaybackRate != .normal {
            args += ["-af", cropAudioTempoFilter(for: session.exportPlaybackRate.rawValue)]
        }

        args += reencodedAudioEncodingArguments(for: output)
        args += ["-y", output]
        return args
    }

    func reencodedAudioEncodingArguments(for output: String) -> [String] {
        let ext = (output as NSString).pathExtension.lowercased()
        var args: [String] = []

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
        return args
    }
}
