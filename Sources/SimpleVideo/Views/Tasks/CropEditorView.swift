import SwiftUI
import AppKit
import AVFoundation

private enum CropHandle {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var size: CGSize {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            return CGSize(width: 14, height: 14)
        case .top, .bottom:
            return CGSize(width: 32, height: 8)
        case .left, .right:
            return CGSize(width: 8, height: 32)
        }
    }
}

private final class CropPlayerPreviewNSView: NSView {
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func setPlayer(_ player: AVPlayer?) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }
}

private struct CropPlayerPreviewView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> CropPlayerPreviewNSView {
        let view = CropPlayerPreviewNSView()
        view.setPlayer(player)
        return view
    }

    func updateNSView(_ nsView: CropPlayerPreviewNSView, context: Context) {
        nsView.setPlayer(player)
    }

    static func dismantleNSView(_ nsView: CropPlayerPreviewNSView, coordinator: ()) {
        nsView.setPlayer(nil)
    }
}

private final class CropCursorTrackingNSView: NSView {
    override var isFlipped: Bool { true }

    var isDragging = false

    var cursorZones: [(NSRect, NSCursor)] = [] {
        didSet {
            if !isDragging { refreshCursorNow() }
        }
    }

    private var trackingArea: NSTrackingArea?

    override func hitTest(_ aPoint: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseMoved(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func applyCursor(at point: NSPoint) {
        for i in stride(from: cursorZones.count - 1, through: 1, by: -1) {
            if cursorZones[i].0.contains(point) {
                cursorZones[i].1.set()
                return
            }
        }
        if !cursorZones.isEmpty, cursorZones[0].0.contains(point) {
            cursorZones[0].1.set()
            return
        }
        NSCursor.arrow.set()
    }

    func refreshCursorNow() {
        guard let window else { return }
        let localPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(localPoint) {
            applyCursor(at: localPoint)
        }
    }
}

private struct CropCursorTrackingView: NSViewRepresentable {
    let zones: [(CGRect, NSCursor)]
    let isDragging: Bool

    func makeNSView(context: Context) -> CropCursorTrackingNSView {
        let view = CropCursorTrackingNSView()
        view.isDragging = isDragging
        view.cursorZones = zones.map { ($0.0, $0.1) }
        return view
    }

    func updateNSView(_ nsView: CropCursorTrackingNSView, context: Context) {
        nsView.isDragging = isDragging
        nsView.cursorZones = zones.map { ($0.0, $0.1) }
        if !isDragging {
            nsView.refreshCursorNow()
        }
    }
}

struct CropEditorView: View {
    let image: NSImage?
    let player: AVPlayer?
    let imagePixelSize: CGSize
    let fixedAspectRatio: CGFloat?
    @Binding var cropRect: CGRect

    @State private var dragStart: CGRect?
    @State private var resizeStart: CGRect?

    private var imageAspect: CGFloat {
        guard imagePixelSize.height > 0 else { return 1 }
        return imagePixelSize.width / imagePixelSize.height
    }

    var body: some View {
        GeometryReader { geo in
            let displayRect = fittedImageRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.86)

                if player != nil {
                    CropPlayerPreviewView(player: player)
                        .frame(width: displayRect.width, height: displayRect.height)
                        .position(x: displayRect.midX, y: displayRect.midY)
                        .allowsHitTesting(false)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: displayRect.width, height: displayRect.height)
                        .position(x: displayRect.midX, y: displayRect.midY)
                }

                if displayRect.width > 0, displayRect.height > 0 {
                    overlayMask(displayRect: displayRect)
                    cropBox(displayRect: displayRect)
                    CropCursorTrackingView(zones: cursorZones(displayRect: displayRect), isDragging: dragStart != nil || resizeStart != nil)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minHeight: 320)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fittedImageRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let containerAspect = size.width / size.height
        let fittedSize: CGSize
        if containerAspect > imageAspect {
            let height = size.height
            fittedSize = CGSize(width: height * imageAspect, height: height)
        } else {
            let width = size.width
            fittedSize = CGSize(width: width, height: width / imageAspect)
        }
        return CGRect(
            x: (size.width - fittedSize.width) / 2,
            y: (size.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func displayedCropRect(in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + cropRect.minX * imageRect.width,
            y: imageRect.minY + cropRect.minY * imageRect.height,
            width: cropRect.width * imageRect.width,
            height: cropRect.height * imageRect.height
        )
    }

    private func overlayMask(displayRect: CGRect) -> some View {
        let crop = displayedCropRect(in: displayRect)
        return Path { path in
            path.addRect(displayRect)
            path.addRect(crop)
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
    }

    private func cropBox(displayRect: CGRect) -> some View {
        let crop = displayedCropRect(in: displayRect)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.08))
                .frame(width: crop.width, height: crop.height)
                .position(x: crop.midX, y: crop.midY)
                .gesture(moveGesture(displayRect: displayRect))

            handle(.topLeft, at: CGPoint(x: crop.minX, y: crop.minY), displayRect: displayRect)
            handle(.top, at: CGPoint(x: crop.midX, y: crop.minY), displayRect: displayRect)
            handle(.topRight, at: CGPoint(x: crop.maxX, y: crop.minY), displayRect: displayRect)
            handle(.right, at: CGPoint(x: crop.maxX, y: crop.midY), displayRect: displayRect)
            handle(.bottomRight, at: CGPoint(x: crop.maxX, y: crop.maxY), displayRect: displayRect)
            handle(.bottom, at: CGPoint(x: crop.midX, y: crop.maxY), displayRect: displayRect)
            handle(.bottomLeft, at: CGPoint(x: crop.minX, y: crop.maxY), displayRect: displayRect)
            handle(.left, at: CGPoint(x: crop.minX, y: crop.midY), displayRect: displayRect)
        }
    }

    private func handle(_ handle: CropHandle, at point: CGPoint, displayRect: CGRect) -> some View {
        handleShape(handle)
            .position(point)
            .gesture(resizeGesture(handle, displayRect: displayRect))
    }

    private func cursorZones(displayRect: CGRect) -> [(CGRect, NSCursor)] {
        let crop = displayedCropRect(in: displayRect)
        var zones: [(CGRect, NSCursor)] = []

        let handles: [(CropHandle, CGPoint)] = [
            (.topLeft,     CGPoint(x: crop.minX, y: crop.minY)),
            (.top,         CGPoint(x: crop.midX, y: crop.minY)),
            (.topRight,    CGPoint(x: crop.maxX, y: crop.minY)),
            (.right,       CGPoint(x: crop.maxX, y: crop.midY)),
            (.bottomRight, CGPoint(x: crop.maxX, y: crop.maxY)),
            (.bottom,      CGPoint(x: crop.midX, y: crop.maxY)),
            (.bottomLeft,  CGPoint(x: crop.minX, y: crop.maxY)),
            (.left,        CGPoint(x: crop.minX, y: crop.midY)),
        ]
        for (h, pt) in handles {
            let size = h.size
            let rect = CGRect(
                x: pt.x - size.width / 2,
                y: pt.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            zones.append((rect, Self.cursor(for: h)))
        }

        zones.insert((crop, .openHand), at: 0)

        return zones
    }

    private static func cursor(for handle: CropHandle) -> NSCursor {
        switch handle {
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        case .topLeft, .bottomRight:
            return nwseResizeCursor
        case .topRight, .bottomLeft:
            return neswResizeCursor
        }
    }

    private static let nwseResizeCursor: NSCursor = systemCursor("_windowResizeNorthWestSouthEastCursor") ?? makeDiagonalCursor(nwse: true)
    private static let neswResizeCursor: NSCursor = systemCursor("_windowResizeNorthEastSouthWestCursor") ?? makeDiagonalCursor(nwse: false)

    private static func systemCursor(_ selectorName: String) -> NSCursor? {
        guard let result = NSCursor.perform(NSSelectorFromString(selectorName)) else { return nil }
        return result.takeUnretainedValue() as? NSCursor
    }

    private static func makeDiagonalCursor(nwse: Bool) -> NSCursor {
        let size: CGFloat = 17
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath()
            let margin: CGFloat = 2
            let arrowLen: CGFloat = 4.5

            let start: NSPoint
            let end: NSPoint
            if nwse {
                start = NSPoint(x: margin, y: rect.maxY - margin)
                end = NSPoint(x: rect.maxX - margin, y: margin)
            } else {
                start = NSPoint(x: rect.maxX - margin, y: rect.maxY - margin)
                end = NSPoint(x: margin, y: margin)
            }

            path.move(to: start)
            path.line(to: end)

            let angle1 = atan2(end.y - start.y, end.x - start.x)
            path.move(to: start)
            path.line(to: NSPoint(
                x: start.x + arrowLen * cos(angle1 + .pi / 5),
                y: start.y + arrowLen * sin(angle1 + .pi / 5)
            ))
            path.move(to: start)
            path.line(to: NSPoint(
                x: start.x + arrowLen * cos(angle1 - .pi / 5),
                y: start.y + arrowLen * sin(angle1 - .pi / 5)
            ))

            let angle2 = atan2(start.y - end.y, start.x - end.x)
            path.move(to: end)
            path.line(to: NSPoint(
                x: end.x + arrowLen * cos(angle2 + .pi / 5),
                y: end.y + arrowLen * sin(angle2 + .pi / 5)
            ))
            path.move(to: end)
            path.line(to: NSPoint(
                x: end.x + arrowLen * cos(angle2 - .pi / 5),
                y: end.y + arrowLen * sin(angle2 - .pi / 5)
            ))

            path.lineWidth = 2.5
            NSColor.white.setStroke()
            path.stroke()

            path.lineWidth = 1.2
            NSColor.black.setStroke()
            path.stroke()

            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }

    @ViewBuilder
    private func handleShape(_ handle: CropHandle) -> some View {
        let s = handle.size
        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            Circle()
                .fill(Color.accentColor)
                .frame(width: s.width, height: s.height)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
        case .top, .bottom:
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor)
                .frame(width: s.width, height: s.height)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1))
        case .left, .right:
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor)
                .frame(width: s.width, height: s.height)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1))
        }
    }

    private func moveGesture(displayRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = cropRect }
                guard let start = dragStart else { return }
                let dx = value.translation.width / max(displayRect.width, 1)
                let dy = value.translation.height / max(displayRect.height, 1)
                cropRect = clampedMovingCropRect(CGRect(
                    x: start.minX + dx,
                    y: start.minY + dy,
                    width: start.width,
                    height: start.height
                ))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ handle: CropHandle, displayRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStart == nil { resizeStart = cropRect }
                guard let start = resizeStart else { return }
                let dx = value.translation.width / max(displayRect.width, 1)
                let dy = value.translation.height / max(displayRect.height, 1)
                var next = start

                switch handle {
                case .topLeft:
                    next.origin.x += dx
                    next.origin.y += dy
                    next.size.width -= dx
                    next.size.height -= dy
                case .top:
                    next.origin.y += dy
                    next.size.height -= dy
                case .topRight:
                    next.origin.y += dy
                    next.size.width += dx
                    next.size.height -= dy
                case .right:
                    next.size.width += dx
                case .bottomRight:
                    next.size.width += dx
                    next.size.height += dy
                case .bottom:
                    next.size.height += dy
                case .bottomLeft:
                    next.origin.x += dx
                    next.size.width -= dx
                    next.size.height += dy
                case .left:
                    next.origin.x += dx
                    next.size.width -= dx
                }

                if let fixedAspectRatio {
                    cropRect = aspectLockedCropRect(proposed: next, anchorFor: handle, aspectRatio: normalizedAspectRatio(for: fixedAspectRatio))
                } else {
                    cropRect = clampedMovingCropRect(next)
                }
            }
            .onEnded { _ in resizeStart = nil }
    }

    private func normalizedAspectRatio(for pixelAspectRatio: CGFloat) -> CGFloat {
        guard imageAspect > 0 else { return pixelAspectRatio }
        return pixelAspectRatio / imageAspect
    }

    private func clampedMovingCropRect(_ rect: CGRect) -> CGRect {
        let minSize: CGFloat = 0.03
        let width = min(max(rect.width, minSize), 1)
        let height = min(max(rect.height, minSize), 1)
        let x = min(max(rect.minX, 0), 1 - width)
        let y = min(max(rect.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func aspectLockedCropRect(proposed: CGRect, anchorFor handle: CropHandle, aspectRatio: CGFloat) -> CGRect {
        guard let start = resizeStart, aspectRatio > 0 else {
            return clampedMovingCropRect(proposed)
        }

        if !isCorner(handle) {
            return aspectLockedEdgeCropRect(proposed: proposed, edge: handle, aspectRatio: aspectRatio)
        }

        let minSize: CGFloat = 0.03
        let anchor: CGPoint
        let maxWidth: CGFloat
        let maxHeight: CGFloat

        switch handle {
        case .topLeft:
            anchor = CGPoint(x: start.maxX, y: start.maxY)
            maxWidth = anchor.x
            maxHeight = anchor.y
        case .topRight:
            anchor = CGPoint(x: start.minX, y: start.maxY)
            maxWidth = 1 - anchor.x
            maxHeight = anchor.y
        case .bottomLeft:
            anchor = CGPoint(x: start.maxX, y: start.minY)
            maxWidth = anchor.x
            maxHeight = 1 - anchor.y
        case .bottomRight:
            anchor = CGPoint(x: start.minX, y: start.minY)
            maxWidth = 1 - anchor.x
            maxHeight = 1 - anchor.y
        default:
            return clampedMovingCropRect(proposed)
        }

        let proposedWidth = max(minSize, abs(proposed.width))
        let proposedHeight = max(minSize, abs(proposed.height))
        var width: CGFloat
        var height: CGFloat

        if proposedWidth / proposedHeight > aspectRatio {
            height = proposedHeight
            width = height * aspectRatio
        } else {
            width = proposedWidth
            height = width / aspectRatio
        }

        width = min(max(width, minSize), maxWidth, maxHeight * aspectRatio)
        height = width / aspectRatio
        if height > maxHeight {
            height = maxHeight
            width = height * aspectRatio
        }

        switch handle {
        case .topLeft:
            return CGRect(x: anchor.x - width, y: anchor.y - height, width: width, height: height)
        case .topRight:
            return CGRect(x: anchor.x, y: anchor.y - height, width: width, height: height)
        case .bottomLeft:
            return CGRect(x: anchor.x - width, y: anchor.y, width: width, height: height)
        case .bottomRight:
            return CGRect(x: anchor.x, y: anchor.y, width: width, height: height)
        default:
            return clampedMovingCropRect(proposed)
        }
    }

    private func isCorner(_ handle: CropHandle) -> Bool {
        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            return true
        default:
            return false
        }
    }

    private func aspectLockedEdgeCropRect(proposed: CGRect, edge: CropHandle, aspectRatio: CGFloat) -> CGRect {
        guard let start = resizeStart else { return clampedMovingCropRect(proposed) }

        let minSize: CGFloat = 0.03
        var width: CGFloat
        var height: CGFloat
        var center = CGPoint(x: start.midX, y: start.midY)

        switch edge {
        case .left:
            width = max(minSize, start.maxX - proposed.minX)
            height = width / aspectRatio
            center.x = start.maxX - width / 2
        case .right:
            width = max(minSize, proposed.maxX - start.minX)
            height = width / aspectRatio
            center.x = start.minX + width / 2
        case .top:
            height = max(minSize, start.maxY - proposed.minY)
            width = height * aspectRatio
            center.y = start.maxY - height / 2
        case .bottom:
            height = max(minSize, proposed.maxY - start.minY)
            width = height * aspectRatio
            center.y = start.minY + height / 2
        default:
            return clampedMovingCropRect(proposed)
        }

        width = min(width, 1)
        height = min(height, 1)
        if width / aspectRatio > 1 {
            width = aspectRatio
            height = 1
        }
        if height * aspectRatio > 1 {
            height = 1 / aspectRatio
            width = 1
        }

        return clampedMovingCropRect(CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        ))
    }
}
