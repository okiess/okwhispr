import Foundation
import AVFoundation
import AppKit

/// The app's orchestration layer. Owns the recorder, the current transcriber,
/// the hotkey, and the permission state. Everything is main-actor because the
/// Carbon hotkey callbacks arrive on the main run loop.
@MainActor
final class AppState: ObservableObject {

    enum Phase {
        case idle
        case listening
        case transcribing
    }

    @Published var phase: Phase = .idle
    @Published var lastTranscript = ""
    @Published var errorMessage: String?
    @Published var isModelLoading = false
    @Published var modelProgress = 0.0
    @Published var micGranted = false
    @Published var accessibilityGranted = false
    @Published var inputMonitoringGranted = false
    @Published var currentEngine = TranscriptionEngine.cohere
    @Published var modelReady = false

    private let recorder = AudioRecorder()
    private var transcriber: Transcriber?
    private var settings = SettingsStore.shared

    /// Watches Input Monitoring and re-creates the hotkey tap the moment the
    /// permission is granted, so the hotkey works without a relaunch.
    private var permissionWatcher: Timer?
    private var lastInputMonitoring = false

    /// Debounces hotkey recovery after an input device change. A Bluetooth
    /// reconnect (e.g. AirPods) can leave the CGEventTap as a "dead tap" that a
    /// plain re-enable cannot recover; only a re-creation does. The generation
    /// cancels a superseded flurry of device-change events so it does not spawn
    /// many timers.
    private var hotkeyRecoveryGeneration = 0

    /// How many times, and at what delays, the hotkey tap is re-created after a
    /// device change, to survive the Bluetooth stack's "delayed device
    /// availability". The later attempts catch a slow-settling connection.
    private static let hotkeyRecoveryDelays: [Double] = [0.5, 1.5, 3.0]

    /// Guards against a key-up that arrives before a key-down finished starting.
    private var captureInProgress = false

    init() {
        refreshPermissions()
        lastInputMonitoring = Permissions.inputMonitoringGranted
        startPermissionWatcher()
        observeInputDeviceChanges()
        // Preload the chosen engine in the background so the first dictation
        // does not have to wait for a model download or warm-up.
        prepareEngine()
    }

    /// Re-creates the global hotkey tap after an input device change, a few times
    /// over ~3s to survive the Bluetooth stack's "delayed device availability".
    private func observeInputDeviceChanges() {
        NotificationCenter.default.addObserver(
            forName: .okwhisprInputDeviceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleHotkeyRecovery()
            }
        }
    }

    /// Debounced: each call supersedes the in-flight recovery sequence, then
    /// re-creates the tap at `hotkeyRecoveryDelays`. Only the latest flurry's
    /// attempts run.
    func scheduleHotkeyRecovery() {
        hotkeyRecoveryGeneration &+= 1
        let generation = hotkeyRecoveryGeneration
        for delay in Self.hotkeyRecoveryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, generation == self.hotkeyRecoveryGeneration else { return }
                AppLogger.log("input device changed; re-creating hotkey tap (attempt @\(delay)s)")
                GlobalHotkey.shared.reactivate()
            }
        }
    }

    // MARK: - Permissions

    func refreshPermissions() {
        micGranted = Permissions.microphoneStatus() == .authorized
        accessibilityGranted = Permissions.accessibilityGranted
        inputMonitoringGranted = Permissions.inputMonitoringGranted
    }

    func requestInputMonitoring() {
        Permissions.requestInputMonitoring()
        // Poll briefly so the menu reflects the change without a rebuild.
        for _ in 0..<40 {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                refreshPermissions()
            }
        }
    }

    /// Self-heal after a signing change: clear the app's own TCC entries, then
    /// re-request Input Monitoring + Accessibility so the user can re-grant.
    /// The permission watcher re-creates the hotkey tap once Input Monitoring
    /// flips on, so no relaunch is needed.
    func resetPermissions() {
        Task {
            await Permissions.resetAll()
            requestInputMonitoring()
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        }
    }

    /// Polls Input Monitoring every second. When it flips to granted while we
    /// are running, the hotkey tap is re-created: it was created before the
    /// grant and never starts receiving events on its own, so the permission
    /// would otherwise only take effect after a relaunch.
    private func startPermissionWatcher() {
        permissionWatcher = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollPermissions() }
        }
    }

    private func pollPermissions() {
        let granted = Permissions.inputMonitoringGranted
        if granted && !lastInputMonitoring {
            AppLogger.log("Input Monitoring granted; re-creating hotkey tap")
            GlobalHotkey.shared.reactivate()
        }
        lastInputMonitoring = granted
        if granted != inputMonitoringGranted {
            inputMonitoringGranted = granted
        }
    }

    func requestMicPermission() {
        Task {
            let granted = await Permissions.requestMicrophone()
            micGranted = granted
            refreshPermissions()
            if !granted {
                errorMessage = L.errMicNotGranted
            }
        }
    }

    func openAccessibility() {
        Permissions.openAccessibilitySettings()
        // Poll briefly so the menu bar reflects the change without a rebuild.
        for _ in 0..<40 {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                refreshPermissions()
            }
        }
    }

    // MARK: - Engine lifecycle

    /// Loads the selected engine (downloads the model on first use).
    func prepareEngine() {
        currentEngine = settings.engine
        let t = TranscriberRegistry.make(
            engine: settings.engine,
            variant: settings.variant,
            language: settings.language)
        // Wire the first-time download progress into the UI.
        // Only update the progress while a load is running: a late tick that
        // arrives after the load finished must not flip the UI back to loading.
        let progressHandler: (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                guard let self, self.isModelLoading else { return }
                self.modelProgress = p
            }
        }
        if let cohere = t as? CohereTranscriber {
            cohere.onProgress = progressHandler
        } else if let apple = t as? AppleOnDeviceTranscriber {
            apple.onProgress = progressHandler
        }
        transcriber = t
        Task {
            isModelLoading = true
            modelProgress = 0
            do {
                try await t.ensureLoaded(language: settings.language)
                modelReady = true
            } catch {
                AppLogger.error("engine prepare failed: \(error)")
                errorMessage = L.errModelLoad("\(error)")
                modelReady = false
            }
            isModelLoading = false
            modelProgress = t.isLoaded ? 1.0 : 0
        }
    }

    /// Switches engine / variant / language and reloads the engine.
    func applySettings() {
        settings = SettingsStore.shared
        prepareEngine()
    }

    // MARK: - Model cache management

    /// Re-reads the downloaded model list from disk for the Settings UI.
    func refreshModels() {
        Task { await ModelStorage.shared.refresh() }
    }

    /// Moves the given model directories to the Trash. When the currently loaded
    /// model is among them, the in-memory reference is dropped so the next
    /// dictation re-downloads a fresh copy instead of using a deleted file.
    func deleteModels(_ infos: [ModelInfo]) {
        guard !infos.isEmpty else { return }
        let activeVariant = settings.variant
        Task { @MainActor [weak self] in
            guard let self else { return }
            let activeWasDeleted = infos.contains { $0.variant == activeVariant }
            do {
                try await ModelStorage.shared.trash(infos)
            } catch {
                AppLogger.error("model delete failed: \(error)")
                self.errorMessage = L.errModelDelete("\(error)")
            }
            if activeWasDeleted {
                self.dropLoadedModel()
            }
            await ModelStorage.shared.refresh()
        }
    }

    /// Discards the loaded model and rebuilds a fresh (unloaded) transcriber, so
    /// the next dictation loads from disk again. Does not re-download on its own.
    func dropLoadedModel() {
        transcriber = TranscriberRegistry.make(
            engine: settings.engine, variant: settings.variant, language: settings.language)
        modelReady = false
        isModelLoading = false
        modelProgress = 0
        errorMessage = nil
    }

    // MARK: - Recording pipeline

    /// Called on hotkey key-down. Starts capture immediately (no model wait) so
    /// the beginning of the speech is not missed.
    func beginRecording() {
        guard phase == .idle else { return }
        refreshPermissions()

        guard micGranted else {
            requestMicPermission()
            errorMessage = L.errMicRequired
            return
        }

        do {
            try recorder.start()
        } catch {
            AppLogger.error("recorder start failed: \(error)")
            errorMessage = L.errRecordStart("\(error)")
            return
        }
        captureInProgress = true
        phase = .listening
        lastTranscript = ""
        errorMessage = nil
    }

    /// Called on hotkey key-up. Stops capture, transcribes, and injects text.
    func endRecording() {
        guard captureInProgress else { return }
        captureInProgress = false
        let capture = recorder.stop()

        // Discard accidental taps shorter than the silence guard.
        if capture.durationSeconds * 1000 < Double(settings.silenceGuardMs) {
            phase = .idle
            AppLogger.log("discarded short capture (\(Int(capture.durationSeconds * 1000)) ms)")
            return
        }

        phase = .transcribing
        let language = settings.language
        let autoPaste = settings.pasteAfter
        let transcriber = self.transcriber

        Task {
            do {
                // If the background preload has not finished, wait for it here.
                if let transcriber, !transcriber.isLoaded {
                    try await transcriber.ensureLoaded(language: language)
                }
                guard let transcriber else {
                    throw TranscriberError.unavailable("No transcription engine is configured.")
                }
                let text = try await transcriber.transcribe(
                    capture.samples, sampleRate: Int(capture.sampleRate.rounded()), language: language)
                self.lastTranscript = text
                self.modelReady = true
                if text.isEmpty {
                    AppLogger.log("empty transcript; nothing to inject")
                } else {
                    TextInjector.inject(text, autoPaste: autoPaste)
                }
                self.phase = .idle
            } catch {
                AppLogger.error("transcription failed: \(error)")
                self.errorMessage = L.errTranscription("\(error)")
                self.phase = .idle
            }
        }
    }

    /// Manual record toggle (used by the menu bar button) for users who prefer
    /// to click. Press once to start, again to stop.
    func toggleRecording() {
        switch phase {
        case .idle:
            beginRecording()
        case .listening:
            endRecording()
        case .transcribing:
            break
        }
    }

    /// Stops an in-progress capture without transcribing (e.g. a cancel action).
    func cancelRecording() {
        guard captureInProgress else { return }
        captureInProgress = false
        recorder.stop()
        phase = .idle
    }
}
