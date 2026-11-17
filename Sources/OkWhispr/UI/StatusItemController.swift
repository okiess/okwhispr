import AppKit
import Combine

/// A robust menu-bar status item built with AppKit (not SwiftUI MenuBarExtra).
/// A manual NSStatusItem keeps the process alive reliably in every login session
/// and gives predictable, battle-tested behavior for a menu-bar utility.
///
/// The menu is rebuilt every time it opens (NSMenuDelegate) so its status line
/// reflects the current phase, and a light timer updates the icon.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let appState: AppState
    private let settings = SettingsStore.shared
    private var cancellable: AnyCancellable?
    private var iconTimer: Timer?

    init(appState: AppState) {
        self.appState = appState
        // A variable-length item so it never overflows the menu bar.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        buildMenu()
        startIconTimer()

        // Rebuild the icon whenever the phase or model state changes.
        cancellable = appState.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.updateIcon() }
        }
    }

    // MARK: - Button / icon

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        updateIcon()
    }

    private func startIconTimer() {
        // Refresh the icon a few times a second so a listening/transcribing state
        // is visible even without opening the menu.
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateIcon() }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch appState.phase {
        case .idle:
            symbol = appState.modelReady ? "mic" : "arrow.down.circle"
        case .listening:
            symbol = "mic.fill"
        case .transcribing:
            symbol = "waveform"
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "OkWhispr") {
            image.isTemplate = true
            button.image = image
        }
        button.toolTip = tooltip
    }

    private var tooltip: String {
        switch appState.phase {
        case .idle:
            return appState.modelReady ? L.tooltipReady : L.tooltipPreparing
        case .listening:
            return L.tooltipListening
        case .transcribing:
            return L.tooltipTranscribing
        }
    }

    // MARK: - Menu (rebuilt on open)

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Status line.
        let statusItem = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        // Toggle recording.
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleRecording),
                                keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = appState.phase != .transcribing && appState.modelReady
        menu.addItem(toggle)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L.menuSettings, action: #selector(openSettings),
                                  keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let login = NSMenuItem(title: L.menuLaunchAtLogin,
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = settings.launchAtLogin ? .on : .off
        menu.addItem(login)

        // Self-heal after a signing change: clear a stale TCC entry and
        // re-request the permissions. Shown when a permission is missing, which
        // includes the stale-signature case (the check returns false then too).
        if !appState.inputMonitoringGranted || !appState.accessibilityGranted || !appState.micGranted {
            let reset = NSMenuItem(title: L.menuResetPermissions,
                                   action: #selector(resetPermissionsAction), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L.menuQuit, action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var statusLine: String {
        if let error = appState.errorMessage {
            return L.statusError(error)
        }
        if !appState.inputMonitoringGranted {
            return L.statusInputMonitoring
        }
        switch appState.phase {
        case .idle:
            return appState.modelReady
                ? L.statusReady(languageCode: settings.language)
                : L.statusPreparing(percent: appState.modelProgress * 100)
        case .listening:
            return L.statusListening
        case .transcribing:
            return L.statusTranscribing
        }
    }

    private var toggleTitle: String {
        switch appState.phase {
        case .idle: return L.toggleStart
        case .listening: return L.toggleStop
        case .transcribing: return L.toggleWorking
        }
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        appState.toggleRecording()
    }

    @objc private func openSettings() {
        SettingsWindow.open()
    }

    @objc private func toggleLaunchAtLogin() {
        settings.launchAtLogin.toggle()
    }

    @objc private func resetPermissionsAction() {
        appState.resetPermissions()
    }

    @objc private func quit() {
        AppDelegate.userInitiatedQuit = true
        NSApp.terminate(nil)
    }
}
