import Foundation

/// Marks a message that was sent by voice, so that the Assistant answers for the ear. The marker travels with the
/// message to the CLI and comes back in its transcript, but it is never shown: every place that displays a user
/// message passes the text through `display`. It can carry the grammatical gender of the voice that will read
/// the answer: `[spoken f]` or `[spoken m]`.
public enum SpokenStyle {
    public enum Gender: Equatable, Sendable {
        case female, male

        var letter: String { self == .female ? "f" : "m" }
    }

    /// The plain marker: a line prefix, including the space after it.
    public static let marker = "[spoken] "

    /// The marker without its trailing space, for one gender or none.
    public static func tag(_ gender: Gender? = nil) -> String {
        guard let gender else { return marker.trimmingCharacters(in: .whitespaces) }
        return "[spoken \(gender.letter)]"
    }

    private static let tags = [tag(), tag(.female), tag(.male)]

    /// The text as the CLI receives it.
    public static func mark(_ text: String, gender: Gender? = nil) -> String { tag(gender) + " " + text }

    /// The text as the person sees it: without the marker, if it has one.
    public static func display(_ text: String) -> String {
        let lead = text.drop(while: { $0 == " " || $0 == "\t" })
        guard let word = tags.first(where: { lead.hasPrefix($0) }) else { return text }
        let after = lead.dropFirst(word.count)
        // Only a marker followed by a space, a line break or the end of the text counts: "[spokenly]" is a word.
        guard after.isEmpty || after.first!.isWhitespace else { return text }
        return String(after.drop(while: { $0 == " " || $0 == "\t" }))
    }

    public static func isMarked(_ text: String) -> Bool { display(text) != text }
}
