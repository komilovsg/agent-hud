import Foundation

/// Project names for the HUD: the full name and a short label under the agent icon.
/// When all sessions are one agent (identical icons), they have to be told apart by project.
public enum ProjectNames {
    /// Faceless folder names: for them we show the parent folder too ("hrm/front").
    static let generic: Set<String> = [
        "front", "frontend", "back", "backend", "app", "apps", "web", "client", "server", "src",
        "mobile", "api", "ui", "packages", "main", "admin", "site",
    ]

    public static func displayName(cwd: String) -> String {
        // An empty path would turn into the process's current folder as a URL.
        guard !cwd.isEmpty else { return "" }
        if AssistantSession.isAssistantFolder(cwd) { return AssistantSession.label }
        let url = URL(fileURLWithPath: cwd)
        let base = url.lastPathComponent
        guard !base.isEmpty, base != "/" else { return cwd }
        if generic.contains(base.lowercased()) {
            let parent = url.deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty, parent != "/" { return parent + "/" + base }
        }
        return base
    }

    static func tokens(_ name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Short labels for a set of projects. The first word shared by several projects ("acme-mobile-app",
    /// "acme-web-client") is dropped -> "mobile", "web"; collisions are refined with the next word
    /// ("hrm-front", "hrm-v2"). A project without "relatives" keeps its full name: "agent-hub", not "agent".
    /// It is better to pass a stable set (all known projects), then the labels do not change
    /// as sessions come and go.
    public static func shortLabels(for cwds: [String], maxLength: Int = 10) -> [String: String] {
        let unique = Array(Set(cwds.filter { !$0.isEmpty })).sorted()
        var names: [String: [String]] = [:]
        for c in unique {
            let t = tokens(displayName(cwd: c))
            names[c] = t.isEmpty ? [displayName(cwd: c).lowercased()] : t
        }
        var firstCount: [String: Int] = [:]
        for t in names.values where t.count > 1 { firstCount[t[0], default: 0] += 1 }
        var parts: [String: [String]] = [:]
        var taken: [String: Int] = [:]
        for c in unique {
            let t = names[c]!
            if t.count > 1, firstCount[t[0], default: 0] >= 2 {
                parts[c] = Array(t.dropFirst())
                taken[c] = 1
            } else {
                parts[c] = t
                taken[c] = t.count
            }
        }
        func label(_ c: String) -> String { parts[c]!.prefix(taken[c]!).joined(separator: "-") }
        // Refine while there are collisions and something to refine with. Colliding ones are refined at the same time,
        // otherwise the first label would move ahead and the second would stay short.
        for _ in 0..<4 {
            var current: [String: String] = [:]
            for c in unique { current[c] = label(c) }
            let clashing = unique.filter { c in
                unique.contains { $0 != c && current[$0] == current[c] } && taken[c]! < parts[c]!.count
            }
            if clashing.isEmpty { break }
            for c in clashing { taken[c]! += 1 }
        }
        return Dictionary(uniqueKeysWithValues: unique.map { ($0, clip(label($0), maxLength)) })
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    /// Stable hue of the project color (0...1) - the same in the HUD, the panel and on the map.
    public static func hue(cwd: String) -> Double {
        Double(stableHash("project:" + cwd) % 360) / 360
    }
}
