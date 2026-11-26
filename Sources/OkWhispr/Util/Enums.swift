import Foundation
import CoreGraphics

/// The transcription engines OkWhispr can run.
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

/// The global hold-to-talk key. Each option is a lone modifier key, observed
/// on the flags-changed event stream.
enum HotkeyOption: String, CaseIterable, Codable {
    case rightCommand
    case fn

    var displayName: String {
        switch self {
        case .rightCommand: return "Hold right ⌘ (Command)"
        case .fn: return "Hold fn (Globe)"
        }
    }

    /// The modifier's virtual keycode (kVK_RightCommand = 54, kVK_Function = 63).
    var keyCode: UInt32 {
        switch self {
        case .rightCommand: return 54
        case .fn: return 63
        }
    }

    /// The flag that is set while the modifier is held.
    var flag: CGEventFlags {
        switch self {
        case .rightCommand: return .maskCommand
        case .fn: return .maskSecondaryFn
        }
    }

    /// Short symbol for tooltips ("right ⌘", "fn").
    var symbol: String {
        switch self {
        case .rightCommand: return "⌘"
        case .fn: return "fn"
        }
    }
}
