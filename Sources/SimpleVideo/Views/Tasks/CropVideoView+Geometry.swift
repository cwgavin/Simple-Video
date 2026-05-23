import SwiftUI

extension CropVideoView {
    func isFullFrameCrop(_ params: CropParameters) -> Bool {
        let pixelWidth = Int(previewPixelSize.width.rounded(.down))
        let pixelHeight = Int(previewPixelSize.height.rounded(.down))
        guard pixelWidth > 0, pixelHeight > 0 else { return false }

        return abs(params.x) <= 1
            && abs(params.y) <= 1
            && abs(params.width - pixelWidth) <= 2
            && abs(params.height - pixelHeight) <= 2
    }

    func evenInt(_ value: CGFloat) -> Int {
        let integer = max(0, Int(value.rounded(.down)))
        return integer - (integer % 2)
    }

    func defaultCropRect() -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func adjustedCropRect(_ rect: CGRect, for pixelAspectRatio: CGFloat?) -> CGRect {
        guard let pixelAspectRatio, pixelAspectRatio > 0,
              previewPixelSize.width > 0, previewPixelSize.height > 0 else {
            return clampCropRect(rect)
        }

        let normalizedAspect = pixelAspectRatio / (previewPixelSize.width / previewPixelSize.height)
        var width: CGFloat = 1.0
        var height = width / normalizedAspect

        if height > 1.0 {
            height = 1.0
            width = height * normalizedAspect
        }

        return clampCropRect(CGRect(
            x: 0.5 - width / 2,
            y: 0.5 - height / 2,
            width: width,
            height: height
        ))
    }

    func clampCropRect(_ rect: CGRect) -> CGRect {
        let minSize: CGFloat = 0.03
        let width = min(max(rect.width, minSize), 1)
        let height = min(max(rect.height, minSize), 1)
        let x = min(max(rect.minX, 0), 1 - width)
        let y = min(max(rect.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func cropRect(from params: CropParameters) -> CGRect {
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
