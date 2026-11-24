import AgentHudCore
import SwiftUI

/// What the command bar shows for voice. The real bar gets it from `VoiceController`; the render check sets it directly.
enum VoiceBarState: Equatable {
    case none
    /// The key is held and the microphone is open: a meter and what has been heard so far.
    case listening(level: Float, partial: String)
    /// The key is released; the final text is on its way.
    case finishing(partial: String)
    /// The heard text is in the field and goes out when the countdown ends.
    case countdown
    /// Listening was refused because these permissions are not granted.
    case missing([PermissionKind])

    /// The listening row takes the place of the text field.
    var showsListening: Bool {
        switch self {
        case .listening, .finishing: return true
        default: return false
        }
    }

    var partial: String {
        switch self {
        case .listening(_, let p), .finishing(let p): return p
        default: return ""
        }
    }

    var level: Float {
        if case .listening(let l, _) = self { return l }
        return 0
    }
}

/// A row of small bars that light up with the input level.
struct LevelMeter: View {
    let level: Float
    private static let bars = 18

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.bars, id: \.self) { i in
                let lit = level > 0 && Float(i + 1) / Float(Self.bars) <= level + 0.5 / Float(Self.bars)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(lit ? Brand.accent : Brand.line)
                    .frame(width: 5, height: 5 + CGFloat(i) * 0.6)
            }
        }
        .frame(height: 16, alignment: .bottom)
        .accessibilityLabel("Input level")
    }
}

/// In place of the text field while the microphone is open: the glyph, the meter and the partial transcript.
struct ListeningField: View {
    let state: VoiceBarState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.system(size: 13)).foregroundStyle(Brand.accent)
                LevelMeter(level: state.level)
            }
            .frame(height: 26, alignment: .leading)
            Text(state.partial.isEmpty ? VoiceText.listeningPlaceholder : state.partial)
                .font(Brand.body(16))
                .foregroundStyle(state.partial.isEmpty ? Brand.inkSubtle : Brand.ink)
                .lineLimit(1...4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings section

/// The "Voice" section of the control panel. Takes plain bindings so that the render check can draw it
/// without touching the saved settings.
struct VoiceSettingsSection: View {
    let index: Int
    @Binding var enabled: Bool
    @Binding var language: String
    @Binding var sendAfterSpeaking: Bool
    @Binding var speakReplies: Bool
    @Binding var allowServer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: index, title: "Voice")
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    BrandToggleRow(title: "Voice", hint: "Hold the command bar hotkey and speak", isOn: $enabled)
                        .padding(.top, 6)
                    if enabled {
                        Divider().overlay(Brand.line)
                        HStack(alignment: .center, spacing: 8) {
                            Text("Language").font(Brand.body(13)).foregroundStyle(Brand.ink)
                            Spacer(minLength: 8)
                            Picker("", selection: $language) {
                                ForEach(VoiceLanguages.all) { Text($0.label).tag($0.code) }
                            }
                            .pickerStyle(.menu).labelsHidden().fixedSize()
                        }
                        BrandToggleRow(title: "Send after speaking", hint: "Goes out 1.5 s after you let go; Esc cancels",
                                       isOn: $sendAfterSpeaking)
                        BrandToggleRow(title: "Speak replies", hint: "A short spoken answer from the Assistant", isOn: $speakReplies)
                        BrandToggleRow(title: "Allow recognition through Apple's servers",
                                       hint: "Only for a language without on-device recognition", isOn: $allowServer)
                        if allowServer {
                            Label(VoiceText.serverNote, systemImage: "exclamationmark.triangle.fill")
                                .font(Brand.body(11, .medium)).foregroundStyle(Brand.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider().overlay(Brand.line).padding(.top, 2)
                    Label(VoiceText.microphoneStatement, systemImage: "mic")
                        .font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
            }
        }
    }
}
