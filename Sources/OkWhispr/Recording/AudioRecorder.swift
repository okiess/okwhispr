import Foundation
import AVFoundation
import CoreAudio
import Accelerate

/// Records the microphone through AVAudioEngine and collects mono Float32 PCM.
///
/// The recorder is start/stop oriented (hold-to-talk). The audio tap runs on a
/// system audio queue, so samples are copied into a lock-protected buffer and
/// drained on `stop()`.
///
/// AVAudioEngine binds its input node to the default input device at first
/// realization and never re-acquires when the device changes at runtime (for
/// example plugging in AirPods). Every start compares the current default input
/// device UID with the one the engine was realized with and recreates the engine
/// when they differ, so a hotplugged mic is picked up without a relaunch.
final class AudioRecorder: @unchecked Sendable {

    struct Capture: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let durationSeconds: Double
    }

    private var engine = AVAudioEngine()
    /// UID the current `engine` was realized against; a difference on the next
    /// start means the default input device changed and the engine is recreated.
    private var realizedInputUID: String?
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var captureRate: Double = 16_000

    private(set) var isRecording = false

    /// Called from the audio thread with the RMS of each captured buffer, for
    /// the live level meter in the recording overlay. Set once before use.
    var onLevel: (@Sendable (Float) -> Void)?

    private var deviceMonitor: AudioDeviceMonitor?

    /// How long `start()` waits for a valid input format to appear after a route
    /// change. Kept small so a hotkey key-down does not feel delayed; after a
    /// fresh engine realization the format is usually valid on the first read.
    private static let formatSettleAttempts = 8
    private static let formatSettleDelayMs = 100

    init() {
        // React to microphone/device changes so a hotplugged mic (e.g. AirPods)
        // is picked up without a relaunch. Created here (not as a property
        // initializer) because the change closure captures `self`.
        let monitor = AudioDeviceMonitor(onChange: { [weak self] in
            self?.handleInputChange()
        })
        deviceMonitor = monitor
        monitor.start()
    }

    deinit {
        stopInternal()
        deviceMonitor?.stop()
    }

    /// Starts a fresh capture. Returns the audio format's sample rate used.
    func start() throws {
        // Re-bind to the current default input device. If it changed since the
        // last realization (or this is the first start), tear down the old
        // engine and create a fresh one so it binds to the live default input.
        let currentUID = AudioDeviceMonitor.currentDefaultInputUID()
        if currentUID != realizedInputUID {
            stopInternal()
            engine = AVAudioEngine()
            realizedInputUID = currentUID
            AppLogger.log("recorder re-bound to input device \(currentUID ?? "none") (\(AudioDeviceMonitor.currentDefaultInputName() ?? "unknown"))")
        }

        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        let input = engine.inputNode
        guard let format = Self.waitForInputFormat(
            input, attempts: Self.formatSettleAttempts, delayMs: Self.formatSettleDelayMs) else {
            throw RecorderError.noInput(Self.noInputDescription(input))
        }

        // Install the tap at the node's native format and take channel 0 as
        // mono. This avoids resampling mismatches that installTap rejects.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] avBuffer, _ in
            guard let self else { return }
            guard let channelData = avBuffer.floatChannelData, avBuffer.frameLength > 0 else { return }
            let frameCount = Int(avBuffer.frameLength)
            let mono = UnsafeBufferPointer(start: channelData[0], count: frameCount)
            let chunk = Array(mono)
            if let onLevel = self.onLevel {
                var rms: Float = 0
                vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameCount))
                onLevel(rms)
            }
            self.lock.lock()
            self.buffer.append(contentsOf: chunk)
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()

        lock.lock()
        captureRate = format.sampleRate
        isRecording = true
        lock.unlock()
        AppLogger.log("recording started @ \(Int(captureRate)) Hz, \(format.channelCount)ch in (device \(realizedInputUID ?? "none"))")
    }

    /// Stops the capture and returns the collected audio.
    @discardableResult
    func stop() -> Capture {
        stopInternal()
        lock.lock()
        let samples = buffer
        buffer.removeAll(keepingCapacity: false)
        let rate = max(captureRate, 1)
        lock.unlock()
        let duration = Double(samples.count) / rate
        return Capture(samples: samples, sampleRate: rate, durationSeconds: duration)
    }

    /// Fired on the main queue when the default input or device topology
    /// changes. The UID check in `start()` already forces a re-bind for the
    /// recorder; this also broadcasts the change so other layers (the global
    /// hotkey, which can become a "dead tap" after a Bluetooth reconnect) can
    /// re-create their machinery.
    private func handleInputChange() {
        let uid = AudioDeviceMonitor.currentDefaultInputUID()
        let name = AudioDeviceMonitor.currentDefaultInputName() ?? "unknown"
        AppLogger.log("input device changed -> \(name) (\(uid ?? "none"))")
        NotificationCenter.default.post(name: .okwhisprInputDeviceChanged, object: nil)
    }

    /// Stops and detaches the engine's input tap and graph. Safe to call multiple
    /// times / from deinit.
    private func stopInternal() {
        // `removeTap` is a no-op if no tap is installed; `reset` is a no-op when
        // the engine is idle.
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
        lock.lock()
        isRecording = false
        lock.unlock()
    }

    /// Reads the input node's format, retrying while it is still 0 Hz / 0
    /// channels (the brief window after a device/route change where the
    /// AudioUnit has not finished negotiating the new format). Returns nil if it
    /// never settles, so the caller can throw a clear error.
    private static func waitForInputFormat(_ input: AVAudioInputNode, attempts: Int, delayMs: Int) -> AVAudioFormat? {
        for attempt in 0..<attempts {
            let format = input.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 {
                return format
            }
            if attempt + 1 < attempts {
                Thread.sleep(forTimeInterval: TimeInterval(delayMs) / 1000.0)
            }
        }
        return nil
    }

    /// A short description of why no input was found, for the error the caller
    /// surfaces to the user.
    private static func noInputDescription(_ input: AVAudioInputNode) -> String {
        let format = input.outputFormat(forBus: 0)
        return "No microphone input available (sampleRate=\(format.sampleRate), "
            + "channels=\(format.channelCount)). "
            + "Check that a default input device is selected and microphone access is granted."
    }

    enum RecorderError: Error, CustomStringConvertible {
        case noInput(String)
        var description: String {
            switch self {
            case .noInput(let detail): return detail
            }
        }
    }
}
