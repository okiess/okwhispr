import Foundation
import AVFoundation
import ApplicationServices
import AppKit
import CoreGraphics

/// Central place to check and request the permissions OkWhispr needs.
///
/// - Microphone: to record speech.
/// - Accessibility: to type the transcript into the active field (⌘V via CGEvent).
///
/// Speech recognition for the Apple fallback engine triggers the standard system
/// privacy prompt automatically when it first runs (macOS 27's SpeechAnalyzer API
/// no longer exposes an explicit authorization call).
enum Permissions {

    // MARK: Microphone

    static func microphoneStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Requests microphone access. Returns the resulting granted state.
    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: Accessibility

    /// True when the app is allowed to post key events (paste into other apps).
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to add OkWhispr to Accessibility. macOS shows the
    /// system dialog once; afterwards the user must toggle it in System Settings.
    static func openAccessibilitySettings() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
        ] as CFDictionary
        // Request the trust prompt if not already trusted.
        _ = AXIsProcessTrustedWithOptions(options)
        if !AXIsProcessTrusted() {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Input Monitoring

    /// True when the app may observe global keyboard events via an event tap.
    /// This is a SEPARATE permission from Accessibility: the global hotkey's
    /// CGEventTap needs Input Monitoring to receive real keyboard input. Without
    /// it the tap is created but gets no events and the system disables it.
    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// Requests the Input Monitoring permission (system dialog, once). The user
    /// must then enable OkWhispr in System Settings → Privacy & Security →
    /// Input Monitoring. After granting, the tap's health check re-enables it.
    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        if !CGPreflightListenEventAccess() {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Requests the Accessibility permission with the system prompt so the app
    /// is added to the accessibility list and the user can toggle it on. Without
    /// an explicit prompt the app never appears there, so there is nothing to
    /// enable. Only prompts when not already trusted, so it is quiet afterwards.
    static func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Reset (self-heal after a signing change)

    /// Clears the app's own TCC entries so a stale entry from a previous
    /// signature does not block a re-grant. Runs `tccutil reset <service>` for
    /// Input Monitoring, Accessibility, and Microphone, off the main thread.
    /// Never throws; failures are logged.
    static func resetAll() async {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.inceedo.okwhispr"
        for service in ["ListenEvent", "Accessibility", "Microphone"] {
            await runTccUtilReset(service: service, bundleID: bundleID)
        }
    }

    private static func runTccUtilReset(service: String, bundleID: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                proc.arguments = ["reset", service, bundleID]
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    AppLogger.log("tccutil reset \(service) for \(bundleID) -> exit \(proc.terminationStatus)")
                } catch {
                    AppLogger.error("tccutil reset \(service) for \(bundleID) failed: \(error)")
                }
                cont.resume()
            }
        }
    }
}
