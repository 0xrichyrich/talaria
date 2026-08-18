import CoreGraphics
import Foundation
import ImageIO
import TalariaKit

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// Attachment RPCs — .research/ws-protocol.md §9, verified against
// tui_gateway/methods_prompt.py:822-1157 and the caps at server.py:11445-11447.
//
// One composer affordance, two server-side destinations:
// - image.attach_bytes / pdf.attach queue *images* onto the session
//   (`attached_images`), state the next prompt.submit consumes and clears.
//   pdf.attach renders each page to PNG via pdftoppm and queues them all.
// - file.attach materializes the bytes in the session workspace and hands back
//   an "@file:" ref, which only reaches the agent if the prompt text carries it.
//
// Everything travels as base64: a phone's files never exist on the gateway
// host, so the path-taking variants (image.attach, file.attach{path}) are
// useless to us.

// MARK: - Limits

/// Server-enforced attachment caps. Checked client-side too so a 40 MB photo
/// fails instantly instead of after a 50 MB base64 upload.
public enum AttachmentLimits {
    /// image.attach_bytes rejects above this with 4018 (server.py:11445 —
    /// matches Anthropic's per-image ceiling).
    public static let imageBytes = 25 * 1024 * 1024
    /// pdf.attach rejects above these with 4018 / 4019 (server.py:11446-11447).
    public static let pdfBytes = 50 * 1024 * 1024
    public static let pdfPages = 25
    /// file.attach has no server cap. The real ceilings are the 384 MiB WS
    /// frame (base64 inflates 4/3) and the encoded copy we hold in phone
    /// memory; 50 MB stays clear of both.
    public static let fileBytes = 50 * 1024 * 1024

    static func megabytes(_ bytes: Int) -> Int { bytes / (1024 * 1024) }
}

/// Application error codes the attach RPCs raise (ws-protocol.md §9). Callers
/// map these to themed copy — the raw server strings are English and terse.
public enum AttachmentErrorCode {
    /// Required param absent (no bytes, no path).
    public static let missingParam = 4015
    /// Extension not an image / not a PDF / file not found.
    public static let unsupportedKind = 4016
    /// Not valid base64, empty payload, or missing %PDF- magic.
    public static let badPayload = 4017
    /// Over the byte cap.
    public static let tooLarge = 4018
    /// PDF page range wider than 25 pages.
    public static let tooManyPages = 4019
    /// Gateway could not write the upload.
    public static let writeFailed = 5027
    /// pdftoppm missing/failed/timed out, or file staging blew up.
    public static let renderFailed = 5028
}

// MARK: - Result

/// What one attach RPC staged on the gateway.
public struct StagedAttachment: Sendable {
    /// Primary gateway-side path — image.detach's key.
    public var path: String
    /// Gateway-side name (a PDF reports its own display name, not a page).
    public var name: String
    /// Every image path this call queued; a PDF queues one per rendered page.
    public var paths: [String]
    /// "@file:…" reference (file.attach only). The agent never sees the file
    /// unless this rides in the prompt text.
    public var refText: String?
    /// Images queued on the session after this call.
    public var count: Int
    /// Pages rendered (pdf.attach only).
    public var pageCount: Int

    init(path: String, name: String, paths: [String], refText: String? = nil,
         count: Int = 0, pageCount: Int = 0) {
        self.path = path; self.name = name; self.paths = paths
        self.refText = refText; self.count = count; self.pageCount = pageCount
    }
}

// MARK: - RPCs

public extension GatewayClient {

    /// image.attach_bytes — upload image bytes and queue them on the session.
    /// `filename` is only an extension hint; the gateway sniffs magic bytes
    /// when it is absent, and rejects extensions outside cli._IMAGE_EXTENSIONS
    /// with 4016 (so HEIC must be transcoded before it gets here — see
    /// `AttachmentEncoder.gatewayImage`).
    func attachImageBytes(sessionID: String, data: Data, filename: String) async throws -> StagedAttachment {
        try Self.checkPayload(data, cap: AttachmentLimits.imageBytes, what: "image")
        let result = try await rpc("image.attach_bytes", .object([
            "session_id": .string(sessionID),
            "content_base64": .string(data.base64EncodedString()),
            "filename": .string(filename),
        ]), timeout: 180)
        try Self.checkAttached(result, fallback: "image not attached")
        let path = result["path"]?.stringValue ?? ""
        return StagedAttachment(path: path,
                                name: Self.lastComponent(path, fallback: filename),
                                paths: path.isEmpty ? [] : [path],
                                count: result["count"]?.intValue ?? 0)
    }

    /// pdf.attach — the gateway renders every page to PNG at 150 DPI with
    /// pdftoppm and queues the pages as images (the vision pipeline takes
    /// images, not PDFs). Fails with 5028 when poppler-utils is missing.
    /// Timeout covers pdftoppm's own 120 s ceiling; the handler runs inline on
    /// the socket reader, so nothing else returns while it renders.
    func attachPDF(sessionID: String, data: Data, filename: String) async throws -> StagedAttachment {
        try Self.checkPayload(data, cap: AttachmentLimits.pdfBytes, what: "PDF")
        let result = try await rpc("pdf.attach", .object([
            "session_id": .string(sessionID),
            "content_base64": .string(data.base64EncodedString()),
            "filename": .string(filename),
            // The server defaults last_page to first_page + 24; naming the cap
            // makes the 4019 boundary ours rather than a surprise.
            "first_page": .number(1),
            "last_page": .number(Double(AttachmentLimits.pdfPages)),
        ]), timeout: 240)
        try Self.checkAttached(result, fallback: "PDF not attached")
        let pages = result["pages"]?.arrayValue?.compactMap { $0["path"]?.stringValue } ?? []
        return StagedAttachment(path: pages.first ?? "",
                                name: result["filename"]?.stringValue ?? filename,
                                paths: pages,
                                count: result["count"]?.intValue ?? 0,
                                pageCount: result["pages_attached"]?.intValue ?? pages.count)
    }

    /// file.attach — stage a non-image file in the session workspace. Returns
    /// the "@file:" ref the prompt must carry; there is no detach RPC (the file
    /// is an artifact, not queued session state).
    func attachFile(sessionID: String, data: Data, filename: String) async throws -> StagedAttachment {
        try Self.checkPayload(data, cap: AttachmentLimits.fileBytes, what: "file")
        let result = try await rpc("file.attach", .object([
            "session_id": .string(sessionID),
            "data_url": .string(AttachmentEncoder.dataURL(data, filename: filename)),
            "name": .string(filename),
        ]), timeout: 180)
        try Self.checkAttached(result, fallback: "file not attached")
        let path = result["path"]?.stringValue ?? ""
        return StagedAttachment(path: path,
                                name: result["name"]?.stringValue ?? filename,
                                paths: [],
                                refText: result["ref_text"]?.stringValue)
    }

    /// image.detach — drop one queued image path from the session. Returns
    /// false when the path was not queued (already consumed by a submit).
    @discardableResult
    func detachImage(sessionID: String, path: String) async throws -> Bool {
        let result = try await rpc("image.detach", ["session_id": .string(sessionID),
                                                    "path": .string(path)])
        return result["detached"]?.boolValue ?? false
    }

    /// clipboard.paste — queue an image from the *gateway host's* clipboard
    /// (hermes_cli.clipboard). Useful when the gateway is the Mac you copied
    /// on; a phone's own clipboard has to travel as bytes instead. Returns nil
    /// when the host clipboard holds no image (`attached:false` + message).
    func pasteClipboardImage(sessionID: String) async throws -> StagedAttachment? {
        let result = try await rpc("clipboard.paste", ["session_id": .string(sessionID)])
        guard result["attached"]?.boolValue == true else { return nil }
        let path = result["path"]?.stringValue ?? ""
        return StagedAttachment(path: path,
                                name: Self.lastComponent(path, fallback: "clipboard.png"),
                                paths: path.isEmpty ? [] : [path],
                                count: result["count"]?.intValue ?? 0)
    }

    // MARK: Shared checks

    /// Fail before the upload rather than after it — the server's own 4017/4018
    /// arrive only once the whole base64 body has crossed the wire.
    private static func checkPayload(_ data: Data, cap: Int, what: String) throws {
        guard !data.isEmpty else {
            throw GatewayError(code: AttachmentErrorCode.badPayload, message: "\(what) is empty")
        }
        guard data.count <= cap else {
            throw GatewayError(code: AttachmentErrorCode.tooLarge,
                               message: "\(what) too large (\(data.count) bytes; cap is \(AttachmentLimits.megabytes(cap)) MB)")
        }
    }

    /// clipboard.paste is the only attach RPC that reports refusal in-band;
    /// the rest raise. Treat a false `attached` as a failure either way.
    private static func checkAttached(_ result: JSONValue, fallback: String) throws {
        guard result["attached"]?.boolValue != true else { return }
        throw GatewayError(code: AttachmentErrorCode.writeFailed,
                           message: result["message"]?.stringValue ?? fallback)
    }

    private static func lastComponent(_ path: String, fallback: String) -> String {
        guard !path.isEmpty else { return fallback }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Encoding

/// Client-side shaping of attachment bytes: format normalization for the
/// gateway's image allow-list, tray thumbnails, and data-URL packing.
public enum AttachmentEncoder {

    /// Extensions image.attach_bytes accepts (cli.py:3609 `_IMAGE_EXTENSIONS`).
    public static let gatewayImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "ico",
    ]

    /// Camera-roll and RAW formats the gateway rejects with 4016 but ImageIO
    /// can decode — we transcode these to JPEG instead of failing the user.
    public static let transcodableImageExtensions: Set<String> = [
        "heic", "heif", "avif", "dng", "raw", "cr2", "nef", "arw",
    ]

    public static func fileExtension(of filename: String) -> String {
        URL(fileURLWithPath: filename).pathExtension.lowercased()
    }

    /// Does this filename name an image we can put through the image path?
    public static func isImage(filename: String) -> Bool {
        let ext = fileExtension(of: filename)
        return gatewayImageExtensions.contains(ext) || transcodableImageExtensions.contains(ext)
    }

    public static func isPDF(filename: String) -> Bool {
        fileExtension(of: filename) == "pdf"
    }

    /// Wire-ready image bytes. Accepted formats pass straight through;
    /// everything else (an iPhone's HEIC camera roll) is transcoded to JPEG,
    /// halving the long edge until it clears the 25 MB cap. Returns nil when
    /// ImageIO cannot decode the data at all.
    public static func gatewayImage(from data: Data, filename: String) -> (data: Data, filename: String)? {
        let ext = fileExtension(of: filename)
        if gatewayImageExtensions.contains(ext), data.count <= AttachmentLimits.imageBytes {
            return (data, filename)
        }
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let base = stem.isEmpty ? "image" : stem
        var maxPixel: CGFloat = 4096
        while true {
            guard let jpeg = jpegData(from: data, maxPixel: maxPixel) else { return nil }
            // 512 px is the floor: a JPEG that small is a few hundred KB, so
            // the loop always terminates well inside the cap.
            if jpeg.count <= AttachmentLimits.imageBytes || maxPixel <= 512 {
                return (jpeg, base + ".jpg")
            }
            maxPixel /= 2
        }
    }

    /// Bounded JPEG for the composer tray. Never re-uploaded — it exists so a
    /// staged 8 MP photo doesn't sit in the model at full size.
    public static func thumbnail(from data: Data, maxPixel: CGFloat = 240) -> Data? {
        jpegData(from: data, maxPixel: maxPixel, quality: 0.7)
    }

    /// "data:<mime>;base64,<b64>" — file.attach's upload shape
    /// (server.py:_decode_attachment_data_url).
    public static func dataURL(_ data: Data, filename: String) -> String {
        "data:\(mimeType(forFilename: filename));base64," + data.base64EncodedString()
    }

    public static func mimeType(forFilename filename: String) -> String {
        let ext = fileExtension(of: filename)
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: ext)?.preferredMIMEType { return type }
        #endif
        return "application/octet-stream"
    }

    /// Downscale + re-encode through ImageIO (available on both platforms, so
    /// the transcode path needs no UIKit).
    private static func jpegData(from data: Data, maxPixel: CGFloat, quality: CGFloat = 0.85) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Bake EXIF orientation into the pixels: the gateway hands raw
            // bytes to the vision model, which honors no orientation tag, so a
            // portrait photo would otherwise arrive on its side.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer as CFMutableData,
                                                                 "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
