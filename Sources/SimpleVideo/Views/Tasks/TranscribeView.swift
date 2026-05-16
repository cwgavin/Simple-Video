import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Transcribe

struct TranscribeView: View {
    @EnvironmentObject var runner: FFmpegRunner
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @State private var inputPath = ""
    @State private var model = "base"
    @State private var language = ""
    @State private var transcript = ""
    @State private var isTranscribing = false
    @State private var isDownloadingModel = false
    @State private var downloadProgress: Double = 0
    @State private var modelStatusVersion = 0

    private var selectedModel: WhisperModelInfo {
        WhisperModelCatalog.info(for: model)
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    private func modelDisplayName(_ model: WhisperModelInfo) -> String {
        switch appLanguage {
        case .english:
            return model.displayName
        case .simplifiedChinese:
            switch model.id {
            case "tiny": return "Tiny（微型）"
            case "base": return "Base（基础）"
            case "small": return "Small（小型）"
            case "medium": return "Medium（中型）"
            case "large": return "Large v3（大型）"
            default: return model.displayName
            }
        }
    }

    private var selectedModelPath: String? {
        _ = modelStatusVersion
        return FFmpegRunner.resolveWhisperModel(model)
    }

    private var selectedDownloadedModelURLs: [URL] {
        _ = modelStatusVersion
        return WhisperModelCatalog.downloadedModelURLs(for: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FilePickerRow(label: L.text(appLanguage, "Input:", "输入："), path: $inputPath,
                           contentTypes: [.movie, .video, .audio])

            HStack(spacing: 0) {
                Text(L.text(appLanguage, "Model:", "模型：")).frame(width: formLabelWidth, alignment: .trailing)
                Picker("model", selection: $model) {
                    ForEach(WhisperModelCatalog.models) { model in
                        Text("\(modelDisplayName(model)) (\(model.sizeDescription))").tag(model.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .pointingHandCursor()
                .padding(.leading, 6)
                Spacer()
            }

            HStack(alignment: .top) {
                Text(L.text(appLanguage, "Model file:", "模型文件：")).frame(width: formLabelWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    if selectedModelPath != nil {
                        Label(selectedDownloadedModelURLs.isEmpty
                              ? L.text(appLanguage, "Available", "可用")
                              : L.text(appLanguage, "Downloaded", "已下载"),
                              systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        if !selectedDownloadedModelURLs.isEmpty {
                            HStack(spacing: 8) {
                                Button(role: .destructive, action: deleteSelectedModel) {
                                    Label(L.text(appLanguage, "Delete \(selectedModel.displayName)", "删除 \(modelDisplayName(selectedModel))"), systemImage: "trash")
                                }
                                .disabled(isDownloadingModel || isTranscribing || runner.isRunning)
                                .pointingHandCursor()
                                Text(L.text(appLanguage,
                                            "Removes it from \(WhisperModelCatalog.modelDirectoryDisplayPath)",
                                            "从 \(WhisperModelCatalog.modelDirectoryDisplayPath) 中移除"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text(L.text(appLanguage,
                                        "This model is coming from the app bundle or an external model directory.",
                                        "此模型来自应用包或外部模型目录。"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(L.text(appLanguage,
                                    "Required before transcription. Saved to \(WhisperModelCatalog.modelDirectoryDisplayPath)",
                                    "转写前需要先下载。保存到 \(WhisperModelCatalog.modelDirectoryDisplayPath)"))
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Button(action: downloadSelectedModel) {
                            Label(isDownloadingModel
                                  ? L.text(appLanguage, "Downloading \(selectedModel.displayName)…", "正在下载 \(modelDisplayName(selectedModel))…")
                                  : L.text(appLanguage, "Download \(selectedModel.displayName)", "下载 \(modelDisplayName(selectedModel))"),
                                  systemImage: "arrow.down.circle")
                        }
                        .pointingHandCursor()
                        .disabled(isDownloadingModel || runner.isRunning)
                        if isDownloadingModel {
                            ProgressView(value: downloadProgress)
                                .frame(maxWidth: 320)
                            Text("\(Int(downloadProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
            }

            HStack {
                Text(L.text(appLanguage, "Language:", "语言：")).frame(width: formLabelWidth, alignment: .trailing)
                TextField(L.text(appLanguage, "auto-detect", "自动检测"), text: $language)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Text(L.text(appLanguage, "e.g. en, zh, ja", "例如 en、zh、ja")).foregroundColor(.secondary).font(.caption)
                Spacer()
            }

            HStack {
                Spacer()
                Button(action: transcribe) {
                    Label(L.text(appLanguage, "Transcribe", "转写"), systemImage: "text.bubble")
                        .frame(minWidth: 100)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(inputPath.isEmpty || selectedModelPath == nil || isDownloadingModel || isTranscribing || runner.isRunning)
                .buttonStyle(.borderedProminent)
            }.padding(.top, 6)

            if !transcript.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L.text(appLanguage, "Transcript:", "转写结果：")).font(.headline)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transcript, forType: .string)
                        } label: {
                            Label(L.text(appLanguage, "Copy", "复制"), systemImage: "doc.on.doc")
                        }
                    }
                    ScrollView {
                        Text(transcript)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .frame(maxHeight: 250)
                }
            }
        }
        .padding()
    }

    private func transcribe() {
        let whisperBin = FFmpegRunner.resolveBinary("whisper")
        let ffmpegBin = FFmpegRunner.resolveBinary("ffmpeg")
        let selectedModel = model
        let languageCode = language.trimmingCharacters(in: .whitespacesAndNewlines)

        if !FileManager.default.isExecutableFile(atPath: whisperBin) {
            runner.log = ""
            runner.status = L.text(appLanguage, "whisper not found", "找不到 whisper")
            runner.log = L.text(
                appLanguage,
                "⚠️  Could not find a bundled whisper.cpp CLI.\n\nExpected one of these inside the app bundle or project Resources:\n  Resources/bin/whisper-cli\n  Resources/bin/whisper\n",
                "⚠️  找不到内置的 whisper.cpp 命令行工具。\n\n应用包或项目 Resources 中需要包含：\n  Resources/bin/whisper-cli\n  Resources/bin/whisper\n"
            )
            return
        }
        if !FileManager.default.isExecutableFile(atPath: ffmpegBin) {
            runner.log = ""
            runner.status = L.text(appLanguage, "ffmpeg not found", "找不到 ffmpeg")
            runner.log = L.text(
                appLanguage,
                "⚠️  Could not find ffmpeg.\n\nBundle it at Resources/bin/ffmpeg or install it system-wide.",
                "⚠️  找不到 ffmpeg。\n\n请将它打包到 Resources/bin/ffmpeg，或在系统中安装。"
            )
            return
        }
        guard let modelPath = FFmpegRunner.resolveWhisperModel(selectedModel) else {
            runner.log = ""
            runner.status = L.text(appLanguage, "model not found", "找不到模型")
            runner.log = L.text(
                appLanguage,
                "⚠️  Could not find the selected whisper.cpp model.\n\nClick Download Model first. Models are saved to:\n  \(WhisperModelCatalog.modelDirectoryDisplayPath)\n",
                "⚠️  找不到所选的 whisper.cpp 模型。\n\n请先点击下载模型。模型会保存到：\n  \(WhisperModelCatalog.modelDirectoryDisplayPath)\n"
            )
            return
        }

        isTranscribing = true
        transcript = ""
        runner.progress = 0
        runner.log = ""
        runner.status = L.text(appLanguage, "Preparing audio…", "正在准备音频…")
        runner.isRunning = true

        let tmpDir = NSTemporaryDirectory() + "simple-video-whisper-\(ProcessInfo.processInfo.globallyUniqueString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        let wavPath = (tmpDir as NSString).appendingPathComponent("input.wav")
        let outputPrefix = (tmpDir as NSString).appendingPathComponent("transcript")

        runLoggedProcess(
            executable: ffmpegBin,
            arguments: [
                "-hide_banner", "-loglevel", "info", "-y",
                "-i", inputPath,
                "-map", "0:a:0?",
                "-vn",
                "-ac", "1",
                "-ar", "16000",
                "-c:a", "pcm_s16le",
                wavPath
            ],
            launchFailureStatus: L.text(appLanguage, "Failed to launch ffmpeg", "启动 ffmpeg 失败"),
            cleanupPath: tmpDir
        ) { status in
            guard status == 0 else {
                finishTranscription(tmpDir: tmpDir, status: L.text(appLanguage, "ffmpeg exited with code \(status)", "ffmpeg 退出，代码 \(status)"))
                return
            }

            runner.progress = 0.2
            runner.status = L.text(appLanguage, "Transcribing…", "正在转写…")

            var args = ["-m", modelPath, "-f", wavPath, "-otxt", "-of", outputPrefix]
            args += ["-l", languageCode.isEmpty ? "auto" : languageCode]

            runLoggedProcess(
                executable: whisperBin,
                arguments: args,
                launchFailureStatus: L.text(appLanguage, "Failed to launch whisper.cpp", "启动 whisper.cpp 失败"),
                cleanupPath: tmpDir
            ) { whisperStatus in
                guard whisperStatus == 0 else {
                    finishTranscription(tmpDir: tmpDir, status: L.text(appLanguage, "whisper.cpp exited with code \(whisperStatus)", "whisper.cpp 退出，代码 \(whisperStatus)"))
                    return
                }

                let txtPath = outputPrefix + ".txt"
                if let content = try? String(contentsOfFile: txtPath, encoding: .utf8) {
                    transcript = content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                finishTranscription(tmpDir: tmpDir, status: L.text(appLanguage, "Done ✓", "完成 ✓"), progress: 1.0)
            }
        }
    }

    private func runLoggedProcess(
        executable: String,
        arguments: [String],
        launchFailureStatus: String,
        cleanupPath: String,
        onExit: @escaping @MainActor (Int32) -> Void
    ) {
        runner.log += "$ \(executable) \(arguments.joined(separator: " "))\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stderr = Pipe()
        let stdout = Pipe()
        process.standardError = stderr
        process.standardOutput = stdout

        let append: @MainActor (Data) -> Void = { data in
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            runner.log += text
        }

        let stderrHandle = stderr.fileHandleForReading
        stderrHandle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { return }
            Task { @MainActor in append(data) }
        }

        let stdoutHandle = stdout.fileHandleForReading
        stdoutHandle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { return }
            Task { @MainActor in append(data) }
        }

        process.terminationHandler = { proc in
            FFmpegRunner.untrackProcess(proc)
            stderrHandle.readabilityHandler = nil
            stdoutHandle.readabilityHandler = nil
            let tailErr = stderrHandle.readDataToEndOfFile()
            let tailOut = stdoutHandle.readDataToEndOfFile()

            Task { @MainActor in
                append(tailErr)
                append(tailOut)
                runner.clearAttachedProcess(proc)
                onExit(proc.terminationStatus)
            }
        }

        do {
            try process.run()
            FFmpegRunner.trackProcess(process)
            runner.attachProcess(process)
        } catch {
            runner.log += "ERROR: \(error.localizedDescription)\n"
            finishTranscription(tmpDir: cleanupPath, status: launchFailureStatus)
        }
    }

    private func finishTranscription(tmpDir: String, status: String, progress: Double = 0) {
        runner.progress = progress
        runner.status = status
        runner.isRunning = false
        runner.clearAttachedProcess()
        isTranscribing = false
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func downloadSelectedModel() {
        let info = selectedModel
        isDownloadingModel = true
        downloadProgress = 0
        runner.log = L.text(appLanguage,
                            "Downloading \(info.displayName) model from:\n\(info.downloadURL.absoluteString)\n",
                            "正在从以下地址下载 \(modelDisplayName(info)) 模型：\n\(info.downloadURL.absoluteString)\n")
        runner.status = L.text(appLanguage, "Downloading \(info.displayName) model…", "正在下载 \(modelDisplayName(info)) 模型…")
        runner.progress = 0

        Task {
            do {
                let destination = try WhisperModelCatalog.downloadedModelURL(for: info)
                let temporaryURL = try await downloadFile(from: info.downloadURL) { progress in
                    downloadProgress = progress
                    runner.progress = progress
                    runner.status = L.text(appLanguage,
                                           "Downloading \(info.displayName) model \(Int(progress * 100))%",
                                           "正在下载 \(modelDisplayName(info)) 模型 \(Int(progress * 100))%")
                }

                let fm = FileManager.default
                do {
                    _ = try fm.replaceItemAt(destination, withItemAt: temporaryURL, backupItemName: nil, options: [])
                } catch {
                    guard !fm.fileExists(atPath: destination.path) else { throw error }
                    try fm.moveItem(at: temporaryURL, to: destination)
                }

                modelStatusVersion += 1
                downloadProgress = 1
                runner.progress = 1
                runner.status = L.text(appLanguage, "Model downloaded ✓", "模型已下载 ✓")
                runner.log += L.text(appLanguage, "Saved model to:\n\(destination.path)\n", "模型已保存到：\n\(destination.path)\n")
            } catch {
                runner.status = L.text(appLanguage, "Model download failed", "模型下载失败")
                runner.log += "ERROR: \(error.localizedDescription)\n"
            }
            isDownloadingModel = false
        }
    }

    private func deleteSelectedModel() {
        let info = selectedModel
        let urls = selectedDownloadedModelURLs
        guard !urls.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = L.text(appLanguage, "Delete \(info.displayName) model?", "删除 \(modelDisplayName(info)) 模型？")
        alert.informativeText = L.text(
            appLanguage,
            "This removes the downloaded model from:\n\(WhisperModelCatalog.modelDirectoryDisplayPath)\n\nYou can download it again later.",
            "这会从以下位置移除已下载的模型：\n\(WhisperModelCatalog.modelDirectoryDisplayPath)\n\n之后可以重新下载。"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L.text(appLanguage, "Delete", "删除"))
        alert.addButton(withTitle: L.text(appLanguage, "Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            for url in urls {
                try FileManager.default.removeItem(at: url)
            }
            modelStatusVersion += 1
            runner.progress = 0
            runner.status = L.text(appLanguage, "Model deleted", "模型已删除")
            runner.log = L.text(appLanguage, "Deleted \(info.displayName) model:\n", "已删除 \(modelDisplayName(info)) 模型：\n") +
                urls.map { $0.path }.joined(separator: "\n") + "\n"
        } catch {
            runner.status = L.text(appLanguage, "Model delete failed", "模型删除失败")
            runner.log = "ERROR: \(error.localizedDescription)\n"
        }
    }

    private func downloadFile(
        from url: URL,
        progressHandler: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        final class DownloadBox {
            var delegate: ModelDownloadDelegate?
            var session: URLSession?
            var task: URLSessionDownloadTask?
        }

        let box = DownloadBox()
        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let delegate = ModelDownloadDelegate(
                progressHandler: progressHandler,
                completion: { result in
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(with: result)
                    box.delegate = nil
                    box.session = nil
                    box.task = nil
                }
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            box.delegate = delegate
            box.session = session
            box.task = task
            task.resume()
        }
    }
}
