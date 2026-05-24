import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConcatView: View {
    private struct FileMetadata {
        let path: String
        let name: String
        let createdAt: Date
        let modifiedAt: Date
    }

    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @ObservedObject var session: ConcatSession
    @State private var isDropTarget = false

    private let mediaTypes = ["video", "audio"]

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    private func mediaTypeTitle(_ type: String) -> String {
        switch type {
        case "video": return L.text(language, "Video", "视频")
        case "audio": return L.text(language, "Audio", "音频")
        default: return type
        }
    }

    private var contentTypes: [UTType] {
        session.mediaType == "video"
            ? [.movie, .video]
            : [.audio]
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = contentTypes
        if panel.runModal() == .OK {
            appendFiles(panel.urls.map(\.path))
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let allowed = contentTypes
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let u = url, u.isFileURL else { return }
                let values = try? u.resourceValues(forKeys: [.contentTypeKey])
                guard let ct = values?.contentType,
                      allowed.contains(where: { ct.conforms(to: $0) }) else { return }
                DispatchQueue.main.async { appendFiles([u.path]) }
            }
        }
        return true
    }

    private func appendFiles(_ newFiles: [String]) {
        guard !newFiles.isEmpty else { return }
        session.files.append(contentsOf: newFiles)
        applySortOrder()
        session.completedOutput = ""
    }

    private func applySortOrder() {
        guard session.sortOrder != .manual else { return }
        session.files = sortedFiles(session.files, using: session.sortOrder)
    }

    private func sortedFiles(_ paths: [String], using order: ConcatSortOrder) -> [String] {
        guard order != .manual else { return paths }
        let metadata = paths.map(fileMetadata(for:))
        return metadata.sorted { lhs, rhs in
            compare(lhs, rhs, using: order)
        }
        .map(\.path)
    }

    private func fileMetadata(for path: String) -> FileMetadata {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return FileMetadata(
            path: path,
            name: url.lastPathComponent,
            createdAt: values?.creationDate ?? .distantPast,
            modifiedAt: values?.contentModificationDate ?? .distantPast
        )
    }

    private func compare(_ lhs: FileMetadata, _ rhs: FileMetadata, using order: ConcatSortOrder) -> Bool {
        let primary: ComparisonResult
        switch order {
        case .manual:
            return false
        case .nameAscending:
            primary = compareText(lhs.name, rhs.name)
        case .nameDescending:
            primary = compareText(rhs.name, lhs.name)
        case .createdAscending:
            primary = compareDate(lhs.createdAt, rhs.createdAt)
        case .createdDescending:
            primary = compareDate(rhs.createdAt, lhs.createdAt)
        case .modifiedAscending:
            primary = compareDate(lhs.modifiedAt, rhs.modifiedAt)
        case .modifiedDescending:
            primary = compareDate(rhs.modifiedAt, lhs.modifiedAt)
        }

        if primary != .orderedSame {
            return primary == .orderedAscending
        }

        let secondary = compareText(lhs.name, rhs.name)
        if secondary != .orderedSame {
            return secondary == .orderedAscending
        }

        return lhs.path < rhs.path
    }

    private func compareText(_ lhs: String, _ rhs: String) -> ComparisonResult {
        (lhs as NSString).localizedStandardCompare(rhs)
    }

    private func compareDate(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L.text(language, "Type:", "类型：")).frame(width: formLabelWidth, alignment: .trailing)
                Picker("type", selection: $session.mediaType) {
                    ForEach(mediaTypes, id: \.self) { Text(mediaTypeTitle($0)).tag($0) }
                }
                .pointingHandCursor()
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .fixedSize()
                Spacer()
            }
            HStack {
                Text(L.text(language, "Files:", "文件：")).frame(width: formLabelWidth, alignment: .trailing)
                Text(L.fileCount(language, session.files.count))
                    .foregroundColor(.secondary)
                Spacer()
                Button(L.text(language, "Add Files…", "添加文件…")) { addFiles() }
                    .pointingHandCursor()
                Button(L.text(language, "Clear", "清空")) { session.files.removeAll(); session.completedOutput = "" }
                    .disabled(session.files.isEmpty)
                    .pointingHandCursor()
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(L.text(language, "Sort By:", "排序：")).frame(width: formLabelWidth, alignment: .trailing)
                    Picker("sortOrder", selection: $session.sortOrder) {
                        ForEach(ConcatSortOrder.allCases) { order in
                            Text(order.title(language: language)).tag(order)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .pointingHandCursor()
                    Spacer()
                }

                HStack(alignment: .top) {
                    Spacer().frame(width: formLabelWidth)
                    Group {
                        if session.files.isEmpty {
                            VStack {
                                Spacer()
                                Text(L.text(language, "Drop files here or click Add Files", "将文件拖到这里，或点击添加文件"))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            List {
                                ForEach(Array(session.files.enumerated()), id: \.offset) { i, file in
                                    HStack {
                                        Text("\(i + 1).")
                                            .foregroundColor(.secondary)
                                            .frame(width: 24, alignment: .trailing)
                                        Text((file as NSString).lastPathComponent)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .help(file)
                                        Spacer()
                                        Button {
                                            session.files.remove(at: i)
                                            session.completedOutput = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                                .onMove { from, to in
                                    let previousFiles = session.files
                                    session.files.move(fromOffsets: from, toOffset: to)
                                    guard session.files != previousFiles else { return }
                                    if session.sortOrder != .manual {
                                        session.sortOrder = .manual
                                    }
                                    session.completedOutput = ""
                                }
                            }
                            .frame(maxHeight: .infinity)
                        }
                    }
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isDropTarget ? Color.accentColor : Color.secondary.opacity(session.files.isEmpty ? 0.3 : 0),
                                          style: session.files.isEmpty && !isDropTarget ? StrokeStyle(lineWidth: 1, dash: [5]) : StrokeStyle(lineWidth: 1.5))
                    )
                    .onTapGesture(count: 2) { addFiles() }
                    .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget, perform: handleDrop)
                }
            }

            OutputHintRow(path: session.completedOutput)
            RunButton(canRun: session.files.count >= 2) {
                session.completedOutput = ""
                let exts = Set(session.files.map { inputExt($0).lowercased() })
                let mixed = exts.count > 1

                if mixed {
                    let alert = NSAlert()
                    alert.messageText = L.text(language, "Mixed formats detected", "检测到不同格式")
                    alert.informativeText = L.text(
                        language,
                        "The selected files have different formats (\(exts.sorted().joined(separator: ", "))). They will be re-encoded to a common format, which is slower than stream copy.",
                        "所选文件格式不同（\(exts.sorted().joined(separator: ", "))）。它们会被重新编码为统一格式，这会比直接复制流更慢。"
                    )
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: L.text(language, "Re-encode & Continue", "重新编码并继续"))
                    alert.addButton(withTitle: L.text(language, "Cancel", "取消"))
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }

                if mixed {
                    var args: [String] = []
                    for f in session.files { args += ["-i", f] }

                    let n = session.files.count
                    if session.mediaType == "video" {
                        let inputs = (0..<n).map { "[\($0):v][\($0):a]" }.joined()
                        let filter = "\(inputs)concat=n=\(n):v=1:a=1[outv][outa]"
                        let out = makeOutputPath(input: session.files[0], ext: "mp4")
                        args += ["-filter_complex", filter,
                                 "-map", "[outv]", "-map", "[outa]",
                                 "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                                 "-c:a", "aac", "-b:a", "192k", "-y", out]
                    } else {
                        let inputs = (0..<n).map { "[\($0):a]" }.joined()
                        let filter = "\(inputs)concat=n=\(n):v=0:a=1[outa]"
                        let out = makeOutputPath(input: session.files[0], ext: "m4a")
                        args += ["-filter_complex", filter,
                                 "-map", "[outa]",
                                 "-c:a", "aac", "-b:a", "192k", "-y", out]
                    }

                    runner.run(args: args, inputForDuration: nil) { session.completedOutput = $0 }
                } else {
                    let tmp = NSTemporaryDirectory() + "simple-video-concat-\(ProcessInfo.processInfo.globallyUniqueString).txt"
                    let listing = session.files.map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
                        .joined(separator: "\n")
                    try? listing.write(toFile: tmp, atomically: true, encoding: .utf8)

                    let out = makeOutputPath(input: session.files[0], ext: inputExt(session.files[0]))
                    runner.run(
                        args: ["-f", "concat", "-safe", "0", "-i", tmp,
                               "-c", "copy", "-y", out],
                        inputForDuration: nil
                    ) {
                        session.completedOutput = $0
                        try? FileManager.default.removeItem(atPath: tmp)
                    }
                }
            }
        }
        .padding()
        .onChange(of: session.mediaType) { _, _ in session.files.removeAll(); session.completedOutput = "" }
        .onChange(of: session.sortOrder) { _, _ in
            applySortOrder()
            session.completedOutput = ""
        }
    }
}
