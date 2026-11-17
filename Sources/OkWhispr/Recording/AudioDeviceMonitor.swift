import Foundation
import CoreAudio

/// Watches the system default input device and hardware topology.
///
/// `AVAudioEngine` binds its input node to the default input device at first
/// realization and does not re-acquire when the device changes at runtime (for
/// example plugging in AirPods), so a hotplugged microphone is ignored until the
/// engine is recreated. This monitor offers two things:
/// - `currentDefaultInputUID()` lets the recorder compare the live device with the
///   one its engine was realized with and recreate the engine when they differ -
///   bulletproof even if the notification below is missed.
/// - `start()` fires a callback on the main queue when the default input or the
///   device topology changes, for proactive logging and diagnostics.
final class AudioDeviceMonitor: @unchecked Sendable {
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private let onChange: (@Sendable () -> Void)?
    private var active = false

    init(onChange: (@Sendable () -> Void)? = nil) {
        self.onChange = onChange
    }

    /// UID of the current default input device, or nil if none / not queryable.
    static func currentDefaultInputUID() -> String? {
        guard let deviceID = Self.currentDefaultInputDeviceID() else { return nil }
        return deviceUID(for: deviceID)
    }

    /// Human-readable name of the current default input device, for logs.
    static func currentDefaultInputName() -> String? {
        guard let deviceID = Self.currentDefaultInputDeviceID() else { return nil }
        return deviceName(for: deviceID)
    }

    /// Starts listening. The callback runs on the main queue.
    func start() {
        guard !active else { return }
        active = true
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange?()
        }
        let devicesStatus = AudioObjectAddPropertyListenerBlock(
            systemObject, &devicesAddress, DispatchQueue.main, devicesListener)

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let defaultInputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange?()
        }
        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            systemObject, &defaultInputAddress, DispatchQueue.main, defaultInputListener)

        if devicesStatus != noErr || defaultStatus != noErr {
            AppLogger.log("audio device monitor install failed devices=\(devicesStatus) default=\(defaultStatus)")
        } else {
            AppLogger.log("audio device monitor active (\(Self.currentDefaultInputName() ?? "unknown"))")
        }

        self.devicesListener = devicesListener
        self.defaultInputListener = defaultInputListener
    }

    /// Stops listening and removes the registered listeners.
    func stop() {
        guard active else { return }
        active = false
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        if let devicesListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectRemovePropertyListenerBlock(systemObject, &address, DispatchQueue.main, devicesListener)
        }
        if let defaultInputListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectRemovePropertyListenerBlock(systemObject, &address, DispatchQueue.main, defaultInputListener)
        }

        self.devicesListener = nil
        self.defaultInputListener = nil
    }

    // MARK: - Core Audio lookups

    private static func currentDefaultInputDeviceID() -> AudioObjectID? {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func deviceUID(for deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { return nil }
        return uid.takeUnretainedValue() as String
    }

    private static func deviceName(for deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeUnretainedValue() as String
    }
}
