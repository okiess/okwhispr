import Foundation
import Combine

/// Persistent user settings, backed by UserDefaults.
/// A single shared instance is read and written by the app and the Settings UI.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let language = "sw.language"
        static let engine = "sw.engine"
        static let variant = "sw.cohereVariant"
        static let hotkey = "sw.hotkey"
        static let launchAtLogin = "sw.launchAtLogin"
        static let pasteAfter = "sw.pasteAfter"
        static let silenceGuardMs = "sw.silenceGuardMs"
    }

    // Defaults are applied lazily so the store stays usable before first launch.
    var language: String {
        get { defaults.string(forKey: Keys.language) ?? "de" }
        set { defaults.set(newValue, forKey: Keys.language); objectWillChange.send() }
    }

    var engine: TranscriptionEngine {
        get { TranscriptionEngine(rawValue: defaults.string(forKey: Keys.engine) ?? "cohere") ?? .cohere }
        set { defaults.set(newValue.rawValue, forKey: Keys.engine); objectWillChange.send() }
    }

    var variant: CohereVariant {
        get { CohereVariant(rawValue: defaults.string(forKey: Keys.variant) ?? "int5") ?? .int5 }
        set { defaults.set(newValue.rawValue, forKey: Keys.variant); objectWillChange.send() }
    }

    var hotkey: HotkeyOption {
        get { HotkeyOption(rawValue: defaults.string(forKey: Keys.hotkey) ?? "rightCommand") ?? .rightCommand }
        set { defaults.set(newValue.rawValue, forKey: Keys.hotkey); objectWillChange.send() }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            LoginItem.setEnabled(newValue)
            objectWillChange.send()
        }
    }

    /// When true, the transcript is pasted (⌘V) into the active field.
    /// When false, it is only placed on the pasteboard so the user can paste it.
    var pasteAfter: Bool {
        get { defaults.object(forKey: Keys.pasteAfter) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.pasteAfter); objectWillChange.send() }
    }

    /// Minimum recording length before we transcribe. Below this, the clip is
    /// treated as an accidental tap and discarded. In milliseconds.
    var silenceGuardMs: Int {
        get { defaults.object(forKey: Keys.silenceGuardMs) as? Int ?? 350 }
        set { defaults.set(newValue, forKey: Keys.silenceGuardMs); objectWillChange.send() }
    }
}
