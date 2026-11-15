import Foundation
import CohereTranscribeASR

/// Local, fully-offline speech-to-text using the Cohere Transcribe 2B model
/// run on Apple Silicon through MLX. This is the default engine.
///
/// The model (~1.6 GB for the INT5 variant) is downloaded from Hugging Face on
/// first use and cached by the library. After that, everything runs on-device
/// with no network and no telemetry.
final class CohereTranscriber: Transcriber, @unchecked Sendable {

    let name: String
    private let variant: CohereVariant
    private let language: String
    private var model: CohereTranscribeModel?
    private let queue = DispatchQueue(label: "com.oliverkiessler.simplewhispr.cohere")

    /// Progress callback during the first-time model download (0.0 - 1.0).
    var onProgress: ((Double) -> Void)?

    init(variant: CohereVariant, language: String) {
        self.variant = variant
        self.language = language
        self.name = "Cohere Transcribe 2B (\(variant.rawValue))"
    }

    var isLoaded: Bool { model != nil }

    /// Downloads (first time) and loads the model into memory.
    func ensureLoaded(language: String) async throws {
        if model != nil { return }
        let modelId = Self.modelId(for: variant)
        AppLogger.log("loading Cohere model: \(modelId)")
        let loaded = try await CohereTranscribeModel.load(
            modelId,
            offlineMode: false,
            progressHandler: { [weak self] p in
                DispatchQueue.main.async { self?.onProgress?(p) }
            }
        )
        self.model = loaded
        AppLogger.log("Cohere model loaded: \(modelId)")
    }

    /// Transcribes a mono Float32 clip. Inference runs on a private serial
    /// queue so it never blocks the main thread and clips are processed
    /// one at a time (dictation is sequential, hold-to-talk).
    func transcribe(_ audio: [Float], sampleRate: Int, language: String) async throws -> String {
        guard let model else {
            throw TranscriberError.unavailable("Cohere model is not loaded yet.")
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.queue.async {
                let text = model.transcribe(audio: audio, sampleRate: sampleRate, language: language)
                cont.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    /// Maps our variant enum to the library's published Hugging Face model ID.
    static func modelId(for variant: CohereVariant) -> String {
        let lib: CohereTranscribeVariant = switch variant {
        case .fp16: .fp16
        case .int5: .int5
        case .int8: .int8
        }
        return lib.modelId
    }
}
