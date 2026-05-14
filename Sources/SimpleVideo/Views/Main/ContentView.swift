import SwiftUI

// MARK: - Main view

struct ContentView: View {
    @StateObject private var runner = FFmpegRunner()
    @State private var selection: FFTask? = .crop
    @State private var isLogPanelExpanded = false
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    @ViewBuilder
    private func detail(for task: FFTask, isActive: Bool = true) -> some View {
        switch task {
        case .crop:         CropVideoView(isActive: isActive)
        case .mergeAV:      MergeAVView()
        case .concat:       ConcatView()
        case .split:        SplitByTimestampsView()
        case .convert:      ConvertView()
        case .convertAudio: ConvertAudioView()
        case .transcribe:   TranscribeView()
        case .cutRange:     CutRangeView()
        case .settings:     SettingsView()
        }
    }

    var body: some View {
        NavigationSplitView {
            List(FFTask.allCases, selection: $selection) { task in
                Label(task.title(language: appLanguage), systemImage: task.icon)
                    .tag(task)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .navigationTitle("Simple Video")
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if let sel = selection {
                        GeometryReader { geo in
                            ZStack(alignment: .topLeading) {
                                ForEach(FFTask.allCases) { task in
                                    ScrollView {
                                        detail(for: task, isActive: sel == task)
                                            .frame(minHeight: geo.size.height)
                                    }
                                    .opacity(sel == task ? 1 : 0)
                                    .allowsHitTesting(sel == task)
                                    .accessibilityHidden(sel != task)
                                    .zIndex(sel == task ? 1 : 0)
                                }
                            }
                        }
                    } else {
                        Text(L.selectTask(appLanguage))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .environmentObject(runner)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: runner.progress)
                    HStack {
                        Text(runner.status).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        if runner.isRunning {
                            Button(L.cancel(appLanguage), role: .destructive) { runner.cancel() }
                        }
                        Button {
                            isLogPanelExpanded.toggle()
                        } label: {
                            Label(
                                isLogPanelExpanded
                                ? L.text(appLanguage, "Hide log", "隐藏日志")
                                : L.text(appLanguage, "Show log", "显示日志"),
                                systemImage: isLogPanelExpanded ? "chevron.down" : "chevron.up"
                            )
                        }
                        if isLogPanelExpanded {
                            Button {
                                runner.log = ""
                                runner.progress = 0
                            } label: {
                                Label(L.clearLog(appLanguage), systemImage: "trash")
                            }
                                .disabled(runner.log.isEmpty)
                        }
                    }
                    if isLogPanelExpanded {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(runner.log.isEmpty ? L.logPlaceholder(appLanguage) : runner.log)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(runner.log.isEmpty ? .secondary : .green)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .id("logBottom")
                            }
                            .background(Color.black.opacity(0.85))
                            .cornerRadius(6)
                            .frame(height: 180)
                            .onChange(of: runner.log) { _, _ in
                                proxy.scrollTo("logBottom", anchor: .bottom)
                            }
                        }
                    }
                }
                .padding(10)
                .environmentObject(runner)
            }
        }
    }
}
