import Foundation

/// In-code localisation layer for OkWhispr's user-facing UI.
///
/// The project is a SwiftPM executable assembled into a `.app` by `build.sh`
/// with no Xcode project, so the standard `.lproj` / `.xcstrings` pipeline is
/// not available. Instead the UI reads its strings from `L`, which returns the
/// text for the current language.
///
/// Two languages exist: English (the default and the fallback) and German,
/// chosen automatically from the macOS system locale. Language is NOT a user
/// setting; it is resolved from the system. Change the system language and
/// relaunch to switch. The menu-bar menu is rebuilt on every open and SwiftUI
/// re-evaluates on relaunch, so both pick up the current language.
///
/// Developer-facing text (AppLogger logs, the CLI test mode) is intentionally
/// left in English and does not go through `L`.
enum UILanguage {
    case english
    case german

    /// German when the system language is German; English otherwise. English is
    /// both the default and the fallback, so any non-German system yields
    /// English.
    static var current: UILanguage {
        // The primary system language.
        if Locale.autoupdatingCurrent.language.languageCode?.identifier == "de" {
            return .german
        }
        // Scan the preferred list too: entries are BCP-47 tags on most OS
        // versions but display names on some, so check both forms.
        for preferred in Locale.preferredLanguages {
            let base = preferred.split(separator: "-").first.map(String.init) ?? ""
            if base == "de" || base.lowercased() == "deutsch" {
                return .german
            }
        }
        return .english
    }

    var code: String {
        switch self {
        case .german: return "de"
        case .english: return "en"
        }
    }
}

/// All user-facing UI strings, resolved for `UILanguage.current`.
///
/// Each accessor is a short `de(..., en: ...)` selection so the English text is
/// kept byte-identical to the original, unchanged strings. Interpolated keys
/// take their arguments (percent, language code, error, model name, ...).
enum L {
    /// Returns the German text when the current language is German, otherwise the
    /// English text.
    private static func de(_ german: String, en english: String) -> String {
        UILanguage.current == .german ? german : english
    }

    // MARK: - Menu-bar tooltip

    static var tooltipReady: String {
        de("OkWhispr: rechte ⌘ gedrückt halten zum Diktieren",
           en: "OkWhispr: hold right ⌘ to dictate")
    }
    static var tooltipPreparing: String {
        de("OkWhispr: lade Modell…",
           en: "OkWhispr: preparing model…")
    }
    static var tooltipListening: String {
        de("Höre zu… rechte ⌘ loslassen zum Transkribieren",
           en: "Listening… release right ⌘ to transcribe")
    }
    static var tooltipTranscribing: String {
        de("Transkribiere…", en: "Transcribing…")
    }

    // MARK: - Status line

    /// The warning glyph plus the (already localised) error text.
    static func statusError(_ error: String) -> String {
        "⚠︎ \(error)"
    }
    static var statusInputMonitoring: String {
        de("⚠︎ Eingabeüberwachung aktivieren (Kurzdruck reagiert nicht)",
           en: "⚠︎ Enable Input Monitoring (tap won't fire)")
    }
    static func statusReady(languageCode: String) -> String {
        let code = languageCode.uppercased()
        return de("Bereit · \(code)", en: "Ready · \(code)")
    }
    static func statusPreparing(percent: Double) -> String {
        let value = Int(percent.rounded())
        return de("Modell wird geladen… \(value) %",
                  en: "Preparing model… \(value) %")
    }
    static var statusListening: String {
        de("Höre zu…", en: "Listening…")
    }
    static var statusTranscribing: String {
        de("Transkribiere…", en: "Transcribing…")
    }

    // MARK: - Toggle menu item

    static var toggleStart: String {
        de("Diktat starten", en: "Start dictation")
    }
    static var toggleStop: String {
        de("Diktat beenden", en: "Stop dictation")
    }
    static var toggleWorking: String {
        de("Arbeitet…", en: "Working…")
    }

    // MARK: - Menu items

    static var menuSettings: String {
        de("Einstellungen…", en: "Settings…")
    }
    static var menuLaunchAtLogin: String {
        de("Beim Anmelden starten", en: "Launch at login")
    }
    static var menuResetPermissions: String {
        de("Berechtigungen zurücksetzen…", en: "Reset permissions…")
    }
    static var menuQuit: String {
        de("OkWhispr beenden", en: "Quit OkWhispr")
    }
    static var cancel: String {
        de("Abbrechen", en: "Cancel")
    }

    // MARK: - Settings tabs

    static var tabGeneral: String {
        de("Allgemein", en: "General")
    }
    static var tabModel: String {
        de("Modell", en: "Model")
    }
    static var tabPermissions: String {
        de("Berechtigungen", en: "Permissions")
    }

    // MARK: - Settings: general

    static var settingsLanguage: String {
        de("Sprache", en: "Language")
    }
    static var settingsLanguageHelp: String {
        de("Gesprochene Sprache in das Mikrofon. Das Modell muss sie unterstützen.",
           en: "Language spoken into the microphone. The model must support it.")
    }
    static var settingsPasteToggle: String {
        de("Ergebnis in das aktive Feld einfügen (⌘V)",
           en: "Paste the result into the active field (⌘V)")
    }
    static var settingsPasteHelp: String {
        de("Wenn aktiviert, wird das Transkript am Cursor eingefügt. Wenn deaktiviert, wird es nur in die Zwischenablage kopiert.",
           en: "When on, the transcript is pasted where your cursor is. When off, it is only copied to your clipboard.")
    }
    static var settingsMinTalkTime: String {
        de("Mindestsprechzeit", en: "Minimum talk time")
    }
    static func settingsMs(_ ms: Int) -> String {
        "\(ms) ms"
    }
    static var settingsMsNote: String {
        de("Kürzeres Drücken wird ignoriert",
           en: "Taps shorter than this are ignored")
    }
    static var settingsMinTalkHelp: String {
        de("Schützt vor versehentlichen Tastendrücken, die die Aufnahme starten und beenden.",
           en: "Guards against accidental key taps that start and stop recording.")
    }
    static var settingsShortcut: String {
        de("Tastenkürzel", en: "Shortcut")
    }
    static var settingsHold: String {
        de("Halte", en: "Hold")
    }
    static var settingsRight: String {
        de("rechts", en: "right")
    }
    static var settingsSpeakRelease: String {
        de("und sprich, dann loslassen zum Transkribieren.",
           en: "and speak, then release to transcribe.")
    }

    // MARK: - Settings: model

    static var settingsEngine: String {
        de("Engine", en: "Engine")
    }
    static var settingsEngineHelp: String {
        de("Cohere Transcribe 2B ist ein lokales 2B-Parameter-Modell. Apple On-Device nutzt das Spracherkennungsmodell von macOS (ab macOS 26) und benötigt keinen App-Download.",
           en: "Cohere Transcribe 2B is a local 2B-parameter model. Apple On-Device uses the macOS speech model (macOS 26+) and needs no app download.")
    }
    static var settingsPrecision: String {
        de("Präzision", en: "Precision")
    }
    static var settingsPrecisionHelp: String {
        de("Höhere Präzision = bessere Qualität, aber mehr Speicher und Download-Größe.",
           en: "Higher precision = better quality but more memory and download size.")
    }
    static var settingsModelStatus: String {
        de("Modellstatus", en: "Model status")
    }
    static var settingsReload: String {
        de("Neu laden", en: "Reload")
    }
    static func statusLoading(name: String) -> String {
        de("Lade \(name)…", en: "Loading \(name)…")
    }
    static var statusReadyShort: String {
        de("Bereit", en: "Ready")
    }
    static var statusNotLoaded: String {
        de("Noch nicht geladen", en: "Not loaded yet")
    }
    static var settingsStorageLocation: String {
        de("Speicherort", en: "Storage location")
    }
    static var settingsStorageLocationHelp: String {
        de("Wo die Modell-Dateien auf der Festplatte abgelegt sind.",
           en: "Where the model files are stored on disk.")
    }
    static var settingsRevealInFinder: String {
        de("In Finder anzeigen", en: "Reveal in Finder")
    }
    static var settingsDownloadedModels: String {
        de("Heruntergeladene Modelle", en: "Downloaded models")
    }
    static var settingsNoModelsYet: String {
        de("Noch keine Modelle heruntergeladen.", en: "No models downloaded yet.")
    }
    static var settingsDelete: String {
        de("Löschen", en: "Delete")
    }
    static var settingsDeleteAll: String {
        de("Alle löschen", en: "Delete all")
    }
    static var confirmDeleteModelTitle: String {
        de("Modell löschen?", en: "Delete model?")
    }
    static func confirmDeleteModelMessage(name: String) -> String {
        de("\(name) wird in den Papierkorb verschoben und beim nächsten Gebrauch erneut heruntergeladen.",
           en: "\(name) is moved to the Trash and re-downloaded on next use.")
    }
    static var confirmDeleteAllTitle: String {
        de("Alle Modelle löschen?", en: "Delete all models?")
    }
    static var confirmDeleteAllMessage: String {
        de("Alle heruntergeladenen Modelle werden in den Papierkorb verschoben und beim nächsten Gebrauch erneut heruntergeladen.",
           en: "All downloaded models are moved to the Trash and re-downloaded on next use.")
    }
    static func errModelDelete(_ error: String) -> String {
        de("Modell konnte nicht gelöscht werden: \(error)",
           en: "Could not delete model: \(error)")
    }

    // MARK: - Settings: permissions

    static var permMic: String {
        de("Mikrofon", en: "Microphone")
    }
    static var permMicHelp: String {
        de("Erforderlich, um deine Sprache aufzunehmen.",
           en: "Required to record your speech.")
    }
    static var permAccessibility: String {
        de("Zugänglichkeit", en: "Accessibility")
    }
    static var permAccessibilityHelp: String {
        de("Erforderlich, damit das Transkript (⌘V) in die genutzte App eingegeben werden kann.",
           en: "Required so the transcript can be typed (⌘V) into the app you are using.")
    }
    static var permInputMonitoring: String {
        de("Eingabeüberwachung", en: "Input Monitoring")
    }
    static var permInputMonitoringHelp: String {
        de("Erforderlich für das globale Tastenkürzel. Ohne sie erhält der rechte-⌘-Druck keine Tasten und das Diktat-Kürzel reagiert nicht. Wenn sie aktiv angezeigt wird, der Druck aber trotzdem nicht reagiert, ist sie möglicherweise an eine frühere App-Signatur gebunden. Nutze unten „Zurücksetzen & erneut anfordern“.",
           en: "Required for the global hotkey. Without it the right-⌘ tap gets no keys and the dictation hotkey does not fire. If it shows on but the tap still does not fire, it may be tied to a previous app signature. Use \"Reset & re-request\" below.")
    }
    static var permStillNotWorking: String {
        de("Noch nicht funktionierend?", en: "Still not working?")
    }
    static var permStaleExplanation: String {
        de("Nach einer Signaturänderung können Berechtigungen veralten. Zurücksetzen entfernt sie, damit du sie für den aktuellen Build neu vergeben kannst.",
           en: "After a signing change the permissions can become stale. Reset clears them so you can re-grant to the current build.")
    }
    static var permResetReRequest: String {
        de("Zurücksetzen & erneut anfordern", en: "Reset & re-request")
    }
    static var permGranted: String {
        de("Zugelassen", en: "Granted")
    }
    static var permGrant: String {
        de("Erlauben…", en: "Grant…")
    }

    // MARK: - Engine / variant / hotkey display names

    static func engineName(_ engine: TranscriptionEngine) -> String {
        switch engine {
        case .cohere:
            return de("Cohere Transcribe 2B (MLX, lokal)",
                      en: "Cohere Transcribe 2B (MLX, local)")
        case .apple:
            return de("Apple On-Device (macOS-Systemmodell)", en: "Apple On-Device (macOS system model)")
        }
    }
    static func variantName(_ variant: CohereVariant) -> String {
        switch variant {
        case .fp16:
            return de("FP16 (am Größten, ~3,8 GB)",
                      en: "FP16 (largest, ~3.8 GB)")
        case .int5:
            return de("INT5 (Standard, ~1,6 GB, empfohlen)",
                      en: "INT5 (default, ~1.6 GB, recommended)")
        case .int8:
            return de("INT8 (~2,2 GB, höchste Qualität)",
                      en: "INT8 (~2.2 GB, highest quality)")
        }
    }
    static func hotkeyName(_ hotkey: HotkeyOption) -> String {
        switch hotkey {
        case .rightCommand:
            return de("Rechte ⌘ (Command) gedrückt halten",
                      en: "Hold right ⌘ (Command)")
        }
    }

    // MARK: - Error messages surfaced in the UI

    static var errMicNotGranted: String {
        de("Der Mikrofonzugriff wurde nicht erteilt. Erlaube ihn in den Systemeinstellungen, um zu diktieren.",
           en: "Microphone access was not granted. Allow it in System Settings to use dictation.")
    }
    static func errModelLoad(_ error: String) -> String {
        de("Modell konnte nicht geladen werden: \(error)",
           en: "Model could not be loaded: \(error)")
    }
    static var errMicRequired: String {
        de("Mikrofonzugriff ist erforderlich.", en: "Microphone access is required.")
    }
    static func errRecordStart(_ error: String) -> String {
        de("Aufnahme konnte nicht gestartet werden: \(error)",
           en: "Could not start recording: \(error)")
    }
    static func errTranscription(_ error: String) -> String {
        de("Transkription fehlgeschlagen: \(error)",
           en: "Transcription failed: \(error)")
    }

    // MARK: - Language picker

    /// The localized name for a language code (e.g. "en" -> "English"/"Englisch"),
    /// so the dictation-language picker reads in the current UI language.
    static func languageName(_ code: String) -> String {
        Locale.autoupdatingCurrent.localizedString(forLanguageCode: code) ?? code
    }
}
