import Foundation

/// Builds a Transcriber for the chosen engine.
///
/// The Cohere MLX engine is provided through `cohereFactory`, which is set by
/// the MLX module when that dependency is linked. Until then it is nil and the
/// app transparently falls back to the Apple on-device engine so dictation
/// always works.
enum TranscriberRegistry {

    static func make(engine: TranscriptionEngine, variant: CohereVariant, language: String) -> Transcriber {
        switch engine {
        case .cohere:
            let t = CohereTranscriber(variant: variant, language: language)
            AppLogger.log("using local MLX engine: \(t.name)")
            return t

        case .apple:
            return AppleOnDeviceTranscriber(language: language)
        }
    }
}
