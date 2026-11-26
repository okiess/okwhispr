import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// A global hold-to-talk hotkey.
///
/// The preferred shortcut is "hold the right Command key", which maps cleanly
/// onto a key-down / key-up pair:
///   - modifier down -> start recording
///   - modifier up   -> stop and transcribe
///
/// IMPORTANT: Carbon's RegisterEventHotKey / kEventHotKeyPressed does NOT deliver
/// a bare modifier-key press. A lone modifier produces no character key event for
/// the hotkey manager to match, so the callback never fires even though
/// RegisterEventHotKey returns noErr. We therefore use a session-level
/// CGEventTap on the flags-changed stream, which is the correct mechanism for
/// "hold a modifier to talk".
///
/// The tap only observes (it never swallows the modifier, so ⌘ keeps working
/// everywhere else) and re-enables itself when the system disables it during a
/// busy main thread (e.g. while transcribing).
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?

    /// Emits the "Input Monitoring not granted" log once, not every tick.
    private var warnedMissingPermission = false
    /// Throttles the re-enable log to at most once per 15s during busy periods.
    private var lastReenableLog = Date.distantPast

    /// The modifier key to react to (right Command or fn).
    fileprivate var activeOption: HotkeyOption = .rightCommand

    /// How long to wait before logging a repeated tap re-enable, so a busy main
    /// thread (e.g. during transcription) does not flood the log.
    private static let reenableLogInterval: TimeInterval = 15

    /// Called on the main thread when the key goes down.
    var onStart: (() -> Void)?
    /// Called on the main thread when the key goes up.
    var onStop: (() -> Void)?
    /// Called on the main thread when another key is pressed while the hotkey
    /// is held (a shortcut such as fn+Left or right-Cmd+C, not a dictation).
    /// The matching key-up then does not fire `onStop`.
    var onCancel: (() -> Void)?

    /// Whether the configured modifier is currently held down.
    fileprivate var isHeld = false
    /// Set when the current hold turned out to be part of a shortcut.
    fileprivate var holdCancelled = false

    /// Counts tap re-creations so a device-change recovery is diagnosable in the log.
    private var reactivationCount = 0

    private init() {}

    /// Registers the tap for the given hold-to-talk modifier key. Calling it
    /// again (e.g. after the user picks another key) re-creates the tap.
    func register(option: HotkeyOption) {
        unregister()

        activeOption = option
        isHeld = false
        holdCancelled = false
        warnedMissingPermission = false
        lastReenableLog = .distantPast

        // flagsChanged drives hold / release; keyDown detects a shortcut typed
        // while the modifier is held, so it can cancel the capture.
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        // userInfo points at this singleton so the C callback can reach it.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            AppLogger.error("CGEvent.tapCreate failed — Accessibility permission may be missing")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startHealthCheck()

        AppLogger.log("global hotkey tap registered (key=\(option.rawValue), keyCode=\(option.keyCode), inputMonitoring=\(Permissions.inputMonitoringGranted))")
    }

    // A health check that keeps the tap alive. macOS disables a tap when the
    // main run loop is busy (e.g. transcribing) or after a code-sign change
    // (the "silent disable race"), and a re-enable done inside the callback can
    // be swallowed. Polling every couple of seconds and re-enabling a disabled
    // tap is the robust backstop so hold-to-talk survives long transcriptions.
    private func startHealthCheck() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkTapEnabled()
        }
    }

    private func checkTapEnabled() {
        guard let tap = eventTap else { return }
        // Without Input Monitoring the tap can never receive events, so do not
        // spin re-enabling it. The AppState watcher re-creates the tap the moment
        // the permission is granted; just report the cause once.
        if !Permissions.inputMonitoringGranted {
            if !warnedMissingPermission {
                AppLogger.log("hotkey tap disabled: Input Monitoring not granted yet; it will activate when granted")
                warnedMissingPermission = true
            }
            return
        }
        warnedMissingPermission = false
        guard !CGEvent.tapIsEnabled(tap: tap) else { return }
        if lastReenableLog.timeIntervalSinceNow < -Self.reenableLogInterval {
            AppLogger.log("tap was disabled, re-enabling (health check)")
            lastReenableLog = Date()
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Re-enables the tap after the system disabled it (called from the C
    /// callback on tap-disabled events, when the main thread was busy).
    fileprivate func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Re-creates the tap using the last-registered key. Called when Input
    /// Monitoring is granted while the app is already running, because a tap
    /// created before the grant never starts receiving events, and after an
    /// input device change (e.g. AirPods), when a Bluetooth reconnect can leave
    /// the tap as a "dead tap" that only a re-creation recovers. register() runs
    /// unregister() first, so this is a clean, idempotent re-creation.
    func reactivate() {
        reactivationCount &+= 1
        register(option: activeOption)
        let enabled = eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        AppLogger.log("hotkey tap re-created (#\(reactivationCount)), enabled=\(enabled)")
    }

    func unregister() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }
}

// The C-compatible callback. It is a global value (no captures) so it can be
// handed to CGEvent.tapCreate. It reacts only to the configured modifier key and
// dispatches down/up on the main thread, then passes the event on untouched so
// the modifier keeps working system-wide.
private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    // The system disables the tap (by timeout or user input) when the main run
    // loop is slow — e.g. while transcribing on the CPU. Re-enable it so hold-to-
    // talk keeps working after a long transcription.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        AppLogger.log("tap DISABLED by \(type == .tapDisabledByTimeout ? "timeout" : "userInput"), re-enabling")
        GlobalHotkey.shared.reenableTap()
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userInfo).takeUnretainedValue()

    // Another key while the hotkey is held means a shortcut (fn+Left,
    // right-Cmd+C, ...), not dictation: cancel the capture once.
    if type == .keyDown {
        if hotkey.isHeld && !hotkey.holdCancelled {
            hotkey.holdCancelled = true
            AppLogger.log("key pressed while \(hotkey.activeOption.rawValue) held; cancelling capture")
            hotkey.onCancel?()
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }

    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let option = hotkey.activeOption
    let isDown: Bool
    switch option {
    case .rightCommand:
        // The keycode distinguishes right from left Command.
        guard UInt32(keycode) == option.keyCode else {
            return Unmanaged.passUnretained(event)
        }
        isDown = event.flags.contains(option.flag)
    case .fn:
        // Match on the fn flag transition, not only keycode 63: the Globe key
        // of some keyboards reports a different keycode. Other modifiers
        // pressed while fn is held do not change the flag and are ignored.
        isDown = event.flags.contains(option.flag)
        guard isDown != hotkey.isHeld else {
            return Unmanaged.passUnretained(event)
        }
    }

    AppLogger.log("flagsChanged key=\(option.rawValue) keyCode=\(keycode) \(isDown ? "DOWN" : "UP")")
    if isDown {
        hotkey.isHeld = true
        hotkey.holdCancelled = false
        hotkey.onStart?()
    } else {
        hotkey.isHeld = false
        if !hotkey.holdCancelled {
            hotkey.onStop?()
        }
        hotkey.holdCancelled = false
    }

    // Pass the event on untouched so the modifier keeps working everywhere.
    return Unmanaged.passUnretained(event)
}
