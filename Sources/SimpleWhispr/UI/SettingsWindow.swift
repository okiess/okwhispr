import AppKit
import Combine
import SwiftUI

/// Opens the SwiftUI `Settings` scene from this menu-bar-only app.
///
/// The app runs with activation policy `.accessory` (no Dock icon), and macOS
/// refuses to raise a window for an app without a Dock icon. The naive
/// `NSApp.sendAction(Selector("showSettingsWindow:"))` call therefore silently
/// does nothing on macOS 14 and later. The reliable path, which works on macOS
/// 14 through 17, is:
///
///   1. temporarily show the Dock icon (activation policy `.regular`),
///   2. drive the `Settings` scene through a hidden window's
///      `@Environment(\.openSettings)` action, deferred one run loop so it does
///      not crash in toolbar code on macOS 26/17,
///   3. force the resulting window to the front,
///   4. revert to `.accessory` once the window closes.
///
/// A hidden 1x1 `Window` scene is required to give the environment action a valid
/// SwiftUI context, and it MUST be declared before the `Settings` scene in the
/// App body (see SimpleWhisprApp). See
/// https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items
@MainActor
enum SettingsWindow {

    /// Asks the hidden context view to open the Settings scene.
    static let openRequest =
        Notification.Name("com.oliverkiessler.simplewhispr.openSettingsRequest")

    /// Brings the Settings window to the front, showing a Dock icon only for the
    /// duration the window is on screen.
    static func open() {
        DockIcon.show()
        NotificationCenter.default.post(name: openRequest, object: nil)
    }

    /// SwiftUI's hardcoded identifier for the `Settings` scene window, with a
    /// title / view-controller fallback for resilience across OS versions.
    private static let identifier = "com_apple_SwiftUI_Settings_window"

    /// Finds the currently open Settings window, if any.
    static func find() -> NSWindow? {
        NSApp.windows.first { window in
            if window.identifier?.rawValue == identifier { return true }
            if window.styleMask.contains(.titled),
               window.title.localizedCaseInsensitiveContains("settings")
                || window.title.localizedCaseInsensitiveContains("preferences") {
                return true
            }
            if let vc = window.contentViewController,
               String(describing: type(of: vc)).contains("Settings") {
                return true
            }
            return false
        }
    }
}

// MARK: - Hidden context view

/// A 1x1 invisible view that lives in the hidden `Window` scene. Its sole job is
/// to hold a live `@Environment(\.openSettings)` action so the Settings scene can
/// be opened programmatically from an `.accessory` app.
struct SettingsContextView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.openRequest)) { _ in
                // Defer one run loop: calling openSettings() synchronously here
                // crashes in toolbar code on macOS 26/17.
                Task { @MainActor in
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()

                    // The window is created just after the action; force it
                    // forward so it is not left behind the front app.
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if let window = SettingsWindow.find() {
                        window.makeKeyAndOrderFront(nil)
                        window.orderFrontRegardless()
                        // A brief elevation beats other windows that steal focus.
                        window.level = .floating
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            window.level = .normal
                        }
                        DockIcon.watchClose(of: window)
                    }
                }
            }
    }
}

// MARK: - Dock icon

/// Shows the Dock icon while the Settings window is open, then hides it again so
/// the app stays menu-bar-only. macOS only raises windows for apps that have a
/// Dock icon, which is why this toggle is required.
@MainActor
enum DockIcon {
    private static var closeObserver: NSObjectProtocol?

    /// Shows the Dock icon so the Settings window can be raised.
    static func show() {
        NSApp.setActivationPolicy(.regular)
    }

    /// Watches the given window and returns to the menu-bar-only state when it
    /// closes.
    static func watchClose(of window: NSWindow) {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            guard window != nil else { return }
            // Defer so we do not mutate the observer set while it is delivering.
            Task { @MainActor in
                if let observer = closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                    closeObserver = nil
                }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
