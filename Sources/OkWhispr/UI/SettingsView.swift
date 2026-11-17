import SwiftUI
import AppKit

/// The Settings window (⌘,). Configures engine, language, and permissions.
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var modelStorage = ModelStorage.shared

    /// The model(s) pending deletion, held so a confirmation dialog can name them.
    @State private var pendingDelete: [ModelInfo]? = nil
    @State private var pendingDeleteAll = false

    private static let languages: [String] = [
        "de",
        "en",
        "fr",
        "es",
        "it",
        "pt",
        "nl",
        "pl",
        "el",
        "vi",
        "zh",
        "ar",
        "ja",
        "ko",
    ]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(L.tabGeneral, systemImage: "gearshape") }
            modelTab
                .tabItem { Label(L.tabModel, systemImage: "cpu") }
            permissionsTab
                .tabItem { Label(L.tabPermissions, systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 440)
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
            Picker(L.settingsLanguage, selection: $settings.language) {
                ForEach(Self.languages, id: \.self) { code in
                    Text(L.languageName(code)).tag(code)
                }
            }
            .help(L.settingsLanguageHelp)

            Toggle(L.settingsPasteToggle, isOn: $settings.pasteAfter)
                .help(L.settingsPasteHelp)

            HStack {
                Text(L.settingsMinTalkTime)
                Picker("", selection: $settings.silenceGuardMs) {
                    Text(L.settingsMs(200)).tag(200)
                    Text(L.settingsMs(350)).tag(350)
                    Text(L.settingsMs(600)).tag(600)
                }
                .labelsHidden()
                Text(L.settingsMsNote).foregroundStyle(.secondary)
            }
            .help(L.settingsMinTalkHelp)

            Divider()
            Text(L.settingsShortcut).font(.headline)
            HStack {
                Text(L.settingsHold)
                Image(systemName: "command")
                Text(L.settingsRight)
                Text(L.settingsSpeakRelease)
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
            Picker(L.settingsEngine, selection: $settings.engine) {
                ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                    Text(L.engineName(engine)).tag(engine)
                }
            }
            .help(L.settingsEngineHelp)

            if settings.engine == .cohere {
                Picker(L.settingsPrecision, selection: $settings.variant) {
                    ForEach(CohereVariant.allCases, id: \.self) { variant in
                        Text(L.variantName(variant)).tag(variant)
                    }
                }
                .help(L.settingsPrecisionHelp)
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.settingsModelStatus).font(.headline)
                    Text(modelStatusText).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L.settingsReload) {
                    NotificationCenter.default.post(name: .didChangeSettings, object: nil)
                }
            }

            Divider()
            storageLocationSection

            Divider()
            downloadedModelsSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { appState.refreshModels() }
    }

    // MARK: Model - storage location

    private var storageLocationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L.settingsStorageLocation).font(.headline)
                Spacer()
                Button(L.settingsRevealInFinder) { modelStorage.revealInFinder(nil) }
            }
            .help(L.settingsStorageLocationHelp)
            Text(ModelStorage.displayPath(modelStorage.baseDirectory))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: Model - downloaded models

    private var downloadedModelsSection: some View {
        Group {
            if modelStorage.models.isEmpty {
                Text(L.settingsNoModelsYet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.settingsDownloadedModels).font(.headline)
                    ForEach(modelStorage.models) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.title).font(.callout)
                                Text(ModelStorage.humanSize(model.sizeBytes))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { pendingDelete = [model] } label: {
                                Image(systemName: "trash")
                            }
                            .help(L.settingsDelete)
                        }
                    }
                    if modelStorage.models.count > 1 {
                        Button(role: .destructive) { pendingDeleteAll = true } label: {
                            Text(L.settingsDeleteAll)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            L.confirmDeleteModelTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L.settingsDelete, role: .destructive) {
                let selected = pendingDelete ?? []
                pendingDelete = nil
                appState.deleteModels(selected)
            }
            Button(L.cancel, role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L.confirmDeleteModelMessage(name: pendingDelete?.first?.title ?? ""))
        }
        .confirmationDialog(
            L.confirmDeleteAllTitle,
            isPresented: $pendingDeleteAll,
            titleVisibility: .visible
        ) {
            Button(L.settingsDeleteAll, role: .destructive) {
                let selected = modelStorage.models
                pendingDeleteAll = false
                appState.deleteModels(selected)
            }
            Button(L.cancel, role: .cancel) { pendingDeleteAll = false }
        } message: {
            Text(L.confirmDeleteAllMessage)
        }
    }

    private var modelStatusText: String {
        if appState.isModelLoading {
            return L.statusLoading(name: appState.currentEngine.shortName)
        }
        if appState.modelReady {
            return L.statusReadyShort
        }
        if let error = appState.errorMessage {
            return error
        }
        return L.statusNotLoaded
    }

    // MARK: Permissions

    private var permissionsTab: some View {
        Form {
            permissionRow(
                title: L.permMic,
                granted: appState.micGranted,
                help: L.permMicHelp,
                action: { appState.requestMicPermission() }
            )
            permissionRow(
                title: L.permAccessibility,
                granted: appState.accessibilityGranted,
                help: L.permAccessibilityHelp,
                action: { appState.openAccessibility() }
            )
            permissionRow(
                title: L.permInputMonitoring,
                granted: appState.inputMonitoringGranted,
                help: L.permInputMonitoringHelp,
                action: { appState.requestInputMonitoring() }
            )

            if !allPermissionsGranted {
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L.permStillNotWorking).font(.headline)
                        Text(L.permStaleExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(L.permResetReRequest) { appState.resetPermissions() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { appState.refreshPermissions() }
        .onChange(of: appState.accessibilityGranted) { _, _ in appState.refreshPermissions() }
        .onChange(of: appState.inputMonitoringGranted) { _, _ in appState.refreshPermissions() }
    }

    private var allPermissionsGranted: Bool {
        appState.micGranted && appState.accessibilityGranted && appState.inputMonitoringGranted
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
                Label(L.permGranted, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(L.permGrant) {
                    action()
                }
            }
        }
    }
}

extension Notification.Name {
    /// Posted when engine / variant / language / paste settings change, so the
    /// running engine can reload.
    static let didChangeSettings = Notification.Name("com.inceedo.okwhispr.settingsChanged")

    /// Posted when the system input/audio device topology changes (for example
    /// AirPods connecting or the default input switching). Used to re-create the
    /// global hotkey tap, which can become a "dead tap" after a Bluetooth
    /// reconnect until it is re-created.
    static let okwhisprInputDeviceChanged = Notification.Name("com.inceedo.okwhispr.inputDeviceChanged")
}
