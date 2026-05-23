import SwiftUI

// MARK: - Main view

struct ContentView: View {
    @ObservedObject var runner: FFmpegRunner
    @StateObject private var concatSession = ConcatSession()
    let cropSession: CropVideoSession
    let cropAudioSession: CropAudioSession
    @State private var selection: FFTask? = .crop
    @State private var isLogPanelExpanded = false
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @AppStorage(AppStorageKey.showLogPanel) private var showLogPanel = false

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    @ViewBuilder
    private func detail(for task: FFTask, isActive: Bool = true) -> some View {
        switch task {
        case .crop:         CropVideoView(isActive: isActive, presentation: .embedded)
        case .cropAudio:    CropAudioView(isActive: isActive)
        case .mergeAV:      MergeAVView()
        case .concat:       ConcatView(session: concatSession)
        case .split:        SplitByTimestampsView()
        case .convert:      ConvertView()
        case .transcribe:   TranscribeView()
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
                            ScrollView {
                                detail(for: sel, isActive: sel != .crop || !cropSession.isShowingStandaloneEditor)
                                    .frame(minHeight: geo.size.height)
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
                .environmentObject(cropSession)
                .environmentObject(cropAudioSession)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    if runner.isRunning {
                        ProgressView(value: runner.progress)
                    }
                    
                    HStack {
                        Text(runner.status).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        if runner.isRunning {
                            Button(L.cancel(appLanguage), role: .destructive) { runner.cancel() }
                                .pointingHandCursor()
                        }
                        if showLogPanel {
                            Button {
                                isLogPanelExpanded.toggle()
                            } label: {
                                IconButtonLabel(
                                    isLogPanelExpanded
                                    ? L.text(appLanguage, "Hide log", "隐藏日志")
                                    : L.text(appLanguage, "Show log", "显示日志"),
                                    systemImage: isLogPanelExpanded ? "chevron.down" : "chevron.up"
                                )
                            }
                                .pointingHandCursor()
                        }
                        if showLogPanel && isLogPanelExpanded {
                            Button {
                                runner.log = ""
                                runner.progress = 0
                                runner.status = L.text(appLanguage, "Idle", "空闲")
                            } label: {
                                IconButtonLabel(L.clearLog(appLanguage), systemImage: "trash")
                            }
                                .disabled(runner.log.isEmpty)
                                .pointingHandCursor()
                        }
                    }
                    
                    if showLogPanel && isLogPanelExpanded {
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
                .animation(.easeInOut(duration: 0.2), value: runner.isRunning)
                .onChange(of: showLogPanel) { _, _ in
                    isLogPanelExpanded = false
                }
            }
        }
    }
}
