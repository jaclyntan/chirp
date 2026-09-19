import AppKit
import Speech
import SwiftUI

// MARK: - Pages

enum Page: Hashable {
    case home, notetaker, dictionary, snippets
    case settings, help, legal

    var label: String {
        switch self {
        case .home: return "Home"
        case .notetaker: return "Notes"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .settings: return "Settings"
        case .help: return "Help"
        case .legal: return "Legal"
        }
    }
}
