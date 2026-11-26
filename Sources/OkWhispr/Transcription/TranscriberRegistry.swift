import Foundation

/// Builds a Transcriber for the chosen engine.
///
/// Cohere runs the local MLX model; Apple uses the system `SpeechAnalyzer`
/// (macOS 26+).
enum TranscriberRegistry {

    static func make(engine: TranscriptionEngine, variant: CohereVariant, language: String) -> Transcriber {
        switch engine {
        case .cohere:
            let t = CohereTranscriber(variant: variant, language: language)
            AppLogger.log("using local MLX engine: \(t.name)")
            return t

        case .apple:
            AppLogger.log("using Apple on-device engine (SpeechAnalyzer)")
            return AppleOnDeviceTranscriber(language: language)
        }
    }
}
