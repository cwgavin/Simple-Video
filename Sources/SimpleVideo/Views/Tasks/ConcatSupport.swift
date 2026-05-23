import SwiftUI

enum ConcatSortOrder: String, CaseIterable, Identifiable {
    case manual
    case nameAscending
    case nameDescending
    case createdAscending
    case createdDescending
    case modifiedAscending
    case modifiedDescending

    var id: Self { self }

    func title(language: AppLanguage) -> String {
        switch self {
        case .manual:
            return L.text(language, "Manual", "手动")
        case .nameAscending:
            return L.text(language, "Name (A → Z)", "名称（A → Z）")
        case .nameDescending:
            return L.text(language, "Name (Z → A)", "名称（Z → A）")
        case .createdAscending:
            return L.text(language, "Created (Oldest First)", "创建时间（从旧到新）")
        case .createdDescending:
            return L.text(language, "Created (Newest First)", "创建时间（从新到旧）")
        case .modifiedAscending:
            return L.text(language, "Modified (Oldest First)", "修改时间（从旧到新）")
        case .modifiedDescending:
            return L.text(language, "Modified (Newest First)", "修改时间（从新到旧）")
        }
    }
}

final class ConcatSession: ObservableObject {
    @Published var mediaType = "video"
    @Published var files: [String] = []
    @Published var sortOrder: ConcatSortOrder = .manual
    @Published var completedOutput = ""
}
