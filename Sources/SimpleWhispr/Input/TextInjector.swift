import Foundation
import AppKit
import Carbon.HIToolbox

/// Places a transcript where the user's cursor is.
///
/// Primary method is direct Accessibility API injection into the focused
/// AXTextField/AXTextArea. If that fails, we fall back to the universal
/// pasteboard + synthetic ⌘V approach. The previous pasteboard contents are
/// restored afterwards so the user's clipboard is left as they found it.
///
/// Posting a synthetic ⌘V requires Accessibility permission; without it the
/// text still lands on the pasteboard and the user can paste it manually.
enum TextInjector {

    /// The virtual key code for "V".
    private static let vKeyCode: CGKeyCode = 9

    static func inject(_ text: String, autoPaste: Bool) {
        // Manual paste mode: just put text on pasteboard
        guard autoPaste else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            AppLogger.log("transcript placed on pasteboard (manual paste). chars=\(text.count)")
            return
        }

        // Try direct Accessibility injection first
        if Permissions.accessibilityGranted {
            if AccessibilityTextInjector.inject(text) {
                AppLogger.log("transcript injected via Accessibility API. chars=\(text.count)")
                return
            }
            AppLogger.log("Accessibility direct inject failed, falling back to ⌘V")
        }

        // Fallback: pasteboard + synthetic ⌘V
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard Permissions.accessibilityGranted else {
            AppLogger.log("Accessibility not granted; leaving text on the pasteboard for manual paste.")
            return
        }

        postCommandV()
        // Give the paste a moment to land, then restore the previous clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            restore(pasteboard, previous)
            AppLogger.log("transcript pasted via ⌘V fallback. chars=\(text.count)")
        }
    }

    // MARK: Pasteboard restore

    private static func restore(_ pb: NSPasteboard, _ previous: String?) {
        if let previous {
            pb.clearContents()
            pb.setString(previous, forType: .string)
        }
    }

    // MARK: Synthetic ⌘V

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            AppLogger.error("Could not create CGEvent source.")
            return
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        // A tiny gap so the target app registers the key pair as a single paste.
        usleep(12_000)
        keyUp?.post(tap: .cghidEventTap)
    }
}
