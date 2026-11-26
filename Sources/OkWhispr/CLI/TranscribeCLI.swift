import Foundation
import AVFoundation
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox
import CohereTranscribeASR

/// A hidden command-line test mode that verifies the full transcription
/// pipeline end-to-end without a microphone. Usage:
///
///   OkWhispr --transcribe <audioFile> [--language de|en|...] [--variant int5|int8|fp16] [--engine cohere|apple]
///
/// It loads the local model (downloading it on first use), decodes the audio
/// file, transcribes it, prints the result, and exits. This is how the build is
/// validated; the normal menu-bar app never runs it.
enum TranscribeCLI {

    /// Returns true if the CLI mode was handled (the caller should skip UI setup).
    @discardableResult
    static func launchIfRequested(_ arguments: [String]) -> Bool {
        // A hotkey self-test (no physical keypress needed). Checked first so it
        // never loads the heavy model.
        if launchHotkeySelftest(arguments) {
            return true
        }
        guard let idx = arguments.firstIndex(of: "--transcribe"), arguments.count > idx + 1 else {
            return false
        }
        let fileURL = URL(fileURLWithPath: arguments[idx + 1])
        let language = value(arguments, after: "--language", default: "de")
        let variant = parseVariant(arguments)
        let rawEngine = value(arguments, after: "--engine", default: TranscriptionEngine.cohere.rawValue)
        guard let engine = TranscriptionEngine(rawValue: rawEngine) else {
            let valid = TranscriptionEngine.allCases.map(\.rawValue).joined(separator: ", ")
            FileHandle.standardError.write(Data("Unknown --engine \"\(rawEngine)\". Valid: \(valid)\n".utf8))
            exit(2)
        }

        AppLogger.log("CLI transcribe: \(fileURL.path) lang=\(language) variant=\(variant.rawValue) engine=\(engine.rawValue)")
        // Fire and forget on the global executor, then exit when done. This keeps
        // the main run loop free so the async model load can make progress.
        Task {
            let exitCode = await run(fileURL: fileURL, language: language, variant: variant, engine: engine)
            AppLogger.log("CLI transcribe finished (exit \(exitCode))")
            exit(Int32(exitCode))
        }
        return true
    }

    private static func run(fileURL: URL, language: String, variant: CohereVariant, engine: TranscriptionEngine) async -> Int32 {
        guard let (samples, sampleRate) = try? decodeAudio(fileURL: fileURL) else {
            FileHandle.standardError.write(Data("Could not read audio file: \(fileURL.path)\n".utf8))
            return 2
        }
        AppLogger.log("decoded \(samples.count) samples @ \(Int(sampleRate)) Hz")
        if samples.count == 0 {
            FileHandle.standardError.write(Data("Audio file has no samples.\n".utf8))
            return 3
        }

        let progress: (Double) -> Void = { p in
            FileHandle.standardError.write(Data(String(format: "loading model… %.0f%%\n", p * 100).utf8))
        }
        let transcriber: Transcriber
        switch engine {
        case .cohere:
            let cohere = CohereTranscriber(variant: variant, language: language)
            cohere.onProgress = progress
            transcriber = cohere
        case .apple:
            let apple = AppleOnDeviceTranscriber(language: language)
            apple.onProgress = progress
            transcriber = apple
        }
        do {
            try await transcriber.ensureLoaded(language: language)
            let start = Date()
            let text = try await transcriber.transcribe(samples, sampleRate: Int(sampleRate.rounded()), language: language)
            let seconds = Date().timeIntervalSince(start)
            FileHandle.standardError.write(Data(String(format: "transcribed in %.2fs\n", seconds).utf8))
            print(text)
            return 0
        } catch {
            AppLogger.error("CLI transcribe failed: \(error)")
            FileHandle.standardError.write(Data("Transcription failed: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: - Audio decoding

    /// Decodes any common audio file to mono Float32 samples at its native rate.
    static func decodeAudio(fileURL: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return ([], format.sampleRate) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return ([], format.sampleRate)
        }
        try file.read(into: buffer)

        let channels = Int(format.channelCount)
        let capacity = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData else { return ([], format.sampleRate) }
        var mono = [Float](repeating: 0, count: capacity)
        if channels <= 1 {
            let ptr = channelData[0]
            for i in 0..<capacity { mono[i] = ptr[i] }
        } else {
            for i in 0..<capacity {
                var sum: Float = 0
                for ch in 0..<channels { sum += channelData[ch][i] }
                mono[i] = sum / Float(channels)
            }
        }
        return (mono, format.sampleRate)
    }

    // MARK: - Argument helpers

    private static func value(_ args: [String], after flag: String, default def: String) -> String {
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return def }
        return args[i + 1]
    }

    private static func parseVariant(_ args: [String]) -> CohereVariant {
        let raw = value(args, after: "--variant", default: "int5")
        switch raw {
        case "fp16": return .fp16
        case "int8": return .int8
        default: return .int5
        }
    }

    // MARK: - Hotkey self-test

    /// Hidden self-test that verifies the hold-to-talk hotkey end-to-end without
    /// a physical keypress. It registers the right-Command tap, posts a synthetic
    /// flags-changed down+up for that key through its own session, and reports
    /// whether the callbacks fired and whether the current process is granted
    /// Input Monitoring. It requires both Accessibility and Input Monitoring.
    ///
    /// Caveat: the result reflects the launching context. A binary run from a
    /// terminal inherits that terminal's TCC, so it can PASS even when the
    /// deployed login-item app is denied - it is a smoke test, not proof the
    /// installed app works.
    ///
    ///   OkWhispr --hotkey-selftest [--key fn]
    @discardableResult
    static func launchHotkeySelftest(_ arguments: [String]) -> Bool {
        guard arguments.contains("--hotkey-selftest") else { return false }
        AppLogger.log("hotkey self-test started")
        var downFired = false
        var upFired = false
        GlobalHotkey.shared.onStart = { downFired = true; AppLogger.log("self-test: key DOWN received") }
        GlobalHotkey.shared.onStop = { upFired = true; AppLogger.log("self-test: key UP received") }
        let rawKey = value(arguments, after: "--key", default: HotkeyOption.rightCommand.rawValue)
        guard let option = HotkeyOption(rawValue: rawKey) else {
            let valid = HotkeyOption.allCases.map(\.rawValue).joined(separator: ", ")
            FileHandle.standardError.write(Data("Unknown --key \"\(rawKey)\". Valid: \(valid)\n".utf8))
            exit(2)
        }
        AppLogger.log("self-test key: \(option.rawValue)")
        GlobalHotkey.shared.register(option: option)

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let src = CGEventSource(stateID: .hidSystemState)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(option.keyCode), keyDown: true) {
                down.type = .flagsChanged
                down.flags = option.flag
                down.post(tap: .cgSessionEventTap)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(option.keyCode), keyDown: false) {
                up.type = .flagsChanged
                up.flags = []
                up.post(tap: .cgSessionEventTap)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let trusted = AXIsProcessTrusted()
            let inputMonitoring = CGPreflightListenEventAccess()
            // PASS only when the tap actually received the keys AND the current
            // process is granted Input Monitoring, so a terminal launch (which
            // inherits a different TCC context) does not report a misleading PASS.
            let ok = downFired && upFired && inputMonitoring
            let detail = "trusted=\(trusted) inputMonitoring=\(inputMonitoring) downFired=\(downFired) upFired=\(upFired)"
            AppLogger.log("hotkey self-test: \(detail) => \(ok ? "PASS" : "FAIL")")
            let caveat = "Note: this reflects the launching context (terminal TCC), not the deployed login-item app.\n"
            let line = ok
                ? "Hotkey self-test PASSED (\(detail)).\n\(caveat)"
                : "Hotkey self-test FAILED (\(detail)).\n"
                  + (inputMonitoring ? "" : "Grant Input Monitoring in System Settings, then retry.\n")
                  + (trusted ? "" : "Grant Accessibility in System Settings, then retry.\n")
                  + caveat
            FileHandle.standardError.write(Data(line.utf8))
            exit(Int32(ok ? 0 : 1))
        }
        return true
    }
}
