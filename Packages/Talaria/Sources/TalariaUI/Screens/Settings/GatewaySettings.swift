import SwiftUI
import TalariaKit
import TalariaTheme

// Settings → Gateways: the connection registry, with the verbs a phone-first
// operator needs on it — switch the live link, rename, sign out, remove
// (Keychain credential included).
//
// This is a *merge*, not a second implementation. The health line, the state
// word and the row's whole visual language are lifted out of Connections'
// file-private `ConnectionRow` into `GatewayHealthRow` below, so there is one
// definition of what a gateway row looks like; the model verbs
// (`switchGateway` / `renameGateway` / `signOutGateway` / `removeGateway`)
// already live on AppModel and are simply called.
//
// Adding a gateway deliberately stays in Connections: that screen owns the
// probe → PKCE sign-in flow and the Hermes Cloud discovery panel, and copying
// either here would be two sign-in paths to keep in step. The row hands off.

struct GatewaySettingsSection: View {
    let model: AppModel
    /// Leave Settings and show the screen that owns the add-gateway flow.
    var onAddGateway: () -> Void

    @State private var actionTarget: SavedGateway?
    @State private var renameTarget: SavedGateway?
    @State private var renameText = ""

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var reducedMotion: Bool {
        model.settings.prefersReducedMotion(system: systemReduceMotion)
    }

    /// Demo rows have no registry entry behind them, so they stay display-only
    /// — exactly as they do in Connections.
    private func savedGateway(for connection: GatewayConnection) -> SavedGateway? {
        ConnectionRegistry.shared.saved.first { $0.id == connection.id }
    }

    var body: some View {
        SettingsSection(theme: theme, title: copy.gatewaysSec,
                        footnote: copy.settingsGatewaysNote(theme.id)) {
            SettingsGroup(theme: theme) {
                if model.connections.isEmpty {
                    SettingsRow(theme: theme, title: copy.settingsNoGateways(theme.id))
                }
                ForEach(model.connections) { connection in
                    let saved = savedGateway(for: connection)
                    GatewayHealthRow(
                        connection: connection,
                        diagnostics: saved.flatMap { model.diagnostics(forGatewayID: $0.id) },
                        isActive: saved.map { model.isActiveGateway($0) } ?? false,
                        isBusy: model.isReconnecting,
                        reducedMotion: reducedMotion,
                        theme: theme,
                        copy: copy,
                        onTap: saved == nil ? nil : { tapped(saved!) },
                        onActions: saved == nil ? nil : { actionTarget = saved })
                }
                SettingsActionRow(theme: theme,
                                  title: copy.settingsAddGateway(theme.id),
                                  subtitle: copy.settingsAddGatewayNote(theme.id),
                                  isLast: true,
                                  action: onAddGateway)
            }
        }
        .confirmationDialog(actionTarget?.name ?? copy.gatewaysSec,
                            isPresented: Binding(get: { actionTarget != nil },
                                                 set: { if !$0 { actionTarget = nil } }),
                            titleVisibility: .visible) {
            if let gateway = actionTarget { actions(for: gateway) }
        } message: {
            Text(copy.connRemoveNote(theme.id))
        }
        .alert(copy.connRenameTitle(theme.id),
               isPresented: Binding(get: { renameTarget != nil },
                                    set: { if !$0 { renameTarget = nil } })) {
            // Metadata-only: the Keychain credential is keyed by URL, so a
            // rename never disturbs the sign-in. A plain field, not
            // `gatewayFieldTraits()` — this is a human name, not a URL, so the
            // URL keyboard and forced lowercase would both be wrong.
            TextField(renameTarget?.name ?? "", text: $renameText)
                .autocorrectionDisabled()
            Button(copy.connSave(theme.id)) {
                if let gateway = renameTarget { model.renameGateway(gateway, to: renameText) }
            }
            Button(copy.cancel, role: .cancel) {}
        } message: {
            if let gateway = renameTarget {
                Text(ConnectionRegistry.address(for: gateway))
            }
        }
        .task {
            // Fresh health while Settings is up, then on the same 20 s beat
            // Connections uses, so the two screens never disagree.
            guard model.mode == .live else { return }
            while !Task.isCancelled {
                await model.refreshConnectionHealth()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// A tap connects: switching flushes the previous gateway's world, and the
    /// active-but-offline row retries instead of re-dialing from scratch.
    private func tapped(_ gateway: SavedGateway) {
        if model.isActiveGateway(gateway) {
            if model.isOffline {
                model.reconnectNow()
            } else {
                actionTarget = gateway
            }
            return
        }
        Task { @MainActor in await model.switchGateway(to: gateway) }
    }

    @ViewBuilder
    private func actions(for gateway: SavedGateway) -> some View {
        if model.isActiveGateway(gateway) {
            if model.isOffline {
                Button(copy.reconnectCTA(theme.id)) { model.reconnectNow() }
            } else {
                Button(copy.connDisconnect(theme.id)) {
                    Task { @MainActor in await model.disconnectGateway() }
                }
            }
        } else {
            Button(copy.connConnect(theme.id)) {
                Task { @MainActor in await model.switchGateway(to: gateway) }
            }
        }
        Button(copy.connRename(theme.id)) {
            renameText = gateway.name
            renameTarget = gateway
        }
        Button(copy.connSignOut(theme.id)) {
            Task { @MainActor in await model.signOutGateway(gateway) }
        }
        Button(copy.connRemove(theme.id), role: .destructive) {
            Task { @MainActor in await model.removeGateway(gateway) }
        }
        Button(copy.cancel, role: .cancel) {}
    }
}

// MARK: - The shared gateway row

/// One saved gateway: state dot, name (+ LIVE tag), transport · address, the
/// health line from the status probe, and the last failure when it is down.
///
/// Extracted from `ConnectionsView`'s file-private `ConnectionRow` so Settings
/// and Connections render the identical row. Connections can adopt this and
/// delete its copy; the initializer is deliberately the same shape, with the
/// two additions this screen needs (`reducedMotion`, `isLast`).
struct GatewayHealthRow: View {
    let connection: GatewayConnection
    let diagnostics: GatewayDiagnostics?
    let isActive: Bool
    let isBusy: Bool
    let reducedMotion: Bool
    let theme: ThemePack
    let copy: CopyPack
    var isLast: Bool = false
    let onTap: (() -> Void)?
    let onActions: (() -> Void)?

    @State private var pulse = false

    private var isUp: Bool { connection.state == .connected }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { onTap?() } label: {
                HStack(alignment: .center, spacing: 12) {
                    stateDot
                    VStack(alignment: .leading, spacing: 2) {
                        nameLine
                        Text(verbatim: "\(connection.kind.rawValue) · \(connection.address)")
                            .font(metaFont)
                            .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.5) : theme.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(healthLine)
                            .font(healthFont)
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                        if let error = diagnostics?.lastError, !error.isEmpty, !isUp {
                            Text(error)
                                .font(healthFont)
                                .foregroundStyle(theme.danger.opacity(0.85))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(stateWord)
                        .font(stateFont)
                        .foregroundStyle(stateColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onTap == nil || isBusy)

            if let onActions {
                Button(action: onActions) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.55) : theme.sub)
                        .frame(width: 28, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(copy.connActions(theme.id)))
            }
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
    }

    private var nameLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(connection.name)
                .font(nameFont)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            if isActive {
                Text(copy.connActive(theme.id))
                    .font(activeFont)
                    .tracking(theme.id == .soft ? 0.5 : 1)
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(theme.accent.opacity(theme.id == .ink ? 0 : 0.1),
                                in: RoundedRectangle(cornerRadius: theme.chipIsCapsule ? 999 : 3))
                    .overlay(RoundedRectangle(cornerRadius: theme.chipIsCapsule ? 999 : 3)
                        .strokeBorder(theme.accent.opacity(theme.id == .ink ? 0.6 : 0), lineWidth: 1))
            }
        }
    }

    /// The breathing dot, held still when motion is reduced — a status dot that
    /// pulses forever is exactly what that setting is for.
    private var stateDot: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 9, height: 9)
            .shadow(color: theme.glowRadius > 0 ? stateColor.opacity(0.8) : .clear,
                    radius: theme.glowRadius / 2)
            .opacity(isUp && !reducedMotion ? (pulse ? 1 : 0.45) : 1)
            .animation(isUp && !reducedMotion
                        ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                        : .default,
                       value: pulse)
            .onAppear { if isUp, !reducedMotion { pulse = true } }
            .onChange(of: isUp) { _, up in pulse = up && !reducedMotion }
    }

    /// connDeco: ok when connected, warn while asleep or probing, danger
    /// otherwise.
    private var stateColor: Color {
        switch connection.state {
        case .connected: theme.ok
        case .asleep, .connecting: theme.warn
        case .offline: theme.danger
        }
    }

    private var stateWord: String {
        if theme.id == .ink, isUp { return "open" }
        if theme.id == .control { return connection.state.rawValue.uppercased() }
        return connection.state.rawValue
    }

    /// "v0.9.3 · oauth · 12ms · 6 bots" from the status probe; without a probe
    /// (demo rows, or a screen opened before the first round trip) the
    /// prototype's ping/bots line.
    private var healthLine: String {
        guard let diagnostics, diagnostics.checkedAt != nil else {
            return isUp ? "\(connection.ping) · \(connection.botCount) \(copy.botsNoun(theme.id))"
                        : "\(connection.botCount) \(copy.botsNoun(theme.id)) · \(copy.connRetrying(theme.id))"
        }
        var parts: [String] = []
        if let version = diagnostics.version, !version.isEmpty { parts.append("v\(version)") }
        parts.append(copy.authModeLabel(diagnostics.authMode, theme.id))
        if let ping = diagnostics.pingMS { parts.append("\(ping)ms") }
        parts.append("\(connection.botCount) \(copy.botsNoun(theme.id))")
        return parts.joined(separator: " · ")
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(14.5, weight: .bold)
        case .control: theme.body(14, weight: .bold)
        case .ink: theme.body(17.5, weight: .bold)
        }
    }

    private var metaFont: Font {
        switch theme.id {
        case .soft: theme.body(11)
        case .control: theme.mono(9.5)
        case .ink: theme.mono(8.5)
        }
    }

    private var healthFont: Font {
        switch theme.id {
        case .soft: theme.body(10.5, weight: .medium)
        case .control: theme.mono(9)
        case .ink: theme.mono(8)
        }
    }

    private var stateFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(14, weight: .bold).smallCaps()
        }
    }

    private var activeFont: Font {
        switch theme.id {
        case .soft: theme.body(8.5, weight: .heavy)
        case .control: theme.mono(7.5, weight: .bold)
        case .ink: theme.mono(7)
        }
    }
}

// MARK: - Copy

extension CopyPack {

    func settingsGatewaysNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Tap a gateway to make it the live one. The ⋯ menu renames, signs out, or removes it — sign out and remove both delete its Keychain credential."
        case .control: "TAP TO SWITCH THE LIVE LINK. ⋯ RENAMES / SIGNS OUT / DELETES — BOTH PURGE THE KEYCHAIN CREDENTIAL."
        case .ink: "Touch a way to travel it. The ⋯ renames, surrenders the seal, or strikes it out — either unmakes the token in the Keychain."
        }
    }

    func settingsNoGateways(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No gateways saved yet"
        case .control: "NO UPLINKS SAVED"
        case .ink: "no ways are open"
        }
    }

    func settingsAddGateway(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Add a gateway"
        case .control: "ADD UPLINK"
        case .ink: "open a new way"
        }
    }

    func settingsAddGatewayNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Opens Connections, where sign-in and Hermes Cloud discovery live"
        case .control: "OPENS CONNECTIONS — SIGN-IN + CLOUD DISCOVERY"
        case .ink: "opens the Ways, where the seal is set"
        }
    }
}
