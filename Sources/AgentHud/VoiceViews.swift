import AgentHudCore
import AppKit
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

/// Where the system lets the person download better voices. The pane's anchor is not documented; when the
/// anchored address is refused the Accessibility pane opens instead, and the help text says where to go next.
enum SpokenContentSettings {
    static let addresses = [
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.universalaccess",
    ]

    @MainActor
    static func open() {
        for a in addresses {
            if let url = URL(string: a), NSWorkspace.shared.open(url) { return }
        }
    }
}

/// "Voice" picker and Preview button for one language.
struct VoicePickerRow: View {
    let language: VoiceLanguage
    let title: String
    let voices: [VoiceInfo]
    @Binding var voiceId: String
    let preview: (VoiceLanguage) -> Void

    private var listed: [VoiceInfo] { VoiceChoice.list(from: voices, language: language.code) }

    private var automaticLabel: String {
        guard let auto = VoiceChoice.pick(from: voices, language: language.code, preferredId: nil) else { return "Automatic" }
        return "Automatic \u{2014} \(auto.name)"
    }

    /// A stored voice that is no longer installed shows as Automatic, which is also what is spoken then.
    private var selection: Binding<String> {
        Binding(get: { listed.contains { $0.id == voiceId } ? voiceId : "" }, set: { voiceId = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(title).font(Brand.body(13)).foregroundStyle(Brand.ink)
                Spacer(minLength: 4)
                Button("Preview") { preview(language) }
                    .controlSize(.small).fixedSize()
            }
            Picker("", selection: selection) {
                Text(automaticLabel).tag("")
                ForEach(listed) { Text("\($0.label) (\($0.language))").tag($0.id) }
            }
            .pickerStyle(.menu).labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(title)
        }
    }
}

/// "Voice" picker and Preview button for one language, listing the neural model's speakers.
struct NeuralSpeakerRow: View {
    let language: VoiceLanguage
    let title: String
    @Binding var speaker: Int
    let preview: (VoiceLanguage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(title).font(Brand.body(13)).foregroundStyle(Brand.ink)
                Spacer(minLength: 4)
                Button("Preview") { preview(language) }
                    .controlSize(.small).fixedSize()
            }
            Picker("", selection: $speaker) {
                ForEach(NeuralVoice.speakers) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu).labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(title)
        }
    }
}

/// Slow / normal / fast under a slider; the ticks sit where those speeds are on the slider.
struct VoiceRateRow: View {
    @Binding var rate: Double

    private static let thumb: CGFloat = 16
    private static let marks: [(label: String, value: Double)] = [
        ("Slow", VoiceRate.minMultiplier), ("Normal", VoiceRate.defaultMultiplier), ("Fast", VoiceRate.maxMultiplier),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Speaking speed").font(Brand.body(13)).foregroundStyle(Brand.ink)
                Spacer()
                Text(String(format: "%.2g\u{00D7}", rate)).font(Brand.mono(11)).foregroundStyle(Brand.inkSubtle)
            }
            Slider(value: $rate, in: VoiceRate.minMultiplier...VoiceRate.maxMultiplier, step: 0.05)
                .labelsHidden().controlSize(.small)
                .accessibilityLabel("Speaking speed")
            GeometryReader { geo in
                let span = VoiceRate.maxMultiplier - VoiceRate.minMultiplier
                let track = max(1, geo.size.width - Self.thumb)
                ZStack(alignment: .topLeading) {
                    ForEach(Self.marks, id: \.label) { mark in
                        let x = Self.thumb / 2 + track * CGFloat((mark.value - VoiceRate.minMultiplier) / span)
                        VStack(spacing: 1) {
                            Rectangle().fill(Brand.line).frame(width: 1, height: 4)
                            Text(mark.label).font(Brand.body(10)).foregroundStyle(Brand.inkSubtle).fixedSize()
                        }
                        .position(x: min(max(x, 14), geo.size.width - 14), y: 10)
                    }
                }
            }
            .frame(height: 22)
        }
    }
}

/// The "Voice" section of the control panel. Takes plain bindings so that the render check can draw it
/// without touching the saved settings.
struct VoiceSettingsSection: View {
    let index: Int
    @Binding var enabled: Bool
    @Binding var language: String
    @Binding var sendAfterSpeaking: Bool
    @Binding var speakReplies: Bool
    @Binding var allowServer: Bool
    /// The installed voices (empty until read) and the person's choice per language; empty id means automatic.
    var voices: [VoiceInfo] = []
    @Binding var voiceIdEnglish: String
    @Binding var voiceIdRussian: String
    @Binding var voiceRate: Double
    @Binding var engine: VoiceEngine
    /// Whether the neural voice is installed; it can be chosen only then.
    var neuralInstalled = false
    @Binding var neuralSpeakerEnglish: Int
    @Binding var neuralSpeakerRussian: Int
    var preview: (VoiceLanguage) -> Void = { _ in }
    var openSpokenContent: () -> Void = {}

    /// A stored neural choice shows as System while the neural voice is not installed, which is also what is spoken then.
    private var engineSelection: Binding<VoiceEngine> {
        Binding(get: { neuralInstalled ? engine : .system }, set: { engine = ($0 == .neural && !neuralInstalled) ? .system : $0 })
    }

    private var usesNeural: Bool { neuralInstalled && engine == .neural }

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
                        Divider().overlay(Brand.line)
                        HStack(alignment: .center, spacing: 8) {
                            Text("Voice engine").font(Brand.body(13)).foregroundStyle(Brand.ink)
                            Spacer(minLength: 8)
                            Picker("", selection: engineSelection) {
                                Text(VoiceEngine.system.label).tag(VoiceEngine.system)
                                Text(VoiceEngine.neural.label).tag(VoiceEngine.neural).disabled(!neuralInstalled)
                            }
                            .pickerStyle(.menu).labelsHidden().fixedSize()
                            .accessibilityLabel("Voice engine")
                        }
                        if !neuralInstalled {
                            Text("Install with scripts/get-neural-voice.sh")
                                .font(Brand.mono(11)).foregroundStyle(Brand.inkSubtle)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if usesNeural {
                            NeuralSpeakerRow(language: VoiceLanguages.info(code: "en-US"), title: "English voice",
                                             speaker: $neuralSpeakerEnglish, preview: preview)
                            NeuralSpeakerRow(language: VoiceLanguages.info(code: "ru-RU"), title: "Russian voice",
                                             speaker: $neuralSpeakerRussian, preview: preview)
                        } else {
                            VoicePickerRow(language: VoiceLanguages.info(code: "en-US"), title: "English voice", voices: voices,
                                           voiceId: $voiceIdEnglish, preview: preview)
                            VoicePickerRow(language: VoiceLanguages.info(code: "ru-RU"), title: "Russian voice", voices: voices,
                                           voiceId: $voiceIdRussian, preview: preview)
                        }
                        VoiceRateRow(rate: $voiceRate)
                        if !usesNeural {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("More natural voices can be downloaded in System Settings")
                                        .font(Brand.body(11)).foregroundStyle(Brand.inkMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("Spoken Content \u{203A} System Voice \u{203A} Manage Voices\u{2026}")
                                        .font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                                        .fixedSize(horizontal: false, vertical: true)
                                    GhostButton(title: "Open Spoken Content settings", symbol: "gearshape", action: openSpokenContent)
                                }
                            } icon: {
                                Image(systemName: "arrow.down.circle").font(.system(size: 11)).foregroundStyle(Brand.inkSubtle)
                        }
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
