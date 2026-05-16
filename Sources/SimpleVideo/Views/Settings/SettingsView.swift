import SwiftUI

struct SettingsView: View {
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @AppStorage(AppStorageKey.showLogPanel) private var showLogPanel = false

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    private func licenseLink(_ title: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.up.right.square")
                    .imageScale(.small)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(language == .english ? "Settings" : "设置")
                .font(.largeTitle)
                .fontWeight(.semibold)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(language == .english ? "Language:" : "语言：")
                            .frame(width: formLabelWidth, alignment: .trailing)
                        Picker("", selection: $appLanguageRaw) {
                            ForEach(AppLanguage.allCases) { option in
                                Text(option.displayName).tag(option.rawValue)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    HStack(alignment: .top) {
                        Text(language == .english ? "Log panel:" : "日志面板：")
                            .frame(width: formLabelWidth, alignment: .trailing)
                        Toggle("", isOn: $showLogPanel)
                            .toggleStyle(.switch)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } label: {
                Label(language == .english ? "General" : "通用", systemImage: "gearshape")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Simple Video")
                        .font(.headline)
                    Text("© 2026 Gavin Cheng. All rights reserved.")
                    Text(language == .english
                         ? "Powered by FFmpeg and whisper.cpp."
                         : "由 FFmpeg 和 whisper.cpp 提供支持。")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } label: {
                Label(language == .english ? "Copyright" : "版权信息", systemImage: "info.circle")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(language == .english
                         ? "This app bundles and runs third-party command-line tools. They remain under their own licenses."
                         : "本应用打包并调用第三方命令行工具。这些组件仍遵循其各自的许可证。")
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        licenseLink("FFmpeg", "https://ffmpeg.org/")
                        licenseLink(language == .english ? "FFmpeg legal / license information" : "FFmpeg 法律与许可信息",
                                    "https://ffmpeg.org/legal.html")
                        licenseLink(language == .english ? "FFmpeg source code" : "FFmpeg 源代码",
                                    "https://ffmpeg.org/download.html")
                        licenseLink("whisper.cpp (MIT)", "https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE")
                        licenseLink(language == .english ? "Whisper model files" : "Whisper 模型文件",
                                    "https://huggingface.co/ggerganov/whisper.cpp")
                        licenseLink(language == .english ? "OpenAI Whisper license" : "OpenAI Whisper 许可证",
                                    "https://github.com/openai/whisper/blob/main/LICENSE")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } label: {
                Label(language == .english ? "Third-party Licenses" : "第三方许可", systemImage: "doc.text")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}
