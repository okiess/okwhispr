import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct OkWhisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu-bar status item is the main UI (see AppDelegate).

        // A 1x1 hidden window that gives @Environment(\.openSettings) a valid
        // SwiftUI context. It MUST be declared before the Settings scene, or the
        // openSettings action is not resolved and opening Settings fails silently
        // in this menu-bar-only (accessory) app.
        Window("", id: "OkWhispr.SettingsContext") {
            SettingsContextView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)
        .defaultPosition(.topLeading)

        Settings {
            SettingsView(appState: appDelegate.appState)
        }
    }
}

/// Bridges launch timing to the Carbon event dispatcher and wires the hotkey,
/// the menu-bar status item, and the "stay resident" behaviour.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Retained so the status item lives for the whole app lifetime.
    private var statusItemController: StatusItemController?

    // A retained activity keeps the app resident even though AppKit re-enables
    // automatic termination during window restoration.
    private var keepAliveActivity: NSObjectProtocol?

    // Set by the menu's Quit action so we can distinguish a real user quit from
    // the system trying to terminate a window-less menu-bar app.
    static var userInitiatedQuit = false

    // Lazy so the main-actor AppState init runs on the main thread.
    lazy var appState: AppState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hidden CLI test mode (used to validate the build end-to-end without a mic).
        if TranscribeCLI.launchIfRequested(CommandLine.arguments) {
            return
        }

        // Menu-bar-only app: no dock icon, stay resident even with no windows.
        NSApp.setActivationPolicy(.accessory)
        keepAliveActivity = ProcessInfo.processInfo.beginActivity(
            options: [.automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "OkWhispr is a resident dictation agent and must stay in the menu bar.")
        ProcessInfo.processInfo.disableSuddenTermination()

        // Force the lazy AppState to create on main, which preloads the engine.
        _ = appState

        // Create the menu-bar status item and keep it retained.
        statusItemController = StatusItemController(appState: appState)

        // Request permissions FIRST so the system prompt shows and the tap is
        // created after the grant. A .listenOnly tap created before Input
        // Monitoring is granted never starts receiving events; the AppState
        // watcher re-creates the tap when the permission is granted later, so the
        // hotkey takes effect without a relaunch. Both requests are no-ops when
        // the permission is already granted.
        //
        // Input Monitoring is separate from Accessibility and is required for the
        // global hotkey; Accessibility is required for the Cmd-V auto-paste.
        Permissions.requestInputMonitoring()
        Permissions.requestAccessibility()

        // Register the global hold-to-talk hotkey (right Command by default).
        GlobalHotkey.shared.onStart = { [weak self] in
            self?.appState.beginRecording()
        }
        GlobalHotkey.shared.onStop = { [weak self] in
            self?.appState.endRecording()
        }
        GlobalHotkey.shared.register(keyCode: UInt32(kVK_RightCommand), modifiers: 0)

        AppLogger.log("OkWhispr launched. engine=\(SettingsStore.shared.engine.displayName)")
    }

    // Refuse system-initiated termination; allow only an explicit user quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppDelegate.userInitiatedQuit {
            return .terminateNow
        }
        return .terminateCancel
    }

    // Don't quit when the Settings window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }
}
