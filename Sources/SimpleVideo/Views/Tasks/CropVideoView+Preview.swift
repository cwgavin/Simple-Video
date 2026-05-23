import SwiftUI
import AppKit

extension CropVideoView {
    func detectBlackBars() {
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

    func loadPreview(for path: String) {
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
}
