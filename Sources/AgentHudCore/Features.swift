/// Switches for features that are built but not shipped.
public enum Features {
    /// Typing into an editor or terminal session is switched off: the editor extension opens a new chat for the
    /// session link instead of the running one, so the text never reaches the session. The code path is kept
    /// for a later rework.
    public static let typeIntoHost = false
}
