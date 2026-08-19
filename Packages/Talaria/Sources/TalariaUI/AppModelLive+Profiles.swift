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
    /// Invalidates async cache completions after any gateway scope is removed.
    private var epoch = 0

    /// profiles.set_asset ceiling is 2 MB; stay under it with headroom for
    /// the base64 expansion the gateway decodes.
    static let maxAssetBytes = 1_400_000

    /// Cache keys carry the stable gateway id, not the current base URL: two
    /// retained gateways can both serve `inbox`, and remote portraits remain
    /// valid without switching either gateway into the primary role.
    private func key(_ botID: String) -> String {
        if let route = GatewayBotRoute(qualifiedID: botID) {
            return "portrait:\(route.gatewayID.count):\(route.gatewayID)\(route.profile)"
        }
        let gatewayID = LiveRuntime.shared.gatewayID ?? "demo"
        return "portrait:\(gatewayID.count):\(gatewayID)\(botID)"
    }

    public func portrait(for botID: String) -> Data? { portraits[key(botID)] }

    public func hasPortrait(_ botID: String) -> Bool { portraits[key(botID)] != nil }

    func captureEpoch() -> Int { epoch }
    func isCurrent(epoch captured: Int) -> Bool { captured == epoch }

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
        epoch &+= 1
        portraits.removeAll()
        absent.removeAll()
        inflight.removeAll()
    }

    func drop(gatewayID: String) {
        epoch &+= 1
        let prefix = "portrait:\(gatewayID.count):\(gatewayID)"
        portraits = portraits.filter { !$0.key.hasPrefix(prefix) }
        absent = Set(absent.filter { !$0.hasPrefix(prefix) })
        inflight = Set(inflight.filter { !$0.hasPrefix(prefix) })
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

public enum ProfileCreationResult: Sendable, Equatable {
    case complete
    /// profiles.create succeeded, but one or more independent configure
    /// sections did not acknowledge. The profile exists and must not be
    /// retried as a create.
    case partial
    case failed
}

extension AppModel {

    // MARK: - Source routing

    /// Resolve a roster id to the gateway/profile pair Hermes RPCs accept.
    /// UI ids stay qualified; only the raw profile crosses the wire.
    internal func profileRoute(for rosterID: String) -> GatewayBotRoute? {
        stateRoute(for: rosterID)
    }

    internal func profileContext(for rosterID: String) async throws
        -> (route: GatewayBotRoute, client: GatewayClient) {
        guard let route = profileRoute(for: rosterID) else {
            throw GatewayRouteError.noRoute
        }
        return (route, try await routedClient(for: route))
    }

    /// Refresh only the roster that owns a profile mutation.
    internal func refreshProfileRoster(gatewayID: String) async {
        if gatewayID == LiveRuntime.shared.gatewayID {
            try? await refreshRoster()
        } else {
            await ConnectionRegistry.shared.refreshSecondaryRoster(gatewayID: gatewayID)
        }
    }

    // MARK: - Editor snapshot (profiles.describe)

    /// The prefill source for "Edit look & soul". Returns nil when the
    /// gateway could not be read — callers MUST then refuse to write soul,
    /// skills or toolsets, since they have nothing true to diff against.
    public func profileSnapshot(botID: String) async -> ProfileSnapshot? {
        guard mode == .live else { return demoSnapshot(botID: botID) }
        guard let context = try? await profileContext(for: botID) else { return nil }
        return try? await context.client.profileSnapshot(context.route.profile)
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

    /// Models offered by the owning gateway, each carrying the provider slug
    /// profiles.configure requires alongside the model id. Only the primary
    /// global picker may use its flat provider-unknown fallback; a remote
    /// profile never borrows catalog state from another gateway.
    public func modelChoices(botID: String? = nil,
                             gatewayID: String? = nil) async -> [ModelChoice] {
        guard mode == .live else {
            return (models.isEmpty ? DemoData.models : models)
                .map { ModelChoice(model: $0, provider: "demo", providerName: "demo") }
        }
        let selectedClient: GatewayClient
        if let botID {
            guard let context = try? await profileContext(for: botID) else { return [] }
            selectedClient = context.client
        } else if let gatewayID, gatewayID != LiveRuntime.shared.gatewayID {
            guard let routed = try? await routedClient(gatewayID: gatewayID) else { return [] }
            selectedClient = routed
        } else {
            guard let client else { return [] }
            selectedClient = client
        }
        if let catalog = try? await selectedClient.modelChoices(), !catalog.isEmpty {
            if (botID == nil && gatewayID == nil)
                || profileRoute(for: botID ?? "")?.gatewayID == activeGatewayID {
                models = catalog.map(\.model)
            }
            return catalog
        }
        // Second try through the chat picker's harvester. Its own last resort
        // is the demo list, which must never be offered as a real pin against
        // a live gateway — an empty row plus the themed "no models" line is
        // the honest answer.
        // The primary picker retains its typed-catalog fallback. A foreign
        // gateway must not borrow that fallback from the primary connection:
        // without provider slugs those rows cannot be written safely anyway.
        let flat = botID == nil && gatewayID == nil ? await availableModels() : []
        guard flat != DemoData.models else { return [] }
        return flat.map { ModelChoice(model: $0, provider: "") }
    }

    // MARK: - Saving an edit

    /// Apply a dirty-diff edit: gateway first (so a failure is visible), then
    /// the local roster row. Returns false when the gateway rejected it.
    @discardableResult
    public func saveProfileEdit(botID: String, edit: ProfileEdit) async -> Bool {
        guard edit.isWireValid else { return false }
        guard mode == .live else {
            applyEditLocally(botID: botID, edit: edit)
            return true
        }
        guard let context = try? await profileContext(for: botID) else { return false }
        let applied: [String: Bool]
        do {
            applied = try await context.client.applyProfileEdit(
                name: context.route.profile, edit)
        } catch {
            return false
        }
        guard edit.wasFullyApplied(applied) else {
            await refreshProfileRoster(gatewayID: context.route.gatewayID)
            return false
        }
        applyEditLocally(botID: botID, edit: edit)
        await refreshProfileRoster(gatewayID: context.route.gatewayID)
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
                                 enabledToolsets: [String]?, uiMeta: JSONValue,
                                 gatewayID: String? = nil) async -> ProfileCreationResult {
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

        guard mode == .live else {
            bots.append(bot)
            return .complete
        }
        let targetGatewayID = gatewayID ?? LiveRuntime.shared.gatewayID
        guard let targetGatewayID else { return .failed }
        let selectedClient: GatewayClient
        if targetGatewayID == LiveRuntime.shared.gatewayID, let client {
            selectedClient = client
        } else {
            guard let routed = try? await routedClient(gatewayID: targetGatewayID) else {
                return .failed
            }
            selectedClient = routed
        }

        // A model pin needs both halves; sending model alone is a silent
        // no-op server-side, so drop it rather than pretend it took.
        let pin = (model?.provider.isEmpty == false) ? model : nil
        do {
            try await selectedClient.createProfile(name: id,
                                                   description: job.isEmpty ? nil : job,
                                                   soul: soul.isEmpty ? nil : soul,
                                                   model: pin?.model,
                                                   provider: pin?.provider)
        } catch {
            return .failed
        }
        let follow = ProfileEdit(disabledSkills: disabledSkills.isEmpty ? nil : disabledSkills,
                                 enabledToolsets: enabledToolsets,
                                 uiMeta: uiMeta)
        let followApplied = try? await selectedClient.applyProfileEdit(name: id, follow)
        if targetGatewayID == LiveRuntime.shared.gatewayID { bots.append(bot) }
        await refreshProfileRoster(gatewayID: targetGatewayID)
        guard let followApplied, follow.wasFullyApplied(followApplied) else { return .partial }
        return .complete
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
        guard mode == .live else {
            bots.append(clone)
            return true
        }
        guard let context = try? await profileContext(for: sourceID) else { return false }
        do {
            try await context.client.createProfile(name: newID,
                                                   cloneFrom: context.route.profile)
        } catch {
            return false
        }
        if context.route.gatewayID == LiveRuntime.shared.gatewayID {
            bots.append(clone)
        }
        await refreshProfileRoster(gatewayID: context.route.gatewayID)
        return true
    }

    /// First free "<id>-N" sibling, matching desktop's duplicate naming.
    public func cloneID(for base: String) -> String {
        let route = profileRoute(for: base)
        let rawBase = route?.profile ?? base
        var suffix = 2
        while unionRosterBots.contains(where: {
            let row = profileRoute(for: $0.id)
            return row?.gatewayID == route?.gatewayID && row?.profile == "\(rawBase)-\(suffix)"
        }) { suffix += 1 }
        return "\(rawBase)-\(suffix)"
    }

    // MARK: - Avatar portraits

    /// profiles.get_asset → portrait cache, and the one place that decides
    /// whether a profile HAS a portrait. Cheap and idempotent: cached hits and
    /// known misses never re-hit the gateway.
    public func refreshAvatar(botID: String, force: Bool = false) async {
        guard mode == .live,
              let context = try? await profileContext(for: botID) else { return }
        let signals = RosterSignals.shared
        // `has_avatar` gates primary rows. Secondary roster projections do not
        // currently retain that flag, so a qualified row asks once and lets
        // the source-qualified absent cache suppress every later request.
        let isRemote = GatewayBotRoute(qualifiedID: botID) != nil
        guard force || isRemote || signals.hasAvatar.contains(botID) else { return }
        let store = ProfileAssetStore.shared
        let cacheID = context.route.qualifiedID
        let cacheEpoch = store.captureEpoch()
        guard store.beginFetch(cacheID, force: force) else { return }
        defer { store.endFetch(cacheID) }
        let dataURL: String?
        do {
            dataURL = try await context.client.profileAvatar(name: context.route.profile)
        } catch {
            // A transport/provider failure is not evidence that the asset is
            // absent. Leave the cache unresolved so a later repaint can retry.
            return
        }
        guard let dataURL,
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
            if store.isCurrent(epoch: cacheEpoch) { store.markAbsent(cacheID) }
            return
        }
        if store.isCurrent(epoch: cacheEpoch) { store.set(data, for: cacheID) }
    }

    /// image.generate → profiles.set_asset. Returns nil on success, else why
    /// it failed so the sheet can say it in the user's theme.
    public func generateAvatarPortrait(botID: String, prompt: String) async -> PortraitFailure? {
        guard mode == .live else { return .notLive }
        guard let context = try? await profileContext(for: botID) else {
            return .failed(GatewayRouteError.noRoute.localizedDescription)
        }
        let cacheID = context.route.qualifiedID
        let cacheEpoch = ProfileAssetStore.shared.captureEpoch()
        let generated: GeneratedPortrait
        do {
            generated = try await context.client.generatePortrait(prompt: prompt)
        } catch let error as GatewayError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard generated.available else { return .unavailable }
        if let message = generated.error, !message.isEmpty { return .failed(message) }
        guard let raw = generated.dataURL else { return .noBytes }
        guard ProfileAssetStore.shared.isCurrent(epoch: cacheEpoch) else {
            return .failed(GatewayRouteError.noRoute.localizedDescription)
        }
        guard let payload = ProfileAssetStore.assetDataURL(from: raw),
              let bytes = ProfileAssetStore.decode(dataURL: payload) else { return .tooLarge }
        do {
            try await context.client.setProfileAvatar(name: context.route.profile,
                                                      dataURL: payload)
        } catch let error as GatewayError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
        if ProfileAssetStore.shared.isCurrent(epoch: cacheEpoch) {
            ProfileAssetStore.shared.set(bytes, for: cacheID)
        }
        return nil
    }

    /// Drop the custom portrait; the geometric avatar takes over again.
    public func clearAvatarPortrait(botID: String) async -> PortraitFailure? {
        guard mode == .live else { return .notLive }
        guard let context = try? await profileContext(for: botID) else {
            return .failed(GatewayRouteError.noRoute.localizedDescription)
        }
        let cacheID = context.route.qualifiedID
        let cacheEpoch = ProfileAssetStore.shared.captureEpoch()
        do {
            try await context.client.clearProfileAvatar(name: context.route.profile)
        } catch let error as GatewayError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
        if ProfileAssetStore.shared.isCurrent(epoch: cacheEpoch) {
            ProfileAssetStore.shared.markAbsent(cacheID)
        }
        return nil
    }

    /// Is portrait generation worth offering on this gateway?
    public func portraitGenerationAvailable(botID: String? = nil) async -> Bool {
        guard mode == .live else { return false }
        if let botID {
            guard let context = try? await profileContext(for: botID) else { return false }
            return await context.client.imageGenerationAvailable()
        }
        guard let client else { return false }
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
