import CoreGraphics
import Foundation
import ImageIO

// Hermes Bot Mode pets — the petdex mascot the desktop draws on a canvas and
// the TUI draws in half-blocks. Wire shapes are the gateway's, not guesses:
//
//   tui_gateway/methods_session.py — pet.info 1546, pet.info.meta 1582,
//     pet.gallery 1710, pet.thumb 1915, pet.generate 2030, pet.hatch 2143
//   tui_gateway/server.py:8906 — `_pet_sprite_payload`, the renderer payload
//     shared by pet.info and pet.hatch
//   agent/pet/constants.py — frame geometry + the row taxonomy
//   agent/pet/state.py — activity → animation row
//
// Every geometry number rides the wire (`frameW`, `frameH`, `loopMs`,
// `stateRows`, …) so a sheet built by a newer engine still renders here; the
// engine constants are never hardcoded on this side.

// MARK: - Animation state

/// Which animation row a pet is shown in (`agent.pet.constants.PetState`).
public enum PetState: String, Sendable, CaseIterable {
    case idle, wave, run, failed, review, jump, waiting

    /// Atlas row names this state accepts, most-preferred first
    /// (`constants.STATE_ALIASES`). Hermes keeps short activity names while the
    /// current 9-row Codex atlas labels its rows `waving`/`jumping`/`running`,
    /// so the renderer has to resolve a name rather than a fixed index.
    public var rowAliases: [String] {
        switch self {
        case .idle: ["idle"]
        case .wave: ["wave", "waving"]
        case .jump: ["jump", "jumping"]
        case .run: ["run", "running"]
        case .failed: ["failed"]
        case .review: ["review"]
        case .waiting: ["waiting"]
        }
    }

    /// Mirror of `agent.pet.state.derive_pet_state`. Only one row can show at a
    /// time, so the most salient signal wins; the priority order is the
    /// engine's, kept verbatim so the phone agrees with the TUI and the desktop.
    public static func derive(busy: Bool = false, awaitingInput: Bool = false,
                              error: Bool = false, celebrate: Bool = false,
                              justCompleted: Bool = false, toolRunning: Bool = false,
                              reasoning: Bool = false) -> PetState {
        if error { return .failed }
        if celebrate { return .jump }
        if justCompleted { return .wave }
        if awaitingInput { return .waiting }
        if toolRunning { return .run }
        if reasoning { return .review }
        if busy { return .run }
        return .idle
    }
}

// MARK: - Geometry

/// The frame geometry + row taxonomy of one concrete spritesheet, exactly as
/// `_pet_sprite_payload` reports it. Cached alongside the decoded sheet so a
/// metadata-only refresh can rebuild a `Pet` without re-downloading anything.
public struct PetGeometry: Sendable, Equatable {
    public var frameWidth: Int
    public var frameHeight: Int
    /// Frames the engine steps through per state when it has no better count.
    public var framesPerState: Int
    /// Full-loop duration for one state.
    public var loopMilliseconds: Double
    /// Row names top → bottom for this sheet's shape (8-row legacy or 9-row Codex).
    public var stateRows: [String]
    /// Real, padding-trimmed frame count keyed by Hermes state name.
    public var framesByState: [String: Int]
    /// Real frame count keyed by this sheet's own row names.
    public var framesByRow: [String: Int]
    public var mime: String

    public init(_ v: JSONValue?) {
        frameWidth = v?["frameW"]?.intValue ?? 192
        frameHeight = v?["frameH"]?.intValue ?? 208
        framesPerState = v?["framesPerState"]?.intValue ?? 6
        loopMilliseconds = v?["loopMs"]?.doubleValue ?? 1100
        stateRows = v?["stateRows"]?.arrayValue?.compactMap(\.stringValue) ?? []
        framesByState = PetGeometry.counts(v?["framesByState"])
        framesByRow = PetGeometry.counts(v?["framesByRow"])
        mime = v?["mime"]?.stringValue ?? "image/png"
    }

    private static func counts(_ v: JSONValue?) -> [String: Int] {
        guard let object = v?.objectValue else { return [:] }
        return object.compactMapValues(\.intValue)
    }

    /// Aspect of one native frame — the sprite is drawn to this ratio at every size.
    public var frameAspect: CGFloat {
        guard frameHeight > 0 else { return 1 }
        return CGFloat(frameWidth) / CGFloat(frameHeight)
    }

    /// Row index for *state*, resolving the alias chain against this sheet's
    /// own taxonomy. Falls back to the idle row like `state_row_index` does.
    public func rowIndex(for state: PetState) -> Int {
        for alias in state.rowAliases {
            if let index = stateRows.firstIndex(of: alias) { return index }
        }
        return 0
    }

    public func rowName(for state: PetState) -> String {
        let index = rowIndex(for: state)
        return index < stateRows.count ? stateRows[index] : state.rawValue
    }

    /// Which row to draw for *state*, and how many of its frames are real.
    ///
    /// Mirrors the desktop canvas's `resolve()`: `framesByState` is the trimmed
    /// truth, and a state whose row has **no** real frames falls back to the
    /// idle row rather than animating that row's transparent padding. A decode
    /// hiccup server-side ships `{}` for both maps rather than failing the
    /// call, which is why `framesPerState` backs the whole thing.
    public func resolve(_ state: PetState) -> (row: String, count: Int) {
        let real = framesByState[state.rawValue] ?? framesPerState
        if real > 0 { return (rowName(for: state), real) }
        let idle = framesByState[PetState.idle.rawValue] ?? framesPerState
        return (rowName(for: .idle), max(1, idle))
    }

    /// Real frame count for a concrete atlas row name (`running-left`,
    /// `waving`, …). 0 means the row is empty — callers cycling a sheet's own
    /// rows filter on this so they never land on blank padding.
    public func frameCount(row: String) -> Int {
        if let n = framesByRow[row], n > 0 { return n }
        if let n = framesByState[row], n > 0 { return n }
        return 0
    }
}

// MARK: - The pet itself

/// The active pet's identity + geometry. Deliberately carries no pixels: the
/// spritesheet is multi-MB and lives in `PetSpriteSheet`, cached by revision.
public struct Pet: Sendable, Equatable, Identifiable {
    public var id: String { slug }
    public var slug: String
    public var displayName: String
    /// `"<mtime_ns>:<size>"` of the sheet file — the send-once cache key.
    public var revision: String
    /// `display.pet.scale`: the master size scalar, multiplying native frame
    /// pixels on every surface (`constants.DEFAULT_SCALE` = 0.33).
    public var scale: Double
    public var geometry: PetGeometry

    public init(slug: String, displayName: String, revision: String,
                scale: Double, geometry: PetGeometry) {
        self.slug = slug
        self.displayName = displayName
        self.revision = revision
        self.scale = scale
        self.geometry = geometry
    }

    /// Engine scale bounds (`constants.MIN_SCALE` / `MAX_SCALE`); `pet.scale`
    /// clamps server-side, and the slider must not offer what it would reject.
    public static let minScale = 0.1
    public static let maxScale = 3.0
    public static let defaultScale = 0.33

    public static func clampScale(_ value: Double) -> Double {
        min(maxScale, max(minScale, value))
    }
}

/// One `pet.info` answer. `enabled == false` is a normal reply — no pet
/// configured, no sprite engine, or the RPC failed open — never an error.
public struct PetInfoPayload: Sendable {
    public var enabled: Bool
    public var pet: Pet?
    /// Base64 sheet bytes; absent when the caller's `knownRevision` matched.
    public var spritesheetBase64: String?
    /// The gateway confirming our cached sheet is still current.
    public var spritesheetUnchanged: Bool

    public init(_ v: JSONValue?) {
        enabled = v?["enabled"]?.boolValue ?? false
        spritesheetBase64 = v?["spritesheetBase64"]?.stringValue
        spritesheetUnchanged = v?["spritesheetUnchanged"]?.boolValue ?? false
        let slug = v?["slug"]?.stringValue ?? ""
        guard enabled, !slug.isEmpty else {
            pet = nil
            return
        }
        pet = Pet(slug: slug,
                  displayName: v?["displayName"]?.stringValue ?? slug,
                  revision: v?["spritesheetRevision"]?.stringValue ?? "",
                  scale: v?["scale"]?.doubleValue ?? Pet.defaultScale,
                  geometry: PetGeometry(v))
    }
}

/// `pet.info.meta` (and the `pet.changed` broadcast, which is meta-shaped):
/// everything needed to decide whether the heavy payload must be refetched.
public struct PetMeta: Sendable, Equatable {
    public var enabled: Bool
    public var slug: String
    public var displayName: String
    public var scale: Double
    public var revision: String

    public init(_ v: JSONValue?) {
        enabled = v?["enabled"]?.boolValue ?? false
        slug = v?["slug"]?.stringValue ?? ""
        displayName = v?["displayName"]?.stringValue ?? slug
        scale = v?["scale"]?.doubleValue ?? Pet.defaultScale
        revision = v?["spritesheetRevision"]?.stringValue ?? ""
    }
}

// MARK: - Decoded spritesheet

/// A decoded atlas, sliced into per-row frames.
///
/// Reference type on purpose: it owns a fully decoded bitmap (a 1536×1872 sheet
/// is ~11 MB) that every `PetSpriteView` on screen shares. `@unchecked
/// Sendable` because `CGImage` is immutable and every stored property is a
/// `let` — the compiler simply has no way to know that about a C type.
public final class PetSpriteSheet: @unchecked Sendable {
    public let revision: String
    public let geometry: PetGeometry
    public let columns: Int
    public let rows: Int

    /// Row name → frames, left to right. Cropped once at init.
    private let framesByRow: [String: [CGImage]]

    /// Refuse absurd atlases rather than allocating a bitmap that would jettison
    /// the app — a sheet this size is a corrupt payload, not a bigger pet.
    private static let maxDimension = 8192

    public convenience init?(base64: String, revision: String, geometry: PetGeometry) {
        guard let data = Data(base64Encoded: base64,
                              options: .ignoreUnknownCharacters) else { return nil }
        self.init(data: data, revision: revision, geometry: geometry)
    }

    public init?(data: Data, revision: String, geometry: PetGeometry) {
        guard geometry.frameWidth > 0, geometry.frameHeight > 0,
              let sheet = PetSpriteSheet.bake(data) else { return nil }

        self.revision = revision
        self.geometry = geometry
        columns = max(1, sheet.width / geometry.frameWidth)
        rows = max(1, sheet.height / geometry.frameHeight)

        // Slice every row up front. Crops of a baked bitmap share its backing
        // store, so this is 70-odd cheap references rather than 70 copies —
        // and it means the animation loop never touches ImageIO.
        var sliced: [String: [CGImage]] = [:]
        for row in 0..<rows {
            let name = row < geometry.stateRows.count ? geometry.stateRows[row] : "row\(row)"
            var frames: [CGImage] = []
            for column in 0..<columns {
                let rect = CGRect(x: column * geometry.frameWidth,
                                  y: row * geometry.frameHeight,
                                  width: geometry.frameWidth,
                                  height: geometry.frameHeight)
                if let frame = sheet.cropping(to: rect) { frames.append(frame) }
            }
            sliced[name] = frames
        }
        framesByRow = sliced
    }

    /// Frames for *state*, falling back to idle when this sheet has no such row
    /// (legacy 8-row atlases have no `waiting`, and a trimmed row can be empty).
    public func frames(for state: PetState) -> [CGImage] {
        let row = geometry.rowName(for: state)
        let available = framesByRow[row] ?? []
        // frameCount is row-addressed: a trimmed atlas row reports fewer real
        // frames than the sheet's nominal framesPerState.
        let wanted = min(geometry.frameCount(row: row), available.count)
        if wanted > 0 { return Array(available.prefix(wanted)) }
        let idle = framesByRow[geometry.rowName(for: .idle)] ?? []
        return idle.isEmpty ? Array(framesByRow.values.first ?? []) : idle
    }

    /// Seconds per frame: the engine's fixed loop divided by the real frame
    /// count, so a 4-frame state and a 6-frame state take the same wall time.
    public func frameInterval(for state: PetState) -> Double {
        let count = max(1, frames(for: state).count)
        return max(0.05, geometry.loopMilliseconds / Double(count) / 1000)
    }

    public var frameAspect: CGFloat { geometry.frameAspect }

    /// Decode once into a premultiplied RGBA bitmap. A `CGImage` straight from
    /// `CGImageSource` decodes lazily, so every cropped frame would re-decode
    /// the whole multi-MB atlas on each draw — with a dozen sprites on the
    /// roster that is the difference between free and unusable.
    private static func bake(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard image.width > 0, image.height > 0,
              image.width <= maxDimension, image.height <= maxDimension else { return nil }
        guard let context = CGContext(data: nil,
                                      width: image.width,
                                      height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}

// MARK: - Gallery

/// One row of `pet.gallery`: the petdex manifest merged with local install
/// state. `spritesheetURL` is the manifest's CDN URL — never fetched by the
/// phone, only handed back to `pet.thumb` so the gateway crops the preview.
public struct PetGalleryEntry: Sendable, Equatable, Identifiable {
    public var id: String { slug }
    public var slug: String
    public var displayName: String
    public var installed: Bool
    public var spritesheetURL: String
    /// petdex's hand-picked set (the gateway infers it from the asset path).
    public var curated: Bool
    /// Hatched here rather than adopted from the manifest.
    public var generated: Bool

    public init(_ v: JSONValue) {
        slug = v["slug"]?.stringValue ?? ""
        displayName = v["displayName"]?.stringValue ?? slug
        installed = v["installed"]?.boolValue ?? false
        spritesheetURL = v["spritesheetUrl"]?.stringValue ?? ""
        curated = v["curated"]?.boolValue ?? false
        generated = v["generated"]?.boolValue ?? false
    }
}

public struct PetGallerySnapshot: Sendable, Equatable {
    /// `display.pet.enabled` — pets can be installed but switched off.
    public var enabled: Bool
    public var activeSlug: String
    public var pets: [PetGalleryEntry]

    public init(_ v: JSONValue?) {
        enabled = v?["enabled"]?.boolValue ?? false
        activeSlug = v?["active"]?.stringValue ?? ""
        pets = v?["pets"]?.arrayValue?.map(PetGalleryEntry.init) ?? []
    }

    public init(enabled: Bool = false, activeSlug: String = "", pets: [PetGalleryEntry] = []) {
        self.enabled = enabled
        self.activeSlug = activeSlug
        self.pets = pets
    }
}

// MARK: - Generation

/// A candidate base look from `pet.generate`, streamed one at a time over
/// `pet.generate.progress` so the grid fills in live.
public struct PetDraft: Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var dataURI: String

    public init(index: Int, dataURI: String) {
        self.index = index
        self.dataURI = dataURI
    }
}

/// One `pet.hatch.progress` beat. Row progress arrives pre-split as
/// `{event:"row", state, done, total}` — with `done`/`total` as *strings*,
/// because the gateway splits them out of a `"<state>:<done>:<total>"` detail
/// string. Every other phase (compose, save, …) arrives as `{event, detail}`.
public struct PetHatchProgress: Sendable, Equatable {
    public var event: String
    public var rowState: String
    public var done: Int
    public var total: Int
    public var detail: String

    public init(_ v: JSONValue?) {
        event = v?["event"]?.stringValue ?? ""
        rowState = v?["state"]?.stringValue ?? ""
        done = PetHatchProgress.int(v?["done"])
        total = PetHatchProgress.int(v?["total"])
        detail = v?["detail"]?.stringValue ?? ""
    }

    private static func int(_ v: JSONValue?) -> Int {
        if let n = v?.intValue { return n }
        return Int(v?.stringValue ?? "") ?? 0
    }

    /// 0…1 across the sheet's rows, or nil for the non-row phases.
    public var fraction: Double? {
        guard event == "row", total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }
}

/// An image backend that can generate a pet (`pet.generate.status`).
public struct PetProvider: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var label: String
    public var isDefault: Bool

    public init(_ v: JSONValue) {
        name = v["name"]?.stringValue ?? ""
        label = v["label"]?.stringValue ?? (v["name"]?.stringValue ?? "")
        isDefault = v["default"]?.boolValue ?? false
    }
}

/// What a finished `pet.hatch` handed back. The pet is installed but *not*
/// active — generation is expensive and varies, so the user judges a live
/// preview before adopting (`pet.select`) or throwing it away (`pet.remove`).
public struct PetHatchResult: Sendable {
    public var slug: String
    public var displayName: String
    public var warnings: [String]
    public var payload: PetInfoPayload

    public init(_ v: JSONValue?) {
        slug = v?["slug"]?.stringValue ?? ""
        displayName = v?["displayName"]?.stringValue ?? slug
        warnings = v?["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        // `pet` is the same `_pet_sprite_payload` shape as pet.info, minus the
        // enabled flag (the hatched pet is by definition not the active one).
        var body = v?["pet"]?.objectValue ?? [:]
        body["enabled"] = .bool(!body.isEmpty)
        payload = PetInfoPayload(.object(body))
    }
}

/// The whole generate → choose → hatch → adopt flow as one value. Lives on the
/// pet runtime; the screen reads it and never owns wire state of its own.
public struct PetGenerationState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Nothing started — the prompt form is showing.
        case idle
        /// `pet.generate` in flight; drafts stream in.
        case drafting
        /// Drafts landed, waiting for the user to pick one and name it.
        case choosing
        /// `pet.hatch` in flight — the egg screen.
        case hatching
        /// Hatched and installed; the preview plays until adopt or discard.
        case preview
    }

    public var phase: Phase = .idle
    /// Whether this gateway has a reference-capable image backend at all.
    public var available = false
    public var providers: [PetProvider] = []
    public var provider = ""

    public var prompt = ""
    public var count = 4

    /// `pet.generate`'s token: keys the staged drafts and cancels generation.
    public var token = ""
    /// Hatch rides its own cancel key — `pet.generate` is still releasing
    /// `token` while the hatch runs and would wipe the arm hatch just set
    /// (methods_session.py:2158).
    public var hatchToken = ""

    public var expectedDrafts = 0
    public var drafts: [PetDraft] = []
    public var selectedDraft: Int?
    public var name = ""

    public var progress: PetHatchProgress?
    public var hatched: PetHatchResult?
    public var warnings: [String] = []
    public var error: String?

    public init() {}

    public var isBusy: Bool { phase == .drafting || phase == .hatching }

    /// Back to the prompt form, keeping what the gateway told us about itself.
    public mutating func reset() {
        let keep = (available, providers, provider)
        self = PetGenerationState()
        (available, providers, provider) = keep
    }
}

extension PetHatchResult: Equatable {
    public static func == (lhs: PetHatchResult, rhs: PetHatchResult) -> Bool {
        lhs.slug == rhs.slug && lhs.displayName == rhs.displayName
            && lhs.warnings == rhs.warnings
            && lhs.payload.pet == rhs.payload.pet
    }
}
