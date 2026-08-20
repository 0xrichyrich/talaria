import Foundation

/// A request returned through the success transport path, but its body did
/// not contain the operation-specific receipt required to prove what Hermes
/// accepted. This is deliberately distinct from an explicit `ok: false`
/// refusal: callers must reconcile state instead of treating the write as
/// safely retryable.
public struct AckValidationError: Error, LocalizedError, Sendable, Equatable {
    public var operation: String
    public var detail: String

    public init(operation: String, detail: String = "Hermes returned a malformed success acknowledgement.") {
        self.operation = operation
        self.detail = detail
    }

    public var errorDescription: String? { "\(operation): \(detail)" }
}

public enum WorkspaceFileSizePolicy {
    public static let maximumBytes = 12 * 1_024 * 1_024

    public static func allows(byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount <= maximumBytes
    }

    static var maximumBase64Characters: Int {
        ((maximumBytes + 2) / 3) * 4
    }
}

// Typed, source-safe access to Hermes' portable workspace surfaces. These
// wrappers deliberately stop at authenticated gateway APIs: Electron-local
// process spawning, Finder/Explorer reveal and the desktop PTY are not remote
// capabilities and are never approximated with shell.exec.

/// Host paths in Hermes payloads belong to the gateway, not to the phone.
/// Foundation's file-URL helpers apply the *phone's* platform rules, which
/// turns a Windows drive or UNC path into a bogus POSIX parent on iOS/macOS.
/// This parser keeps the remote platform's root semantics and rejects any
/// traversal that would climb above that root.
public enum WorkspaceRemotePath {
    private enum Prefix: Equatable {
        case posix
        case drive(String)
        case unc(server: String, share: String)
        case relative

        var isCaseInsensitive: Bool {
            switch self {
            case .drive, .unc: true
            case .posix, .relative: false
            }
        }
    }

    private struct Parsed {
        var prefix: Prefix
        var segments: [String]
    }

    public static func normalized(_ raw: String) -> String? {
        parse(raw).map(render)
    }

    public static func parent(of raw: String) -> String? {
        guard var parsed = parse(raw), !parsed.segments.isEmpty else { return nil }
        parsed.segments.removeLast()
        if parsed.prefix == .relative, parsed.segments.isEmpty { return nil }
        return render(parsed)
    }

    public static func basename(of raw: String) -> String {
        guard let parsed = parse(raw) else { return "" }
        if let last = parsed.segments.last { return last }
        if case .unc(_, let share) = parsed.prefix { return share }
        return ""
    }

    public static func isFilesystemRoot(_ raw: String) -> Bool {
        guard let parsed = parse(raw) else { return false }
        return parsed.prefix != .relative && parsed.segments.isEmpty
    }

    public static func isAbsolute(_ raw: String) -> Bool {
        guard let parsed = parse(raw) else { return false }
        return parsed.prefix != .relative
    }

    public static func contains(_ rawPath: String, in rawRoot: String) -> Bool {
        guard let path = parse(rawPath), let root = parse(rawRoot),
              prefixesMatch(path.prefix, root.prefix),
              root.segments.count <= path.segments.count else { return false }
        let insensitive = root.prefix.isCaseInsensitive
        return root.segments.indices.allSatisfy { index in
            insensitive
                ? root.segments[index].caseInsensitiveCompare(path.segments[index]) == .orderedSame
                : root.segments[index] == path.segments[index]
        }
    }

    private static func parse(_ raw: String) -> Parsed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        let value = trimmed.replacingOccurrences(of: "\\", with: "/")

        let prefix: Prefix
        let pieces: [Substring]
        if value.hasPrefix("//") {
            let all = value.drop(while: { $0 == "/" }).split(separator: "/", omittingEmptySubsequences: true)
            guard all.count >= 2 else { return nil }
            prefix = .unc(server: String(all[0]), share: String(all[1]))
            pieces = Array(all.dropFirst(2))
        } else if value.count >= 3 {
            let chars = Array(value.prefix(3))
            if chars[0].isLetter, chars[1] == ":", chars[2] == "/" {
                prefix = .drive(String(chars[0]).uppercased())
                pieces = value.dropFirst(3).split(separator: "/", omittingEmptySubsequences: true)
            } else if value.dropFirst().first == ":" {
                // `C:relative` is drive-current-directory syntax. Its meaning
                // depends on process state and cannot be fenced remotely.
                return nil
            } else if value.hasPrefix("/") {
                prefix = .posix
                pieces = value.drop(while: { $0 == "/" }).split(separator: "/", omittingEmptySubsequences: true)
            } else {
                prefix = .relative
                pieces = value.split(separator: "/", omittingEmptySubsequences: true)
            }
        } else if value.hasPrefix("/") {
            prefix = .posix
            pieces = value.drop(while: { $0 == "/" }).split(separator: "/", omittingEmptySubsequences: true)
        } else if value.count >= 2, value.dropFirst().first == ":" {
            return nil
        } else {
            prefix = .relative
            pieces = value.split(separator: "/", omittingEmptySubsequences: true)
        }

        var segments: [String] = []
        for piece in pieces {
            if piece == "." { continue }
            if piece == ".." {
                guard !segments.isEmpty else { return nil }
                segments.removeLast()
            } else {
                segments.append(String(piece))
            }
        }
        if prefix == .relative, segments.isEmpty { return nil }
        return Parsed(prefix: prefix, segments: segments)
    }

    private static func render(_ parsed: Parsed) -> String {
        let suffix = parsed.segments.joined(separator: "/")
        switch parsed.prefix {
        case .posix:
            return suffix.isEmpty ? "/" : "/" + suffix
        case .drive(let drive):
            return suffix.isEmpty ? "\(drive):/" : "\(drive):/" + suffix
        case .unc(let server, let share):
            let root = "//\(server)/\(share)"
            return suffix.isEmpty ? root : root + "/" + suffix
        case .relative:
            return suffix
        }
    }

    private static func prefixesMatch(_ lhs: Prefix, _ rhs: Prefix) -> Bool {
        switch (lhs, rhs) {
        case (.posix, .posix), (.relative, .relative):
            return true
        case (.drive(let a), .drive(let b)):
            return a.caseInsensitiveCompare(b) == .orderedSame
        case (.unc(let aserver, let ashare), .unc(let bserver, let bshare)):
            return aserver.caseInsensitiveCompare(bserver) == .orderedSame
                && ashare.caseInsensitiveCompare(bshare) == .orderedSame
        default:
            return false
        }
    }
}

public struct GatewayWorkspaceRoute: Hashable, Sendable, Identifiable {
    public var gatewayID: String
    public var profile: String?

    public var id: String {
        gatewayID + "\u{1f}" + (profile ?? "")
    }

    public init(gatewayID: String, profile: String? = nil) {
        self.gatewayID = gatewayID
        self.profile = profile?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public enum WorkspaceFileSource: String, Hashable, Sendable {
    case managed
    case project
}

public struct ManagedFileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int
    public var modifiedAt: Double?
    public var mimeType: String
    public var source: WorkspaceFileSource

    init(_ value: JSONValue, source: WorkspaceFileSource = .managed) {
        name = value["name"]?.stringValue ?? ""
        path = value["path"]?.stringValue ?? ""
        isDirectory = value["is_directory"]?.boolValue
            ?? value["isDirectory"]?.boolValue ?? false
        size = value["size"]?.intValue ?? 0
        modifiedAt = value["mtime"]?.doubleValue
        mimeType = value["mime_type"]?.stringValue ?? "application/octet-stream"
        self.source = source
    }
}

public struct ManagedFileListing: Sendable {
    public var path: String
    public var parent: String?
    public var root: String
    public var lockedRoot: String?
    public var canChangePath: Bool
    public var entries: [ManagedFileEntry]
    public var source: WorkspaceFileSource

    init(_ value: JSONValue, source: WorkspaceFileSource = .managed, requestedPath: String? = nil) {
        path = value["path"]?.stringValue ?? requestedPath ?? ""
        if let wireParent = value["parent"]?.stringValue?.nilIfEmpty {
            parent = WorkspaceRemotePath.normalized(wireParent)
        } else if source == .project, let requestedPath {
            parent = WorkspaceRemotePath.parent(of: requestedPath)
        } else {
            parent = nil
        }
        root = value["root"]?.stringValue ?? requestedPath ?? ""
        lockedRoot = value["locked_root"]?.stringValue?.nilIfEmpty
        canChangePath = value["can_change_path"]?.boolValue ?? false
        self.source = source
        entries = value["entries"]?.arrayValue?.compactMap { row in
            let entry = ManagedFileEntry(row, source: source)
            return WorkspaceSensitivePath.allows(entry.path) ? entry : nil
        } ?? []
    }

    /// Decode only the locked managed-files shape that Hermes can fence with
    /// canonical real paths. An unlocked local-home listing or any response
    /// whose returned paths escape that fence is intentionally unavailable to
    /// a remote Command Center.
    init(validatingManaged value: JSONValue, requestedPath: String? = nil) throws {
        self.init(value, source: .managed, requestedPath: requestedPath)
        guard let locked = value["locked_root"]?.stringValue
            .flatMap(WorkspaceRemotePath.normalized),
              WorkspaceRemotePath.isAbsolute(locked),
              !WorkspaceRemotePath.isFilesystemRoot(locked),
              let returned = WorkspaceRemotePath.normalized(path),
              WorkspaceRemotePath.contains(returned, in: locked),
              remotePathsMatch(value["root"]?.stringValue, locked) else {
            throw GatewayError(
                code: 501,
                message: "Hermes did not provide a locked, canonical managed-files boundary. Files remain unavailable."
            )
        }
        if let requestedPath, !requestedPath.isEmpty,
           !remotePathsMatch(requestedPath, returned) {
            throw GatewayError(code: 502,
                               message: "Hermes returned a different managed directory than Talaria requested.")
        }
        if let parent = value["parent"]?.stringValue?.nilIfEmpty {
            guard let normalized = WorkspaceRemotePath.normalized(parent),
                  WorkspaceRemotePath.contains(normalized, in: locked) else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned an unsafe managed-directory parent.")
            }
            self.parent = normalized
        }
        guard let rows = value["entries"]?.arrayValue else {
            throw GatewayError(code: 502, message: "Hermes omitted the managed-directory entries.")
        }
        for row in rows {
            guard let child = row["path"]?.stringValue.flatMap(WorkspaceRemotePath.normalized),
                  WorkspaceRemotePath.contains(child, in: locked),
                  WorkspaceSensitivePath.allows(child) else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned an entry outside the managed-files safety boundary.")
            }
        }
        path = returned
        root = locked
        lockedRoot = locked
        entries = rows.map { ManagedFileEntry($0, source: .managed) }
    }
}

public struct ManagedFileBody: Sendable {
    public var name: String
    public var path: String
    public var mimeType: String
    public var bytes: Data
    public var isText: Bool
    public var isTruncated: Bool
    public var textPreview: String?
    public var lockedRoot: String?

    init(_ value: JSONValue, source: WorkspaceFileSource = .managed) throws {
        name = value["name"]?.stringValue ?? ""
        path = value["path"]?.stringValue ?? ""
        mimeType = value["mime_type"]?.stringValue ?? "application/octet-stream"
        lockedRoot = value["locked_root"]?.stringValue.flatMap(WorkspaceRemotePath.normalized)
        guard let encoded = value["data_url"]?.stringValue,
              let comma = encoded.firstIndex(of: ","),
              encoded[..<comma].contains(";base64") else {
            throw GatewayError(code: -71, message: "Managed file response contained invalid data.")
        }
        let payload = encoded[encoded.index(after: comma)...]
        guard payload.utf8.count <= WorkspaceFileSizePolicy.maximumBase64Characters else {
            throw GatewayError(code: 413, message: "This file exceeds Talaria’s 12 MB mobile preview limit.")
        }
        guard let decoded = Data(base64Encoded: String(payload)) else {
            throw GatewayError(code: -71, message: "Managed file response contained invalid data.")
        }
        guard WorkspaceFileSizePolicy.allows(byteCount: decoded.count) else {
            throw GatewayError(code: 413, message: "This file exceeds Talaria’s 12 MB mobile preview limit.")
        }
        if let declaredSize = value["size"]?.intValue, declaredSize != decoded.count {
            throw GatewayError(code: 502,
                               message: "Hermes returned managed-file bytes that do not match its declared size.")
        }
        bytes = decoded
        isText = mimeType.hasPrefix("text/")
        isTruncated = false
        textPreview = isText ? String(data: decoded, encoding: .utf8) : nil
    }

    init(validatingManaged value: JSONValue, requestedPath: String) throws {
        try self.init(value, source: .managed)
        guard let lockedRoot,
              WorkspaceRemotePath.isAbsolute(lockedRoot),
              !WorkspaceRemotePath.isFilesystemRoot(lockedRoot),
              let returned = WorkspaceRemotePath.normalized(path),
              remotePathsMatch(returned, requestedPath),
              WorkspaceRemotePath.contains(returned, in: lockedRoot),
              WorkspaceSensitivePath.allows(returned) else {
            throw GatewayError(code: 502,
                               message: "Hermes could not prove the requested file stayed inside its locked managed root.")
        }
        path = returned
    }

    init(project value: JSONValue, path: String) throws {
        self.path = value["path"]?.stringValue ?? path
        name = WorkspaceRemotePath.basename(of: path)
        mimeType = value["mimeType"]?.stringValue ?? "text/plain"
        lockedRoot = nil
        isTruncated = value["truncated"]?.boolValue ?? false
        let binary = value["binary"]?.boolValue ?? false
        isText = !binary
        if !binary, let text = value["text"]?.stringValue {
            bytes = Data(text.utf8)
            textPreview = text
        } else {
            bytes = Data()
            textPreview = nil
        }
    }
}

public struct HermesProjectFolder: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var label: String?
    public var isPrimary: Bool

    init(_ value: JSONValue) {
        path = value["path"]?.stringValue ?? ""
        label = value["label"]?.stringValue?.nilIfEmpty
        isPrimary = value["is_primary"]?.boolValue ?? false
    }
}

public struct HermesProject: Identifiable, Hashable, Sendable {
    public var id: String
    public var slug: String
    public var name: String
    public var description: String?
    public var icon: String?
    public var color: String?
    public var primaryPath: String?
    public var isArchived: Bool
    public var folders: [HermesProjectFolder]

    init(_ value: JSONValue) {
        id = value["id"]?.stringValue ?? ""
        slug = value["slug"]?.stringValue ?? ""
        name = value["name"]?.stringValue ?? slug
        description = value["description"]?.stringValue?.nilIfEmpty
        icon = value["icon"]?.stringValue?.nilIfEmpty
        color = value["color"]?.stringValue?.nilIfEmpty
        primaryPath = value["primary_path"]?.stringValue?.nilIfEmpty
        isArchived = value["archived"]?.boolValue ?? false
        folders = value["folders"]?.arrayValue?.map(HermesProjectFolder.init) ?? []
    }
}

public struct HermesProjectListing: Sendable {
    public var projects: [HermesProject]
    public var activeID: String?

    init(_ value: JSONValue) {
        projects = value["projects"]?.arrayValue?.map(HermesProject.init) ?? []
        activeID = value["active_id"]?.stringValue?.nilIfEmpty
    }

    init(validatingAcknowledgement value: JSONValue, operation: String) throws {
        guard value["projects"]?.arrayValue != nil,
              value["active_id"] == .null || value["active_id"]?.stringValue != nil else {
            throw AckValidationError(operation: operation,
                                     detail: "Hermes did not return a valid authoritative project listing.")
        }
        self.init(value)
    }
}

public struct HermesProjectSessionPreview: Identifiable, Hashable, Sendable {
    public var id: String { profile + "\u{1f}" + storedID }
    public var storedID: String
    public var profile: String
    public var title: String
    public var preview: String
    public var lastActive: Double

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.stringValue?.nilIfEmpty else { return nil }
        storedID = id
        profile = value["profile"]?.stringValue?.nilIfEmpty ?? "default"
        title = value["title"]?.stringValue?.nilIfEmpty ?? "Untitled session"
        preview = value["preview"]?.stringValue ?? ""
        lastActive = value["last_active"]?.doubleValue ?? value["started_at"]?.doubleValue ?? 0
    }
}

public struct HermesProjectTree: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var path: String?
    public var sessionCount: Int
    public var totalTokens: Int
    public var totalCostUSD: Double
    public var previews: [HermesProjectSessionPreview]

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.stringValue?.nilIfEmpty else { return nil }
        self.id = id
        label = value["label"]?.stringValue?.nilIfEmpty ?? id
        path = value["path"]?.stringValue?.nilIfEmpty
        sessionCount = value["sessionCount"]?.intValue ?? 0
        totalTokens = value["totalTokens"]?.intValue ?? 0
        totalCostUSD = value["totalCostUsd"]?.doubleValue ?? 0
        previews = value["previewSessions"]?.arrayValue?.compactMap(HermesProjectSessionPreview.init) ?? []
    }
}

public struct HermesGitFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var status: String
    public var staged: Bool
    public var unstaged: Bool
    public var added: Int
    public var removed: Int

    init(_ value: JSONValue) {
        path = value["path"]?.stringValue ?? ""
        status = value["status"]?.stringValue ?? "M"
        staged = value["staged"]?.boolValue ?? false
        unstaged = value["unstaged"]?.boolValue ?? !staged
        added = value["added"]?.intValue ?? 0
        removed = value["removed"]?.intValue ?? 0
    }
}

public struct HermesGitStatus: Sendable {
    public var branch: String?
    public var defaultBranch: String?
    public var detached: Bool
    public var ahead: Int
    public var behind: Int
    public var added: Int
    public var removed: Int
    public var files: [HermesGitFile]

    init(_ value: JSONValue) {
        branch = value["branch"]?.stringValue?.nilIfEmpty
        defaultBranch = value["defaultBranch"]?.stringValue?.nilIfEmpty
        detached = value["detached"]?.boolValue ?? false
        ahead = value["ahead"]?.intValue ?? 0
        behind = value["behind"]?.intValue ?? 0
        added = value["added"]?.intValue ?? 0
        removed = value["removed"]?.intValue ?? 0
        files = value["files"]?.arrayValue?.map(HermesGitFile.init) ?? []
    }
}

public struct HermesGitBranch: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var checkedOut: Bool
    public var isDefault: Bool
    public var isRemote: Bool
    public var worktreePath: String?

    init(_ value: JSONValue) {
        name = value["name"]?.stringValue ?? ""
        checkedOut = value["checkedOut"]?.boolValue ?? false
        isDefault = value["isDefault"]?.boolValue ?? false
        isRemote = value["isRemote"]?.boolValue ?? false
        worktreePath = value["worktreePath"]?.stringValue?.nilIfEmpty
    }
}

public struct HermesGitWorktree: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var branch: String?
    public var isMain: Bool
    public var detached: Bool
    public var locked: Bool

    init(_ value: JSONValue) {
        path = value["path"]?.stringValue ?? ""
        branch = value["branch"]?.stringValue?.nilIfEmpty
        isMain = value["isMain"]?.boolValue ?? false
        detached = value["detached"]?.boolValue ?? false
        locked = value["locked"]?.boolValue ?? false
    }
}

public enum HermesCommandOrigin: String, Hashable, Sendable {
    case builtIn
    case skill
    case quickCommand
    case unclassified
}

public struct HermesCommand: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var summary: String
    public var origin: HermesCommandOrigin
}

public enum WorkspaceCommandDisposition: Equatable, Sendable {
    case readOnly
    case recoverablePromptDraft
    case unsupported(String)
}

/// Command Center never asks `command.dispatch` to classify an arbitrary
/// name: a user quick command can execute a shell before its result type is
/// returned. Eligibility therefore comes from this app-owned policy plus the
/// catalog's authoritative origin metadata.
public enum WorkspaceCommandPolicy {
    private static let noArgumentReadOnly: Set<String> = [
        "agents", "bundles", "gateway", "insights", "platforms", "plugins",
        "profile", "status", "tasks", "toolsets", "usage", "version", "whoami",
    ]
    private static let destructiveSemantic: Set<String> = ["goal", "moa", "retry", "undo"]

    public static func canonicalName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.drop(while: { $0 == "/" })).lowercased()
    }

    public static func catalogCommand(named raw: String, in catalog: [HermesCommand]) -> HermesCommand? {
        let name = canonicalName(raw)
        guard !name.isEmpty else { return nil }
        return catalog.first { canonicalName($0.name) == name }
    }

    public static func isCatalogEligible(_ command: HermesCommand) -> Bool {
        let name = canonicalName(command.name)
        guard !destructiveSemantic.contains(name) else { return false }
        switch command.origin {
        case .skill:
            return true
        case .quickCommand, .unclassified:
            return false
        case .builtIn:
            return noArgumentReadOnly.contains(name)
                || ["help", "context", "egress", "queue"].contains(name)
        }
    }

    public static func disposition(for command: HermesCommand,
                                   argument rawArgument: String) -> WorkspaceCommandDisposition {
        let name = canonicalName(command.name)
        let argument = rawArgument.trimmingCharacters(in: .whitespacesAndNewlines)

        if destructiveSemantic.contains(name) {
            return .unsupported("/\(name) changes session or agent state and has no Command Center-specific confirmation design.")
        }
        switch command.origin {
        case .quickCommand:
            return .unsupported("User quick commands are not dispatched because they can execute arbitrary shell or plugin code before returning a type.")
        case .unclassified:
            return .unsupported("Hermes did not classify this command as a built-in or skill.")
        case .skill:
            return .recoverablePromptDraft
        case .builtIn:
            break
        }

        if name == "queue" {
            return argument.isEmpty
                ? .unsupported("/queue requires a prompt.")
                : .recoverablePromptDraft
        }
        if name == "help" { return .readOnly }
        if name == "context" {
            return argument.isEmpty || argument.lowercased() == "all"
                ? .readOnly
                : .unsupported("Command Center supports only /context or /context all.")
        }
        if name == "egress" {
            return argument.isEmpty || argument.lowercased() == "status"
                ? .readOnly
                : .unsupported("Command Center exposes only read-only egress status.")
        }
        if noArgumentReadOnly.contains(name) {
            return argument.isEmpty
                ? .readOnly
                : .unsupported("/\(name) is read-only here and does not accept arguments.")
        }
        return .unsupported("This built-in is outside Command Center’s code-owned safe allowlist.")
    }
}

public enum HermesCommandDispatch: Sendable, Equatable {
    case exec(String)
    case plugin(String)
    case alias(String)
    case skill(name: String, message: String, display: String?)
    case send(message: String, notice: String?, display: String?)
    case prefill(message: String, notice: String?)

    init(_ value: JSONValue) throws {
        switch value["type"]?.stringValue {
        case "exec":
            guard let output = value["output"]?.stringValue else {
                throw GatewayError(code: -83, message: "Hermes returned an invalid command output directive.")
            }
            self = .exec(output)
        case "plugin":
            guard let output = value["output"]?.stringValue else {
                throw GatewayError(code: -83, message: "Hermes returned an invalid plugin directive.")
            }
            self = .plugin(output)
        case "alias":
            guard let target = value["target"]?.stringValue?.nilIfEmpty else {
                throw GatewayError(code: -83, message: "Hermes returned an invalid alias directive.")
            }
            self = .alias(target)
        case "skill":
            guard let name = value["name"]?.stringValue?.nilIfEmpty,
                  let message = value["message"]?.stringValue?.nilIfEmpty else {
                throw GatewayError(code: -83, message: "Hermes returned an invalid skill directive.")
            }
            self = .skill(name: name, message: message,
                          display: value["display"]?.stringValue?.nilIfEmpty)
        case "send":
            guard let message = value["message"]?.stringValue?.nilIfEmpty else {
                throw GatewayError(code: -83, message: "Hermes returned a command without its model message.")
            }
            self = .send(message: message,
                         notice: value["notice"]?.stringValue?.nilIfEmpty,
                         display: value["display"]?.stringValue?.nilIfEmpty)
        case "prefill":
            guard let message = value["message"]?.stringValue else {
                throw GatewayError(code: -83, message: "Hermes returned an invalid prefill directive.")
            }
            self = .prefill(message: message, notice: value["notice"]?.stringValue?.nilIfEmpty)
        default:
            throw GatewayError(code: -83, message: "Hermes returned an unsupported command directive.")
        }
    }
}

public enum ManagedTextWriteResult: Sendable, Equatable {
    case saved
    case conflict(current: Data)
}

public struct HermesUpdateCheck: Sendable, Equatable {
    public var canApply: Bool
    public var recommendedCommand: String?
    public var message: String?
    public var raw: JSONValue

    init(_ value: JSONValue) throws {
        guard let canApply = value["can_apply"]?.boolValue else {
            throw GatewayError(code: -86, message: "Hermes did not report whether this installation can update itself.")
        }
        self.canApply = canApply
        recommendedCommand = value["update_command"]?.stringValue?.nilIfEmpty
            ?? value["recommended_command"]?.stringValue?.nilIfEmpty
        message = value["message"]?.stringValue?.nilIfEmpty
        raw = value
    }
}

public struct HermesProcess: Identifiable, Hashable, Sendable {
    public var id: String
    public var command: String
    public var status: String
    public var cwd: String
    public var outputTail: String
    public var uptimeSeconds: Int

    init(_ value: JSONValue) {
        id = value["session_id"]?.stringValue
            ?? value["id"]?.stringValue ?? value["process_id"]?.stringValue ?? ""
        command = value["command"]?.stringValue ?? value["cmd"]?.stringValue ?? ""
        status = value["status"]?.stringValue ?? "running"
        cwd = value["cwd"]?.stringValue ?? ""
        outputTail = value["output_tail"]?.stringValue
            ?? value["output_preview"]?.stringValue ?? ""
        uptimeSeconds = value["uptime_seconds"]?.intValue ?? 0
    }
}

public extension GatewayClient {
    func workspaceStatus() async throws -> JSONValue {
        try await restJSON(path: "api/status", timeout: 15)
    }

    func workspaceMemoryStatus() async throws -> JSONValue {
        try await restJSON(path: "api/memory", timeout: 30)
    }

    func workspaceCuratorStatus() async throws -> JSONValue {
        try await restJSON(path: "api/curator", timeout: 30)
    }

    func setWorkspaceCuratorPaused(_ paused: Bool) async throws -> JSONValue {
        let response = try await restJSON(path: "api/curator/paused", method: "PUT",
                                          body: .object(["paused": .bool(paused)]), timeout: 30)
        if response["ok"]?.boolValue == false {
            throw GatewayError(code: 409, message: "Hermes refused the curator state change.")
        }
        guard response["ok"]?.boolValue == true,
              response["paused"]?.boolValue == paused else {
            throw AckValidationError(operation: "Change curator state")
        }
        return response
    }

    func runWorkspaceCurator() async throws -> JSONValue {
        let response = try await restJSON(path: "api/curator/run", method: "POST",
                                          body: .object([:]), timeout: 30)
        try requireAccepted(response, operation: "Run curator")
        guard response["name"]?.stringValue == "curator-run",
              response["pid"]?.intValue != nil else {
            throw AckValidationError(operation: "Run curator",
                                     detail: "Hermes omitted the accepted curator action identity.")
        }
        return response
    }

    func workspaceUsage(days: Int = 30, profile: String? = nil) async throws -> JSONValue {
        var query = [URLQueryItem(name: "days", value: String(min(max(days, 1), 365)))]
        if let profile = profile?.nilIfEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        return try await restJSON(path: "api/analytics/usage", query: query, timeout: 60)
    }

    func startWorkspaceAction(path: String, body: JSONValue? = nil,
                              timeout: TimeInterval = 30) async throws -> JSONValue {
        try await restJSON(path: path, method: "POST", body: body ?? .object([:]), timeout: timeout)
    }

    func workspaceActionStatus(name: String) async throws -> JSONValue {
        try await restJSON(path: "api/actions/\(name)/status", timeout: 15)
    }

    func checkHermesUpdate() async throws -> HermesUpdateCheck {
        try HermesUpdateCheck(try await restJSON(path: "api/hermes/update/check", timeout: 60))
    }

    func resetWorkspaceMemory(target: String) async throws -> JSONValue {
        guard ["all", "memory", "user"].contains(target) else {
            throw GatewayError(code: -81, message: "Unsupported memory reset target.")
        }
        return try await startWorkspaceAction(path: "api/memory/reset",
                                              body: .object(["target": .string(target)]))
    }

    func createDebugShare() async throws -> JSONValue {
        try await startWorkspaceAction(path: "api/ops/debug-share",
                                       body: .object(["lines": .number(1000), "redact": .bool(true)]),
                                       timeout: 120)
    }

    func managedFiles(path: String? = nil) async throws -> ManagedFileListing {
        let query = path?.nilIfEmpty.map { [URLQueryItem(name: "path", value: $0)] } ?? []
        return try ManagedFileListing(
            validatingManaged: try await restJSON(path: "api/files", query: query),
            requestedPath: path
        )
    }

    func managedFile(path: String) async throws -> ManagedFileBody {
        try ManagedFileBody(
            validatingManaged: try await restJSON(
                path: "api/files/read",
                query: [URLQueryItem(name: "path", value: path)], timeout: 60
            ),
            requestedPath: path
        )
    }

    func projectFiles(path: String) async throws -> ManagedFileListing {
        _ = path
        throw GatewayError(
            code: 501,
            message: "Project files are unavailable because this Hermes version does not return an authoritative realpath/containment proof. Managed Files remain available."
        )
    }

    func projectFile(path: String) async throws -> ManagedFileBody {
        _ = path
        throw GatewayError(
            code: 501,
            message: "Project-file content is blocked until Hermes can prove the resolved target remains inside the selected project root."
        )
    }

    func discoveredWorkspaceRoots() async throws -> [String] {
        let response = try await rpc("projects.discover_repos")
        return response["repos"]?.arrayValue?.compactMap {
            $0.stringValue?.nilIfEmpty ?? $0["root"]?.stringValue?.nilIfEmpty
        } ?? []
    }

    @discardableResult
    func uploadManagedFile(path: String, bytes: Data, mimeType: String,
                           overwrite: Bool) async throws -> ManagedFileEntry {
        guard WorkspaceFileSizePolicy.allows(byteCount: bytes.count) else {
            throw GatewayError(code: 413, message: "Files larger than 12 MB are not uploaded from the phone.")
        }
        let dataURL = "data:\(mimeType);base64,\(bytes.base64EncodedString())"
        let response = try await restJSON(path: "api/files/upload", method: "POST", body: .object([
            "path": .string(path), "data_url": .string(dataURL), "overwrite": .bool(overwrite),
        ]), timeout: 120)
        try requireAccepted(response, operation: "Managed file upload")
        try requireManagedFence(response, target: path, operation: "Managed file upload")
        guard let entry = response["entry"],
              remotePathsEqual(entry["path"]?.stringValue, path) else {
            throw AckValidationError(operation: "Managed file upload",
                                     detail: "Hermes did not return the exact uploaded path.")
        }
        return ManagedFileEntry(entry)
    }

    @discardableResult
    func createManagedDirectory(path: String) async throws -> ManagedFileEntry {
        let response = try await restJSON(path: "api/files/mkdir", method: "POST",
                                          body: .object(["path": .string(path)]))
        try requireAccepted(response, operation: "Managed directory creation")
        try requireManagedFence(response, target: path, operation: "Managed directory creation")
        guard let entry = response["entry"], remotePathsEqual(entry["path"]?.stringValue, path),
              entry["is_directory"]?.boolValue == true else {
            throw AckValidationError(operation: "Managed directory creation",
                                     detail: "Hermes did not return the exact created directory.")
        }
        return ManagedFileEntry(entry)
    }

    func deleteManagedFile(path: String, recursive: Bool = false) async throws {
        let response = try await restJSON(path: "api/files", method: "DELETE", body: .object([
            "path": .string(path), "recursive": .bool(recursive),
        ]))
        try requireAccepted(response, operation: "Managed file deletion")
        try requireManagedFence(response, target: path, operation: "Managed file deletion")
        guard remotePathsEqual(response["path"]?.stringValue, path) else {
            throw AckValidationError(operation: "Managed file deletion",
                                     detail: "Hermes did not echo the deleted path.")
        }
    }

    func projects() async throws -> HermesProjectListing {
        HermesProjectListing(try await rpc("projects.list"))
    }

    func allProfileProjectTree() async throws -> [HermesProjectTree] {
        let value = try await restJSON(path: "api/profiles/projects/tree", query: [
            URLQueryItem(name: "preview_limit", value: "100"),
            URLQueryItem(name: "session_limit", value: "5000"),
        ], timeout: 60)
        if let errors = value["errors"]?.arrayValue, !errors.isEmpty,
           (value["projects"]?.arrayValue ?? []).isEmpty {
            throw GatewayError(code: 500, message: "Hermes could not read any profile project tree.")
        }
        return value["projects"]?.arrayValue?.compactMap(HermesProjectTree.init) ?? []
    }

    /// On-demand all-profile drill-in. Hermes' overview is preview-bounded;
    /// request the protocol's maximum hydration window only when a user enters
    /// a project. Never substitute Talaria's local session cache, and never
    /// present a server-truncated list as complete.
    func allProfileProjectSessions(id: String) async throws -> HermesProjectTree {
        let value = try await restJSON(path: "api/profiles/projects/tree", query: [
            URLQueryItem(name: "preview_limit", value: "5000"),
            URLQueryItem(name: "session_limit", value: "5000"),
        ], timeout: 120)
        if let errors = value["errors"]?.arrayValue, !errors.isEmpty {
            throw GatewayError(code: 502,
                               message: "Hermes could not hydrate every profile for this project.")
        }
        guard let project = value["projects"]?.arrayValue?
            .compactMap(HermesProjectTree.init)
            .first(where: { $0.id == id }) else {
            throw GatewayError(code: 404, message: "Hermes no longer reports this project.")
        }
        guard project.previews.count >= project.sessionCount else {
            throw GatewayError(
                code: 501,
                message: "This project exceeds Hermes’ bounded all-profile drill-in window; Talaria will not present a partial session list as authoritative."
            )
        }
        return project
    }

    func createProject(name: String, folders: [String], primaryPath: String?,
                       description: String? = nil, use: Bool = false) async throws -> HermesProject {
        var body: [String: JSONValue] = [
            "name": .string(name), "folders": .array(folders.map(JSONValue.string)), "use": .bool(use),
        ]
        if let primaryPath = primaryPath?.nilIfEmpty { body["primary_path"] = .string(primaryPath) }
        if let description = description?.nilIfEmpty { body["description"] = .string(description) }
        let response = try await rpc("projects.create", .object(body))
        guard let project = response["project"],
              let id = project["id"]?.stringValue?.nilIfEmpty else {
            throw AckValidationError(operation: "Create project",
                                     detail: "Hermes did not return the created project identity.")
        }
        let decoded = HermesProject(project)
        guard decoded.id == id else {
            throw AckValidationError(operation: "Create project")
        }
        return decoded
    }

    func updateProject(id: String, name: String? = nil, description: String? = nil,
                       icon: String? = nil, color: String? = nil) async throws -> HermesProject {
        var body: [String: JSONValue] = ["id": .string(id)]
        if let name { body["name"] = .string(name) }
        if let description { body["description"] = .string(description) }
        if let icon { body["icon"] = .string(icon) }
        if let color { body["color"] = .string(color) }
        let response = try await rpc("projects.update", .object(body))
        guard let project = response["project"], project["id"]?.stringValue == id else {
            throw AckValidationError(operation: "Update project",
                                     detail: "Hermes did not return the updated project identity.")
        }
        return HermesProject(project)
    }

    func addProjectFolder(id: String, path: String, label: String? = nil,
                          isPrimary: Bool = false) async throws -> HermesProject {
        var body: [String: JSONValue] = [
            "id": .string(id), "path": .string(path), "is_primary": .bool(isPrimary),
        ]
        if let label = label?.nilIfEmpty { body["label"] = .string(label) }
        let response = try await rpc("projects.add_folder", .object(body))
        guard let project = response["project"], project["id"]?.stringValue == id else {
            throw AckValidationError(operation: "Add project folder",
                                     detail: "Hermes did not return the updated project identity.")
        }
        return HermesProject(project)
    }

    func removeProjectFolder(id: String, path: String) async throws -> HermesProject {
        let response = try await rpc("projects.remove_folder", .object([
            "id": .string(id), "path": .string(path),
        ]))
        guard let project = response["project"], project["id"]?.stringValue == id else {
            throw AckValidationError(operation: "Remove project folder",
                                     detail: "Hermes did not return the updated project identity.")
        }
        return HermesProject(project)
    }

    func setPrimaryProjectFolder(id: String, path: String) async throws -> HermesProject {
        let response = try await rpc("projects.set_primary", .object([
            "id": .string(id), "path": .string(path),
        ]))
        guard let project = response["project"], project["id"]?.stringValue == id else {
            throw AckValidationError(operation: "Set primary project folder",
                                     detail: "Hermes did not return the updated project identity.")
        }
        return HermesProject(project)
    }

    func archiveProject(id: String, restore: Bool = false) async throws -> HermesProjectListing {
        try HermesProjectListing(validatingAcknowledgement: try await rpc("projects.archive", .object([
            "id": .string(id), "restore": .bool(restore),
        ])), operation: restore ? "Restore project" : "Archive project")
    }

    func deleteProject(id: String) async throws -> HermesProjectListing {
        try HermesProjectListing(validatingAcknowledgement:
            try await rpc("projects.delete", .object(["id": .string(id)])),
            operation: "Delete project")
    }

    func setActiveProject(id: String?) async throws -> String? {
        let response = try await rpc("projects.set_active", .object([
            "id": id.map(JSONValue.string) ?? .null,
        ]))
        let active = response["active_id"]?.stringValue?.nilIfEmpty
        if let id, active != id {
            throw AckValidationError(operation: "Select project",
                                     detail: "Hermes did not echo the selected project identity.")
        }
        if id == nil, response["active_id"] != .null {
            throw AckValidationError(operation: "Clear active project")
        }
        return active
    }

    func workspaceGitStatus(path: String) async throws -> HermesGitStatus {
        let value = try await restJSON(path: "api/git/status",
                                       query: [URLQueryItem(name: "path", value: path)])
        guard value != .null else {
            throw GatewayError(code: 404, message: "The selected folder is not a Git repository.")
        }
        return HermesGitStatus(value)
    }

    func gitReviewFiles(path: String) async throws -> [HermesGitFile] {
        let value = try await restJSON(path: "api/git/review/list", query: [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "scope", value: "uncommitted"),
        ])
        return value["files"]?.arrayValue?.map(HermesGitFile.init) ?? []
    }

    func gitBranches(path: String) async throws -> [HermesGitBranch] {
        let value = try await restJSON(path: "api/git/branches",
                                       query: [URLQueryItem(name: "path", value: path)])
        return value["branches"]?.arrayValue?.map(HermesGitBranch.init) ?? []
    }

    func gitWorktrees(path: String) async throws -> [HermesGitWorktree] {
        let value = try await restJSON(path: "api/git/worktrees",
                                       query: [URLQueryItem(name: "path", value: path)])
        return value["worktrees"]?.arrayValue?.map(HermesGitWorktree.init) ?? []
    }

    func gitBaseBranches(path: String) async throws -> [HermesGitBranch] {
        let value = try await restJSON(path: "api/git/base-branches",
                                       query: [URLQueryItem(name: "path", value: path)])
        return value["branches"]?.arrayValue?.map(HermesGitBranch.init) ?? []
    }

    func addGitWorktree(path: String, name: String, branch: String,
                        base: String?) async throws {
        var body: [String: JSONValue] = [
            "path": .string(path), "name": .string(name), "branch": .string(branch),
        ]
        if let base = base?.nilIfEmpty { body["base"] = .string(base) }
        let response = try await restJSON(path: "api/git/worktree/add", method: "POST",
                                          body: .object(body), timeout: 120)
        guard response["path"]?.stringValue?.nilIfEmpty != nil,
              response["branch"]?.stringValue == branch else {
            throw AckValidationError(operation: "Create Git worktree")
        }
    }

    /// Convert a local or remote-tracking ref into a worktree using Hermes'
    /// `existingBranch` contract. Passing `origin/feature` to branch/switch is
    /// not equivalent: it can fail or detach HEAD instead of creating the
    /// tracking local branch that the desktop flow promises.
    func addExistingGitWorktree(path: String, branch: String) async throws {
        let response = try await restJSON(path: "api/git/worktree/add", method: "POST",
                                          body: .object([
                                            "path": .string(path),
                                            "existingBranch": .string(branch),
                                          ]), timeout: 120)
        let expectedLocal = branch.split(separator: "/", maxSplits: 1)
            .dropFirst().first.map(String.init) ?? branch
        guard response["path"]?.stringValue?.nilIfEmpty != nil,
              response["branch"]?.stringValue == expectedLocal else {
            throw AckValidationError(operation: "Create branch worktree")
        }
    }

    func switchGitBranch(path: String, branch: String) async throws {
        let response = try await restJSON(path: "api/git/branch/switch", method: "POST", body: .object([
            "path": .string(path), "branch": .string(branch),
        ]), timeout: 60)
        guard response["branch"]?.stringValue == branch else {
            throw AckValidationError(operation: "Switch Git branch")
        }
    }

    func removeGitWorktree(path: String, worktreePath: String, force: Bool = false) async throws {
        let response = try await restJSON(path: "api/git/worktree/remove", method: "POST", body: .object([
            "path": .string(path), "worktreePath": .string(worktreePath), "force": .bool(force),
        ]), timeout: 60)
        guard remotePathsEqual(response["removed"]?.stringValue, worktreePath) else {
            throw AckValidationError(operation: "Remove Git worktree")
        }
    }

    func gitDiff(path: String, file: String, staged: Bool = false) async throws -> String {
        let value = try await restJSON(path: "api/git/review/diff", query: [
            URLQueryItem(name: "path", value: path), URLQueryItem(name: "file", value: file),
            URLQueryItem(name: "scope", value: "uncommitted"),
            URLQueryItem(name: "staged", value: staged ? "true" : "false"),
        ])
        return value["diff"]?.stringValue ?? ""
    }

    func mutateGitFile(path: String, file: String, action: String) async throws {
        guard ["stage", "unstage", "revert"].contains(action) else {
            throw GatewayError(code: -79, message: "Unsupported Git file action.")
        }
        let response = try await restJSON(path: "api/git/review/\(action)", method: "POST", body: .object([
            "path": .string(path), "file": .string(file),
        ]))
        try requireAccepted(response, operation: "Git \(action)")
    }

    func commitGit(path: String, message: String, push: Bool = false) async throws {
        let response = try await restJSON(path: "api/git/review/commit", method: "POST", body: .object([
            "path": .string(path), "message": .string(message), "push": .bool(push),
        ]), timeout: 120)
        try requireAccepted(response, operation: "Git commit")
    }

    func pushGit(path: String) async throws {
        let response = try await restJSON(path: "api/git/review/push", method: "POST",
                                          body: .object(["path": .string(path)]), timeout: 120)
        try requireAccepted(response, operation: "Git push")
    }

    func createPullRequest(path: String) async throws -> URL {
        let response = try await restJSON(path: "api/git/review/create-pr", method: "POST",
                                          body: .object(["path": .string(path)]), timeout: 120)
        guard let raw = response["url"]?.stringValue?.nilIfEmpty,
              let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw AckValidationError(operation: "Create pull request",
                                     detail: "Hermes did not return a valid pull request URL.")
        }
        return url
    }

    func commandCatalog() async throws -> [HermesCommand] {
        let response = try await rpc("commands.catalog")
        let skills = Set(response["skills"]?.objectValue?.keys.map {
            WorkspaceCommandPolicy.canonicalName($0)
        } ?? [])
        let quickCommands = Set(response["categories"]?.arrayValue?.flatMap { category -> [String] in
            guard category["name"]?.stringValue == "User commands" else { return [] }
            return category["pairs"]?.arrayValue?.compactMap {
                $0.arrayValue?.first?.stringValue.map(WorkspaceCommandPolicy.canonicalName)
            } ?? []
        } ?? [])
        let categorizedBuiltIns = Set(response["categories"]?.arrayValue?.flatMap { category -> [String] in
            guard category["name"]?.stringValue != "User commands" else { return [] }
            return category["pairs"]?.arrayValue?.compactMap {
                $0.arrayValue?.first?.stringValue.map(WorkspaceCommandPolicy.canonicalName)
            } ?? []
        } ?? [])
        return response["pairs"]?.arrayValue?.compactMap { pair in
            guard let parts = pair.arrayValue, let name = parts.first?.stringValue?.nilIfEmpty else { return nil }
            let canonical = WorkspaceCommandPolicy.canonicalName(name)
            let origin: HermesCommandOrigin
            // command.dispatch checks user quick commands before skills, so a
            // collision must inherit the executable quick-command risk.
            if quickCommands.contains(canonical) { origin = .quickCommand }
            else if skills.contains(canonical) { origin = .skill }
            else if categorizedBuiltIns.contains(canonical) { origin = .builtIn }
            else { origin = .unclassified }
            return HermesCommand(name: name, summary: parts.dropFirst().first?.stringValue ?? "",
                                 origin: origin)
        } ?? []
    }

    func dispatchHermesCommand(sessionID: String, name: String, argument: String) async throws
        -> HermesCommandDispatch {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = String(trimmed.drop(while: { $0 == "/" }))
        guard !canonical.isEmpty,
              canonical.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw GatewayError(code: -82, message: "Choose a Hermes command.")
        }
        return try HermesCommandDispatch(try await rpc("command.dispatch", .object([
            "session_id": .string(sessionID), "name": .string(canonical),
            "arg": .string(argument),
        ]), timeout: 120))
    }

    func processes(sessionID: String) async throws -> [HermesProcess] {
        let response = try await rpc("process.list", .object(["session_id": .string(sessionID)]))
        return response["processes"]?.arrayValue?.map(HermesProcess.init) ?? []
    }

    func killProcess(sessionID: String, processID: String) async throws {
        let response = try await rpc("process.kill", .object([
            "session_id": .string(sessionID), "process_id": .string(processID),
        ]))
        guard let status = response["status"]?.stringValue else {
            throw AckValidationError(operation: "Stop background process")
        }
        guard ["killed", "already_exited"].contains(status) else {
            throw GatewayError(code: 409, message: response["error"]?.stringValue
                               ?? "Hermes refused to stop the background process.")
        }
    }

    private func requireAccepted(_ response: JSONValue, operation: String) throws {
        if response["ok"]?.boolValue == false {
            let detail = response["detail"]?.stringValue
                ?? response["message"]?.stringValue
                ?? response["error"]?.stringValue
                ?? "Hermes did not confirm acceptance."
            throw GatewayError(code: -84, message: "\(operation) was refused: \(detail)")
        }
        guard response["ok"]?.boolValue == true else {
            throw AckValidationError(operation: operation)
        }
    }

    private func remotePathsEqual(_ lhs: String?, _ rhs: String) -> Bool {
        remotePathsMatch(lhs, rhs)
    }

    private func requireManagedFence(_ response: JSONValue, target: String,
                                     operation: String) throws {
        guard let locked = response["locked_root"]?.stringValue
            .flatMap(WorkspaceRemotePath.normalized),
              WorkspaceRemotePath.isAbsolute(locked),
              !WorkspaceRemotePath.isFilesystemRoot(locked),
              let normalizedTarget = WorkspaceRemotePath.normalized(target),
              WorkspaceRemotePath.contains(normalizedTarget, in: locked),
              remotePathsMatch(response["root"]?.stringValue, locked) else {
            throw AckValidationError(
                operation: operation,
                detail: "Hermes did not echo the locked managed-files boundary for the accepted write."
            )
        }
    }
}

public enum WorkspaceSensitivePath {
    private static let basenames: Set<String> = [
        "auth.json", "auth.lock", "credentials", "config.yaml",
        ".anthropic_oauth.json", "google_token.json", "google_oauth_pending.json",
        "google_oauth.json", "webhook_subscriptions.json", "bws_cache.json",
        "bws_cache.enc.json", ".git-credentials",
    ]
    private static let directoryNames: Set<String> = ["mcp-tokens", "pairing", ".ssh", ".gnupg"]

    public static func allows(_ path: String) -> Bool {
        let parts = path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").map { $0.lowercased() }
        guard let name = parts.last else { return false }
        if name == ".env" || name.hasPrefix(".env.") || name == ".envrc" { return false }
        if basenames.contains(name) { return false }
        return parts.allSatisfy { !directoryNames.contains($0) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private func remotePathsMatch(_ lhs: String?, _ rhs: String) -> Bool {
    guard let lhs = lhs.flatMap(WorkspaceRemotePath.normalized),
          let rhs = WorkspaceRemotePath.normalized(rhs) else { return false }
    return WorkspaceRemotePath.contains(lhs, in: rhs)
        && WorkspaceRemotePath.contains(rhs, in: lhs)
}
