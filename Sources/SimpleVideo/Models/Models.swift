import Foundation

// MARK: - Task model

enum FFTask: String, CaseIterable, Identifiable, Hashable {
    case crop = "Crop Video"
    case cropAudio = "Crop Audio"
    case mergeAV = "Merge A/V"
    case concat = "Concatenate"
    case split = "Split by Timestamps"
    case cutRange = "Remove Time Range"
    case convert = "Convert"
    case transcribe = "Transcribe"
    case settings = "Settings"

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch language {
        case .english:
            return rawValue
        case .simplifiedChinese:
            switch self {
            case .cropAudio:   return "裁剪音频"
            case .mergeAV:      return "合并音视频"
            case .concat:       return "拼接文件"
            case .split:        return "按时间戳分割"
            case .cutRange:     return "移除时间段"
            case .crop:         return "裁剪视频"
            case .convert:      return "转换格式"
            case .transcribe:   return "语音转文字"
            case .settings:     return "设置"
            }
        }
    }

    var icon: String {
        switch self {
        case .cropAudio:     return "waveform"
        case .mergeAV:       return "plus.square.on.square"
        case .concat:        return "text.line.first.and.arrowtriangle.forward"
        case .split:         return "scissors"
        case .cutRange:      return "timeline.selection"
        case .crop:          return "crop"
        case .convert:       return "arrow.triangle.2.circlepath"
        case .transcribe:    return "text.bubble"
        case .settings:      return "gearshape"
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .english
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

enum AppStorageKey {
    static let showLogPanel = "showLogPanel"
    static let iconOnlyButtons = "iconOnlyButtons"
}

enum L {
    static func text(_ language: AppLanguage, _ english: String, _ simplifiedChinese: String) -> String {
        switch language {
        case .english: return english
        case .simplifiedChinese: return simplifiedChinese
        }
    }

    static func selectTask(_ language: AppLanguage) -> String {
        switch language {
        case .english: return "Select a task"
        case .simplifiedChinese: return "选择一个功能"
        }
    }

    static func cancel(_ language: AppLanguage) -> String {
        switch language {
        case .english: return "Cancel"
        case .simplifiedChinese: return "取消"
        }
    }

    static func clearLog(_ language: AppLanguage) -> String {
        switch language {
        case .english: return "Clear log"
        case .simplifiedChinese: return "清空日志"
        }
    }

    static func logPlaceholder(_ language: AppLanguage) -> String {
        switch language {
        case .english: return "ffmpeg output will appear here…"
        case .simplifiedChinese: return "ffmpeg 输出会显示在这里…"
        }
    }

    static func fileCount(_ language: AppLanguage, _ count: Int) -> String {
        switch language {
        case .english: return "\(count) file\(count == 1 ? "" : "s") added"
        case .simplifiedChinese: return "已添加 \(count) 个文件"
        }
    }
}
