import SwiftUI

struct TrimTimelineView: View {
    let duration: Double
    let minimumDuration: Double
    let startHandleLabel: String
    let endHandleLabel: String
    let formatTime: (Double) -> String
    let selectedHandle: TrimHandleSelection
    @Binding var start: Double
    @Binding var end: Double
    @Binding var playhead: Double
    let onSeek: (Double) -> Void
    let onSetStart: (Double) -> Void
    let onSetEnd: (Double) -> Void
    let onSelectStart: () -> Void
    let onSelectEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let startX = xPosition(for: start, width: width)
            let endX = xPosition(for: end, width: width)
            let playheadX = xPosition(for: playhead, width: width)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .separatorColor).opacity(0.35))
                    .frame(height: 14)
                    .offset(y: 20)
                    .gesture(playheadDragGesture(width: width))

                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(endX - startX, 1), height: 14)
                    .offset(x: startX, y: 20)
                    .gesture(playheadDragGesture(width: width))

                excludedRegion(width: startX)
                    .offset(y: 20)
                excludedRegion(width: max(width - endX, 0))
                    .offset(x: endX, y: 20)

                timeHandle(label: startHandleLabel, isSelected: selectedHandle == .start)
                    .pointingHandCursor()
                    .position(x: startX, y: 27)
                    .onTapGesture {
                        onSelectStart()
                    }
                    .gesture(startDragGesture(width: width))

                timeHandle(label: endHandleLabel, isSelected: selectedHandle == .end)
                    .pointingHandCursor()
                    .position(x: endX, y: 27)
                    .onTapGesture {
                        onSelectEnd()
                    }
                    .gesture(endDragGesture(width: width))

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 34)
                    .shadow(radius: 1)
                    .pointingHandCursor()
                    .position(x: playheadX, y: 27)
                    .gesture(playheadDragGesture(width: width))

                HStack {
                    Text(formatTime(start))
                    Spacer()
                    Text(formatTime(playhead))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(formatTime(end))
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .offset(y: 48)
            }
        }
        .frame(height: 72)
    }

    private func excludedRegion(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.35))
            .frame(width: max(width, 0), height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func timeHandle(label: String, isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.75))
            .frame(width: 18, height: 32)
            .overlay {
                Text(label)
                    .font(.caption2.bold())
                    .foregroundColor(.white)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.white : Color.white.opacity(0.7), lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? Color.accentColor.opacity(0.35) : .clear, radius: 3)
    }

    private func startDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelectStart()
                let next = min(max(time(for: value.location.x, width: width), 0), max(end - minimumDuration, 0))
                onSetStart(next)
            }
    }

    private func endDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelectEnd()
                let next = min(max(time(for: value.location.x, width: width), start + minimumDuration), duration)
                onSetEnd(next)
            }
    }

    private func playheadDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let next = min(max(time(for: value.location.x, width: width), 0), duration)
                onSeek(next)
            }
    }

    private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return min(max(CGFloat(time / duration) * width, 0), width)
    }

    private func time(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }
}
