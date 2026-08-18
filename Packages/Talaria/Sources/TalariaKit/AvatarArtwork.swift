import Foundation

/// Which stored profile assets are real pictures, and which are a still copy of
/// the live vector face.
///
/// This is a fact about `profiles.get_asset` bytes rather than about drawing,
/// so it lives beside the rest of the wire contract — and so
/// `ProtocolChecks.rosterCosmeticsSurviveRefresh` can hold it to the same
/// dimensions desktop uses.
public enum AvatarArtwork {
    /// Upstream encodes an avatar's provenance in its pixel dimensions rather
    /// than a flag, because the profile asset store carries no metadata
    /// (plugin.js:374-391): **160×160 is the roster's own rasterized copy of
    /// the live vector face**, produced for inter-agent notices; pets are
    /// 96×104 and user uploads are 256. The desktop roster explicitly refuses
    /// to display a 160×160 PNG (plugin.js:411-417) — parking that still on the
    /// row would replace the animated face with a photograph of itself.
    ///
    /// This is not hypothetical: on the maintainer's own gateway all five
    /// profiles carry a 160×160 `profiles.get_asset` avatar today, so a client
    /// that trusts `has_avatar` alone shows five frozen faces and none of the
    /// avatar language's motion ever appears. Any client that both uploads and
    /// downloads profile avatars needs this guard or its bots slowly freeze
    /// into stills.
    public static func isBackfilledFacePNG(_ data: Data) -> Bool {
        // PNG signature, then IHDR width/height as big-endian UInt32 at 16..24.
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 24 else { return false }
        let head = [UInt8](data.prefix(24))
        guard Array(head[0..<8]) == signature else { return false }
        func be32(_ i: Int) -> UInt32 {
            (UInt32(head[i]) << 24) | (UInt32(head[i + 1]) << 16)
                | (UInt32(head[i + 2]) << 8) | UInt32(head[i + 3])
        }
        return be32(16) == 160 && be32(20) == 160
    }

    /// Data-URL form, matching what `profiles.get_asset` returns
    /// (`{data, found, mime, size}` with `data` a `data:image/png;base64,…`).
    public static func isBackfilledFacePNG(dataURL: String) -> Bool {
        let marker = "base64,"
        guard dataURL.hasPrefix("data:image/png;base64,"),
              let range = dataURL.range(of: marker) else { return false }
        // 32 base64 chars decode to the 24 bytes the sniff needs.
        let head = String(dataURL[range.upperBound...].prefix(32))
        guard let data = Data(base64Encoded: head) else { return false }
        return isBackfilledFacePNG(data)
    }

    /// Should these bytes be shown as a profile portrait?
    ///
    /// Desktop's guard, verbatim in structure (plugin.js:415):
    /// `isBackfilledFacePng(res.data) && mine.imageKind !== 'photo' && !mine.pet`
    /// — a 160×160 asset is refused *unless* the profile's own ui_meta says the
    /// stored image is a photo a human chose. Talaria has no `pet` key on the
    /// bot-meta block (pets are their own gateway resource), so the two inputs
    /// that remain are the bytes and `imageKind`.
    ///
    /// - Parameter wantsStoredPhoto: `ui_meta["hermes-bots"].imageKind == "photo"`.
    public static func isDisplayablePortrait(_ data: Data, wantsStoredPhoto: Bool) -> Bool {
        !isBackfilledFacePNG(data) || wantsStoredPhoto
    }
}
