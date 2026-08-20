import SwiftUI
import UniformTypeIdentifiers
import TalariaKit
import TalariaTheme

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct CommandCenterView: View {
    private let model: AppModel
    private let initialGatewayID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .projects

    enum Section: String, CaseIterable, Identifiable {
        case projects = "Projects"
        case files = "Files"
        case review = "Review"
        case commands = "Commands"
        case system = "System"
        var id: String { rawValue }
    }

    public init(model: AppModel, initialGatewayID: String? = nil) {
        self.model = model
        self.initialGatewayID = initialGatewayID
    }

    private var theme: ThemePack { model.theme.pack }
    private var runtime: WorkspaceRuntime { .shared }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sourcePicker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Section.allCases) { item in
                            Button { section = item } label: {
                                CommandSectionChip(title: item.rawValue, selected: section == item,
                                                   theme: theme)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(section == item ? .isSelected : [])
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Group {
                    switch section {
                    case .projects: WorkspaceProjectsSection(model: model, close: { dismiss() })
                    case .files: WorkspaceFilesSection(model: model)
                    case .review: WorkspaceGitSection(model: model)
                    case .commands: WorkspaceCommandsSection(model: model)
                    case .system: WorkspaceSystemSection(model: model, close: { dismiss() })
                    }
                }
            }
            .background(theme.bg)
            .navigationTitle("Command Center")
            .modifier(CommandInlineTitle())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.refreshWorkspace() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(runtime.loading || runtime.mutationBusy
                              || runtime.systemActionRunning || runtime.commandRunning)
                    .accessibilityLabel("Refresh Command Center")
                }
            }
        }
        .task { model.prepareWorkspace(gatewayID: initialGatewayID) }
    }

    @ViewBuilder private var sourcePicker: some View {
        if model.workspaceSources.count > 1 {
            Picker("Gateway", selection: Binding(
                get: { runtime.gatewayID ?? model.workspaceSources.first?.id ?? "" },
                set: { model.selectWorkspaceGateway($0) }
            )) {
                ForEach(model.workspaceSources) { source in
                    Text(source.isActive ? "\(source.name) · active" : source.name).tag(source.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(runtime.mutationBusy || runtime.systemActionRunning || runtime.commandRunning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}

enum WorkspaceCommandSurfacePolicy {
    static let unavailableReason = "Hermes resolves plugins and quick commands before built-ins, and its catalog does not provide a non-shadowable resolved-handler contract. Command Center therefore does not dispatch slash commands."

    static func exposesDispatch(capability: Bool?) -> Bool {
        _ = capability
        return false
    }

    static func ownsProcesses(selectedTargetID: String?, processesTargetID: String?) -> Bool {
        guard let selectedTargetID else { return false }
        return processesTargetID == selectedTargetID
    }
}

enum WorkspaceProjectSessionNavigation {
    @MainActor @discardableResult
    static func open(_ session: HermesProjectSessionPreview, gatewayID: String,
                     model: AppModel, close: () -> Void) -> Bool {
        guard !gatewayID.isEmpty, !session.storedID.isEmpty else { return false }
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: session.profile)
        let botID = gatewayID == LiveRuntime.shared.gatewayID ? route.profile : route.qualifiedID
        model.openStoredSession(session.storedID, botID: botID)
        close()
        return true
    }
}

private struct WorkspaceProjectsSection: View {
    let model: AppModel
    let close: () -> Void
    @State private var showCreate = false
    @State private var name = ""
    @State private var root = ""
    @State private var pendingDelete: HermesProject?
    @State private var editingProject: HermesProject?
    @State private var sessionProject: HermesProjectTree?
    @State private var busy = false

    private var runtime: WorkspaceRuntime { .shared }
    private var allowedRoots: [String] {
        runtime.fileRoots
    }

    var body: some View {
        List {
            workspaceError(runtime.error)
            if !runtime.projectUncertain.isEmpty {
                Section {
                    Label("Outcome uncertain: \(runtime.projectUncertain)", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Button("Refresh and inspect authoritative projects") {
                        Task { await model.refreshWorkspace() }
                    }
                    Button("I verified the result; allow another project mutation") {
                        runtime.projectUncertain = ""
                    }
                } footer: {
                    Text("Talaria will not replay a project write whose acceptance could not be proven.")
                }
            }
            if runtime.capability["projects"] == false {
                ContentUnavailableView("Projects unavailable", systemImage: "folder.badge.questionmark",
                                       description: Text("This gateway predates Hermes Projects or did not answer the capability probe."))
            } else {
                Section {
                    ForEach(runtime.projects.filter { !$0.isArchived }) { project in
                        Button { Task { await model.selectProject(project) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: project.id == runtime.activeProjectID ? "folder.fill" : "folder")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.name).font(.headline)
                                    Text(project.primaryPath ?? project.folders.first?.path ?? "No folder")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if project.id == runtime.activeProjectID { Image(systemName: "checkmark") }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(runtime.mutationBusy || runtime.systemActionRunning || runtime.commandRunning)
                        .contextMenu {
                            Button("Manage project") { editingProject = project }
                            Button("Archive project") { archive(project, restore: false) }
                            Button("Delete project", role: .destructive) { pendingDelete = project }
                        }
                        .swipeActions {
                            Button(role: .destructive) { pendingDelete = project } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { archive(project, restore: false) } label: {
                                Label("Archive", systemImage: "archivebox")
                            }.tint(.orange)
                        }
                    }
                } header: {
                    Text("Gateway launch-profile projects")
                } footer: {
                    Text("Hermes project writes are scoped to this gateway’s launch profile. All-profile project trees remain read-only upstream.")
                }
                Section {
                    Button { showCreate = true } label: { Label("New project", systemImage: "plus") }
                }
                if !runtime.projects.filter(\.isArchived).isEmpty {
                    Section("Archived") {
                        ForEach(runtime.projects.filter(\.isArchived)) { project in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(project.name)
                                    Text(project.primaryPath ?? "No primary folder")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Restore") { archive(project, restore: true) }
                                Button(role: .destructive) { pendingDelete = project } label: {
                                    Image(systemName: "trash")
                                }.accessibilityLabel("Delete \(project.name)")
                            }
                        }
                    }
                }
                if !runtime.projectTree.isEmpty {
                    Section("All-profile activity · read only") {
                        ForEach(runtime.projectTree) { project in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(project.label).font(.headline)
                                    Spacer()
                                    Text("\(project.sessionCount) sessions").font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(project.previews.prefix(3)) { session in
                                    Button {
                                        WorkspaceProjectSessionNavigation.open(
                                            session, gatewayID: runtime.gatewayID ?? "",
                                            model: model, close: close
                                        )
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.title).lineLimit(1)
                                            Text("@\(session.profile) · \(session.preview)")
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }.buttonStyle(.plain)
                                }
                                if project.sessionCount > 0 {
                                    Button(project.sessionCount > project.previews.count
                                           ? "Load bounded session list"
                                           : "View session list") {
                                        sessionProject = project
                                    }
                                }
                                if project.sessionCount > project.previews.count {
                                    Text("The overview is preview-bounded. Entering the project requests Hermes’ largest all-profile window; Talaria rejects it if the response reaches the limit or otherwise appears partial.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                } else if project.sessionCount > 0, project.previews.count <= 3 {
                                    Text("No additional sessions are represented in this bounded overview.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay { if runtime.loading { ProgressView("Loading workspace…") } }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                Form {
                    TextField("Project name", text: $name)
                    Picker("Gateway folder", selection: $root) {
                        Text("Choose a reported folder").tag("")
                        ForEach(allowedRoots, id: \.self) { Text($0).tag($0) }
                    }
                    Text("Only folders reported by Hermes Projects or the managed Files root are eligible. Talaria never accepts an arbitrary filesystem path or silently widens the gateway root.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("New Project")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCreate = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            busy = true
                            Task {
                                do {
                                    try await model.createWorkspaceProject(name: name, root: root)
                                    showCreate = false; name = ""; root = ""
                                } catch { runtime.error = error.localizedDescription }
                                busy = false
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || root.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                }
            }
        }
        .sheet(item: $editingProject) { project in
            WorkspaceProjectEditor(model: model, project: project, roots: allowedRoots)
        }
        .sheet(item: $sessionProject) { project in
            WorkspaceProjectSessionsSheet(model: model, project: project,
                                          gatewayID: runtime.gatewayID ?? "", close: close)
        }
        .confirmationDialog("Permanently delete \(pendingDelete?.name ?? "project")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete project", role: .destructive) {
                guard let project = pendingDelete else { return }
                pendingDelete = nil
                Task { do { try await model.deleteWorkspaceProject(project) }
                       catch { runtime.error = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This deletes the Hermes project record. It does not delete the project folder or Git repository.")
        }
    }

    private func archive(_ project: HermesProject, restore: Bool) {
        Task {
            do { try await model.archiveWorkspaceProject(project, restore: restore) }
            catch { runtime.error = error.localizedDescription }
        }
    }
}

private struct WorkspaceProjectSessionsSheet: View {
    let model: AppModel
    let project: HermesProjectTree
    let gatewayID: String
    let close: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hydrated: HermesProjectTree?
    @State private var error = ""

    var body: some View {
        NavigationStack {
            List {
                if let hydrated {
                    ForEach(hydrated.previews) { session in
                        Button {
                            WorkspaceProjectSessionNavigation.open(
                                session, gatewayID: gatewayID, model: model,
                                close: { dismiss(); close() }
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title)
                                Text("@\(session.profile) · \(session.preview)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.buttonStyle(.plain)
                    }
                    Text("\(hydrated.sessionCount) sessions shown from Hermes’ on-demand all-profile response. Talaria verified that the bounded response did not reach its truncation limit.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !error.isEmpty {
                    ContentUnavailableView("Project drill-in unavailable",
                                           systemImage: "folder.badge.questionmark",
                                           description: Text(error))
                } else {
                    HStack { Spacer(); ProgressView("Loading project sessions…"); Spacer() }
                }
            }
            .navigationTitle(project.label).modifier(CommandInlineTitle())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .task {
            do { hydrated = try await model.loadAuthoritativeWorkspaceProjectSessions(projectID: project.id) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct WorkspaceProjectEditor: View {
    let model: AppModel
    let project: HermesProject
    let roots: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var addRoot = ""
    @State private var busy = false
    @State private var pendingRemoval: HermesProjectFolder?
    private var runtime: WorkspaceRuntime { .shared }

    init(model: AppModel, project: HermesProject, roots: [String]) {
        self.model = model; self.project = project; self.roots = roots
        _name = State(initialValue: project.name)
        _description = State(initialValue: project.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical)
                }
                Section("Folders") {
                    ForEach(project.folders) { folder in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(folder.label ?? folder.path)
                                if folder.label != nil { Text(folder.path).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if folder.isPrimary { Text("Primary").font(.caption).foregroundStyle(.secondary) }
                            else {
                                Button("Make primary") { mutate { try await model.setWorkspacePrimaryFolder(project, path: folder.path) } }
                                    .disabled(busy || runtime.mutationBusy)
                            }
                            Button(role: .destructive) {
                                pendingRemoval = folder
                            } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove \(folder.path)")
                            .disabled(busy || runtime.mutationBusy)
                        }
                    }
                    Picker("Add reported root", selection: $addRoot) {
                        Text("Choose folder").tag("")
                        ForEach(roots.filter { root in !project.folders.contains(where: { $0.path == root }) }, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Button("Add folder") {
                        let root = addRoot
                        mutate { try await model.addWorkspaceProjectFolder(project, path: root) }
                    }.disabled(addRoot.isEmpty || busy)
                }
                Text("Project writes affect only this gateway’s launch profile. The all-profile activity overview is read-only.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Manage Project").modifier(CommandInlineTitle())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        mutate {
                            try await model.updateWorkspaceProject(project, name: name, description: description)
                        }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
            }
            .confirmationDialog("Remove this project folder?",
                                isPresented: Binding(
                                    get: { pendingRemoval != nil },
                                    set: { if !$0 { pendingRemoval = nil } }
                                ), titleVisibility: .visible) {
                Button("Remove folder", role: .destructive) {
                    guard let folder = pendingRemoval else { return }
                    pendingRemoval = nil
                    mutate { try await model.removeWorkspaceProjectFolder(project, path: folder.path) }
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("This detaches \(pendingRemoval?.path ?? "the folder") from the Hermes project record. It does not delete the folder or repository.")
            }
        }
    }

    private func mutate(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            do { try await operation(); dismiss() }
            catch { runtime.error = error.localizedDescription }
            busy = false
        }
    }
}

private struct WorkspaceFilesSection: View {
    let model: AppModel
    @State private var opened: ManagedFileEntry?
    @State private var deleting: ManagedFileEntry?
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var importing = false
    @State private var importError = ""

    private var runtime: WorkspaceRuntime { .shared }
    private var managedRoots: [String] {
        runtime.fileRoots.filter { runtime.fileRootSources[$0] == .managed }
    }
    private var projectRoots: [String] {
        runtime.fileRoots.filter { runtime.fileRootSources[$0] == .project }
    }

    var body: some View {
        List {
            workspaceError(runtime.error)
            workspaceError(importError)
            if !runtime.fileUncertain.isEmpty {
                Section {
                    Label("Outcome uncertain: \(runtime.fileUncertain)", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Button("Refresh and inspect this directory") {
                        Task {
                            if let listing = runtime.fileListing {
                                await model.openManagedDirectory(listing.path, source: listing.source)
                            }
                        }
                    }
                    Button("I verified the result; allow another file mutation") {
                        runtime.fileUncertain = ""
                    }
                } footer: {
                    Text("Talaria will not replay a managed-file write whose acceptance could not be proven.")
                }
            }
            if runtime.capability["files"] == false {
                if !projectRoots.isEmpty {
                    ContentUnavailableView(
                        "Project files safely unavailable",
                        systemImage: "folder.badge.questionmark",
                        description: Text("This Hermes version does not return an authoritative resolved-path containment proof for /api/fs. Talaria will not expose project contents through a lexical-only symlink fence. Git and Projects remain available.")
                    )
                } else {
                    ContentUnavailableView("Managed files unavailable", systemImage: "externaldrive.badge.questionmark")
                }
            } else if managedRoots.isEmpty {
                ContentUnavailableView("No safe workspace roots", systemImage: "folder.badge.questionmark",
                                       description: Text("Hermes did not advertise a locked managed-files root."))
            } else if let listing = runtime.fileListing {
                if managedRoots.count > 1 {
                    Section {
                        Picker("Workspace root", selection: Binding(
                            get: { managedRoots.first(where: { WorkspacePathFence.contains(listing.path, in: [$0]) }) ?? managedRoots[0] },
                            set: { newValue in
                                Task { await model.openManagedDirectory(
                                    newValue, source: .managed) }
                            }
                        )) { ForEach(managedRoots, id: \.self) { Text($0).tag($0) } }
                    }
                }
                Section {
                    if let parent = listing.parent,
                       WorkspacePathFence.contains(parent, in: managedRoots) {
                        Button { Task { await model.openManagedDirectory(parent, source: listing.source) } } label: {
                            Label("Parent folder", systemImage: "arrow.up.left")
                        }
                    }
                    ForEach(listing.entries) { entry in
                        Button {
                            if entry.isDirectory {
                                Task { await model.openManagedDirectory(entry.path, source: entry.source) }
                            }
                            else { opened = entry }
                        } label: {
                            HStack {
                                Image(systemName: entry.isDirectory ? "folder.fill" : fileGlyph(entry.mimeType))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).lineLimit(1)
                                    if !entry.isDirectory { Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            if entry.source == .managed {
                                Button(role: .destructive) { deleting = entry } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text(listing.path)
                } footer: {
                    Text("Hermes’ locked managed-files policy resolves and contains each path before returning content. Project /api/fs paths remain blocked until the gateway can prove the same boundary.")
                }
                if listing.source == .managed {
                    Section {
                        Button { importing = true } label: { Label("Upload file", systemImage: "square.and.arrow.up") }
                        Button { showNewFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    } footer: {
                        Text("Uploads, new folders and permanent deletion stay inside Hermes’ locked managed-files root. Existing file content is read-only until Hermes supports atomic compare-and-swap writes.")
                    }
                }
            } else {
                ContentUnavailableView("Workspace root unavailable", systemImage: "folder.badge.questionmark",
                                       description: Text("Hermes did not return a listing for the selected project root."))
                Button("Retry first safe root") {
                    if let root = managedRoots.first {
                        Task { await model.openManagedDirectory(root, source: .managed) }
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            Task { await importFile(result) }
        }
        .sheet(item: $opened) { WorkspaceFileDetail(model: model, entry: $0) }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $folderName)
            Button("Create") {
                let value = folderName; folderName = ""
                Task { do { try await model.createWorkspaceFolder(name: value) }
                       catch { runtime.error = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) { folderName = "" }
        }
        .confirmationDialog("Permanently delete \(deleting?.name ?? "item")?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button(deleting?.isDirectory == true ? "Delete folder recursively" : "Delete file", role: .destructive) {
                guard let entry = deleting else { return }; deleting = nil
                Task { do { try await model.deleteWorkspaceEntry(entry, recursive: entry.isDirectory) }
                       catch { runtime.error = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Hermes managed-file deletion is permanent. This is not the system Trash.")
        }
    }

    private func importFile(_ result: Result<URL, Error>) async {
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard WorkspaceFileSizePolicy.allows(byteCount: data.count) else {
                throw NSError(domain: "TalariaWorkspace", code: 413,
                              userInfo: [NSLocalizedDescriptionKey: "Files larger than 12 MB are not uploaded from the phone."])
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            try await model.uploadManagedFile(name: url.lastPathComponent, bytes: data, mimeType: mime, overwrite: false)
            importError = ""
        } catch { importError = error.localizedDescription }
    }
}

private struct WorkspaceFileDetail: View {
    let model: AppModel
    let entry: ManagedFileEntry
    @Environment(\.dismiss) private var dismiss
    @State private var fileBody: ManagedFileBody?
    @State private var text = ""
    @State private var error = ""
    @State private var shareURL: URL?

    private var isText: Bool { fileBody?.isText == true }

    var bodyView: some View {
        Group {
            if fileBody == nil, error.isEmpty { ProgressView("Reading file…") }
            else if !error.isEmpty { ContentUnavailableView("Could not open file", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else if isText {
                VStack(spacing: 0) {
                    if fileBody?.isTruncated == true {
                        Label("Preview truncated. Share exports the complete file.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote).padding(10)
                    }
                    Label("Read only: Hermes does not yet provide an atomic expected-hash or If-Match write contract.",
                          systemImage: "lock.fill")
                        .font(.footnote).padding(10)
                    ScrollView([.horizontal, .vertical]) {
                        Text(text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(8)
                    }
                }
            } else {
                ContentUnavailableView("Binary file", systemImage: "doc", description: Text("Use Share to export this file with its original name."))
            }
        }
    }

    var body: some View {
        NavigationStack {
            bodyView
                .navigationTitle(entry.name).modifier(CommandInlineTitle())
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    if let shareURL {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: shareURL) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
        }
        .task {
            do {
                let value = try await model.loadManagedFile(entry)
                fileBody = value
                text = value.textPreview ?? String(data: value.bytes, encoding: .utf8) ?? ""
                shareURL = try makeShareFile(value.bytes)
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear {
            if let shareURL { try? FileManager.default.removeItem(at: shareURL.deletingLastPathComponent()) }
        }
    }

    private func makeShareFile(_ data: Data) throws -> URL {
        let safe = WorkspaceExportName.safe(entry.name, fallback: "workspace-file")
        let folder = FileManager.default.temporaryDirectory.appending(path: "talaria-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: safe)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        return url
    }
}

private struct WorkspaceGitSection: View {
    let model: AppModel
    @State private var opened: HermesGitFile?
    @State private var riskyAction: RiskyGitAction?
    @State private var commitMessage = ""
    @State private var showCommit = false
    @State private var showWorktree = false
    @State private var worktreeName = ""
    @State private var worktreeBranch = ""
    @State private var busy = false

    private var runtime: WorkspaceRuntime { .shared }

    enum RiskyGitAction: Identifiable {
        case revert(HermesGitFile), push, pullRequest, switchBranch(HermesGitBranch), removeWorktree(HermesGitWorktree)
        var id: String { String(describing: self) }
    }

    var body: some View {
        List {
            workspaceError(runtime.error)
            if !runtime.gitUncertain.isEmpty {
                Section {
                    Label("Outcome uncertain: \(runtime.gitUncertain)", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Button("Refresh and review authoritative repository state") {
                        Task { await model.refreshGit() }
                    }
                    Button("I reviewed the repository; allow another mutation") {
                        runtime.gitUncertain = ""
                    }
                } footer: {
                    Text("Talaria will not replay or send another Git write after a transport error.")
                }
            }
            if runtime.gitPath.isEmpty {
                ContentUnavailableView("Choose a project", systemImage: "arrow.triangle.branch", description: Text("Select a project with a primary folder to review its repository."))
            } else if runtime.capability["git"] == false {
                ContentUnavailableView("Git unavailable", systemImage: "arrow.triangle.branch", description: Text(runtime.gitPath))
            } else if let status = runtime.gitStatus {
                Section {
                    LabeledContent("Repository", value: runtime.gitPath)
                    LabeledContent("Branch", value: status.detached ? "Detached HEAD" : status.branch ?? "Unknown")
                    LabeledContent("Remote", value: "↑\(status.ahead) ↓\(status.behind)")
                    LabeledContent("Changes", value: "+\(status.added) −\(status.removed)")
                }
                Section("Changed files") {
                    ForEach(runtime.gitFiles) { file in
                        Button { opened = file } label: {
                            HStack {
                                Text(file.status).font(.system(.caption, design: .monospaced)).frame(width: 20)
                                Text(file.path).lineLimit(1)
                                Spacer()
                                Text("+\(file.added) −\(file.removed)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            Button(file.unstaged ? "Stage" : "Unstage") {
                                Task {
                                    do { try await model.mutateGitFile(file, action: file.unstaged ? "stage" : "unstage") }
                                    catch { runtime.error = error.localizedDescription }
                                }
                            }.tint(file.unstaged ? .green : .orange)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Revert", role: .destructive) { riskyAction = .revert(file) }
                        }
                        .contextMenu {
                            if file.unstaged {
                                Button("Stage file") { mutate(file, action: "stage") }
                            }
                            if file.staged {
                                Button("Unstage file") { mutate(file, action: "unstage") }
                            }
                            Button("Discard changes", role: .destructive) { riskyAction = .revert(file) }
                        }
                    }
                }
                if !runtime.gitBranches.isEmpty {
                    Section("Branches") {
                        ForEach(runtime.gitBranches) { branch in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(branch.name).font(.system(.body, design: .monospaced))
                                    Text(branch.isRemote ? "Remote branch" : (branch.isDefault ? "Default branch" : "Local branch"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if branch.checkedOut { Label("Checked out", systemImage: "checkmark.circle.fill").font(.caption) }
                                else {
                                    Button(branch.isRemote ? "Track in worktree" : "Switch") {
                                        riskyAction = .switchBranch(branch)
                                    }
                                }
                            }
                        }
                    }
                }
                if !runtime.gitWorktrees.isEmpty {
                    Section("Worktrees") {
                        ForEach(runtime.gitWorktrees) { worktree in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(worktree.branch ?? (worktree.detached ? "Detached HEAD" : "Worktree"))
                                    Text(worktree.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if worktree.isMain { Text("Main").font(.caption).foregroundStyle(.secondary) }
                                else {
                                    Button(role: .destructive) { riskyAction = .removeWorktree(worktree) } label: {
                                        Image(systemName: "trash")
                                    }.accessibilityLabel("Remove worktree \(worktree.path)")
                                }
                            }
                        }
                        Button("New worktree") { showWorktree = true }
                            .disabled(runtime.mutationBusy || !runtime.gitUncertain.isEmpty)
                    }
                }
                Section {
                    Button("Commit staged changes") { showCommit = true }
                        .disabled(runtime.gitFiles.allSatisfy { !$0.staged } || !runtime.gitUncertain.isEmpty || runtime.mutationBusy)
                    Button("Push \(status.branch ?? "branch")") { riskyAction = .push }
                        .disabled(!runtime.gitUncertain.isEmpty || runtime.mutationBusy)
                    Button("Create pull request") { riskyAction = .pullRequest }
                        .disabled(!runtime.gitUncertain.isEmpty || runtime.mutationBusy)
                } footer: {
                    Text("Talaria never pushes automatically. Revert, commit, push and PR creation require an explicit confirmation and are never replayed after an uncertain response.")
                }
            }
        }
        .refreshable { await model.refreshGit() }
        .sheet(item: $opened) { WorkspaceDiffView(model: model, file: $0) }
        .alert("Commit staged changes", isPresented: $showCommit) {
            TextField("Commit message", text: $commitMessage)
            Button("Commit") {
                let message = commitMessage; commitMessage = ""
                Task { do { try await model.commitWorkspace(message: message) }
                       catch { runtime.error = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) { commitMessage = "" }
        } message: { Text(runtime.gitPath) }
        .sheet(isPresented: $showWorktree) {
            NavigationStack {
                Form {
                    TextField("Worktree name", text: $worktreeName)
                    TextField("New branch", text: $worktreeBranch).modifier(CommandLiteralInput())
                    Text("Hermes creates the worktree beneath the repository’s managed .worktrees directory. Talaria never accepts an arbitrary destination path.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("New Worktree").modifier(CommandInlineTitle())
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showWorktree = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            let name = worktreeName, branch = worktreeBranch
                            Task {
                                do {
                                    try await model.createWorkspaceWorktree(name: name, branch: branch)
                                    worktreeName = ""; worktreeBranch = ""; showWorktree = false
                                } catch { runtime.error = error.localizedDescription }
                            }
                        }.disabled(worktreeName.trimmingCharacters(in: .whitespaces).isEmpty
                                   || worktreeBranch.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .confirmationDialog(riskyTitle, isPresented: Binding(get: { riskyAction != nil }, set: { if !$0 { riskyAction = nil } }), titleVisibility: .visible) {
            Button(riskyButton, role: riskyRole) { performRisky() }
            Button("Cancel", role: .cancel) { riskyAction = nil }
        } message: { Text(riskyMessage) }
    }

    private var riskyTitle: String {
        switch riskyAction { case .revert(let file): "Discard all changes to \(file.path)?"; case .push: "Push this branch?"; case .pullRequest: "Create a pull request?"; case .switchBranch(let branch): branch.isRemote ? "Track \(branch.name) in a worktree?" : "Switch to \(branch.name)?"; case .removeWorktree(let worktree): "Remove worktree \(worktree.path)?"; case nil: "Confirm Git action" }
    }
    private var riskyButton: String {
        switch riskyAction { case .revert: "Discard changes"; case .push: "Push"; case .pullRequest: "Create PR"; case .switchBranch(let branch): branch.isRemote ? "Create tracking worktree" : "Switch branch"; case .removeWorktree: "Remove worktree"; case nil: "Continue" }
    }
    private var riskyRole: ButtonRole? {
        if case .revert = riskyAction { return .destructive }
        if case .removeWorktree = riskyAction { return .destructive }
        return nil
    }
    private var riskyMessage: String {
        let target: String
        if case .switchBranch(let branch) = riskyAction, branch.isRemote {
            target = "\nHermes will create a local tracking branch in a new managed worktree; Talaria will not switch directly to a remote-tracking ref or detach HEAD."
        } else {
            target = ""
        }
        return "Gateway: \(runtime.gatewayID ?? "unknown")\nRepository: \(runtime.gitPath)\(target)"
    }

    private func performRisky() {
        guard let action = riskyAction else { return }; riskyAction = nil; busy = true
        Task {
            do {
                switch action {
                case .revert(let file): try await model.mutateGitFile(file, action: "revert")
                case .push: try await model.pushWorkspace()
                case .pullRequest:
                    if let url = try await model.createWorkspacePullRequest() { await MainActor.run { UIApplicationBridge.open(url) } }
                case .switchBranch(let branch): try await model.switchWorkspaceBranch(branch)
                case .removeWorktree(let worktree): try await model.removeWorkspaceWorktree(worktree)
                }
            } catch { runtime.error = error.localizedDescription }
            busy = false
        }
    }

    private func mutate(_ file: HermesGitFile, action: String) {
        Task {
            do { try await model.mutateGitFile(file, action: action) }
            catch { runtime.error = error.localizedDescription }
        }
    }
}

private struct WorkspaceDiffView: View {
    let model: AppModel
    let file: HermesGitFile
    @Environment(\.dismiss) private var dismiss
    @State private var diff = ""
    @State private var error = ""
    @State private var staged = false

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Text(diff.isEmpty && error.isEmpty ? "Loading…" : (error.isEmpty ? diff : error))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .safeAreaInset(edge: .top) {
                if file.staged && file.unstaged {
                    Picker("Diff source", selection: $staged) {
                        Text("Working tree").tag(false)
                        Text("Staged").tag(true)
                    }
                    .pickerStyle(.segmented).padding(.horizontal).padding(.top, 6)
                }
            }
            .navigationTitle(file.path).modifier(CommandInlineTitle())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task { staged = file.staged && !file.unstaged; await load() }
        .onChange(of: staged) { _, _ in Task { await load() } }
    }

    private func load() async {
        error = ""; diff = ""
        do { diff = try await model.loadGitDiff(file, staged: staged) }
        catch { self.error = error.localizedDescription }
    }
}

private struct WorkspaceCommandsSection: View {
    private struct PendingProcessKill: Identifiable {
        var id: String { target.id + "\u{1f}" + process.id }
        var process: HermesProcess
        var target: WorkspaceProcessTarget
    }

    let model: AppModel
    @State private var pendingKill: PendingProcessKill?
    private var runtime: WorkspaceRuntime { .shared }

    private var selectedTarget: WorkspaceProcessTarget? {
        let id = runtime.processTargetID ?? model.workspaceProcessTargets.first?.id
        return model.workspaceProcessTargets.first { $0.id == id }
    }

    private var ownsSelectedProcesses: Bool {
        WorkspaceCommandSurfacePolicy.ownsProcesses(
            selectedTargetID: selectedTarget?.id,
            processesTargetID: runtime.processesTargetID
        )
    }

    var body: some View {
        List {
            workspaceError(runtime.error)
            if !runtime.commandUncertain.isEmpty {
                Section {
                    Label("Outcome uncertain: \(runtime.commandUncertain)", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Button("I reviewed the target session; allow another process action") {
                        runtime.commandUncertain = ""
                        Task { await model.refreshWorkspaceProcesses() }
                    }
                } footer: {
                    Text("The gateway connection ended before Talaria could prove the process action completed. It will not be replayed.")
                }
            }
            Section {
                ContentUnavailableView(
                    "Slash commands unavailable in Command Center",
                    systemImage: "command.circle",
                    description: Text(WorkspaceCommandSurfacePolicy.unavailableReason)
                )
            } footer: {
                Text("Command Center’s process monitor and confirmed stop action use direct, session-qualified process RPCs instead of command.dispatch.")
            }
            if !model.workspaceProcessTargets.isEmpty {
                Section {
                    if let selectedTarget, ownsSelectedProcesses {
                        if runtime.processes.isEmpty {
                            Text("No background processes in \(selectedTarget.discriminator).")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(runtime.processes) { process in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(process.command.isEmpty ? process.id : process.command).lineLimit(1)
                                    Text("\(process.status) · \(Duration.seconds(process.uptimeSeconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !process.cwd.isEmpty {
                                        Text(process.cwd).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    if !process.outputTail.isEmpty {
                                        Text(process.outputTail).font(.system(.caption2, design: .monospaced))
                                            .lineLimit(4).textSelection(.enabled)
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    pendingKill = PendingProcessKill(process: process, target: selectedTarget)
                                } label: {
                                    Image(systemName: "stop.fill")
                                }
                                .disabled(runtime.mutationBusy || runtime.commandRunning
                                          || runtime.systemActionRunning)
                                .accessibilityLabel("Stop \(process.command.isEmpty ? process.id : process.command) on \(selectedTarget.discriminator)")
                            }
                        }
                    } else if let selectedTarget {
                        HStack { ProgressView(); Text("Loading processes for \(selectedTarget.discriminator)…") }
                    } else {
                        Text("The selected process target is no longer available.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Refresh processes") { Task { await model.refreshWorkspaceProcesses() } }
                        .disabled(runtime.mutationBusy || runtime.commandRunning || runtime.systemActionRunning)
                } header: {
                    Text("Background processes")
                } footer: {
                    if let selectedTarget { Text("Process authority: \(selectedTarget.discriminator)") }
                }
            }
        }
        .task { await model.refreshWorkspaceProcesses() }
        .onChange(of: model.workspaceProcessTargets.map(\.id)) { _, ids in
            let selected = runtime.processTargetID.flatMap { ids.contains($0) ? $0 : nil }
                ?? ids.first
            runtime.resetProcesses(targetID: selected)
            if let selected {
                Task { await model.refreshWorkspaceProcesses(targetID: selected) }
            }
        }
        .confirmationDialog("Stop \(pendingKill?.process.command.isEmpty == false ? pendingKill?.process.command ?? "process" : pendingKill?.process.id ?? "process")?",
                            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
                            titleVisibility: .visible) {
            Button("Stop process", role: .destructive) {
                guard let pending = pendingKill else { return }; pendingKill = nil
                Task { await model.killWorkspaceProcess(pending.process, targetID: pending.target.id) }
            }
            Button("Cancel", role: .cancel) { pendingKill = nil }
        } message: {
            Text("Exact target: \(pendingKill?.target.discriminator ?? "unavailable"). Talaria sends this process ID only to that gateway/profile/session and never exposes global process.stop.")
        }
    }

    private var processSelection: Binding<String> {
        Binding(get: {
            selectedTarget?.id ?? model.workspaceProcessTargets.first?.id ?? ""
        }, set: { newValue in
            guard model.workspaceProcessTargets.contains(where: { $0.id == newValue }) else {
                runtime.resetProcesses(targetID: nil)
                return
            }
            runtime.resetProcesses(targetID: newValue)
            Task { await model.refreshWorkspaceProcesses(targetID: newValue) }
        })
    }
}

private struct WorkspaceSystemSection: View {
    let model: AppModel
    let close: () -> Void
    private var runtime: WorkspaceRuntime { .shared }
    @State private var pending: AppModel.WorkspaceSystemAction?

    var body: some View {
        List {
            workspaceError(runtime.error)
            if !runtime.systemUncertain.isEmpty {
                Section {
                    Label("Outcome uncertain: \(runtime.systemUncertain)", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Button("I verified the result; allow another system mutation") {
                        runtime.systemUncertain = ""
                        Task { await model.refreshWorkspace() }
                    }
                } footer: {
                    Text("Talaria will not replay a request whose acceptance was unclear, or claim completion after Hermes replaces the accepted action PID with another client’s same-name action.")
                }
            }
            Section("Selected source") {
                LabeledContent("Gateway", value: model.workspaceSources.first(where: { $0.id == runtime.gatewayID })?.name ?? "Unavailable")
                ForEach(["projects", "files", "git", "commands"], id: \.self) { capability in
                    LabeledContent(capability.capitalized,
                                   value: runtime.capability[capability].map { $0 ? "Available" : "Unavailable" } ?? "Not probed")
                }
            }
            if let status = runtime.systemStatus {
                Section("Gateway status") {
                    LabeledContent("Version", value: status["version"]?.stringValue ?? "Unknown")
                    LabeledContent("State", value: status["gateway_state"]?.stringValue
                                   ?? (status["ready"]?.boolValue == true ? "ready" : "connected"))
                    if let uptime = status["uptime_seconds"]?.doubleValue {
                        LabeledContent("Uptime", value: Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                    }
                }
            }
            if let totals = runtime.usage?["totals"] {
                Section("Last 30 days") {
                    LabeledContent("Input tokens", value: formatNumber(totals["total_input"]?.doubleValue))
                    LabeledContent("Output tokens", value: formatNumber(totals["total_output"]?.doubleValue))
                    LabeledContent("Sessions", value: formatNumber(totals["total_sessions"]?.doubleValue))
                    LabeledContent("API calls", value: formatNumber(totals["total_api_calls"]?.doubleValue))
                    if let cost = totals["total_actual_cost"]?.doubleValue
                        ?? totals["total_estimated_cost"]?.doubleValue {
                        LabeledContent("Estimated cost", value: cost.formatted(.currency(code: "USD")))
                    }
                }
            }
            if let memory = runtime.memoryStatus {
                Section("Memory") {
                    LabeledContent("Provider", value: memory["active"]?.stringValue?.isEmpty == false
                                   ? memory["active"]?.stringValue ?? "Built in" : "Built in")
                    if let files = memory["builtin_files"] {
                        LabeledContent("MEMORY.md", value: ByteCountFormatter.string(
                            fromByteCount: Int64(files["memory"]?.intValue ?? 0), countStyle: .file))
                        LabeledContent("USER.md", value: ByteCountFormatter.string(
                            fromByteCount: Int64(files["user"]?.intValue ?? 0), countStyle: .file))
                    }
                    Button("Reset MEMORY.md", role: .destructive) { pending = .memoryFileReset }
                        .disabled(runtime.mutationBusy || runtime.systemActionRunning)
                    Button("Reset USER.md", role: .destructive) { pending = .userFileReset }
                        .disabled(runtime.mutationBusy || runtime.systemActionRunning)
                    Button("Reset both built-in files", role: .destructive) { pending = .memoryReset }
                        .disabled(runtime.mutationBusy || runtime.systemActionRunning)
                }
            }
            if let curator = runtime.curatorStatus {
                Section("Curator") {
                    LabeledContent("State", value: curator["enabled"]?.boolValue == false
                                   ? "Disabled" : (curator["paused"]?.boolValue == true ? "Paused" : "Running"))
                    if let hours = curator["interval_hours"]?.doubleValue {
                        LabeledContent("Interval", value: "Every \(hours.formatted()) hours")
                    }
                    Button(curator["paused"]?.boolValue == true ? "Resume curator" : "Pause curator") {
                        Task { await model.setWorkspaceCuratorPaused(curator["paused"]?.boolValue != true) }
                    }
                    .disabled(runtime.mutationBusy || runtime.systemActionRunning)
                    Button("Run curator now") { pending = .curator }
                        .disabled(runtime.mutationBusy || runtime.systemActionRunning)
                }
            }
            Section("Diagnostics") {
                Button("Run Hermes doctor") { pending = .doctor }
                    .disabled(!runtime.systemUncertain.isEmpty || runtime.mutationBusy
                              || runtime.systemActionRunning)
                Button("Run security audit") { pending = .securityAudit }
                    .disabled(!runtime.systemUncertain.isEmpty || runtime.mutationBusy
                              || runtime.systemActionRunning)
                Button("Create gateway backup") { pending = .backup }
                    .disabled(!runtime.systemUncertain.isEmpty || runtime.mutationBusy
                              || runtime.systemActionRunning || runtime.backupDownloadRunning)
                if let backupURL = runtime.backupExportURL {
                    ShareLink(item: backupURL) {
                        Label("Share downloaded backup", systemImage: "square.and.arrow.up")
                    }
                } else if runtime.backupDownloadRunning {
                    HStack {
                        ProgressView()
                        Text("Streaming backup to protected temporary storage…")
                    }
                    Button("Cancel backup download", role: .destructive) {
                        model.cancelWorkspaceBackupDownload()
                    }
                } else if runtime.backupArchive != nil {
                    Button("Download latest backup") { Task { await downloadBackup() } }
                        .disabled(runtime.mutationBusy || runtime.systemActionRunning)
                }
                Button("Check for Hermes updates") { Task { await model.checkWorkspaceUpdate() } }
                    .disabled(runtime.mutationBusy || runtime.systemActionRunning)
                if let message = runtime.updateMessage, !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if runtime.updateCanApply == false {
                    Label(runtime.updateRecommendedCommand.map { "Managed update unavailable. Recommended: \($0)" }
                          ?? "Managed update unavailable for this installation.",
                          systemImage: "shippingbox")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Restart gateway") { pending = .restartGateway }
                    .disabled(!runtime.systemUncertain.isEmpty || runtime.mutationBusy
                              || runtime.systemActionRunning)
                Button("Update Hermes") { pending = .updateHermes }
                    .disabled(!runtime.systemUncertain.isEmpty || runtime.updateCanApply != true
                              || runtime.mutationBusy || runtime.systemActionRunning)
                Button("Create redacted debug share") { pending = .debugShare }
                    .disabled(!runtime.systemUncertain.isEmpty || runtime.mutationBusy
                              || runtime.systemActionRunning)
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Restart and update are accepted-before-disconnect operations and are never replayed. Debug Share uploads redacted diagnostics to Hermes’ paste service for six hours.")
            }
            if runtime.systemActionRunning {
                Section { HStack { ProgressView(); Text("Running source-qualified action…") } }
            }
            if !runtime.systemOutput.isEmpty {
                Section("Latest result") {
                    ScrollView(.horizontal) {
                        Text(runtime.systemOutput).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            Section {
                Button("Open gateway, logs, providers and maintenance settings") {
                    close(); model.requestSettings()
                }
            } footer: {
                Text("Command Center reuses Talaria’s existing source-qualified Operator and provider settings instead of cloning a second control plane.")
            }
            Section("Platform boundary") {
                Text("Interactive Terminal remains a desktop-only surface until Hermes exposes a hardened remote PTY contract with explicit session, cwd, resize, backpressure, reconnect and approval semantics. Commands above are safe, bounded and noninteractive.")
            }
        }
        .confirmationDialog(pending?.displayName ?? "Confirm action",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button(confirmLabel, role: confirmRole) {
                guard let action = pending else { return }; pending = nil
                Task {
                    if action == .curator { await model.runWorkspaceCurator() }
                    else { await model.runWorkspaceSystemAction(action) }
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(confirmMessage)
        }
        .onDisappear {
            model.cancelWorkspaceBackupDownload()
            runtime.removeBackupExport()
        }
    }

    private var confirmLabel: String { pending?.displayName ?? "Continue" }
    private var confirmRole: ButtonRole? {
        switch pending {
        case .memoryReset, .memoryFileReset, .userFileReset, .restartGateway, .updateHermes: .destructive
        default: nil
        }
    }
    private var confirmMessage: String {
        switch pending {
        case .debugShare:
            "This uploads a redacted diagnostic report and logs to a third-party paste service. Links auto-delete after six hours."
        case .memoryReset:
            "This permanently deletes MEMORY.md and USER.md for the gateway launch profile."
        case .memoryFileReset:
            "This permanently deletes MEMORY.md for the gateway launch profile."
        case .userFileReset:
            "This permanently deletes USER.md for the gateway launch profile."
        case .restartGateway, .updateHermes:
            "The selected gateway may disconnect immediately after accepting this request. Talaria will not retry it automatically."
        case .backup:
            "Hermes will create a backup archive inside its managed backup directory."
        case .doctor, .securityAudit, .curator:
            "Run this diagnostic on the selected gateway?"
        case nil: ""
        }
    }

    private func downloadBackup() async {
        do { _ = try await model.downloadWorkspaceBackup() }
        catch is CancellationError { }
        catch { runtime.error = error.localizedDescription }
    }

    private func formatNumber(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.notation(.compactName))
    }
}

private struct WorkspaceErrorRow: View {
    let message: String
    var body: some View {
        if !message.isEmpty { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
    }
}

private struct CommandSectionChip: View {
    let title: String
    let selected: Bool
    let theme: ThemePack

    var body: some View {
        Text(title)
            .font(.callout.weight(selected ? .bold : .medium))
            .foregroundStyle(selected ? theme.accent : theme.sub)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(selected ? theme.accent.opacity(0.12) : theme.panel, in: Capsule())
    }
}

@ViewBuilder private func workspaceError(_ message: String) -> some View {
    WorkspaceErrorRow(message: message)
}

private func fileGlyph(_ mime: String) -> String {
    if mime.hasPrefix("image/") { return "photo" }
    if mime.hasPrefix("video/") { return "film" }
    if mime.hasPrefix("audio/") { return "waveform" }
    if mime.hasPrefix("text/") { return "doc.text" }
    return "doc"
}

@MainActor private enum UIApplicationBridge {
    static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

private struct CommandInlineTitle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}

private struct CommandLiteralInput: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        content
        #endif
    }
}
