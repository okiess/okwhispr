import Foundation

/// Apple's on-device speech recognition, as a fallback engine.
///
/// On macOS 27 the classic `SFSpeechRecognizer` API was replaced by the
/// `SpeechAnalyzer`/`DictationTranscriber` API. This implementation is a safe
/// placeholder that reports itself unavailable, so the build is never blocked
/// by an untestable, streaming speech API. The app's primary and default engine
/// is the local MLX Cohere Transcribe 2B model, which does not depend on Apple's
/// speech service at all.
///
/// A `SpeechAnalyzer`-based implementation can be dropped in here later; it
/// conforms to the same `Transcriber` protocol and the registry picks it up.
final class AppleOnDeviceTranscriber: Transcriber {

    let name = "Apple On-Device"
    private let language: String

    init(language: String) {
        self.language = language
    }

    var isLoaded: Bool { false }

    func ensureLoaded(language: String) async throws {
        throw TranscriberError.unavailable(
            "The Apple on-device fallback needs a macOS 27 SpeechAnalyzer implementation. "
            + "Select \"Cohere Transcribe 2B\" (the default) for local dictation.")
    }

    func transcribe(_ audio: [Float], sampleRate: Int, language: String) async throws -> String {
        throw TranscriberError.unavailable("Apple on-device engine is not enabled in this build.")
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
