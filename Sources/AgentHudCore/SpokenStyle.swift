import Foundation

/// Marks a message that was sent by voice, so that the Assistant answers for the ear. The marker travels with the
/// message to the CLI and comes back in its transcript, but it is never shown: every place that displays a user
/// message passes the text through `display`.
public enum SpokenStyle {
    /// The one definition of the marker: a line prefix, including the space after it.
    public static let marker = "[spoken] "

    /// The text as the CLI receives it.
    public static func mark(_ text: String) -> String { marker + text }

    /// The text as the person sees it: without the marker, if it has one.
    public static func display(_ text: String) -> String {
        let word = marker.trimmingCharacters(in: .whitespaces)
        let lead = text.drop(while: { $0 == " " || $0 == "\t" })
        guard lead.hasPrefix(word) else { return text }
        let after = lead.dropFirst(word.count)
        // Only a marker followed by a space, a line break or the end of the text counts: "[spokenly]" is a word.
        guard after.isEmpty || after.first!.isWhitespace else { return text }
        return String(after.drop(while: { $0 == " " || $0 == "\t" }))
    }

    public static func isMarked(_ text: String) -> Bool { display(text) != text }
}
