import Foundation
import AVFoundation
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox
import CohereTranscribeASR

/// A hidden command-line test mode that verifies the full transcription
/// pipeline end-to-end without a microphone. Usage:
///
///   SimpleWhispr --transcribe <audioFile> [--language de|en|...] [--variant int5|int8|fp16]
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

        AppLogger.log("CLI transcribe: \(fileURL.path) lang=\(language) variant=\(variant.rawValue)")
        // Fire and forget on the global executor, then exit when done. This keeps
        // the main run loop free so the async model load can make progress.
        Task {
            let exitCode = await run(fileURL: fileURL, language: language, variant: variant)
            AppLogger.log("CLI transcribe finished (exit \(exitCode))")
            exit(Int32(exitCode))
        }
        return true
    }

    private static func run(fileURL: URL, language: String, variant: CohereVariant) async -> Int32 {
        guard let (samples, sampleRate) = try? decodeAudio(fileURL: fileURL) else {
            FileHandle.standardError.write(Data("Could not read audio file: \(fileURL.path)\n".utf8))
            return 2
        }
        AppLogger.log("decoded \(samples.count) samples @ \(Int(sampleRate)) Hz")
        if samples.count == 0 {
            FileHandle.standardError.write(Data("Audio file has no samples.\n".utf8))
            return 3
        }

        let transcriber = CohereTranscriber(variant: variant, language: language)
        transcriber.onProgress = { p in
            FileHandle.standardError.write(Data(String(format: "loading model… %.0f%%\n", p * 100).utf8))
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
    /// whether the callbacks fired. It requires Accessibility permission — the
    /// same permission the hotkey and the paste need — so a FAIL with
    /// "trusted=false" means the user must grant Accessibility in System Settings.
    ///
    ///   SimpleWhispr --hotkey-selftest
    @discardableResult
    static func launchHotkeySelftest(_ arguments: [String]) -> Bool {
        guard arguments.contains("--hotkey-selftest") else { return false }
        AppLogger.log("hotkey self-test started")
        var downFired = false
        var upFired = false
        GlobalHotkey.shared.onStart = { downFired = true; AppLogger.log("self-test: key DOWN received") }
        GlobalHotkey.shared.onStop = { upFired = true; AppLogger.log("self-test: key UP received") }
        GlobalHotkey.shared.register(keyCode: UInt32(kVK_RightCommand), modifiers: 0)

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let src = CGEventSource(stateID: .hidSystemState)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_RightCommand), keyDown: true) {
                down.flags = .maskCommand
                down.post(tap: .cgSessionEventTap)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_RightCommand), keyDown: false) {
                up.flags = []
                up.post(tap: .cgSessionEventTap)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let trusted = AXIsProcessTrusted()
            let ok = downFired && upFired
            let detail = "trusted=\(trusted) downFired=\(downFired) upFired=\(upFired)"
            AppLogger.log("hotkey self-test: \(detail) => \(ok ? "PASS" : "FAIL")")
            let line = ok
                ? "Hotkey self-test PASSED (\(detail)).\n"
                : "Hotkey self-test FAILED (\(detail)).\n"
                  + (trusted ? "" : "Grant Accessibility in System Settings, then retry.\n")
            FileHandle.standardError.write(Data(line.utf8))
            exit(Int32(ok ? 0 : 1))
        }
        return true
    }
}
