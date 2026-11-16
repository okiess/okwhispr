import Foundation

/// Writes mono Float32 PCM to a 16-bit PCM WAV file. Used by the Apple on-device
/// engine, which reads a file URL. The MLX engine consumes the [Float] directly.
enum WAVWriter {
    static func writeMonoFloat(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        let bitDepth = 16
        let channels = 1
        let sampleCount = samples.count
        let bytesPerSample = bitDepth / 8
        let dataSize = Int32(sampleCount * bytesPerSample)
        let sampleRate32 = Int32(sampleRate)
        let byteRate = sampleRate32 * Int32(channels) * Int32(bytesPerSample)
        let blockAlign = Int16(channels * bytesPerSample)

        var data = Data()
        func appendLE32(_ value: Int32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func appendLE16(_ value: Int16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func appendASCII(_ s: String) {
            data.append(contentsOf: Array(s.utf8))
        }

        // RIFF header
        appendASCII("RIFF")
        appendLE32(36 + dataSize)                 // total data size
        appendASCII("WAVE")
        // fmt chunk
        appendASCII("fmt ")
        appendLE32(16)                            // subchunk1 size (PCM)
        appendLE16(1)                             // audio format = PCM
        appendLE16(Int16(channels))
        appendLE32(sampleRate32)
        appendLE32(byteRate)
        appendLE16(blockAlign)
        appendLE16(Int16(bitDepth))
        // data chunk
        appendASCII("data")
        appendLE32(dataSize)

        // 16-bit little-endian samples, clamped to [-1, 1].
        for s in samples {
            let clamped = max(-1.0, min(1.0, Double(s)))
            appendLE16(Int16(clamped * 32767.0))
        }

        try data.write(to: url, options: .atomic)
    }
}
