import Foundation
import AVFoundation
import Speech

/// Apple's on-device speech recognition through the `SpeechAnalyzer` /
/// `SpeechTranscriber` API (macOS 26+).
///
/// It uses the system speech model, so there is no app-managed model download.
/// The first use of a language may ask macOS to install that language's speech
/// assets; that download is done by the system, and recognition itself runs
/// fully on-device. On macOS 15 the engine reports itself unavailable.
final class AppleOnDeviceTranscriber: Transcriber {

    let name = "Apple On-Device"
    private let language: String

    /// Guards `loadTask` and `loadedLanguage`: the background preload and an
    /// early dictation can call `ensureLoaded` at the same time.
    private let lock = NSLock()
    /// The asset preparation in flight (or done) for a language, shared by
    /// concurrent callers so assets are only requested once.
    private var loadTask: (language: String, task: Task<Void, Error>)?
    private var loadedLanguage: String?

    /// Progress (0...1) of a system speech asset download, if one is needed.
    var onProgress: ((Double) -> Void)?

    init(language: String) {
        self.language = language
    }

    var isLoaded: Bool { lock.withLock { loadedLanguage != nil } }

    func ensureLoaded(language: String) async throws {
        guard #available(macOS 26, *) else {
            throw TranscriberError.unavailable("Apple on-device transcription requires macOS 26 or later.")
        }
        let onProgress = self.onProgress
        let task: Task<Void, Error> = lock.withLock {
            if let current = loadTask, current.language == language { return current.task }
            loadedLanguage = nil
            let task = Task { try await AppleSpeechEngine.prepare(language: language, onProgress: onProgress) }
            loadTask = (language, task)
            return task
        }
        do {
            try await task.value
            lock.withLock {
                if loadTask?.task == task { loadedLanguage = language }
            }
        } catch {
            // Drop the failed attempt so the next call retries.
            lock.withLock {
                if loadTask?.task == task { loadTask = nil }
            }
            throw error
        }
    }

    func transcribe(_ audio: [Float], sampleRate: Int, language: String) async throws -> String {
        guard #available(macOS 26, *) else {
            throw TranscriberError.unavailable("Apple on-device transcription requires macOS 26 or later.")
        }
        if audio.isEmpty { return "" }
        try await ensureLoaded(language: language)
        return try await AppleSpeechEngine.transcribe(audio, sampleRate: sampleRate, language: language)
    }
}

/// The macOS 26 `SpeechAnalyzer` implementation, kept separate so the rest of
/// the app still builds and runs on macOS 15.
@available(macOS 26, *)
private enum AppleSpeechEngine {

    /// Resolves the language to a supported locale and installs its assets.
    static func prepare(language: String, onProgress: ((Double) -> Void)?) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriberError.unavailable("Apple speech transcription is not available on this Mac.")
        }
        let locale = try await resolveLocale(language)
        let module = SpeechTranscriber(locale: locale, preset: .transcription)

        let status = await AssetInventory.status(forModules: [module])
        AppLogger.log("Apple speech assets for \(locale.identifier): \(status)")
        if status == .installed { return }
        if status == .unsupported {
            throw TranscriberError.unavailable("Apple speech transcription does not support \(locale.identifier) on this Mac.")
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                let p = progress.fractionCompleted
                DispatchQueue.main.async { onProgress?(p) }
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }

        // Only report success once the assets are really there. Without a
        // request (e.g. macOS is already downloading them) they may not be yet.
        let finalStatus = await AssetInventory.status(forModules: [module])
        guard finalStatus == .installed else {
            throw TranscriberError.unavailable(
                "Apple speech assets for \(locale.identifier) are not installed yet (\(finalStatus)). Try again shortly.")
        }
        AppLogger.log("Apple speech assets installed for \(locale.identifier)")
    }

    /// Transcribes a mono Float32 clip with a fresh analyzer.
    static func transcribe(_ audio: [Float], sampleRate: Int, language: String) async throws -> String {
        let locale = try await resolveLocale(language)
        let module = SpeechTranscriber(locale: locale, preset: .transcription)

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(audio.count))
        else {
            throw TranscriberError.unavailable("Could not create an audio buffer.")
        }
        source.frameLength = AVAudioFrameCount(audio.count)
        audio.withUnsafeBufferPointer { src in
            source.floatChannelData![0].update(from: src.baseAddress!, count: audio.count)
        }

        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module], considering: sourceFormat) ?? sourceFormat
        let input = try convert(source, to: targetFormat)

        let analyzer = SpeechAnalyzer(modules: [module])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Collect finalized segments and join them with a single space, so
        // sentences never run together regardless of segment whitespace.
        let collector = Task { () throws -> String in
            var segments: [String] = []
            for try await result in module.results where result.isFinal {
                let segment = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty { segments.append(segment) }
            }
            return segments.joined(separator: " ")
        }

        do {
            try await analyzer.prepareToAnalyze(in: targetFormat)
            try await analyzer.start(inputSequence: stream)
            continuation.yield(AnalyzerInput(buffer: input))
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            collector.cancel()
            throw TranscriberError.recognitionFailed(error)
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveLocale(_ language: String) async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw TranscriberError.unavailable("Apple speech transcription does not support language \"\(language)\".")
        }
        return locale
    }

    /// Converts a buffer to the analyzer's preferred format (sample rate / type).
    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw TranscriberError.unavailable("Unsupported audio format conversion.")
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriberError.unavailable("Could not create a conversion buffer.")
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw TranscriberError.recognitionFailed(conversionError) }
        return output
    }
}

enum TranscriberError: Error, CustomStringConvertible {
    case unavailable(String)
    case recognitionFailed(Error)

    var description: String {
        switch self {
        case .unavailable(let m): return m
        case .recognitionFailed(let e): return "Recognition failed: \(e.localizedDescription)"
        }
    }
}
