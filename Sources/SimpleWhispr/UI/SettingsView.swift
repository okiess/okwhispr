import SwiftUI
import AppKit

/// The Settings window (⌘,). Configures engine, language, and permissions.
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared

    private static let languages: [(code: String, name: String)] = [
        ("de", "German (Deutsch)"),
        ("en", "English"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("el", "Greek"),
        ("vi", "Vietnamese"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
    ]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            modelTab
                .tabItem { Label("Model", systemImage: "cpu") }
            permissionsTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 360)
        .onReceive(NotificationCenter.default.publisher(for: .didChangeSettings)) { _ in
            appState.applySettings()
        }
        .onChange(of: settings.engine) { _, _ in
            NotificationCenter.default.post(name: .didChangeSettings, object: nil)
        }
        .onChange(of: settings.variant) { _, _ in
            NotificationCenter.default.post(name: .didChangeSettings, object: nil)
        }
        .onChange(of: settings.language) { _, _ in
            NotificationCenter.default.post(name: .didChangeSettings, object: nil)
        }
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Picker("Language", selection: $settings.language) {
                ForEach(Self.languages, id: \.code) { item in
                    Text(item.name).tag(item.code)
                }
            }
            .help("Language spoken into the microphone. The model must support it.")

            Toggle("Paste the result into the active field (⌘V)", isOn: $settings.pasteAfter)
                .help("When on, the transcript is pasted where your cursor is. When off, it is only copied to your clipboard.")

            HStack {
                Text("Minimum talk time")
                Picker("", selection: $settings.silenceGuardMs) {
                    Text("200 ms").tag(200)
                    Text("350 ms").tag(350)
                    Text("600 ms").tag(600)
                }
                .labelsHidden()
                Text("— taps shorter than this are ignored").foregroundStyle(.secondary)
            }
            .help("Guards against accidental key taps that start and stop recording.")

            Divider()
            Text("Shortcut").font(.headline)
            HStack {
                Text("Hold")
                Image(systemName: "command")
                Text("right")
                Text("and speak, then release to transcribe.")
                Spacer()
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: Model

    private var modelTab: some View {
        Form {
            Picker("Engine", selection: $settings.engine) {
                ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .help("Cohere Transcribe 2B is a local 2B-parameter model. Apple On-Device needs no download.")

            if settings.engine == .cohere {
                Picker("Precision", selection: $settings.variant) {
                    ForEach(CohereVariant.allCases, id: \.self) { variant in
                        Text(variant.displayName).tag(variant)
                    }
                }
                .help("Higher precision = better quality but more memory and download size.")
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model status").font(.headline)
                    Text(modelStatusText).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reload") {
                    NotificationCenter.default.post(name: .didChangeSettings, object: nil)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var modelStatusText: String {
        if appState.isModelLoading {
            return "Loading \(appState.currentEngine.shortName)…"
        }
        if appState.modelReady {
            return "Ready"
        }
        if let error = appState.errorMessage {
            return error
        }
        return "Not loaded yet"
    }

    // MARK: Permissions

    private var permissionsTab: some View {
        Form {
            permissionRow(
                title: "Microphone",
                granted: appState.micGranted,
                help: "Required to record your speech.",
                action: { appState.requestMicPermission() }
            )
            permissionRow(
                title: "Accessibility",
                granted: appState.accessibilityGranted,
                help: "Required so the transcript can be typed (⌘V) into the app you are using.",
                action: { appState.openAccessibility() }
            )
            permissionRow(
                title: "Input Monitoring",
                granted: appState.inputMonitoringGranted,
                help: "Required for the global hotkey. Without it the right-⌘ tap is created but receives no keys and the dictation hotkey does not fire.",
                action: { appState.requestInputMonitoring() }
            )
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { appState.refreshPermissions() }
        .onChange(of: appState.accessibilityGranted) { _, _ in appState.refreshPermissions() }
        .onChange(of: appState.inputMonitoringGranted) { _, _ in appState.refreshPermissions() }
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, help: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant…") {
                    action()
                }
            }
        }
    }
}

extension Notification.Name {
    /// Posted when engine / variant / language / paste settings change, so the
    /// running engine can reload.
    static let didChangeSettings = Notification.Name("com.oliverkiessler.simplewhispr.settingsChanged")
}
