import SwiftUI

extension View {
    /// 按需挂载工具栏搜索框（「位置」页使用自己的搜索框）。
    @ViewBuilder
    func searchableIf(_ condition: Bool, text: Binding<String>, prompt: String) -> some View {
        if condition {
            searchable(text: text, placement: .toolbar, prompt: prompt)
        } else {
            self
        }
    }
}

extension PhotoColorLabel {
    var color: Color {
        switch self {
        case .none: return .clear
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}

extension PhotoFlag {
    var color: Color {
        switch self {
        case .none: return .secondary
        case .pick: return .green
        case .reject: return .red
        }
    }
}
