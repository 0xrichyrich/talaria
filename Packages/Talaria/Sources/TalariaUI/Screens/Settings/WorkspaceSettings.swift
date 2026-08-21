import SwiftUI
import TalariaKit
import TalariaTheme

// Phone-sized, Settings-only remote of Hermes Desktop's files + git rails.
// This is not a PTY and not a tab-bar Command Center. Authenticated REST only:
//   GET /api/files            hermes_cli/web_server.py:2553
//   GET /api/files/read       hermes_cli/web_server.py:2586
//   GET /api/git/status       hermes_cli/web_routers/git.py:33

public struct GatewayFileEntry: Equatable, Identifiable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int?
    public var mimeType: String?
    public var id: String { path }

    init(_ value: JSONValue) {
        name = value["name"]?.stringValue ?? ""
        path = value["path"]?.stringValue ?? name
        isDirectory = value["is_directory"]?.boolValue ?? false
        size = value["size"]?.intValue
        mimeType = value["mime_type"]?.stringValue
    }
}

public struct GatewayFileListing: Equatable, Sendable {
    var path: String
    public var parent: String?
    public var entries: [GatewayFileEntry]
    public var lockedRoot: String?

    static let empty = GatewayFileListing(path: "", parent: nil, entries: [], lockedRoot: nil)

    init(path: String, parent: String?, entries: [GatewayFileEntry], lockedRoot: String?) {
        self.path = path; self.parent = parent; self.entries = entries; self.lockedRoot = lockedRoot
    }

    init(_ value: JSONValue) {
        path = value["path"]?.stringValue ?? ""
        parent = value["parent"]?.stringValue
        lockedRoot = value["locked_root"]?.stringValue ?? value["root"]?.stringValue
        entries = (value["entries"]?.arrayValue ?? []).map(GatewayFileEntry.init)
    }
}

public struct GatewayGitStatus: Equatable, Sendable {
    public var branch: String
    public var ahead: Int
    public var behind: Int
    public var staged: Int
    public var unstaged: Int
    public var untracked: Int
    public var changed: Int
    public var files: [String]

    static let empty = GatewayGitStatus(branch: "", ahead: 0, behind: 0, staged: 0,
                                        unstaged: 0, untracked: 0, changed: 0, files: [])

    init(branch: String, ahead: Int, behind: Int, staged: Int, unstaged: Int,
         untracked: Int, changed: Int, files: [String]) {
        self.branch = branch; self.ahead = ahead; self.behind = behind
        self.staged = staged; self.unstaged = unstaged; self.untracked = untracked
        self.changed = changed; self.files = files
    }

    init(_ value: JSONValue) {
        branch = value["branch"]?.stringValue ?? ""
        ahead = value["ahead"]?.intValue ?? 0
        behind = value["behind"]?.intValue ?? 0
        staged = value["staged"]?.intValue ?? 0
        unstaged = value["unstaged"]?.intValue ?? 0
        untracked = value["untracked"]?.intValue ?? 0
        changed = value["changed"]?.intValue ?? 0
        files = (value["files"]?.arrayValue ?? []).prefix(12).compactMap { row in
            row["path"]?.stringValue ?? row.stringValue
        }
    }
}

public struct GatewayProject: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var archived: Bool
    public var isActive: Bool

    init(_ value: JSONValue, activeID: String?) {
        id = value["id"]?.stringValue ?? ""
        name = value["name"]?.stringValue ?? id
        path = value["primary_path"]?.stringValue
            ?? value["folders"]?.arrayValue?.first?["path"]?.stringValue
            ?? ""
        archived = value["archived"]?.boolValue ?? false
        isActive = !id.isEmpty && id == activeID
    }

    init(_ project: HermesProject, activeID: String?) {
        id = project.id
        name = project.name
        path = project.primaryPath ?? project.folders.first?.path ?? ""
        archived = project.isArchived
        isActive = !id.isEmpty && id == activeID
    }
}

public struct GatewayProjectList: Equatable, Sendable {
    public var projects: [GatewayProject]
    public var activeID: String?

    static let empty = GatewayProjectList(projects: [], activeID: nil)

    init(projects: [GatewayProject], activeID: String?) {
        self.projects = projects; self.activeID = activeID
    }

    init(_ value: JSONValue) {
        let decoded = (value["projects"]?.arrayValue ?? []).map {
            GatewayProject($0, activeID: nil)
        }
        let reported = value["active_id"]?.stringValue
        let active = reported.flatMap { candidate in
            decoded.contains(where: { $0.id == candidate && !$0.archived })
                ? candidate : nil
        }
        activeID = active
        projects = decoded.map { project in
            var project = project
            project.isActive = project.id == active
            return project
        }
    }

    init(_ listing: HermesProjectListing) {
        activeID = listing.activeID
        projects = listing.projects.map { GatewayProject($0, activeID: listing.activeID) }
    }
}

extension GatewayClient {
    func listManagedFiles(path: String?) async throws -> GatewayFileListing {
        var query: [URLQueryItem] = []
        if let path, !path.isEmpty {
            query.append(URLQueryItem(name: "path", value: path))
        }
        return GatewayFileListing(try await restJSON(path: "api/files", query: query, timeout: 30))
    }

    func gitStatus(path: String) async throws -> GatewayGitStatus {
        GatewayGitStatus(try await restJSON(
            path: "api/git/status",
            query: [URLQueryItem(name: "path", value: path)],
            timeout: 30))
    }

    func listProjects(in route: GatewayWorkspaceRoute) async throws -> GatewayProjectList {
        GatewayProjectList(try await projects(in: route))
    }
}

public struct WorkspaceSettingsSection: View {
    private let model: AppModel
    public init(model: AppModel) { self.model = model }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    @State private var listing = GatewayFileListing.empty
    @State private var git = GatewayGitStatus.empty
    @State private var projects = GatewayProjectList.empty
    @State private var projectProfiles: [WorkspaceProfileSource] = []
    @State private var selectedProjectProfile = ""
    @State private var path: String?
    @State private var error: String?
    @State private var isLoading = false
    @State private var previewName = ""
    @State private var previewText = ""
    @State private var loadRequest: UInt64 = 0

    private var projectProfileNeedsRecovery: Bool {
        !selectedProjectProfile.isEmpty
            && !projectProfiles.contains(where: { $0.profile == selectedProjectProfile })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            projectProfileSection
            projectsSection
            filesSection
            gitSection
            if let error {
                Text(error).font(theme.mono(10)).foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load(path: path) }
    }

    @ViewBuilder private var projectProfileSection: some View {
        if projectProfiles.count > 1 || projectProfileNeedsRecovery {
            SettingsSection(theme: theme, title: "Projects profile",
                            footnote: "Projects are read from exactly this Hermes profile.") {
                SettingsGroup(theme: theme) {
                    Picker("Profile", selection: Binding(
                        get: { selectedProjectProfile },
                        set: { profile in
                            guard profile != selectedProjectProfile else { return }
                            selectedProjectProfile = profile
                            Task { await load(path: path) }
                        }
                    )) {
                        if projectProfileNeedsRecovery {
                            Text("Unavailable · @\(selectedProjectProfile)").tag(selectedProjectProfile)
                        }
                        ForEach(projectProfiles) { source in
                            Text(source.isDefault ? "\(source.label) · default" : source.label)
                                .tag(source.profile)
                        }
                    }
                    .disabled(isLoading)
                    .modifier(SettingsRowChrome(theme: theme, isLast: true))
                }
            }
        }
    }

    private var projectsSection: some View {
        SettingsSection(theme: theme, title: copy.settingsWorkspaceProjects(theme.id),
                        footnote: copy.settingsWorkspaceProjectsNote(theme.id)) {
            SettingsGroup(theme: theme) {
                if let selected = projectProfiles.first(where: { $0.profile == selectedProjectProfile }) {
                    Text("@\(selected.profile)")
                        .font(theme.mono(10))
                        .foregroundStyle(theme.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(SettingsRowChrome(theme: theme, isLast: false))
                }
                if projects.projects.isEmpty {
                    Text(copy.settingsWorkspaceProjectsEmpty(theme.id))
                        .font(SettingsType.rowSubtitle(theme))
                        .foregroundStyle(theme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(SettingsRowChrome(theme: theme, isLast: true))
                } else {
                    ForEach(Array(projects.projects.prefix(20).enumerated()), id: \.element.id) { index, project in
                        Button {
                            if !project.path.isEmpty {
                                Task { await load(path: project.path) }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.isActive ? "\(project.name) · active" : project.name)
                                    .font(SettingsType.rowTitle(theme))
                                    .foregroundStyle(theme.ink)
                                if !project.path.isEmpty {
                                    Text(project.path)
                                        .font(theme.mono(9))
                                        .foregroundStyle(theme.faint)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .modifier(SettingsRowChrome(theme: theme,
                                                    isLast: index == min(19, projects.projects.count - 1)))
                    }
                }
            }
        }
    }

    private var filesSection: some View {
        SettingsSection(theme: theme, title: copy.settingsWorkspaceFiles(theme.id),
                        footnote: copy.settingsWorkspaceFilesNote(theme.id)) {
            SettingsGroup(theme: theme) {
                HStack {
                    Text(listing.path.isEmpty ? copy.settingsWorkspaceRoot(theme.id) : listing.path)
                        .font(theme.mono(10)).foregroundStyle(theme.sub)
                        .lineLimit(2)
                    Spacer()
                    if listing.parent != nil {
                        Button(copy.settingsWorkspaceUp(theme.id)) {
                            Task { await load(path: listing.parent) }
                        }
                        .font(theme.body(12, weight: .semibold))
                    }
                }
                .modifier(SettingsRowChrome(theme: theme, isLast: listing.entries.isEmpty && previewText.isEmpty))
                ForEach(Array(listing.entries.prefix(40).enumerated()), id: \.element.id) { index, entry in
                    Button {
                        Task {
                            if entry.isDirectory {
                                await load(path: entry.path)
                            } else {
                                await preview(entry)
                            }
                        }
                    } label: {
                        HStack {
                            Text(entry.isDirectory ? "📁 \(entry.name)" : entry.name)
                                .font(theme.body(13)).foregroundStyle(theme.ink)
                                .lineLimit(1)
                            Spacer()
                            if let size = entry.size, !entry.isDirectory {
                                Text(copy.settingsMemoryFileSize(theme.id, bytes: size))
                                    .font(theme.mono(9)).foregroundStyle(theme.faint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .modifier(SettingsRowChrome(theme: theme,
                                                isLast: index == min(39, listing.entries.count - 1) && previewText.isEmpty))
                }
                if !previewText.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(previewName).font(theme.mono(10, weight: .semibold)).foregroundStyle(theme.accent)
                        Text(previewText).font(theme.mono(9.5)).foregroundStyle(theme.sub)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                }
            }
        }
    }

    private var gitSection: some View {
        SettingsSection(theme: theme, title: copy.settingsWorkspaceGit(theme.id),
                        footnote: copy.settingsWorkspaceGitNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Text(copy.settingsWorkspaceGitStatus(theme.id, git: git))
                    .font(SettingsType.rowSubtitle(theme))
                    .foregroundStyle(theme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(SettingsRowChrome(theme: theme, isLast: git.files.isEmpty))
                ForEach(git.files, id: \.self) { file in
                    Text(file).font(theme.mono(10)).foregroundStyle(theme.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(SettingsRowChrome(theme: theme, isLast: file == git.files.last))
                }
            }
        }
    }

    private func load(path next: String?) async {
        guard model.mode == .live, let client = model.client else { return }
        loadRequest &+= 1
        let request = loadRequest
        isLoading = true
        defer {
            if loadRequest == request { isLoading = false }
        }
        do {
            guard let gatewayID = model.activeGatewayID ?? LiveRuntime.shared.gatewayID,
                  !gatewayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GatewayError(code: 400,
                                   message: "Choose a connected gateway before loading profile-scoped projects.")
            }
            let liveGeneration = LiveRuntime.shared.generation
            let clientID = ObjectIdentifier(client)
            await client.setTrafficAdmission {
                await ProfileLifecycleTrafficAdmission.acquire(gatewayID)
            }
            let trafficLease = try await client.acquireTrafficLease()
            do {
                // This exact captured primary client must freshly prove the raw
                // profile immediately before the project read. The outer lease
                // prevents a local lifecycle mutation from entering between
                // validation and `projects.list`.
                let rows = try await client.listProfiles(includeSessions: false)
                let sources = try Self.projectProfileSources(rows)
                guard settingsSourceIsCurrent(clientID: clientID, gatewayID: gatewayID,
                                              liveGeneration: liveGeneration,
                                              request: request) else {
                    throw CancellationError()
                }
                projectProfiles = sources
                let rawProfile = selectedProjectProfile.isEmpty ? nil : selectedProjectProfile
                let selected: String?
                if let rawProfile {
                    selected = rawProfile
                } else {
                    selected = sources.first(where: \.isDefault)?.profile ?? sources.first?.profile
                }
                guard let selected,
                      let route = WorkspaceProjectScope.route(
                        gatewayID: gatewayID, rawProfile: selected,
                        knownProfiles: sources.map(\.profile)
                      ) else {
                    throw GatewayError(code: 409,
                                       message: "The selected Projects profile was renamed or deleted.")
                }
                _ = try WorkspaceProjectScope.requireCurrent(route, in: rows)
                selectedProjectProfile = selected

                async let fileListing = client.listManagedFiles(path: next)
                async let projectListing = client.listProjects(in: route)
                let (listed, scopedProjects) = try await (fileListing, projectListing)
                guard settingsSourceIsCurrent(clientID: clientID, gatewayID: gatewayID,
                                              liveGeneration: liveGeneration,
                                              request: request) else {
                    throw CancellationError()
                }
                listing = listed
                path = listed.path
                projects = scopedProjects
                previewText = ""
                previewName = ""
                error = nil
                if !listed.path.isEmpty {
                    let status = try? await client.gitStatus(path: listed.path)
                    guard settingsSourceIsCurrent(clientID: clientID, gatewayID: gatewayID,
                                                  liveGeneration: liveGeneration,
                                                  request: request) else {
                        throw CancellationError()
                    }
                    git = status ?? .empty
                }
                await trafficLease?.release()
            } catch {
                await trafficLease?.release()
                throw error
            }
        } catch is CancellationError {
            return
        } catch {
            guard loadRequest == request else { return }
            projects = .empty
            self.error = error.localizedDescription
        }
    }

    private static func projectProfileSources(_ rows: [HermesProfile]) throws -> [WorkspaceProfileSource] {
        _ = try WorkspaceProjectScope.knownRawProfiles(from: rows)
        return rows.map {
            WorkspaceProfileSource(profile: $0.name, label: $0.displayName, isDefault: $0.isDefault)
        }
    }

    private func settingsSourceIsCurrent(clientID: ObjectIdentifier, gatewayID: String,
                                         liveGeneration: Int, request: UInt64) -> Bool {
        loadRequest == request
            && model.mode == .live
            && (model.activeGatewayID ?? LiveRuntime.shared.gatewayID) == gatewayID
            && LiveRuntime.shared.generation == liveGeneration
            && model.client.map(ObjectIdentifier.init) == clientID
    }

    private func preview(_ entry: GatewayFileEntry) async {
        guard let client = model.client else { return }
        do {
            let value = try await client.restJSON(
                path: "api/files/read",
                query: [URLQueryItem(name: "path", value: entry.path)],
                timeout: 30)
            previewName = entry.name
            let dataURL = value["data_url"]?.stringValue ?? ""
            previewText = Self.decodePreview(dataURL) ?? copy.settingsWorkspaceBinary(theme.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func decodePreview(_ dataURL: String) -> String? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let encoded = String(dataURL[dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        let text = String(data: data, encoding: .utf8)
        guard let text, !text.contains("\0") else { return nil }
        return String(text.prefix(4_000))
    }
}

public extension CopyPack {
    func settingsWorkspaceProjects(_ t: ThemeID) -> String { t == .control ? "PROJECTS" : "Projects" }
    func settingsWorkspaceProjectsNote(_ t: ThemeID) -> String {
        t == .control ? "PROFILE-SCOPED projects.list — TAP OPENS THE PRIMARY PATH IN FILES." : "Projects for the selected Hermes profile. Tap one to browse its primary folder. Creating projects stays on desktop."
    }
    func settingsWorkspaceProjectsEmpty(_ t: ThemeID) -> String {
        t == .control ? "NO PROJECTS" : "No projects on this gateway."
    }
    func settingsWorkspaceFiles(_ t: ThemeID) -> String { t == .control ? "GATEWAY FILES" : "Gateway files" }
    func settingsWorkspaceFilesNote(_ t: ThemeID) -> String {
        t == .control ? "GET /api/files · READ-ONLY ON THE PHONE." : "Browse the gateway's managed files. Nothing is uploaded from this phone."
    }
    func settingsWorkspaceRoot(_ t: ThemeID) -> String { t == .control ? "MANAGED ROOT" : "Managed root" }
    func settingsWorkspaceUp(_ t: ThemeID) -> String { t == .control ? "UP" : "Up" }
    func settingsWorkspaceBinary(_ t: ThemeID) -> String { t == .control ? "BINARY FILE" : "Binary file — open it on the gateway host." }
    func settingsWorkspaceGit(_ t: ThemeID) -> String { t == .control ? "GIT STATUS" : "Git status" }
    func settingsWorkspaceGitNote(_ t: ThemeID) -> String {
        t == .control ? "GET /api/git/status · NO COMMIT FROM THE PHONE." : "Read-only git status for this folder. Commits stay on desktop."
    }
    func settingsWorkspaceGitStatus(_ t: ThemeID, git: GatewayGitStatus) -> String {
        if git.branch.isEmpty { return t == .control ? "NOT A REPO" : "Not a git repository." }
        return t == .control
            ? "\(git.branch.uppercased()) · \(git.changed) CHANGED · +\(git.ahead)/-\(git.behind)"
            : "\(git.branch) · \(git.changed) changed · ahead \(git.ahead) / behind \(git.behind)"
    }
}
