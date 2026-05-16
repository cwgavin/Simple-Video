import SwiftUI
import AppKit
import AVFoundation

extension CropVideoView {
    static func generatePreviewFrame(path: String) async throws -> Data {
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

    static func requiresPreviewProxy(path: String) async -> Bool {
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

    static func generatePreviewProxy(
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

    static func detectCropParameters(path: String) async throws -> CropParameters {
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
}
