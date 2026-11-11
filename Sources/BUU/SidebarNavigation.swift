import Foundation

enum SidebarMode: String, CaseIterable, Identifiable, Sendable {
    case chats
    case agentic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .agentic: return "Agentic"
        }
    }
}


