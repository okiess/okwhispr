import Foundation

/// A pluggable speech-to-text engine.
///
/// The protocol is deliberately small so new engines (e.g. the local MLX
/// Cohere model) can be added without touching the recording or UI layers.
protocol Transcriber: AnyObject {
    var name: String { get }
    var isLoaded: Bool { get }

    /// Ensures the model / recognizer is ready. Downloads the model on first
    /// use where applicable. `language` is an ISO code such as "de" or "en".
    func ensureLoaded(language: String) async throws

    /// Transcribes a mono Float32 clip. May resample internally.
    /// Returns the transcript (empty string on no speech).
    func transcribe(_ audio: [Float], sampleRate: Int, language: String) async throws -> String
}
