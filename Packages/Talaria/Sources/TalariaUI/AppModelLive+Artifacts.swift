import Foundation
import Observation
import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Artifacts, for real: fetching the bytes an agent produced and putting them
// in front of you.
//
// The INDEX is still derived — there is no artifacts RPC anywhere in the
// gateway, so AppModelLive+Feeds.swift scans recent transcripts for produced
// files, images and links exactly the way desktop's artifact-utils.ts does.
// What this file adds is the half desktop has and Talaria did not: the bytes.
//
// Every produced file lives on the GATEWAY host, not the phone, so reading one
// is an authenticated REST fetch. Three doors, tried narrowest-first, all under
// the same `/api/*` auth gate:
//
//  · `GET /api/media?path=`          (web_server.py:2227-2258) — image
//    extensions only, ≤25 MB, and only under the gateway's own media roots
//    (`~/.hermes/{images,screenshots,cache}`). This is where the agent's image
//    tools write, and it is the door most likely to survive a locked-down
//    gateway, so images try it first.
//  · `GET /api/fs/read-text?path=`   (web_server.py:2872-2894) — UTF-8 preview
//    with a language hint and a `truncated` flag (512 KB preview window).
//  · `GET /api/fs/read-data-url?path=` (web_server.py:2943-2955) — anything
//    else, ≤16 MB, as a base64 data URL.
//    `GET /api/files/read?path=` (2586-2617) is the last fallback: same shape,
//    but subject to the managed-files root policy, so it can refuse paths the
//    fs door allows (and vice-versa on a hosted gateway).
//
// Deliberate non-fetch: an http(s) artifact is NEVER fetched while the grid
// scrolls. A link the agent found is a third-party host, and a phone should not
// silently talk to one because a card came into view. The detail sheet fetches
// an image URL only after you open it — that is the user asking — and a plain
// link is offered as "open in the browser" rather than inlined.

// MARK: - What a fetch produced

/// One artifact body, as far as the phone could get it.
public enum ArtifactBody: Sendable {
    /// Decodable image bytes (from a gateway read or an inline data: URL).
    case image(Data)
    /// A UTF-8 preview. `truncated` is the gateway's own flag: it serves at
    /// most 512 KB of a text file and says so rather than lying about length.
    case text(String, language: String, truncated: Bool, bytes: Int)
    /// Bytes we can hand to the share sheet but cannot render inline.
    case binary(Data, mime: String)
    /// A protected local copy downloaded with source-qualified header auth.
    case media(URL)
    case unavailable(ArtifactUnavailable)

    /// The bytes, when there are any — what export/share needs.
    var data: Data? {
        switch self {
        case .image(let data): return data
        case .binary(let data, _): return data
        case .text(let text, _, _, _): return text.data(using: .utf8)
        case .media, .unavailable: return nil
        }
    }

    var byteCost: Int {
        switch self {
        case .image(let data): return data.count
        case .binary(let data, _): return data.count
        case .text(let text, _, _, _): return text.utf8.count
        case .media(let url):
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        case .unavailable: return 0
        }
    }
}

/// Immutable authority for one artifact fetch. The same path can exist on two
/// gateways and in two sessions on one gateway; all four fields therefore
/// participate in caching and completion fencing.
struct ArtifactProvenance: Hashable, Sendable {
    var gatewayID: String
    var profile: String
    var sessionID: String
    var value: String

    var cacheKey: String {
        [gatewayID, profile, sessionID, value].joined(separator: "\u{1f}")
    }
}

/// Why an artifact could not be shown, in terms the copy pack can theme. Each
/// case is a real gateway answer, not a generic failure — a file that moved
/// reads differently from one the gateway refuses to serve.
public enum ArtifactUnavailable: Error, Sendable, Equatable {
    /// Demo mode, or no gateway attached.
    case notLive
    /// Live, but this gateway has no reachable HTTP credential.
    case noREST
    /// An http(s) artifact: it is a link, and links are opened, not inlined.
    case remoteLink
    /// 413 — past the gateway's serve ceiling (25 MB media / 16 MB data URL).
    case tooLarge
    /// 404 — the agent wrote it, then it moved or was cleaned up.
    case missing
    /// 403/415 — outside the gateway's serve roots, or a type it won't serve.
    case refused
    /// Anything else, carrying the gateway's own words.
    case unreadable(String)
}

// MARK: - Cache

/// Fetched artifact bodies and their thumbnails, held for the life of the app
/// run. Cache keys carry the gateway they came from, like `ProfileAssetStore`:
/// two gateways can both have `/tmp/out.png` and they are not the same file.
///
/// Bounded by bytes, not by count — one 12 MB render and two hundred 3 KB text
/// files are very different tenants. Eviction is least-recently-read.
@MainActor
@Observable
public final class ArtifactStore {
    public static let shared = ArtifactStore()

    private var bodies: [String: ArtifactBody] = [:]
    /// Downscaled grid thumbs, derived once per image instead of on every
    /// scroll pass.
    private var thumbs: [String: Image] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var cost: [String: Int] = [:]
    @ObservationIgnored private var bytes = 0
    struct FetchLease: Sendable {
        var sourceKey: String
        var fetchID: UUID
        var waiterID: UUID
        var task: Task<ArtifactBody, Never>
    }

    private struct Inflight {
        var id: UUID
        var task: Task<ArtifactBody, Never>
        var waiters: Set<UUID>
    }

    @ObservationIgnored private var tasks: [String: Inflight] = [:]

    /// Resident ceiling. Generous enough to keep a screenful of renders warm,
    /// small enough that a gallery sweep cannot push the app into a jetsam.
    static let budget = 40 * 1_024 * 1_024
    /// Never pull a body bigger than this, whatever the gateway would serve.
    static let maxFetchBytes = 12 * 1_024 * 1_024
    /// Longest edge of a grid thumbnail, in points × 3 (Retina headroom).
    static let thumbEdge: CGFloat = 260

    func body(for source: ArtifactProvenance) -> ArtifactBody? {
        let id = source.cacheKey
        guard let body = bodies[id] else { return nil }
        touch(id)
        return body
    }

    func thumbnail(for source: ArtifactProvenance) -> Image? { thumbs[source.cacheKey] }

    func acquire(for source: ArtifactProvenance,
                 make: () -> Task<ArtifactBody, Never>) -> FetchLease {
        let key = source.cacheKey
        let waiter = UUID()
        if var inflight = tasks[key] {
            inflight.waiters.insert(waiter)
            tasks[key] = inflight
            return FetchLease(sourceKey: key, fetchID: inflight.id,
                              waiterID: waiter, task: inflight.task)
        }
        let task = make()
        let fetchID = UUID()
        tasks[key] = Inflight(id: fetchID, task: task, waiters: [waiter])
        return FetchLease(sourceKey: key, fetchID: fetchID, waiterID: waiter, task: task)
    }

    func inflightWaiterCount(for source: ArtifactProvenance) -> Int {
        tasks[source.cacheKey]?.waiters.count ?? 0
    }

    func release(_ lease: FetchLease, cancelIfLast: Bool) {
        guard var inflight = tasks[lease.sourceKey], inflight.id == lease.fetchID,
              inflight.waiters.remove(lease.waiterID) != nil else { return }
        if inflight.waiters.isEmpty, cancelIfLast {
            tasks[lease.sourceKey] = nil
            inflight.task.cancel()
        } else {
            tasks[lease.sourceKey] = inflight
        }
    }

    @discardableResult
    func finish(_ body: ArtifactBody, lease: FetchLease,
                for source: ArtifactProvenance) -> Bool {
        let id = source.cacheKey
        guard let inflight = tasks[id], inflight.id == lease.fetchID else {
            if !Self.sameOwnedFile(body, bodies[id]) { Self.removeOwnedFile(body) }
            return false
        }
        tasks[id] = nil
        if let prior = bodies[id] {
            Self.removeOwnedFile(prior)
            bytes -= cost[id] ?? 0
        }
        bodies[id] = body
        cost[id] = body.byteCost
        bytes += body.byteCost
        touch(id)
        if case .image(let data) = body, thumbs[id] == nil {
            thumbs[id] = ArtifactImaging.thumbnail(data, maxDimension: Self.thumbEdge)
        }
        evict()
        return true
    }

    /// Drop everything for the current gateway (sign-out, gateway swap). Keys
    /// are gateway-scoped so this is belt-and-braces, but a stale render of
    /// another machine's file is exactly the kind of thing that must not linger.
    public func flush() {
        for inflight in tasks.values { inflight.task.cancel() }
        for body in bodies.values { Self.removeOwnedFile(body) }
        tasks.removeAll()
        bodies.removeAll(); thumbs.removeAll(); cost.removeAll(); order.removeAll()
        bytes = 0
    }

    private func touch(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
    }

    private func evict() {
        while bytes > Self.budget, let oldest = order.first {
            order.removeFirst()
            bytes -= cost.removeValue(forKey: oldest) ?? 0
            if let body = bodies[oldest] { Self.removeOwnedFile(body) }
            bodies[oldest] = nil
            thumbs[oldest] = nil
        }
    }

    private static func removeOwnedFile(_ body: ArtifactBody) {
        guard case .media(let url) = body,
              url.path.contains("/talaria-media-") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func sameOwnedFile(_ lhs: ArtifactBody, _ rhs: ArtifactBody?) -> Bool {
        guard case .media(let left) = lhs, case .media(let right) = rhs else { return false }
        return left == right
    }
}

// MARK: - Image helpers

@MainActor
enum ArtifactImaging {
    /// A grid-sized thumbnail, alpha intact. Deliberately NOT the portrait
    /// path's JPEG re-encode: a generated PNG with transparency flattens onto
    /// black there, which on a light theme reads as a broken render.
    static func thumbnail(_ data: Data, maxDimension: CGFloat) -> Image? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return Image(uiImage: image) }
        let ratio = maxDimension / longest
        let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return Image(uiImage: resized)
        #else
        // AppKit scales on draw, so the full-size image is already the thumb.
        return ProfileAssetStore.image(from: data)
        #endif
    }

    static func full(_ data: Data) -> Image? { ProfileAssetStore.image(from: data) }
}

// MARK: - Model surface

public extension AppModel {

    /// The path or URL a card was extracted from. `Artifact` is a shared model
    /// with no location field, so the value rides inside the id
    /// (`<unix>|<session>|<value>`, AppModelLive+Feeds.swift).
    func artifactLocation(_ artifact: Artifact) -> String {
        Self.artifactValue(artifact.id)
    }

    internal func artifactProvenance(_ artifact: Artifact) -> ArtifactProvenance? {
        let value = artifactLocation(artifact)
        if let ref = FeedsRuntime.shared.artifactSessions[artifact.id] {
            let profile = GatewayBotRoute(qualifiedID: ref.botID)?.profile ?? ref.botID
            guard !ref.gatewayID.isEmpty, !profile.isEmpty, !ref.storedID.isEmpty else {
                return nil
            }
            return ArtifactProvenance(gatewayID: ref.gatewayID, profile: profile,
                                      sessionID: ref.storedID, value: value)
        }
        // Public URLs and inline data do not consume gateway authority. Keep
        // their cache identity tied to the producing bot/session anyway.
        if value.hasPrefix("http://") || value.hasPrefix("https://")
            || value.hasPrefix("data:") || mode == .demo {
            let parts = artifact.id.split(separator: "|", maxSplits: 2,
                                          omittingEmptySubsequences: false)
            let session = parts.count > 1 ? String(parts[1]) : artifact.id
            return ArtifactProvenance(gatewayID: mode == .demo ? "demo" : "public",
                                      profile: artifact.botID, sessionID: session, value: value)
        }
        // A gateway-hosted path without its recorded SessionRef must never
        // silently fall back to whichever gateway happens to be primary.
        return nil
    }

    /// Cached body, if one has landed. Views read this in `body` so a fetch
    /// completing repaints them.
    func artifactBody(_ artifact: Artifact) -> ArtifactBody? {
        guard let source = artifactProvenance(artifact) else { return nil }
        return ArtifactStore.shared.body(for: source)
    }

    /// The grid thumbnail for an image artifact, once fetched.
    func artifactThumbnail(_ artifact: Artifact) -> Image? {
        guard let source = artifactProvenance(artifact) else { return nil }
        return ArtifactStore.shared.thumbnail(for: source)
    }

    /// Fetch (or return) an artifact's bytes.
    ///
    /// `allowRemote` stays off for the grid: a card scrolling into view must
    /// never make the phone reach a third-party host. The detail sheet turns it
    /// on for image URLs, because opening one is the user asking for it.
    ///
    /// Deduped — a second caller awaits the first fetch rather than starting
    /// its own, so a card and its detail sheet cost one request.
    @discardableResult
    func loadArtifact(_ artifact: Artifact, allowRemote: Bool = false) async -> ArtifactBody {
        guard let source = artifactProvenance(artifact) else { return .unavailable(.noREST) }
        let store = ArtifactStore.shared
        if let cached = store.body(for: source) { return cached }
        let kind = artifact.kind
        let sourceGeneration = LiveRuntime.shared.generation
        let lease = store.acquire(for: source) {
            Task { @MainActor [weak self] in
                guard let self else { return ArtifactBody.unavailable(.notLive) }
                return await self.fetchArtifactBody(source: source, kind: kind,
                                                    allowRemote: allowRemote)
            }
        }
        let body = await withTaskCancellationHandler {
            await lease.task.value
        } onCancel: {
            Task { @MainActor in store.release(lease, cancelIfLast: true) }
        }
        if Task.isCancelled {
            store.release(lease, cancelIfLast: true)
            if case .media = body { /* finish() owns stale-file cleanup below */ }
            _ = store.finish(body, lease: lease, for: source)
            return .unavailable(.notLive)
        }
        guard artifactProvenance(artifact) == source,
              (source.gatewayID == "public" || source.gatewayID == "demo"
               || LiveRuntime.shared.generation == sourceGeneration) else {
            store.release(lease, cancelIfLast: true)
            _ = store.finish(body, lease: lease, for: source)
            return .unavailable(.notLive)
        }
        let published = store.finish(body, lease: lease, for: source)
        return published ? body : (store.body(for: source) ?? .unavailable(.notLive))
    }

    /// Grid-side prefetch: gateway-hosted images only, and only when there is a
    /// credential to fetch with. Anything else stays a placeholder until asked
    /// for, which is what keeps the tab from becoming a network storm.
    func prefetchArtifactThumbnail(_ artifact: Artifact) {
        guard mode == .live, !isOffline, artifact.kind == .image else { return }
        guard let source = artifactProvenance(artifact) else { return }
        let value = source.value
        guard !value.hasPrefix("http://"), !value.hasPrefix("https://") else { return }
        let store = ArtifactStore.shared
        guard store.body(for: source) == nil else { return }
        Task { @MainActor in await self.loadArtifact(artifact) }
    }

    /// Put the artifact's full path or URL on the clipboard. Pasting a gateway
    /// path back into the composer ("summarise ~/out/report.md") is one of the
    /// few genuinely useful things to do with a file artifact on a phone.
    func copyArtifactLocation(_ artifact: Artifact) {
        let value = artifactLocation(artifact)
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }

    /// Materialize an artifact as a file on the phone so the share sheet (or,
    /// on the Mac, anything that takes a file URL) can take it. Returns the
    /// temp URL, or the reason there is nothing to hand over.
    func artifactShareFile(_ artifact: Artifact) async -> Result<URL, ArtifactUnavailable> {
        var body = artifactBody(artifact)
        if body == nil || body?.data == nil {
            body = await loadArtifact(artifact, allowRemote: true)
        }
        guard let body else { return .failure(.unreadable("")) }
        if case .unavailable(let why) = body { return .failure(why) }
        if case .media(let url) = body {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .failure(.missing)
            }
            return .success(url)
        }
        guard let data = body.data else { return .failure(.unreadable("")) }
        let name = Self.shareFilename(for: artifact, location: artifactLocation(artifact),
                                      body: body)
        do {
            try Task.checkCancellation()
            let url = try TalariaExportBox.write(data, named: name)
            if Task.isCancelled {
                TalariaExportBox.removeOwned(url)
                return .failure(.unreadable("Cancelled"))
            }
            return .success(url)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    /// A filesystem-safe name for the shared copy, keeping the agent's own
    /// filename wherever it gave one. An inline `data:` image has no filename
    /// at all — its "last path component" is the whole base64 payload — so it
    /// is named from its media type instead.
    static func shareFilename(for artifact: Artifact, location: String,
                              body: ArtifactBody) -> String {
        if location.hasPrefix("data:") {
            let subtype = GatewayREST.mime(ofDataURL: location)
                .split(separator: "/").last.map(String.init) ?? "png"
            return "\(artifact.botID)-image.\(subtype.prefix(5))"
        }
        let raw = ArtifactScan.label(of: location)
        let cleaned = raw.map { $0.isLetter || $0.isNumber || "._- ".contains($0) ? $0 : "-" }
        var name = String(cleaned).trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "." { name = "artifact-\(artifact.botID)" }
        name = String(name.prefix(80))
        // A produced file with no extension still needs one, or iOS has no idea
        // what to offer in the share sheet.
        if !name.contains(".") {
            switch body {
            case .text: name += ".txt"
            case .image: name += ".png"
            case .media: name += ".mp4"
            case .binary, .unavailable: name += ".bin"
            }
        }
        // The gateway serves at most 512 KB of a text file. A copy that is only
        // the head of one has to say so in its own name — otherwise the phone
        // hands someone a truncated report that looks whole.
        if case .text(_, _, true, _) = body, let dot = name.lastIndex(of: ".") {
            name.insert(contentsOf: "-partial", at: dot)
        }
        return name
    }

    // MARK: - Fetch

    private func fetchArtifactBody(source: ArtifactProvenance, kind: ArtifactKind,
                                   allowRemote: Bool) async -> ArtifactBody {
        let value = source.value
        // Inline data: URLs are already the bytes — an image.generate result
        // pasted into the transcript never needs a round trip.
        if value.hasPrefix("data:") {
            return Self.boundedArtifactDataURL(value)
        }

        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            guard kind == .image, allowRemote, let url = URL(string: value) else {
                return .unavailable(.remoteLink)
            }
            return await Self.fetchRemoteImage(url)
        }

        guard mode == .live else { return .unavailable(.notLive) }
        guard let (base, credential) = gatewayRESTContext(gatewayID: source.gatewayID) else {
            return .unavailable(.noREST)
        }

        let path = Self.gatewayPath(value)
        let ext = (ArtifactScan.ext(of: value) ?? "").lowercased()
        var last: ArtifactUnavailable = .missing

        if kind == .media {
            do {
                return .media(try await GatewayREST.downloadMedia(
                    baseURL: base, credential: credential, path: path,
                    suggestedName: ArtifactScan.label(of: value)))
            } catch {
                return .unavailable(Self.artifactFailure(error))
            }
        }

        if kind == .image {
            do {
                let dataURL = try await GatewayREST.mediaDataURL(baseURL: base,
                                                                 credential: credential, path: path)
                let bounded = Self.boundedArtifactDataURL(dataURL)
                if case .image = bounded { return bounded }
                if case .unavailable(.tooLarge) = bounded { return bounded }
            } catch {
                last = Self.artifactFailure(error)
                // 403 here only means "outside the media roots" — an agent that
                // wrote into a project directory is the normal case, so the
                // general file doors below still get their turn.
            }
        }

        if kind != .image, kind != .media, Self.textExtensions.contains(ext) {
            do {
                let read = try await GatewayREST.fsText(baseURL: base, credential: credential,
                                                        path: path)
                if !read.binary {
                    return .text(read.text, language: read.language,
                                 truncated: read.truncated, bytes: read.bytes)
                }
            } catch {
                last = Self.artifactFailure(error)
            }
        }

        for door in [GatewayREST.fsDataURL, GatewayREST.managedDataURL] {
            do {
                let (dataURL, mime, size) = try await door(base, credential, path)
                guard size <= ArtifactStore.maxFetchBytes else { return .unavailable(.tooLarge) }
                guard let data = ProfileAssetStore.decode(dataURL: dataURL) else {
                    last = .unreadable("")
                    continue
                }
                guard data.count <= ArtifactStore.maxFetchBytes else {
                    return .unavailable(.tooLarge)
                }
                if kind == .image || mime.hasPrefix("image/") { return .image(data) }
                if kind == .media || mime.hasPrefix("audio/") || mime.hasPrefix("video/") {
                    return .binary(data, mime: mime)
                }
                // A file with no known text extension can still be text (a
                // LICENSE, a Dockerfile); decode before giving up on a preview.
                if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml"),
                   let text = String(data: data, encoding: .utf8) {
                    return .text(text, language: Self.language(for: ext), truncated: false,
                                 bytes: data.count)
                }
                return .binary(data, mime: mime)
            } catch {
                last = Self.artifactFailure(error)
            }
        }
        return .unavailable(last)
    }

    /// A user-opened image URL. Plain `URLSession`, no gateway credential: this
    /// is a public address the agent surfaced, and attaching the gateway's
    /// token to a third-party request would leak it.
    private static func fetchRemoteImage(_ url: URL) async -> ArtifactBody {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let limiter = ArtifactDownloadLimiter(limit: Int64(ArtifactStore.maxFetchBytes))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration, delegate: limiter,
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (temporary, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(code) else { return .unavailable(.missing) }
            if limiter.didExceedLimit { return .unavailable(.tooLarge) }
            let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= ArtifactStore.maxFetchBytes else { return .unavailable(.tooLarge) }
            let data = try Data(contentsOf: temporary, options: [.mappedIfSafe])
            guard data.count <= ArtifactStore.maxFetchBytes else { return .unavailable(.tooLarge) }
            guard ProfileAssetStore.image(from: data) != nil else {
                return .unavailable(.remoteLink)
            }
            return .image(data)
        } catch {
            if limiter.didExceedLimit { return .unavailable(.tooLarge) }
            return .unavailable(.unreadable(""))
        }
    }

    static func dataURLFitsArtifactLimit(_ value: String) -> Bool {
        guard let marker = value.range(of: "base64,") else { return false }
        let encoded = value[marker.upperBound...]
        // Base64 expands three bytes to four characters. Subtract terminal
        // padding so the boundary is exact without allocating decoded bytes.
        let padding = encoded.suffix(2).reduce(0) { $1 == "=" ? $0 + 1 : $0 }
        let upperBound = (encoded.utf8.count / 4) * 3 - padding
        return upperBound >= 0 && upperBound <= ArtifactStore.maxFetchBytes
    }

    /// Applies the local 12 MB ceiling before allocating decoded `/api/media`
    /// base64 and verifies the decoded result as a second, exact fence.
    static func boundedArtifactDataURL(_ value: String) -> ArtifactBody {
        guard dataURLFitsArtifactLimit(value) else { return .unavailable(.tooLarge) }
        guard let data = ProfileAssetStore.decode(dataURL: value) else {
            return .unavailable(.unreadable(""))
        }
        guard data.count <= ArtifactStore.maxFetchBytes else {
            return .unavailable(.tooLarge)
        }
        return .image(data)
    }

    /// `file://` URLs are how some tools report a path; the gateway's own
    /// `_fs_path` accepts them, but `/api/media` does not, so unwrap once here
    /// and every door sees the same string.
    static func gatewayPath(_ value: String) -> String {
        guard value.hasPrefix("file://") else { return value }
        return URL(string: value)?.path(percentEncoded: false)
            ?? String(value.dropFirst("file://".count))
    }

    /// HTTP status → the reason the user reads. The gateway is specific about
    /// these (404 moved, 403 outside roots, 413 over the ceiling) and a phone
    /// showing "failed" for all three throws that away.
    static func artifactFailure(_ error: Error) -> ArtifactUnavailable {
        guard let gateway = error as? GatewayError else { return .unreadable("") }
        switch gateway.code {
        case 404, 410: return .missing
        case 403, 415: return .refused
        case 413: return .tooLarge
        case ..<0: return .noREST
        default: return .unreadable(gateway.message)
        }
    }

    /// Extensions worth trying the text door for. Mirrors the gateway's own
    /// preview-language table (web_server.py:_FS_PREVIEW_LANGUAGE_BY_EXT) plus
    /// the plain-text shapes an agent writes most.
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonl", "csv", "tsv", "log", "yaml", "yml", "toml",
        "ini", "conf", "cfg", "env", "py", "swift", "ts", "tsx", "js", "jsx", "mjs", "rb", "rs",
        "go", "java", "kt", "c", "h", "cpp", "hpp", "cs", "php", "sh", "zsh", "bash", "sql",
        "html", "htm", "xml", "css", "scss", "diff", "patch", "lua", "graphql", "svg",
    ]

    /// Language label for the code viewer when the gateway did not supply one.
    static func language(for ext: String) -> String {
        switch ext {
        case "md", "markdown": return "markdown"
        case "py": return "python"
        case "ts", "tsx": return "typescript"
        case "js", "jsx", "mjs": return "javascript"
        case "yml", "yaml": return "yaml"
        case "sh", "zsh", "bash": return "shell"
        case "": return "text"
        default: return ext
        }
    }
}

// MARK: - Export scratch space

/// Where a shared copy is staged. Files are written into the app's temp
/// directory and swept on the next export — the share sheet copies what it
/// needs synchronously, so nothing has to survive the trip.
enum TalariaExportBox {
    static let folder = "talaria-share"
    /// Anything older than this from a previous share is gone.
    static let maxAge: TimeInterval = 3_600

    static func write(_ data: Data, named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: folder)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sweep(root)
        let dir = root.appending(path: "share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        #endif
        return url
    }

    static func removeOwned(_ url: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: folder)
            .standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return }
        try? FileManager.default.removeItem(at: candidate.deletingLastPathComponent())
    }

    private static func sweep(_ dir: URL) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? manager.removeItem(at: entry)
        }
    }
}

// MARK: - Share sheet

#if os(iOS)
/// The system share sheet, for handing a staged file to Files, Mail, Messages
/// or anything else that takes one. Presented inside a `.sheet`, so iPad gets
/// its popover anchoring for free.
struct TalariaShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onFinish: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items,
                                                  applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish?() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

/// An exported file, ready to present. Identifiable so it can drive
/// `.sheet(item:)` from both the artifacts detail and the sessions sheet.
struct ExportedFile: Identifiable, Equatable {
    let url: URL
    var id: String { url.path }

    func removeOwnedShareCopy() { TalariaExportBox.removeOwned(url) }
}

private final class ArtifactDownloadLimiter: NSObject, URLSessionDownloadDelegate,
                                               @unchecked Sendable {
    private let lock = NSLock()
    private var exceeded = false
    private let limit: Int64

    init(limit: Int64) { self.limit = limit }

    var didExceedLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return exceeded
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > limit || totalBytesWritten > limit else { return }
        lock.lock(); exceeded = true; lock.unlock()
        downloadTask.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

// MARK: - REST plumbing shared by this area

public extension GatewayREST {

    static let maximumMediaDownloadBytes: Int64 = 40 * 1_024 * 1_024

    static func authenticatedMediaRequest(baseURL: URL, credential: GatewayCredential,
                                          path: String) throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appending(path: "api/files/stream"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components?.url else {
            throw GatewayError(code: -9, message: "bad media URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 180)
        GatewayAuthClient(baseURL: baseURL).apply(credential: credential, to: &request)
        return request
    }

    static func downloadMedia(baseURL: URL, credential: GatewayCredential, path: String,
                              suggestedName: String) async throws -> URL {
        let request = try authenticatedMediaRequest(baseURL: baseURL, credential: credential,
                                                    path: path)
        let limiter = ArtifactDownloadLimiter(limit: maximumMediaDownloadBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: limiter,
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await withTrafficLease(baseURL: baseURL) {
                try await session.download(for: request)
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if limiter.didExceedLimit {
                throw GatewayError(code: 413, message: "Media exceeds the 40 MB mobile preview limit.")
            }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GatewayError(code: status, message: "Media download failed (HTTP \(status)).")
        }
        let expected = response.expectedContentLength
        let actual = Int64((try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard expected <= maximumMediaDownloadBytes,
              actual <= maximumMediaDownloadBytes else {
            throw GatewayError(code: 413, message: "Media exceeds the 40 MB mobile preview limit.")
        }
        try Task.checkCancellation()

        sweepArtifactMediaDownloads()
        let safe = suggestedName.map { character in
            character.isLetter || character.isNumber || "._- ".contains(character)
                ? character : "-"
        }
        let name = String(safe).trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "talaria-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: folder) } }
        let destination = folder.appending(path: name.isEmpty ? "media.bin" : String(name.prefix(100)))
        try FileManager.default.moveItem(at: temporary, to: destination)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path)
        #endif
        try Task.checkCancellation()
        completed = true
        return destination
    }

    private static func sweepArtifactMediaDownloads() {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
        guard let entries = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3_600)
        for entry in entries where entry.lastPathComponent.hasPrefix("talaria-media-") {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? manager.removeItem(at: entry)
        }
    }

    /// Acquire the same source-qualified ordinary-traffic lease used by
    /// `GatewayClient.rpc/restData`, and retain it across the complete HTTP
    /// await. Lifecycle's rename/delete and authoritative inventory calls do
    /// not use this executor: they are the explicit exclusive-fence owner.
    static func withTrafficLease<Value: Sendable>(
        baseURL: URL,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let lease = try await ProfileLifecycleTrafficAdmission.acquire(baseURL: baseURL)
        do {
            let value = try await operation()
            await lease?.release()
            return value
        } catch {
            await lease?.release()
            throw error
        }
    }

    /// One authed request against the gateway's HTTP surface, with the status
    /// code mapped onto `GatewayError` so callers can tell 403 from 404 from
    /// 413 — which is the whole difference between "refused", "gone" and "too
    /// big" in the copy the user reads.
    static func restData(baseURL: URL, credential: GatewayCredential, path: String,
                         query: [URLQueryItem] = [], method: String = "GET",
                         body: Data? = nil, timeout: TimeInterval = 30,
                         what: String) async throws -> Data {
        try await withTrafficLease(baseURL: baseURL) {
            var comps = URLComponents(url: baseURL.appending(path: path),
                                      resolvingAgainstBaseURL: false)
            if !query.isEmpty { comps?.queryItems = query }
            guard let url = comps?.url else {
                throw GatewayError(code: -9, message: "bad \(what) URL")
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            GatewayAuthClient(baseURL: baseURL).apply(credential: credential, to: &request)
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let payload = try? JSONDecoder().decode(JSONValue.self, from: data)
                let detail = payload?["detail"]?.stringValue ?? payload?["error"]?.stringValue
                throw GatewayError(code: code, message: detail ?? "\(what) failed (HTTP \(code))")
            }
            return data
        }
    }

    static func restJSON(baseURL: URL, credential: GatewayCredential, path: String,
                         query: [URLQueryItem] = [], method: String = "GET",
                         body: Data? = nil, timeout: TimeInterval = 30,
                         what: String) async throws -> JSONValue {
        let data = try await restData(baseURL: baseURL, credential: credential, path: path,
                                      query: query, method: method, body: body,
                                      timeout: timeout, what: what)
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }

    /// `GET /api/media?path=` (web_server.py:2227-2258) → `{"data_url": …}`.
    /// Image extensions only, ≤25 MB, and only under the gateway's resolved
    /// media roots — `~/.hermes/{images,screenshots,cache}`.
    static func mediaDataURL(baseURL: URL, credential: GatewayCredential,
                             path: String) async throws -> String {
        let payload = try await restJSON(baseURL: baseURL, credential: credential,
                                         path: "api/media",
                                         query: [URLQueryItem(name: "path", value: path)],
                                         what: "media")
        guard let url = payload["data_url"]?.stringValue, !url.isEmpty else {
            throw GatewayError(code: 404, message: "no media")
        }
        return url
    }

    /// `GET /api/fs/read-text?path=` (web_server.py:2872-2894) →
    /// `{binary, byteSize, language, mimeType, path, text, truncated}`. The
    /// gateway serves at most 512 KB and flags the cut itself.
    static func fsText(baseURL: URL, credential: GatewayCredential, path: String) async throws
        -> (text: String, binary: Bool, language: String, truncated: Bool, bytes: Int) {
        let payload = try await restJSON(baseURL: baseURL, credential: credential,
                                         path: "api/fs/read-text",
                                         query: [URLQueryItem(name: "path", value: path)],
                                         what: "file")
        guard let text = payload["text"]?.stringValue else {
            throw GatewayError(code: 404, message: "no text")
        }
        return (text,
                payload["binary"]?.boolValue ?? false,
                payload["language"]?.stringValue ?? "text",
                payload["truncated"]?.boolValue ?? false,
                payload["byteSize"]?.intValue ?? text.utf8.count)
    }

    /// `GET /api/fs/read-data-url?path=` (web_server.py:2943-2955) → `{dataUrl}`,
    /// ≤16 MB, any regular file. The mime rides inside the data URL.
    static func fsDataURL(_ baseURL: URL, _ credential: GatewayCredential,
                          _ path: String) async throws -> (String, String, Int) {
        let payload = try await restJSON(baseURL: baseURL, credential: credential,
                                         path: "api/fs/read-data-url",
                                         query: [URLQueryItem(name: "path", value: path)],
                                         timeout: 45, what: "file")
        guard let url = payload["dataUrl"]?.stringValue, !url.isEmpty else {
            throw GatewayError(code: 404, message: "no file")
        }
        return (url, mime(ofDataURL: url), 0)
    }

    /// `GET /api/files/read?path=` (web_server.py:2586-2617) →
    /// `{name, path, size, mime_type, data_url}`. Same job as the fs door but
    /// under the managed-files root policy, which a hosted gateway locks to one
    /// directory — so it can serve paths the fs door refuses, and vice-versa.
    static func managedDataURL(_ baseURL: URL, _ credential: GatewayCredential,
                               _ path: String) async throws -> (String, String, Int) {
        let payload = try await restJSON(baseURL: baseURL, credential: credential,
                                         path: "api/files/read",
                                         query: [URLQueryItem(name: "path", value: path)],
                                         timeout: 45, what: "file")
        guard let url = payload["data_url"]?.stringValue, !url.isEmpty else {
            throw GatewayError(code: 404, message: "no file")
        }
        return (url,
                payload["mime_type"]?.stringValue ?? mime(ofDataURL: url),
                payload["size"]?.intValue ?? 0)
    }

    /// "data:image/png;base64,…" → "image/png".
    static func mime(ofDataURL url: String) -> String {
        guard url.hasPrefix("data:"), let semi = url.firstIndex(of: ";") else {
            return "application/octet-stream"
        }
        let type = url[url.index(url.startIndex, offsetBy: 5)..<semi]
        return type.isEmpty ? "application/octet-stream" : String(type)
    }
}

// MARK: - Copy

public extension CopyPack {

    /// Why a preview is not on screen. One line, actionable where the user can
    /// act and honest where they cannot.
    func artifactUnavailable(_ t: ThemeID, _ why: ArtifactUnavailable) -> String {
        switch why {
        case .notLive:
            switch t {
            case .soft: return "Connect a gateway to open what your bots made."
            case .control: return "NO LINK — BYTES LIVE ON THE GATEWAY HOST."
            case .ink: return "The way is closed; the relic cannot be brought here."
            }
        case .noREST:
            return needsRESTNote(t)
        case .remoteLink:
            switch t {
            case .soft: return "This one lives on the web — open it in the browser."
            case .control: return "REMOTE URL — OPEN EXTERNALLY."
            case .ink: return "This lies out in the world; open it abroad."
            }
        case .tooLarge:
            switch t {
            case .soft: return "Too big to bring over the wire. Open it on the gateway host."
            case .control: return "OVER SERVE CEILING — HOST-SIDE ONLY."
            case .ink: return "Too great to carry; it must be read where it lies."
            }
        case .missing:
            switch t {
            case .soft: return "Not on the gateway any more — it was moved or cleaned up."
            case .control: return "NOT FOUND ON HOST — MOVED OR REAPED."
            case .ink: return "It is no longer where it was set down."
            }
        case .refused:
            switch t {
            case .soft: return "The gateway will not serve this file to a remote client."
            case .control: return "HOST REFUSED — OUTSIDE SERVE ROOTS."
            case .ink: return "The house will not release this one."
            }
        case .unreadable(let detail):
            if !detail.isEmpty { return detail }
            switch t {
            case .soft: return "Could not read that file."
            case .control: return "READ FAILED."
            case .ink: return "It could not be read."
            }
        }
    }

    /// Second half of the Artifacts footnote: how the bytes get here, said out
    /// loud, because "a gallery of your files" and "files fetched one at a time
    /// from the gateway over the same auth as everything else" are different
    /// claims.
    func artifactsFetchNote(_ t: ThemeID) -> String {
        switch t {
        case .soft:
            return "Previews are fetched from the gateway host on demand over its authenticated file routes, and cached on this device only. Links are never fetched — open them yourself."
        case .control:
            return "PREVIEWS PULLED ON DEMAND VIA AUTHED /API/MEDIA · /API/FS · CACHED LOCALLY. LINKS NEVER AUTO-FETCHED."
        case .ink:
            return "Each relic is fetched from the house only when you ask, and kept here alone. What lies abroad is never fetched unbidden."
        }
    }

    func artifactOpenSession(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Open the chat that made this"
        case .control: "OPEN PRODUCING SESSION"
        case .ink: "open the audience that made it"
        }
    }

    func artifactOpenLink(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Open in browser"
        case .control: "OPEN EXTERNALLY"
        case .ink: "open it abroad"
        }
    }

    func artifactCopyPath(_ t: ThemeID, kind: ArtifactKind) -> String {
        switch (kind, t) {
        case (.link, .soft): return "Copy URL"
        case (.link, .control): return "COPY URL"
        case (.link, .ink): return "copy the address"
        case (_, .soft): return "Copy path"
        case (_, .control): return "COPY PATH"
        case (_, .ink): return "copy the path"
        }
    }

    func artifactShare(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Share…"
        case .control: "EXPORT"
        case .ink: "carry a copy away"
        }
    }

    func artifactCopied(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Copied"
        case .control: "COPIED"
        case .ink: "taken down"
        }
    }

    func artifactLoading(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Fetching from the gateway…"
        case .control: "PULLING FROM HOST…"
        case .ink: "sending for it…"
        }
    }

    func artifactBinaryBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No preview for this type — share it to open it in another app."
        case .control: "NO INLINE RENDERER — EXPORT TO OPEN ELSEWHERE."
        case .ink: "It cannot be shown here; carry a copy to where it can."
        }
    }

    func artifactTruncated(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Showing the first part — the gateway serves 512 KB of a text file."
        case .control: "TRUNCATED — HOST SERVES 512 KB PREVIEW."
        case .ink: "Only the opening is shown; the house yields no more at once."
        }
    }

    /// Byte counts in the current voice ("14 KB" / "14 KB" / "14 kb").
    func artifactSize(_ t: ThemeID, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1_024, unit < units.count - 1 { value /= 1_024; unit += 1 }
        let text = value >= 100 || unit == 0 ? String(format: "%.0f", value)
                                             : String(format: "%.1f", value)
        return t == .ink ? text + " " + units[unit].lowercased() : text + " " + units[unit]
    }
}
