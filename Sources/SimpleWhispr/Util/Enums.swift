import Foundation

/// The transcription engines SimpleWhispr can run.
enum TranscriptionEngine: String, CaseIterable, Codable {
    /// Local, fully offline 2B-parameter model (Cohere Transcribe 2B) via MLX.
    case cohere
    /// Apple's on-device speech recognition. Fast, zero download, always present.
    case apple

    var displayName: String {
        switch self {
        case .cohere: return "Cohere Transcribe 2B (MLX, local)"
        case .apple: return "Apple On-Device"
        }
    }

    var shortName: String {
        switch self {
        case .cohere: return "Cohere 2B"
        case .apple: return "Apple"
        }
    }
}

/// MLX precision variants for the Cohere model.
enum CohereVariant: String, CaseIterable, Codable {
    case fp16
    case int5
    case int8

    var displayName: String {
        switch self {
        case .fp16: return "FP16 (largest, ~3.8 GB)"
        case .int5: return "INT5 (default, ~1.6 GB, recommended)"
        case .int8: return "INT8 (~2.2 GB, highest quality)"
        }
    }
}

/// The global hotkey. For now only "hold right Command" is offered, which is the
/// user's preferred shortcut. It is kept as an enum so more can be added later.
enum HotkeyOption: String, CaseIterable, Codable {
    case rightCommand

    var displayName: String {
        switch self {
        case .rightCommand: return "Hold right ⌘ (Command)"
        }
    }
}
