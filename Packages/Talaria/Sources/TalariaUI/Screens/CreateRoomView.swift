import SwiftUI
import TalariaKit
import TalariaTheme

/// Discord-style creation over the union roster. A source-qualified `Bot.id`
/// is retained through selection; 2...6 is enforced in both UI and engine.
public struct CreateRoomView: View {
    private let model: AppModel
    private let onCreated: (RoomID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var query = ""
    @State private var selected: [RoomMember] = []
    @State private var saving = false
    @State private var error: String?

    public init(model: AppModel, onCreated: @escaping (RoomID) -> Void = { _ in }) {
        self.model = model; self.onCreated = onCreated
    }

    private var theme: ThemePack { model.theme.pack }
    private var roster: [Bot] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return model.unionRosterBots }
        return model.unionRosterBots.filter {
            TalariaVoice.displayName(for: $0, model.theme.themeID).lowercased().contains(needle)
                || ($0.rawDisplayName?.lowercased().contains(needle) ?? false)
                || $0.handle.lowercased().contains(needle)
                || ($0.remoteSource?.connectionLabel.lowercased().contains(needle) ?? false)
        }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("Room name", text: $name)
                    .textFieldStyle(.plain).font(theme.body(15, weight: .semibold))
                    .padding(12).background(theme.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                TextField("Find bots or gateways", text: $query)
                    .textFieldStyle(.plain).font(theme.body(13)).padding(10)
                    .background(theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Text("Pick 2–6 bots").font(theme.body(12, weight: .semibold))
                    Spacer()
                    Text(verbatim: "\(selected.count)/6").font(theme.mono(10))
                }.foregroundStyle(theme.faint)
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(roster) { bot in memberRow(bot) }
                    }
                }
                if let error { Text(error).font(theme.body(11)).foregroundStyle(theme.danger) }
            }
            .padding(16).background(theme.bg)
            .navigationTitle("New Room")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Creating…" : "Create", action: create)
                        .disabled(!canCreate || saving)
                }
            }
        }
    }

    private func memberRow(_ bot: Bot) -> some View {
        let route = model.gatewayRoute(for: bot.id)
        let checked = route.map { value in selected.contains { $0.route == value } } ?? false
        let disabled = !checked && selected.count >= RoomEngine.maximumMembers
        return Button {
            guard let route else { return }
            if checked { selected.removeAll { $0.route == route } }
            else if !disabled {
                selected.append(model.capturedRoomMember(
                    for: bot, route: route,
                    sourceLabel: bot.remoteSource?.connectionLabel
                        ?? model.activeConnectionLabel))
            }
        } label: {
            HStack(spacing: 10) {
                AvatarView(bot: bot, size: 34, theme: theme)
                VStack(alignment: .leading, spacing: 2) {
                    Text(TalariaVoice.displayName(for: bot, model.theme.themeID))
                        .font(theme.body(14, weight: .semibold)).foregroundStyle(theme.ink)
                    Text("@\(bot.handle)" + (bot.remoteSource.map { " · \($0.connectionLabel)" } ?? ""))
                        .font(theme.mono(9)).foregroundStyle(theme.faint)
                }
                Spacer()
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? theme.accent : theme.faint)
            }.padding(.vertical, 7).contentShape(Rectangle()).opacity(disabled ? 0.45 : 1)
        }.buttonStyle(.plain).disabled(disabled)
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (RoomEngine.minimumMembers...RoomEngine.maximumMembers).contains(selected.count)
    }

    private func create() {
        guard canCreate else { return }
        saving = true; error = nil
        Task { @MainActor in
            do {
                let id = try await model.createRoom(name: name, members: selected)
                onCreated(id); dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
