import Foundation
import Observation
import Hub

// On-disk model storage + streaming Hugging Face Hub downloads.
//
// Layout mirrors HubApi's snapshot convention so MLXLMCommon can load
// straight from the snapshot directory:
//
//   <Application Support>/TalariaLocalModels/models/<org>/<name>/…
//
// The tree is excluded from iCloud/iTunes backup (multi-GB and always
// re-downloadable) and is fully deletable per model from Settings.

// MARK: - Store

/// Filesystem bookkeeping for downloaded models. Value type; safe to share
/// between the download manager (main actor) and LocalModelProvider (actor).
public struct LocalModelStore: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory ?? Self.defaultBaseDirectory
    }

    /// Application Support/TalariaLocalModels — not Documents (models are not
    /// user documents) and never backed up.
    public static var defaultBaseDirectory: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "TalariaLocalModels", directoryHint: .isDirectory)
    }

    /// Hub client rooted at our storage tree.
    var hub: HubApi { HubApi(downloadBase: baseDirectory) }

    /// Files worth fetching from a hub repo: weights + configs/tokenizers.
    /// (mlx-community conversions ship safetensors + JSON; `*.model` /
    /// `*.txt` cover sentencepiece/BPE tokenizers on other repos.)
    static let snapshotGlobs = ["*.safetensors", "*.json", "*.model", "*.txt"]

    /// Where a repo's snapshot lives (whether or not it is downloaded yet).
    public func snapshotDirectory(for hubID: String) -> URL {
        hub.localRepoLocation(Hub.Repo(id: hubID))
    }

    /// A snapshot counts as downloaded when the weights and the model config
    /// are both present (a cancelled download can leave partial trees).
    public func isDownloaded(_ hubID: String) -> Bool {
        snapshotDirectoryIfDownloaded(for: hubID) != nil
    }

    public func snapshotDirectoryIfDownloaded(for hubID: String) -> URL? {
        let dir = snapshotDirectory(for: hubID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appending(path: "config.json").path),
              let names = try? fm.contentsOfDirectory(atPath: dir.path),
              names.contains(where: { $0.hasSuffix(".safetensors") })
        else { return nil }
        return dir
    }

    /// Hub ids of every complete snapshot on disk — catalog entries first
    /// (in catalog order), then any side-loaded repos alphabetically.
    public func downloadedModelIDs() -> [String] {
        var ids = ModelCatalog.all.map(\.hubID).filter(isDownloaded)
        let fm = FileManager.default
        let modelsRoot = baseDirectory.appending(path: "models", directoryHint: .isDirectory)
        if let orgs = try? fm.contentsOfDirectory(
            at: modelsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles) {
            var extra: [String] = []
            for org in orgs {
                guard let repos = try? fm.contentsOfDirectory(
                    at: org, includingPropertiesForKeys: [.isDirectoryKey],
                    options: .skipsHiddenFiles) else { continue }
                for repo in repos {
                    let id = "\(org.lastPathComponent)/\(repo.lastPathComponent)"
                    if !ids.contains(id), isDownloaded(id) { extra.append(id) }
                }
            }
            ids += extra.sorted()
        }
        return ids
    }

    /// Bytes on disk for one model's snapshot (0 when absent).
    public func sizeOnDisk(_ hubID: String) -> Int64 {
        directorySize(snapshotDirectory(for: hubID))
    }

    /// Bytes on disk for the whole model tree.
    public func totalSizeOnDisk() -> Int64 {
        directorySize(baseDirectory)
    }

    /// Delete one model's snapshot (partial or complete).
    public func delete(_ hubID: String) throws {
        let dir = snapshotDirectory(for: hubID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Streaming snapshot download. `progress` is called off the main actor
    /// with overall fraction completed; cancel via task cancellation.
    /// Re-running after a cancel/failure re-fetches whatever is missing.
    public func download(_ hubID: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try ensureBaseDirectory()
        return try await hub.snapshot(
            from: Hub.Repo(id: hubID),
            matching: Self.snapshotGlobs
        ) { p in
            progress(p.fractionCompleted)
        }
    }

    /// Create the storage root and exclude it from backup.
    func ensureBaseDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: baseDirectory.path) {
            try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
        var url = baseDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func directorySize(_ root: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - Download manager

/// Observable download state machine for the model-management UI. One
/// download per model at a time; progress is throttled so SwiftUI is not
/// invalidated hundreds of times per second.
@MainActor @Observable
public final class ModelDownloadManager {
    public enum DownloadState: Equatable, Sendable {
        case notDownloaded
        /// Overall fraction 0…1 across all files in the snapshot.
        case downloading(fraction: Double)
        case downloaded
        /// Human-readable failure; retry by calling `download` again.
        case failed(String)
    }

    public let store: LocalModelStore
    public private(set) var states: [String: DownloadState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(store: LocalModelStore = LocalModelStore()) {
        self.store = store
        refresh()
    }

    /// Re-scan the disk (call on appear and after external deletions).
    public func refresh() {
        for spec in ModelCatalog.all where tasks[spec.hubID] == nil {
            states[spec.hubID] = store.isDownloaded(spec.hubID) ? .downloaded : .notDownloaded
        }
    }

    public func state(for hubID: String) -> DownloadState {
        states[hubID] ?? .notDownloaded
    }

    public var anyDownloadRunning: Bool { !tasks.isEmpty }

    /// Start (or ignore, if already running) a download of `spec`.
    public func download(_ spec: LocalModelSpec) {
        let hubID = spec.hubID
        guard tasks[hubID] == nil else { return }
        if case .downloaded = state(for: hubID) { return }

        states[hubID] = .downloading(fraction: 0)
        let store = self.store
        let throttle = ProgressThrottle()

        tasks[hubID] = Task { [weak self] in
            do {
                _ = try await store.download(hubID) { fraction in
                    guard throttle.shouldReport(fraction) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.tasks[hubID] != nil else { return }
                        self.states[hubID] = .downloading(fraction: fraction)
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.tasks[hubID] = nil
                    // Trust the disk, not the network: verify the snapshot.
                    self.states[hubID] = store.isDownloaded(hubID)
                        ? .downloaded
                        : .failed("download finished incomplete — try again")
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.tasks[hubID] = nil
                    self.states[hubID] = store.isDownloaded(hubID) ? .downloaded : .notDownloaded
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.tasks[hubID] = nil
                    self.states[hubID] = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Cancel an in-flight download; already-fetched files stay on disk and
    /// a later `download` resumes from them.
    public func cancelDownload(for hubID: String) {
        tasks[hubID]?.cancel()
    }

    /// Delete a model from disk (cancels any in-flight download first).
    public func delete(_ hubID: String) throws {
        tasks[hubID]?.cancel()
        tasks[hubID] = nil
        try store.delete(hubID)
        states[hubID] = .notDownloaded
    }
}

/// Rate-limits progress callbacks (≥1% delta or ≥0.2 s apart, plus the
/// terminal 100%). Class + lock because Hub calls the handler from
/// URLSession's delegate queue.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFraction = -1.0
    private var lastTime = Date.distantPast

    func shouldReport(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if fraction >= 1.0 || fraction - lastFraction >= 0.01
            || now.timeIntervalSince(lastTime) >= 0.2 {
            lastFraction = fraction
            lastTime = now
            return true
        }
        return false
    }
}
