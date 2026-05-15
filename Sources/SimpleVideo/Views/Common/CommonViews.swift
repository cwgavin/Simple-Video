import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - File picker helpers

enum Files {
    static func openFile(contentTypes: [UTType] = []) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if !contentTypes.isEmpty {
            panel.allowedContentTypes = contentTypes
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Common UI bits

/// Generates an output path next to `input` named with a millisecond timestamp
/// so collisions are effectively impossible.
/// Example: `/Users/me/Movies/clip.mov`, ext `mp4`
///       → `/Users/me/Movies/20260426-001234-567.mp4`
func makeOutputPath(input: String, ext: String) -> String {
    let url = URL(fileURLWithPath: input)
    let dir = url.deletingLastPathComponent().path
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
    let stamp = fmt.string(from: Date())
    return "\(dir)/\(stamp).\(ext)"
}

func makeOutputDirectory(input: String, label: String) -> String {
    let url = URL(fileURLWithPath: input)
    let dir = url.deletingLastPathComponent().path
    let baseName = url.deletingPathExtension().lastPathComponent
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
    let stamp = fmt.string(from: Date())
    return "\(dir)/\(baseName)-\(label)-\(stamp)"
}

func inputExt(_ path: String) -> String {
    let e = (path as NSString).pathExtension
    return e.isEmpty ? "mp4" : e
}

func parseTimestamp(_ raw: String) -> Double? {
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return nil }

    var values: [Double] = []
    for part in parts {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed), value >= 0 else { return nil }
        values.append(value)
    }

    switch values.count {
    case 1:
        return values[0]
    case 2:
        guard values[1] < 60 else { return nil }
        return values[0] * 60 + values[1]
    case 3:
        guard values[1] < 60, values[2] < 60 else { return nil }
        return values[0] * 3600 + values[1] * 60 + values[2]
    default:
        return nil
    }
}

enum TimestampParseResult {
    case success([Double])
    case failure(String)
}

func parseTimestampList(_ raw: String) -> TimestampParseResult {
    let tokens = raw
        .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard !tokens.isEmpty else {
        return .failure("Enter at least one timestamp.")
    }

    var seconds: [Double] = []
    for token in tokens {
        guard let value = parseTimestamp(token), value > 0 else {
            return .failure("Invalid timestamp: \(token)")
        }
        seconds.append(value)
    }

    let sorted = seconds.sorted()
    guard sorted == seconds else {
        return .failure("Timestamps must be in ascending order.")
    }
    guard Set(seconds).count == seconds.count else {
        return .failure("Timestamps must be unique.")
    }

    return .success(seconds)
}

func ffmpegTimestampList(_ seconds: [Double]) -> String {
    seconds
        .map { value in
            let text = String(format: "%.3f", value)
            return text.replacingOccurrences(of: #"(\.\d*?[1-9])0+$|\.0+$"#,
                                             with: "$1",
                                             options: .regularExpression)
        }
        .joined(separator: ",")
}

func ffmpegTime(_ seconds: Double) -> String {
    ffmpegTimestampList([seconds])
}

let formLabelWidth: CGFloat = 100

private struct PointingHandCursorModifier: ViewModifier {
    let isEnabled: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    isHovering = true
                    if isEnabled {
                        NSCursor.pointingHand.push()
                    }
                } else {
                    if isHovering && isEnabled {
                        NSCursor.pop()
                    }
                    isHovering = false
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                guard isHovering else { return }
                if enabled {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering && isEnabled {
                    NSCursor.pop()
                }
                isHovering = false
            }
    }
}

extension View {
    func pointingHandCursor(enabled: Bool = true) -> some View {
        modifier(PointingHandCursorModifier(isEnabled: enabled))
    }
}

struct FilePickerRow: View {
    let label: String
    @Binding var path: String
    var contentTypes: [UTType] = []

    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var isDropTarget = false

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    private var displayName: String {
        path.isEmpty ? "" : (path as NSString).lastPathComponent
    }

    private func browse() {
        if let p = Files.openFile(contentTypes: contentTypes) {
            path = p
        }
    }

    var body: some View {
        HStack {
            Text(label).frame(width: formLabelWidth, alignment: .trailing)
            ZStack(alignment: .leading) {
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { browse() }
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor))
                    )
                    .help(path.isEmpty ? "" : path)

                if displayName.isEmpty {
                    Text(L.text(language,
                                "No file selected — drag a file here or click Browse",
                                "未选择文件 — 可拖入文件或点击浏览"))
                        .foregroundColor(.secondary)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isDropTarget ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let u = url, u.isFileURL else { return }
                    if !contentTypes.isEmpty {
                        let values = try? u.resourceValues(forKeys: [.contentTypeKey])
                        guard let ct = values?.contentType,
                              contentTypes.contains(where: { ct.conforms(to: $0) }) else {
                            return
                        }
                    }
                    DispatchQueue.main.async { self.path = u.path }
                }
                return true
            }
            Button(L.text(language, "Browse…", "浏览…")) { browse() }
                .pointingHandCursor()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Always-visible output row. The label is always shown; the path and
/// Reveal button only appear after a successful run.
struct OutputHintRow: View {
    let path: String
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    var body: some View {
        HStack {
            Text(L.text(language, "Output →", "输出 →")).frame(width: formLabelWidth, alignment: .trailing)
                .foregroundColor(.secondary)
            if path.isEmpty {
                Spacer()
            } else {
                HStack(spacing: 6) {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help(L.text(language, "Reveal in Finder", "在 Finder 中显示"))
                    .buttonStyle(.borderless)
                    .pointingHandCursor()
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RunButton: View {
    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    let canRun: Bool
    let action: () -> Void

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Label(L.text(language, "Run", "运行"), systemImage: "play.fill")
                    .frame(minWidth: 100)
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canRun || runner.isRunning)
            .buttonStyle(.borderedProminent)
            .pointingHandCursor(enabled: canRun && !runner.isRunning)
        }.padding(.top, 6)
    }
}
