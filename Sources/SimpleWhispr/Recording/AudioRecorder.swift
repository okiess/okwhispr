import Foundation
import AVFoundation

/// Records the microphone through AVAudioEngine and collects mono Float32 PCM.
///
/// The recorder is start/stop oriented (hold-to-talk). The audio tap runs on a
/// system audio queue, so samples are copied into a lock-protected buffer and
/// drained on `stop()`.
final class AudioRecorder: @unchecked Sendable {

    struct Capture: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let durationSeconds: Double
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var captureRate: Double = 16_000
    private var startTime: CFAbsoluteTime = 0
    private var configured = false

    private(set) var isRecording = false

    deinit {
        stopInternal()
    }

    /// Starts a fresh capture. Returns the audio format's sample rate used.
    func start() throws {
        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        let input = engine.inputNode
        let outputFormat = input.outputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            throw RecorderError.noInput("No microphone input format available (sampleRate=\(outputFormat.sampleRate)).")
        }

        // Install the tap at the node's native format and take channel 0 as
        // mono. This avoids resampling mismatches that installTap rejects.
        input.installTap(onBus: 0, bufferSize: 1024, format: outputFormat) { [weak self] avBuffer, _ in
            guard let self else { return }
            guard let channelData = avBuffer.floatChannelData, avBuffer.frameLength > 0 else { return }
            let frameCount = Int(avBuffer.frameLength)
            let mono = UnsafeBufferPointer(start: channelData[0], count: frameCount)
            let chunk = Array(mono)
            self.lock.lock()
            self.buffer.append(contentsOf: chunk)
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()

        lock.lock()
        captureRate = outputFormat.sampleRate
        startTime = CFAbsoluteTimeGetCurrent()
        isRecording = true
        configured = true
        lock.unlock()
        AppLogger.log("recording started @ \(Int(captureRate)) Hz, \(input.outputFormat(forBus: 0).channelCount)ch in")
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

    private func stopInternal() {
        // Safe to call multiple times / from deinit.
        if engine.isRunning {
            engine.stop()
        }
        // removeTap is a no-op if no tap is installed; safe to call unconditionally.
        engine.inputNode.removeTap(onBus: 0)
        lock.lock()
        isRecording = false
        lock.unlock()
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
