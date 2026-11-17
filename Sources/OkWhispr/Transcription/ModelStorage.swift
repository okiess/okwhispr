import Foundation
import AppKit

/// Local, self-contained view over the on-disk model cache.
///
/// The `CohereTranscribeASR` library downloads the MLX model files into
/// `~/Library/Caches/qwen3-speech/` on first use. This type mirrors that layout
/// (including the two overridable cache-directory env vars and the legacy flat
/// layout) so the UI can show where the models live and delete them. Deletion is
/// reversible: the files are moved to the Trash and the model is re-downloaded on
/// next use. No network or telemetry is involved.
@MainActor
final class ModelStorage: ObservableObject {
    static let shared = ModelStorage()

    /// The downloaded model directories, refreshed from disk on demand.
    @Published var models: [ModelInfo] = []

    private init() {}

    /// The cache base, resolved exactly like the library: env override wins,
    /// otherwise `~/.cachesDirectory`, with `qwen3-speech` appended.
    var baseDirectory: URL { Self.resolveBase() }

    // MARK: - Actions

    /// Re-reads the model directories from disk and updates `models`.
    func refresh() async {
        let base = Self.resolveBase()
        let found = await Task.detached(priority: .userInitiated) {
            ModelStorage.enumerate(base: base)
        }.value
        models = found
    }

    /// Moves the given model directories to the Trash. Re-throwing on failure.
    func trash(_ infos: [ModelInfo]) async throws {
        for info in infos {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        var result: NSURL?
                        try FileManager.default.trashItem(at: info.url, resultingItemURL: &result)
                        AppLogger.log("trashed model at \(info.url.path)")
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Opens the cache base (or a specific model folder) in Finder.
    func revealInFinder(_ info: ModelInfo?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        if let info {
            NSWorkspace.shared.activateFileViewerSelecting([info.url])
        } else {
            NSWorkspace.shared.open(baseDirectory)
        }
    }

    // MARK: - Layout resolution

    /// Mirrors `HuggingFaceDownloader.resolveBaseCacheDir(cacheDirName: "qwen3-speech")`.
    nonisolated static func resolveBase() -> URL {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let root: URL
        if let override = env["QWEN3_CACHE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else if let override = env["QWEN3_ASR_CACHE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            root = caches ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        }
        return root.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    /// Discovers the model directories that actually hold weights.
    nonisolated static func enumerate(base: URL) -> [ModelInfo] {
        let fm = FileManager.default
        var found: [ModelInfo] = []
        var seen = Set<String>()

        func add(_ url: URL, layout: ModelLayout) {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            guard isModelDirectory(url) else { return }
            let variant = variantFor(url)
            found.append(
                ModelInfo(
                    id: key,
                    url: url,
                    variant: variant,
                    layout: layout,
                    sizeBytes: sizeOfDirectory(url),
                    title: variant.map { L.variantName($0) } ?? url.lastPathComponent
                )
            )
        }

        // Hub-style layout: base/models/<owner>/<model>
        let modelsDir = base.appendingPathComponent("models", isDirectory: true)
        if let owners = try? fm.contentsOfDirectory(
            at: modelsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            for owner in owners where fm.fileExists(atPath: owner.path) {
                if let sub = try? fm.contentsOfDirectory(
                    at: owner, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) {
                    for model in sub { add(model, layout: .hub) }
                }
            }
        }

        // Legacy flat layout: base/<sanitizedCacheKey> (skip the "models" subtree)
        if let flat = try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            for dir in flat where dir.lastPathComponent != "models" {
                add(dir, layout: .legacy)
            }
        }

        return found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Helpers

    nonisolated private static let cacheDirectoryName = "qwen3-speech"
    nonisolated private static let weightExtensions: Set<String> = ["safetensors", "mlmodelc", "mlpackage"]

    /// A directory counts as a model when it holds a weight file (or a shard
    /// index), mirroring the library's "weights exist" check.
    nonisolated private static func isModelDirectory(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        guard let contents = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return contents.contains {
            weightExtensions.contains($0.pathExtension) || $0.lastPathComponent == "model.safetensors.index.json"
        }
    }

    /// Maps a model directory to a variant by matching its published model ID.
    nonisolated private static func variantFor(_ url: URL) -> CohereVariant? {
        let name = url.lastPathComponent
        for variant in CohereVariant.allCases {
            let modelId = CohereTranscriber.modelId(for: variant)
            let modelPart = modelId.split(separator: "/").last.map(String.init) ?? modelId
            if name == modelPart || name == sanitizedCacheKey(modelId) {
                return variant
            }
        }
        return nil
    }

    /// Mirrors `HuggingFaceDownloader.sanitizedCacheKey`.
    nonisolated private static func sanitizedCacheKey(_ modelId: String) -> String {
        let replaced = modelId.replacingOccurrences(of: "/", with: "_")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var scalars = [UnicodeScalar]()
        scalars.reserveCapacity(replaced.unicodeScalars.count)
        for scalar in replaced.unicodeScalars {
            scalars.append(allowed.contains(scalar) ? scalar : "_")
        }
        var cleaned = String(String.UnicodeScalarView(scalars))
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            cleaned = "model"
        }
        return cleaned
    }

    /// Total on-disk size of a directory tree, preferring allocated size.
    nonisolated private static func sizeOfDirectory(_ url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) {
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: keys)
                total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// A human-readable size, e.g. "1.6 GB".
    nonisolated static func humanSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    /// Renders a path with a `~` home prefix for compact display.
    nonisolated static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path == home { return "~" }
        if url.path.hasPrefix(home + "/") {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }
}

extension ModelStorage {
    /// How a model directory was found, for display purposes.
    enum ModelLayout: Sendable {
        case hub
        case legacy
    }
}

/// One downloaded model directory, discovered on disk.
struct ModelInfo: Identifiable, Equatable, Sendable {
    var id: String
    var url: URL
    var variant: CohereVariant?
    var layout: ModelStorage.ModelLayout
    var sizeBytes: Int64
    var title: String
}
