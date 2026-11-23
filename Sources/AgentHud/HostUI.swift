import AgentHudCore
import SwiftUI

/// Labels and icons depending on where the session runs: terminal, app or VS Code.
extension HostInfo {
    /// "in the terminal", "in the app", "in VS Code" - for phrases like "the agent is waiting for a reply ...".
    var placeIn: String {
        switch place {
        case .terminal: return isEditorTerminal ? "in the VS Code terminal" : "in the terminal"
        case .desktopApp: return "in the app"
        case .editor: return "in \(editorName)"
        }
    }

    /// "the terminal", "the app", "VS Code" - for "went to ...".
    var placeTo: String {
        switch place {
        case .terminal: return "the terminal"
        case .desktopApp: return "the app"
        case .editor: return editorName
        }
    }

    /// The "answer where the agent is running" button.
    var passthroughTitle: String {
        switch place {
        case .terminal: return "In terminal"
        case .desktopApp: return "In app"
        case .editor: return "In \(editorName)"
        }
    }

    var placeSymbol: String {
        switch place {
        case .terminal: return "terminal"
        case .desktopApp: return "macwindow"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var openTitle: String {
        switch place {
        case .terminal: return isEditorTerminal ? "Open in VS Code" : "Open in terminal"
        case .desktopApp: return "Open in app"
        case .editor: return "Open in VS Code"
        }
    }

    /// Whether the next prompt can be sent right from the HUD (via the VS Code extension link).
    var canPrefillPrompt: Bool { place == .editor }
}

/// Project color: the same in the HUD, the panel and the agent map.
enum ProjectColor {
    static func color(_ cwd: String, saturation: Double = 0.62, brightness: Double = 0.86) -> Color {
        Color(hue: ProjectNames.hue(cwd: cwd), saturation: saturation, brightness: brightness)
    }
}

/// Project label under the agent icon: a colored capsule with a short name.
struct ProjectChip: View {
    let cwd: String
    let label: String
    var size: CGFloat = 9

    var body: some View {
        Text(label)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(ProjectColor.color(cwd, saturation: 0.75, brightness: 0.45))
            .background(Capsule().fill(ProjectColor.color(cwd, saturation: 0.35, brightness: 1)))
            .overlay(Capsule().strokeBorder(ProjectColor.color(cwd).opacity(0.5), lineWidth: 0.5))
            .fixedSize()
    }
}

/// Project color dot.
struct ProjectDot: View {
    let cwd: String
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(ProjectColor.color(cwd)).frame(width: size, height: size)
    }
}
