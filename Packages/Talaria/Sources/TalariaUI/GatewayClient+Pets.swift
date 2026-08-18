import Foundation
import TalariaKit

// The pet RPC surface (tui_gateway/methods_session.py 1546-2239). Two things
// shape this wrapper:
//
// 1. **Bandwidth.** `pet.info` carries the whole spritesheet as base64 — a
//    1536×1872 PNG is several megabytes. The gateway implements send-once
//    semantics (#54730): pass the revision you already hold as `knownRevision`
//    and an unchanged sheet comes back as metadata plus
//    `spritesheetUnchanged: true`, with no bytes at all. That is not an
//    optimization to remember later — it is the only acceptable way to call
//    this RPC from a phone, so `knownRevision` is a required argument here.
//    `pet.info.meta` is cheaper still (five fields, one stat) and is what the
//    model polls before deciding whether the heavy call is needed at all.
//
// 2. **Silence.** Every read-side pet RPC fails open server-side: a gateway
//    with no pet engine, no configured pet, or a decode hiccup answers
//    `{"enabled": false}` rather than erroring. A gateway that predates the
//    surface entirely answers -32601. Both mean "there are no pets here", and
//    both must leave the UI exactly as it would be without this file.
//
// Reads and cosmetic writes are `@_profile_scoped` server-side: `display.pet.*`
// lives in each profile's config.yaml and sprites install under its `pets/`
// dir, so `profile` picks whose pet is being read or written. The generation
// RPCs (`pet.generate*`, `pet.hatch`, `pet.cancel`) are NOT profile-scoped —
// they stage into a gateway-global temp root and only touch a profile when the
// hatched pet is later adopted with `pet.select`.

/// Result of the small `{ok, slug, displayName}` mutations (select / rename).
public struct PetMutation: Sendable, Equatable {
    public var ok: Bool
    public var slug: String
    public var displayName: String

    init(_ v: JSONValue?) {
        ok = v?["ok"]?.boolValue ?? false
        slug = v?["slug"]?.stringValue ?? ""
        displayName = v?["displayName"]?.stringValue ?? ""
    }
}

/// `pet.generate.status` — whether a reference-capable image backend is
/// configured. False means offer setup, not a dead prompt box.
public struct PetGenerateCapability: Sendable, Equatable {
    public var available: Bool
    public var providers: [PetProvider]

    init(_ v: JSONValue?) {
        available = v?["available"]?.boolValue ?? false
        providers = v?["providers"]?.arrayValue?.map(PetProvider.init) ?? []
    }

    public static let unavailable = PetGenerateCapability(nil)
}

extension GatewayClient {

    // `methodNotFound` (-32601, "gateway too old for this surface") is declared
    // once in GatewayClient+Capabilities.swift and shared by every optional
    // surface, pets included.

    // MARK: - Reading the active pet

    /// The active pet with its spritesheet.
    ///
    /// `knownRevision` is the revision of the sheet the caller already holds
    /// (empty when it holds none). When it matches, the reply omits
    /// `spritesheetBase64` and sets `spritesheetUnchanged` — several megabytes
    /// that never leave the gateway.
    ///
    /// The long timeout is for the payload, not the work: encoding and shipping
    /// a multi-MB base64 blob over a slow uplink outlasts the default budget.
    public func petInfo(profile: String? = nil,
                        knownRevision: String = "") async throws -> PetInfoPayload {
        var params: [String: JSONValue] = [:]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        if !knownRevision.isEmpty { params["knownRevision"] = .string(knownRevision) }
        return PetInfoPayload(try await rpc("pet.info", .object(params), timeout: 120))
    }

    /// Active-pet metadata only — slug, name, scale, sheet revision. Cheap
    /// enough to call on every `pet.changed`, which is the point: it decides
    /// whether `petInfo` needs to run.
    public func petInfoMeta(profile: String? = nil) async throws -> PetMeta {
        var params: [String: JSONValue] = [:]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        return PetMeta(try await rpc("pet.info.meta", .object(params), timeout: 20))
    }

    /// Half-block cell frames for one state — the TUI's renderer payload.
    /// Talaria draws real pixels from the spritesheet, so nothing here consumes
    /// this; it is wrapped so the pet surface is complete and diagnosable.
    public func petCells(state: PetState, columns: Int = 0,
                         profile: String? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = ["state": .string(state.rawValue)]
        if columns > 0 { params["cols"] = .number(Double(columns)) }
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        return try await rpc("pet.cells", .object(params), timeout: 30)
    }

    // MARK: - Gallery

    /// Adoptable pets: the petdex manifest merged with local install state.
    ///
    /// `localOnly` skips the (possibly slow, possibly unreachable) manifest
    /// fetch and returns just what is installed — the picker loads that first
    /// so the user's own pets render immediately, then re-asks for the full
    /// list. The gateway warms the manifest in the background on that first
    /// call, so the follow-up usually hits a cache.
    public func petGallery(profile: String? = nil,
                           localOnly: Bool = false) async throws -> PetGallerySnapshot {
        var params: [String: JSONValue] = [:]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        if localOnly { params["localOnly"] = .bool(true) }
        return PetGallerySnapshot(try await rpc("pet.gallery", .object(params), timeout: 60))
    }

    /// A cropped idle-frame PNG for one pet — the grid thumbnail.
    ///
    /// The gateway crops and caches it, so this costs kilobytes where the
    /// spritesheet costs megabytes: a thumbnail must never be drawn by
    /// fetching a sheet. `url` is the manifest's spritesheet URL and is only
    /// meaningful for pets that are not installed yet — the gateway fetches it
    /// so the phone never talks to the CDN itself.
    /// Returns nil when the gateway could not produce one (`{ok: false}`).
    public func petThumbnail(slug: String, url: String = "",
                             profile: String? = nil) async throws -> Data? {
        var params: [String: JSONValue] = ["slug": .string(slug)]
        if !url.isEmpty { params["url"] = .string(url) }
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await rpc("pet.thumb", .object(params), timeout: 60)
        guard result["ok"]?.boolValue == true,
              let dataURI = result["dataUri"]?.stringValue,
              let marker = dataURI.range(of: "base64,") else { return nil }
        return Data(base64Encoded: String(dataURI[marker.upperBound...]),
                    options: .ignoreUnknownCharacters)
    }

    // MARK: - Adopting, renaming, removing

    /// Adopt a pet: install it if needed, then make it active. Writes
    /// `display.pet.*` in the profile's config; surfaces re-read `pet.info`.
    /// Downloads from petdex when the pet isn't installed, hence the budget.
    public func petSelect(slug: String, profile: String? = nil) async throws -> PetMutation {
        var params: [String: JSONValue] = ["slug": .string(slug)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        return PetMutation(try await rpc("pet.select", .object(params), timeout: 180))
    }

    /// Delete a pet's on-disk directory. Removing the *active* pet also turns
    /// the display off server-side, so nothing renders a missing sprite.
    /// Returns whether a directory was actually deleted.
    @discardableResult
    public func petRemove(slug: String, profile: String? = nil) async throws -> Bool {
        var params: [String: JSONValue] = ["slug": .string(slug)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await rpc("pet.remove", .object(params), timeout: 60)
        return result["ok"]?.boolValue ?? false
    }

    /// Rename a pet. The slug is realigned to the new name, so the answer's
    /// `slug` may differ from the one sent — callers must adopt it. If the
    /// renamed pet was active the gateway follows the slug in config too.
    public func petRename(slug: String, name: String,
                          profile: String? = nil) async throws -> PetMutation {
        var params: [String: JSONValue] = ["slug": .string(slug), "name": .string(name)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        return PetMutation(try await rpc("pet.rename", .object(params), timeout: 60))
    }

    /// Export a pet as a re-importable zip (`pet.json` + sprite).
    public func petExport(slug: String, profile: String? = nil) async throws -> (filename: String, data: Data) {
        var params: [String: JSONValue] = ["slug": .string(slug)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await rpc("pet.export", .object(params), timeout: 120)
        let name = result["filename"]?.stringValue ?? "\(slug).zip"
        let data = (result["zipBase64"]?.stringValue).flatMap {
            Data(base64Encoded: $0, options: .ignoreUnknownCharacters)
        }
        guard let data else { throw GatewayError(code: 5031, message: "pet.export returned no archive") }
        return (name, data)
    }

    // MARK: - Display settings

    /// `display.pet.enabled = false`. Installed pets survive; nothing renders.
    public func petDisable(profile: String? = nil) async throws {
        var params: [String: JSONValue] = [:]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        try await rpc("pet.disable", .object(params), timeout: 20)
    }

    /// Persist `display.pet.scale`. The gateway clamps to the engine bounds and
    /// returns what it stored, so the slider follows the truth rather than its
    /// own optimistic value.
    @discardableResult
    public func petScale(_ scale: Double, profile: String? = nil) async throws -> Double {
        var params: [String: JSONValue] = ["scale": .number(scale)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await rpc("pet.scale", .object(params), timeout: 20)
        return result["scale"]?.doubleValue ?? scale
    }

    // MARK: - Generation

    /// Whether this gateway can generate a pet at all. Cheap (config + plugin
    /// discovery); the screen asks on open so it can offer setup instead of a
    /// prompt box that cannot work.
    public func petGenerateStatus() async throws -> PetGenerateCapability {
        PetGenerateCapability(try await rpc("pet.generate.status", .object([:]), timeout: 30))
    }

    /// Generate candidate base looks. Returns the token that keys the staged
    /// drafts for a later `petHatch`, plus every draft that survived.
    ///
    /// Drafts also stream over `pet.generate.progress` as they land — the first
    /// of those events carries the token alone, before any image, precisely so
    /// a Stop pressed early can still target this run. Callers should drive the
    /// grid from the events and treat this return value as the settled truth.
    ///
    /// `referenceImage` is a data URL the drafts are grounded on (a photo of
    /// the pet you actually want). Either it or `prompt` must be present.
    public func petGenerate(prompt: String, count: Int = 4, style: String = "auto",
                            referenceImage: String = "",
                            provider: String = "") async throws -> (token: String, drafts: [PetDraft]) {
        var params: [String: JSONValue] = [
            "count": .number(Double(max(1, min(4, count)))),
            "style": .string(style),
        ]
        if !prompt.isEmpty { params["prompt"] = .string(prompt) }
        if !referenceImage.isEmpty { params["referenceImage"] = .string(referenceImage) }
        if !provider.isEmpty { params["provider"] = .string(provider) }
        // Four reference-grounded image generations, serially, over someone
        // else's API. Minutes, not seconds.
        let result = try await rpc("pet.generate", .object(params), timeout: 900)
        let drafts = result["drafts"]?.arrayValue?.compactMap { row -> PetDraft? in
            guard let uri = row["dataUri"]?.stringValue, !uri.isEmpty else { return nil }
            return PetDraft(index: row["index"]?.intValue ?? 0, dataURI: uri)
        } ?? []
        return (result["token"]?.stringValue ?? "", drafts)
    }

    /// Turn a chosen draft into a full pet: every animation row, rastered into
    /// a spritesheet and installed. The pet is **not** made active — the reply
    /// carries its renderer payload so the surface can play the result and let
    /// the user decide (`petSelect` to adopt, `petRemove` to discard).
    ///
    /// `cancelToken` must be a fresh key, not `token`: when a hatch starts
    /// while `pet.generate` is still unwinding, the generation's release would
    /// wipe an arm registered under the same key and the Stop button would go
    /// dead (methods_session.py:2158).
    public func petHatch(token: String, index: Int, name: String,
                         description: String = "", prompt: String = "",
                         style: String = "auto", cancelToken: String = "",
                         provider: String = "") async throws -> PetHatchResult {
        var params: [String: JSONValue] = [
            "token": .string(token),
            "index": .number(Double(index)),
            "name": .string(name),
            "style": .string(style),
        ]
        if !description.isEmpty { params["description"] = .string(description) }
        if !prompt.isEmpty { params["prompt"] = .string(prompt) }
        if !cancelToken.isEmpty { params["cancelToken"] = .string(cancelToken) }
        if !provider.isEmpty { params["provider"] = .string(provider) }
        // Six-plus reference-grounded generations plus the raster/compose pass.
        return PetHatchResult(try await rpc("pet.hatch", .object(params), timeout: 1800))
    }

    /// Ask an in-flight generate/hatch to stop. Best-effort and idempotent —
    /// an unknown or finished token is a no-op — and deliberately off the
    /// gateway's worker pool so it lands while the heavy run occupies it.
    public func petCancel(token: String) async {
        guard !token.isEmpty else { return }
        _ = try? await rpc("pet.cancel", ["token": .string(token)], timeout: 20)
    }
}
