import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Live-mode profile editing, bot-sheet hydration and avatar portraits.
//
// The editor contract (see GatewayClient+Profiles.swift): read with
// profiles.describe, write only what changed. Nothing here ever sends a
// section the sheet did not first load from the gateway, so a save can never
// overwrite SOUL.md, the disabled-skill list or the toolset pin with the
// editor's own defaults.

// MARK: - Portrait cache

/// In-memory cache of profiles.get_asset avatar bytes, keyed by profile id.
///
/// Extensions cannot add stored properties to AppModel (and AppModel.swift is
/// owned elsewhere), so the cache rides a MainActor singleton the same way
/// LiveRuntime does. It is @Observable, so a view that reads a portrait in
/// its body repaints when the fetch lands.
@MainActor
@Observable
public final class ProfileAssetStore {
    public static let shared = ProfileAssetStore()

    private var portraits: [String: Data] = [:]
    /// Profiles the gateway answered {found:false} for — never re-fetched
    /// until something invalidates them (a set_asset, or a reconnect).
    private var absent: Set<String> = []
    private var inflight: Set<String> = []

    /// profiles.set_asset ceiling is 2 MB; stay under it with headroom for
    /// the base64 expansion the gateway decodes.
    static let maxAssetBytes = 1_400_000

    /// Cache keys carry the gateway they came from: two gateways can both
    /// serve a profile called "inbox", and one must never wear the other's
    /// face after a connection switch.
    private func key(_ botID: String) -> String {
        (LiveRuntime.shared.baseURL?.absoluteString ?? "demo") + "|" + botID
    }

    public func portrait(for botID: String) -> Data? { portraits[key(botID)] }

    public func hasPortrait(_ botID: String) -> Bool { portraits[key(botID)] != nil }

    /// This profile's asset question is already settled — bytes held, or a
    /// verdict recorded that they are not displayable. Lets the roster answer
    /// skip re-arming a fetch it has already had answered.
    func isResolved(_ botID: String) -> Bool {
        let id = key(botID)
        return portraits[id] != nil || absent.contains(id)
    }

    /// True when a fetch should run — nothing cached, no known miss, and no
    /// request already in flight. Callers must pair this with `endFetch`.
    func beginFetch(_ botID: String, force: Bool = false) -> Bool {
        let id = key(botID)
        if force {
            absent.remove(id)
        } else if portraits[id] != nil || absent.contains(id) {
            return false
        }
        return inflight.insert(id).inserted
    }

    func endFetch(_ botID: String) { inflight.remove(key(botID)) }

    func set(_ data: Data, for botID: String) {
        let id = key(botID)
        absent.remove(id)
        portraits[id] = data
    }

    func markAbsent(_ botID: String) {
        let id = key(botID)
        portraits.removeValue(forKey: id)
        absent.insert(id)
    }

    /// Drop everything — for a sign-out, where even the previous gateway's
    /// cached faces should not linger in memory.
    public func flush() {
        portraits.removeAll()
        absent.removeAll()
        inflight.removeAll()
    }

    // MARK: Data URLs

    static func decode(dataURL: String) -> Data? {
        guard let marker = dataURL.range(of: "base64,") else { return nil }
        return Data(base64Encoded: String(dataURL[marker.upperBound...]))
    }

    /// A data URL small enough for profiles.set_asset. Oversized generations
    /// are re-encoded as JPEG rather than rejected — a 1024px portrait from a
    /// PNG-emitting provider routinely lands above the asset ceiling.
    static func assetDataURL(from dataURL: String) -> String? {
        guard let data = decode(dataURL: dataURL) else { return nil }
        if data.count <= maxAssetBytes, dataURL.hasPrefix("data:image/") { return dataURL }
        guard let jpeg = reencodeJPEG(data, maxDimension: 768, quality: 0.85) else { return nil }
        guard jpeg.count <= maxAssetBytes else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    static func reencodeJPEG(_ data: Data, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxDimension / longest)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: quality)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #else
        return nil
        #endif
    }

    /// Platform-gated decode for display.
    public static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}

/// Why a portrait could not be generated, in terms the sheets can theme.
public enum PortraitFailure: Sendable, Equatable {
    /// Demo mode — nothing to call.
    case notLive
    /// The gateway has no image-generation provider configured.
    case unavailable
    /// Generated, but only a gateway-host path/URL came back — a phone
    /// cannot read that, and set_asset needs bytes.
    case noBytes
    /// The image was too large to store as a profile asset even re-encoded.
    case tooLarge
    case failed(String)
}

extension AppModel {

    // MARK: - Editor snapshot (profiles.describe)

    /// The prefill source for "Edit look & soul". Returns nil when the
    /// gateway could not be read — callers MUST then refuse to write soul,
    /// skills or toolsets, since they have nothing true to diff against.
    public func profileSnapshot(botID: String) async -> ProfileSnapshot? {
        guard mode == .live, let client else { return demoSnapshot(botID: botID) }
        return try? await client.profileSnapshot(botID)
    }

    /// Demo mode mirrors the same shape so both sheets take one code path.
    private func demoSnapshot(botID: String) -> ProfileSnapshot {
        let bot = bot(botID)
        let catalog = skills.isEmpty ? DemoData.skills : skills
        return ProfileSnapshot(
            name: botID,
            description: bot?.job ?? "",
            soul: bot?.description ?? "",
            model: bot?.pinnedModel ?? "",
            provider: "demo",
            skills: catalog.map { ProfileSnapshot.Skill(name: $0, enabled: true) },
            toolsets: [],
            toolsetsPinned: false,
            mcpServers: [])
    }

    // MARK: - Model catalog

    /// Models offered by the gateway, each carrying the provider slug that
    /// profiles.configure requires alongside the model id. Falls back to the
    /// flat availableModels() list (provider unknown) so the picker still
    /// renders; a choice with no provider is not written as a pin.
    public func modelChoices() async -> [ModelChoice] {
        guard mode == .live, let client else {
            return (models.isEmpty ? DemoData.models : models)
                .map { ModelChoice(model: $0, provider: "demo", providerName: "demo") }
        }
        if let catalog = try? await client.modelChoices(), !catalog.isEmpty {
            models = catalog.map(\.model)
            return catalog
        }
        // Second try through the chat picker's harvester. Its own last resort
        // is the demo list, which must never be offered as a real pin against
        // a live gateway — an empty row plus the themed "no models" line is
        // the honest answer.
        let flat = await availableModels()
        guard flat != DemoData.models else { return [] }
        return flat.map { ModelChoice(model: $0, provider: "") }
    }

    // MARK: - Saving an edit

    /// Apply a dirty-diff edit: gateway first (so a failure is visible), then
    /// the local roster row. Returns false when the gateway rejected it.
    @discardableResult
    public func saveProfileEdit(botID: String, edit: ProfileEdit) async -> Bool {
        guard mode == .live, let client else {
            applyEditLocally(botID: botID, edit: edit)
            return true
        }
        do {
            try await client.applyProfileEdit(name: botID, edit)
        } catch {
            return false
        }
        applyEditLocally(botID: botID, edit: edit)
        try? await refreshRoster()
        return true
    }

    /// Mirror the saved sections onto the roster row so the sheet's caller
    /// sees the change before profiles.list comes back.
    private func applyEditLocally(botID: String, edit: ProfileEdit) {
        guard let index = bots.firstIndex(where: { $0.id == botID }) else { return }
        if let description = edit.description, !description.isEmpty {
            bots[index].job = description
            if mode == .live { bots[index].description = description }
        }
        // Demo mode has no SOUL.md — the canned world keeps the persona on the
        // roster row, which is also where demoSnapshot reads it back from.
        if mode == .demo, let soul = edit.soul {
            bots[index].description = soul.isEmpty ? nil : soul
        }
        if let model = edit.model { bots[index].pinnedModel = model }
        // Only when the edit actually carries cosmetics — and read through the
        // one precedence rule, not a local copy of half of it. This used to
        // consult `ui_meta["talaria"]` alone, so an edit whose desktop block
        // and Talaria mirror disagreed painted the mirror here and the block on
        // the next roster answer.
        if let shape = BotCosmetics.storedShape(uiMeta: edit.uiMeta) {
            bots[index].shape = shape
        }
        if let hue = BotCosmetics.storedHue(uiMeta: edit.uiMeta) {
            bots[index].hue = hue
        }
    }

    // MARK: - Creating a profile

    /// profiles.create (+ a configure pass for the sections create does not
    /// take) then a roster refresh. Returns false when the gateway refused —
    /// the sheet keeps the user's typing instead of dismissing on a lie.
    public func createBotProfile(id: String, job: String, soul: String,
                                 model: ModelChoice?, disabledSkills: [String],
                                 enabledToolsets: [String]?, uiMeta: JSONValue) async -> Bool {
        // The same resolution the roster answer will run on this profile a
        // moment from now. It used to read Talaria's mirror alone and fall back
        // to a fixed circle/teal — so a new bot flashed a face nothing else in
        // the app agreed with, for exactly as long as it took `profiles.list`
        // to come back.
        let bot = Bot(id: id,
                      job: job.isEmpty ? "General agent" : job,
                      shape: BotCosmetics.shape(uiMeta: uiMeta, name: id),
                      hue: BotCosmetics.hue(uiMeta: uiMeta, name: id),
                      status: .idle,
                      preview: "Profile created. Say hello.", previewTime: "new",
                      unread: 0,
                      description: job.isEmpty ? nil : job,
                      pinnedModel: model?.model)

        guard mode == .live, let client else {
            bots.append(bot)
            return true
        }

        // A model pin needs both halves; sending model alone is a silent
        // no-op server-side, so drop it rather than pretend it took.
        let pin = (model?.provider.isEmpty == false) ? model : nil
        do {
            try await client.createProfile(name: id,
                                           description: job.isEmpty ? nil : job,
                                           soul: soul.isEmpty ? nil : soul,
                                           model: pin?.model,
                                           provider: pin?.provider)
        } catch {
            return false
        }
        let follow = ProfileEdit(disabledSkills: disabledSkills.isEmpty ? nil : disabledSkills,
                                 enabledToolsets: enabledToolsets,
                                 uiMeta: uiMeta)
        _ = try? await client.applyProfileEdit(name: id, follow)
        bots.append(bot)
        try? await refreshRoster()
        return true
    }

    /// Desktop "Duplicate": profiles.create {clone_from, clone_all:true} —
    /// config, .env, SOUL.md, memory and skills, minus history.
    @discardableResult
    public func duplicateProfile(from sourceID: String, to newID: String) async -> Bool {
        guard let source = bot(sourceID) else { return false }
        let clone = Bot(id: newID, job: source.job, shape: source.shape, hue: source.hue,
                        status: .idle, preview: "Cloned — config, skills, memory copied.",
                        previewTime: "new", unread: 0, description: source.description,
                        pinnedModel: source.pinnedModel)
        guard mode == .live, let client else {
            bots.append(clone)
            return true
        }
        do {
            try await client.createProfile(name: newID, cloneFrom: sourceID)
        } catch {
            return false
        }
        bots.append(clone)
        try? await refreshRoster()
        return true
    }

    /// First free "<id>-N" sibling, matching desktop's duplicate naming.
    public func cloneID(for base: String) -> String {
        var suffix = 2
        while bots.contains(where: { $0.id == "\(base)-\(suffix)" }) { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    // MARK: - Avatar portraits

    /// profiles.get_asset → portrait cache, and the one place that decides
    /// whether a profile HAS a portrait. Cheap and idempotent: cached hits and
    /// known misses never re-hit the gateway.
    public func refreshAvatar(botID: String, force: Bool = false) async {
        guard mode == .live, let client else { return }
        let signals = RosterSignals.shared
        // `has_avatar` off the roster row is the fetch gate — the gateway has
        // already said whether an asset exists, so a shape-only roster costs
        // zero `profiles.get_asset` calls instead of one per row on every cold
        // start. A sheet that opens before any roster answer landed (`force`)
        // still asks.
        guard force || signals.hasAvatar.contains(botID) else { return }
        let store = ProfileAssetStore.shared
        guard store.beginFetch(botID, force: force) else { return }
        defer { store.endFetch(botID) }
        guard let dataURL = try? await client.profileAvatar(name: botID),
              let data = ProfileAssetStore.decode(dataURL: dataURL),
              // Desktop's own guard, same inputs and same verdict
              // (plugin.js:411-417): "A 160px raster of the vector face is only
              // for inter-agent notices. Do not park it on the roster or the
              // live face dies." It is the roster backfill's own upload coming
              // back — `pushLocalAvatars` rasterizes the live SVG at 160 px and
              // stores it (plugin.js:304-341), pose, blink and all — so
              // displaying it replaces an animated face with a snapshot of
              // itself, frozen mid-blink and no longer following the theme.
              // Unless the profile says the stored image is a photo a human
              // picked, in which case 160×160 is just its size.
              AvatarArtwork.isDisplayablePortrait(
                  data, wantsStoredPhoto: signals.wantsStoredPhoto(botID)) else {
            // `markAbsent`, not a bare return: this is a settled verdict about
            // bytes already seen, so the row keeps its live face for good
            // instead of re-fetching and re-rejecting the same asset every poll.
            store.markAbsent(botID)
            return
        }
        store.set(data, for: botID)
    }

    /// image.generate → profiles.set_asset. Returns nil on success, else why
    /// it failed so the sheet can say it in the user's theme.
    public func generateAvatarPortrait(botID: String, prompt: String) async -> PortraitFailure? {
        guard mode == .live, let client else { return .notLive }
        let generated: GeneratedPortrait
        do {
            generated = try await client.generatePortrait(prompt: prompt)
        } catch let error as GatewayError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard generated.available else { return .unavailable }
        if let message = generated.error, !message.isEmpty { return .failed(message) }
        guard let raw = generated.dataURL else { return .noBytes }
        guard let payload = ProfileAssetStore.assetDataURL(from: raw),
              let bytes = ProfileAssetStore.decode(dataURL: payload) else { return .tooLarge }
        do {
            try await client.setProfileAvatar(name: botID, dataURL: payload)
        } catch let error as GatewayError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
        ProfileAssetStore.shared.set(bytes, for: botID)
        return nil
    }

    /// Drop the custom portrait; the geometric avatar takes over again.
    public func clearAvatarPortrait(botID: String) async {
        guard mode == .live, let client else { return }
        try? await client.clearProfileAvatar(name: botID)
        ProfileAssetStore.shared.markAbsent(botID)
    }

    /// Is portrait generation worth offering on this gateway?
    public func portraitGenerationAvailable() async -> Bool {
        guard mode == .live, let client else { return false }
        return await client.imageGenerationAvailable()
    }

    /// The prompt behind "generate a portrait": the bot's own identity, in
    /// the avatar language the rest of the app draws (shape × hue).
    public static func portraitPrompt(name: String, job: String, soul: String,
                                      shape: AvatarShape, hue: AvatarHue) -> String {
        let persona = soul.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)
        var lines = ["Portrait emblem for an AI agent named \"\(name)\"."]
        if !job.isEmpty { lines.append("Its job: \(job).") }
        if !persona.isEmpty { lines.append("Its character: \(persona)") }
        lines.append("Flat vector emblem, centered, symmetrical, built around a "
                     + "\(shape.rawValue) silhouette in \(hue.rawValue), dark background, "
                     + "no text, no lettering, no watermark.")
        return lines.joined(separator: " ")
    }
}

// MARK: - Portrait-aware avatar

/// AvatarView plus the profile's generated/custom portrait when one exists.
/// Drop-in for `AvatarView(bot:size:theme:)` on any surface that has the
/// model in hand (roster rows, chat header, the Active Now rail, this sheet).
///
/// THE face path. It is the only thing that chooses between a stored portrait
/// and the live geometric face, and it makes that choice from bytes actually
/// held and already vetted (`ProfileAssetStore`), never from `has_avatar`.
/// Callers used to branch on the flag themselves and hand a portrait view only
/// to rows the gateway claimed art for — a second decision, taken from a
/// weaker input, that flipped the roster's whole identity one poll after
/// launch. There is nothing left to branch on: draw this.
public struct BotPortraitView: View {
    private let model: AppModel
    private let bot: Bot
    private let size: CGFloat
    private let theme: ThemePack
    /// Force the working pose regardless of `bot.status` — the Active Now rail
    /// hardcodes it the way desktop hardcodes `mood: 'work'` on those chips
    /// (plugin.js:6934).
    private let isWorking: Bool?

    public init(model: AppModel, bot: Bot, size: CGFloat, theme: ThemePack,
                isWorking: Bool? = nil) {
        self.model = model; self.bot = bot; self.size = size; self.theme = theme
        self.isWorking = isWorking
    }

    public var body: some View {
        Group {
            if let data = ProfileAssetStore.shared.portrait(for: bot.id),
               let image = ProfileAssetStore.image(from: data) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(AvatarSilhouette(bot.shape))
                    .overlay(
                        AvatarSilhouette(bot.shape)
                            .stroke(theme.id == .ink ? theme.lineStrong : theme.line,
                                    lineWidth: 1))
                    .shadow(color: theme.avatarGlowRadius > 0
                            ? theme.color(for: bot.hue).opacity(0.45) : .clear,
                            radius: theme.avatarGlowRadius * size / 44)
            } else {
                AvatarView(shape: bot.shape, hue: bot.hue, size: size,
                           isWorking: isWorking ?? (bot.status == .working),
                           theme: theme, identity: bot.id)
            }
        }
        .frame(width: size, height: size)
        // Surfaces that never saw a roster answer — the bot sheet, the chat
        // header on a deep link — still need the fetch armed. Rows reached
        // through `profiles.list` were already prefetched from the answer
        // itself (`applyRosterAnswer`); `beginFetch` makes the overlap free.
        .task(id: bot.id) { await model.refreshAvatar(botID: bot.id) }
    }
}
