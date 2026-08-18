import SwiftUI
import TalariaKit
import TalariaTheme

// Connections — pushed from the Roster's net chip. Four sections, ported
// from Talaria.dc.html `data-screen-label="Connections"`:
//   Appearance — the three theme swatch cards, switching + persisting live.
//   Gateways   — saved connections with state dot, themed state word, and a
//                health line (version · auth mode · ping · bots) from the
//                status probe, plus the last probe error. Tapping a row makes
//                that gateway the live one; the ⋯ menu renames, signs out, or
//                removes it (Keychain credential included). A dashed
//                "+ add gateway" row opens a sheet that reuses the
//                AuthController sign-in flow, and offers Hermes Cloud agent
//                discovery when a Nous Portal token is on the device.
//   Notify me when — push prefs with the CRITICAL/CRIT/GRAVE tag, the
//                notifications control card, and the APNs relay footnote.

public struct ConnectionsView: View {
    private let model: AppModel
    private let onBack: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var showAddSheet = false
    /// The row whose ⋯ menu is open.
    @State private var actionTarget: SavedGateway?
    @State private var renameTarget: SavedGateway?

    public init(model: AppModel, onBack: (() -> Void)? = nil) {
        self.model = model
        self.onBack = onBack
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    private var listGap: CGFloat {
        switch theme.rowStyle {
        case .ledger: 0
        case .terminal: 7
        case .card: 8
        }
    }

    /// The way out of the demo world: leave to the empty real state, or
    /// re-run onboarding from the top.
    private var demoBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(theme.warn)
                    .frame(width: 7, height: 7)
                Text(copy.demoBannerTitle)
                    .font(theme.body(14, weight: .bold))
                    .foregroundStyle(theme.ink)
            }
            Text(copy.demoBannerBody)
                .font(theme.body(12.5))
                .foregroundStyle(theme.sub)
            HStack(spacing: 8) {
                Button {
                    model.exitDemoMode()
                } label: {
                    Text(copy.demoLeave)
                        .font(theme.mono(11, weight: .bold))
                        .foregroundStyle(theme.accentFg)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: theme.buttonRadius))
                }
                .buttonStyle(.plain)
                Button {
                    model.exitDemoMode()
                    model.resetOnboarding()
                } label: {
                    Text(copy.demoReonboard)
                        .font(theme.mono(11, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(theme.inset, in: RoundedRectangle(cornerRadius: theme.buttonRadius))
                        .overlay(RoundedRectangle(cornerRadius: theme.buttonRadius)
                            .stroke(theme.lineStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius)
            .stroke(theme.warn.opacity(0.45), lineWidth: 1))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The rename sheet hangs off the header rather than the container:
            // two `.sheet` modifiers on one view compete for the same
            // presentation slot, and the add-gateway sheet owns that one.
            header
                .sheet(item: $renameTarget) { gateway in
                    RenameGatewaySheet(model: model, gateway: gateway)
                }
            ScrollView {
                VStack(alignment: .leading, spacing: listGap) {
                    if model.demoDataLoaded {
                        demoBanner
                            .padding(.bottom, 8)
                    }

                    GatewaySectionLabel(theme: theme, text: copy.appearance)
                        .padding(.horizontal, 2)

                    HStack(spacing: 8) {
                        ForEach(ThemeID.allCases, id: \.self) { id in
                            ThemeSwatchCard(id: id, current: theme, showsTagline: true) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    model.theme.themeID = id
                                }
                            }
                        }
                    }
                    .padding(.bottom, theme.rowStyle == .ledger ? 10 : 0)

                    GatewaySectionLabel(theme: theme, text: copy.gatewaysSec)
                        .padding(.top, 10)
                        .padding(.horizontal, 2)

                    ForEach(Array(model.connections.enumerated()), id: \.element.id) { index, conn in
                        gatewayRow(conn, index: index)
                    }

                    addGatewayRow

                    GatewaySectionLabel(theme: theme, text: copy.notifySec)
                        .padding(.top, 12)
                        .padding(.horizontal, 2)

                    NotificationsCard(model: model)
                        .padding(.bottom, 8)

                    prefsGroup

                    GatewayFootnote(theme: theme, text: copy.pushNote)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .sheet(isPresented: $showAddSheet) {
            AddGatewaySheet(model: model)
        }
        .confirmationDialog(actionTarget?.name ?? copy.gatewaysSec,
                            isPresented: Binding(get: { actionTarget != nil },
                                                 set: { if !$0 { actionTarget = nil } }),
                            titleVisibility: .visible) {
            if let gateway = actionTarget { rowActions(for: gateway) }
        } message: {
            Text(copy.connRemoveNote(theme.id))
        }
        .task {
            // Saved gateways get a fresh health probe whenever the screen is
            // up, then every 20 s while it stays up; in live mode the rows come
            // straight from the registry.
            guard model.mode == .live else { return }
            while !Task.isCancelled {
                await model.refreshConnectionHealth()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if let onBack { onBack() } else { dismiss() }
            } label: {
                Text(verbatim: "‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                    .frame(width: 31, height: 31)
                    .background(theme.id == .ink ? Color.clear : theme.panel)
                    .clipShape(iconButtonShape)
                    .overlay(iconButtonShape.strokeBorder(
                        theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                if theme.showsKicker {
                    Text(copy.kickerConn)
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                }
                Text(copy.titleConn)
                    .font(subtitleFont)
                    .foregroundStyle(theme.ink)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var iconButtonShape: RoundedRectangle {
        let radius: CGFloat = theme.iconCornerFraction >= 0.5 ? 15.5 : 31 * theme.iconCornerFraction
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var subtitleFont: Font {
        switch theme.id {
        case .soft: theme.display(20)
        case .control: theme.display(18)
        case .ink: theme.display(22, weight: .bold).smallCaps()
        }
    }

    // MARK: Gateway rows

    /// Demo rows have no registry entry behind them, so they stay display-only.
    private func savedGateway(for connection: GatewayConnection) -> SavedGateway? {
        ConnectionRegistry.shared.saved.first { $0.id == connection.id }
    }

    @ViewBuilder
    private func gatewayRow(_ connection: GatewayConnection, index: Int) -> some View {
        let saved = savedGateway(for: connection)
        ConnectionRow(
            connection: connection,
            diagnostics: saved.flatMap { model.diagnostics(forGatewayID: $0.id) },
            isActive: saved.map { model.isActiveGateway($0) } ?? false,
            isBusy: model.isReconnecting,
            theme: theme,
            copy: copy,
            onTap: saved == nil ? nil : { tapped(saved!) },
            onActions: saved == nil ? nil : { actionTarget = saved })
            .modifier(ConnRowEntrance(delay: Double(index) * 0.055))
    }

    /// A tap connects: switching gateways flushes the previous world, and the
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
    private func rowActions(for gateway: SavedGateway) -> some View {
        let isActive = model.isActiveGateway(gateway)
        if isActive {
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
        Button(copy.connRename(theme.id)) { renameTarget = gateway }
        Button(copy.connSignOut(theme.id)) {
            Task { @MainActor in await model.signOutGateway(gateway) }
        }
        Button(copy.connRemove(theme.id), role: .destructive) {
            Task { @MainActor in await model.removeGateway(gateway) }
        }
        Button(copy.cancel, role: .cancel) {}
    }

    // MARK: + Add gateway

    private var addGatewayRow: some View {
        Button {
            showAddSheet = true
        } label: {
            Text(copy.addGateway)
                .font(addFont)
                .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.5) : theme.faint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(11)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : theme.cardRadius,
                                     style: .continuous)
                        .strokeBorder(dashColor,
                                      style: StrokeStyle(lineWidth: theme.id == .soft ? 1.5 : 1,
                                                         dash: [5, 4]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .bold)
        case .control: theme.mono(10.5, weight: .semibold)
        case .ink: theme.body(14.5, weight: .semibold).smallCaps()
        }
    }

    private var dashColor: Color {
        switch theme.id {
        case .soft: theme.ink.opacity(0.15)
        case .control: theme.accent.opacity(0.25)
        case .ink: theme.ink.opacity(0.4)
        }
    }

    // MARK: Notify prefs

    private var prefsGroup: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.notificationPrefs.enumerated()), id: \.element.id) { index, pref in
                PrefRow(pref: pref, theme: theme,
                        isLast: index == model.notificationPrefs.count - 1) {
                    togglePref(pref)
                }
            }
        }
        .modifier(PrefGroupChrome(theme: theme))
    }

    private func togglePref(_ pref: NotificationPref) {
        guard let idx = model.notificationPrefs.firstIndex(where: { $0.id == pref.id }) else { return }
        model.notificationPrefs[idx].isOn.toggle()
    }
}

// MARK: - Gateway row

private struct ConnectionRow: View {
    let connection: GatewayConnection
    let diagnostics: GatewayDiagnostics?
    let isActive: Bool
    let isBusy: Bool
    let theme: ThemePack
    let copy: CopyPack
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
        .modifier(ConnRowChrome(theme: theme))
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

    private var stateDot: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 9, height: 9)
            .shadow(color: theme.glowRadius > 0 ? stateColor.opacity(0.8) : .clear,
                    radius: theme.glowRadius / 2)
            .opacity(isUp ? (pulse ? 1 : 0.45) : 1)
            .animation(isUp ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                       value: pulse)
            .onAppear { if isUp { pulse = true } }
            .onChange(of: isUp) { _, up in pulse = up }
    }

    /// Prototype connDeco: ok when connected, warn when asleep, danger
    /// otherwise; `connecting` reads as warn while the probe is in flight.
    private var stateColor: Color {
        switch connection.state {
        case .connected: theme.ok
        case .asleep, .connecting: theme.warn
        case .offline: theme.danger
        }
    }

    /// Ink says "open" for a live way; everything else is the raw state word
    /// (control uppercases via its state style).
    private var stateWord: String {
        if theme.id == .ink, isUp { return "open" }
        if theme.id == .control { return connection.state.rawValue.uppercased() }
        return connection.state.rawValue
    }

    /// "v0.9.3 · oauth · 12ms · 6 bots" from the status probe. Without a probe
    /// (demo rows, or a screen opened before the first round trip) it falls
    /// back to the prototype's ping/bots line.
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

/// Row chrome per rowStyle: soft = floating card, control = terminal panel,
/// ink = ruled ledger line. (File-scoped copy; each screen keeps its own.)
private struct ConnRowChrome: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        switch theme.rowStyle {
        case .card:
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.ink.opacity(0.05), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 3, y: 1)
        case .terminal:
            content
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ledger:
            content
                .padding(.horizontal, 2)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
        }
    }
}

// MARK: - Notification pref row

private struct PrefRow: View {
    let pref: NotificationPref
    let theme: ThemePack
    let isLast: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                nameLine
                Text(pref.subtitle)
                    .font(theme.id == .control ? theme.mono(10) : theme.body(theme.id == .ink ? 13 : 12))
                    .italic(theme.id == .ink)
                    .foregroundStyle(theme.id == .control ? theme.faint : theme.sub)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PrefToggle(isOn: pref.isOn, theme: theme, action: toggle)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .overlay(alignment: .bottom) {
            if !isLast { theme.line.frame(height: 1) }
        }
    }

    /// Name plus the danger-colored critical tag (critCss); the tag word is
    /// themed outside CopyPack: CRITICAL / CRIT / GRAVE.
    private var nameLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(pref.name)
                .font(nameFont)
                .foregroundStyle(theme.ink)
            if pref.isCritical {
                Text(critTag)
                    .font(critFont)
                    .tracking(theme.id == .soft ? 0.5 : 1)
                    .foregroundStyle(theme.danger)
            }
        }
    }

    private var critTag: String {
        switch theme.id {
        case .soft: "CRITICAL"
        case .control: "CRIT"
        case .ink: "GRAVE"
        }
    }

    private var critFont: Font {
        switch theme.id {
        case .soft: theme.body(9, weight: .heavy)
        case .control: theme.mono(8, weight: .bold)
        case .ink: theme.mono(7.5, weight: .semibold)
        }
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(14, weight: .semibold)
        case .control: theme.body(13.5, weight: .semibold)
        case .ink: theme.body(16, weight: .semibold)
        }
    }
}

/// groupCss — the container behind the prefs list: white rounded card in
/// soft, terminal panel in control, chrome-free ruled block in ink.
private struct PrefGroupChrome: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        switch theme.id {
        case .soft:
            content
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(theme.ink.opacity(0.05), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 3, y: 1)
        case .control:
            content
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ink:
            content
        }
    }
}

/// The design's 46×27 switch (trackOn/trackOff/knobCss tokens). File-scoped
/// copy, matching RoutinesView's toggle so both screens agree.
private struct PrefToggle: View {
    let isOn: Bool
    let theme: ThemePack
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                trackShape
                    .fill(trackFill)
                    .overlay(trackShape.strokeBorder(trackBorder, lineWidth: 1))
                knobShape
                    .fill(knobFill)
                    .frame(width: 21, height: 21)
                    .shadow(color: theme.id == .soft ? Color.black.opacity(0.2) : .clear,
                            radius: 1.5, y: 1)
                    .offset(x: isOn ? 21 : 2.5)
            }
            .frame(width: 46, height: 27)
            .animation(.easeInOut(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 6 : 14, style: .continuous)
    }

    private var knobShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 4 : 10.5, style: .continuous)
    }

    private var trackFill: Color {
        switch theme.id {
        case .soft: isOn ? theme.ok : theme.ink.opacity(0.12)
        case .control: isOn ? theme.accent.opacity(0.35) : theme.ink.opacity(0.08)
        case .ink: isOn ? theme.ok.opacity(0.25) : .clear
        }
    }

    private var trackBorder: Color {
        switch theme.id {
        case .soft: .clear
        case .control: theme.lineStrong
        case .ink: theme.lineStrong
        }
    }

    private var knobFill: Color {
        switch theme.id {
        case .soft: theme.panel
        case .control: theme.ink
        case .ink: isOn ? theme.ink : theme.ink.opacity(0.35)
        }
    }
}

// MARK: - Rename sheet

/// Metadata-only rename: the Keychain credential is keyed by URL, so the name
/// is free to change.
private struct RenameGatewaySheet: View {
    let model: AppModel
    let gateway: SavedGateway

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Button { dismiss() } label: {
                    Text(copy.cancel)
                        .font(theme.id == .control ? theme.mono(11, weight: .semibold)
                                                   : theme.body(14, weight: .semibold))
                        .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.55) : theme.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(copy.connRenameTitle(theme.id))
                    .font(theme.id == .ink ? theme.display(20, weight: .bold).smallCaps()
                                           : theme.body(16, weight: .heavy))
                    .foregroundStyle(theme.ink)
                Spacer()
                Text(copy.cancel)
                    .font(theme.id == .control ? theme.mono(11, weight: .semibold)
                                               : theme.body(14, weight: .semibold))
                    .hidden()
            }
            .padding(.top, 16)

            TextField(gateway.name, text: $name)
                .gatewayFieldTraits()
                .modifier(GatewayFlowInputChrome(theme: theme))

            GatewayFootnote(theme: theme, text: ConnectionRegistry.address(for: gateway))

            GatewayFlowButton(theme: theme, label: copy.connSave(theme.id), role: .primary) {
                model.renameGateway(gateway, to: name)
                dismiss()
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .onAppear { if name.isEmpty { name = gateway.name } }
    }
}

// MARK: - Add-gateway sheet (reuses the AuthController flow)

private struct AddGatewaySheet: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var auth = AuthController()
    @State private var directory = CloudDirectory()
    @State private var name = ""
    @State private var gatewayMode: GatewayModeChoice = .tailscale
    @State private var urlString = ""

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    TextField("Name", text: $name)
                        .gatewayFieldTraits()
                        .modifier(GatewayFlowInputChrome(theme: theme))

                    HStack(spacing: 7) {
                        ForEach(GatewayModeChoice.allCases, id: \.self) { mode in
                            GatewayModeChip(theme: theme, label: mode.label,
                                            isOn: gatewayMode == mode) {
                                withAnimation(.easeInOut(duration: 0.2)) { gatewayMode = mode }
                            }
                        }
                    }

                    if gatewayMode == .cloud {
                        CloudAgentPanel(theme: theme, copy: copy, directory: directory) { agent in
                            pick(agent)
                        }
                    }

                    TextField(gatewayMode == .cloud ? copy.cloudURLPlaceholder
                                                    : OnboardingView.placeholderURL,
                              text: $urlString)
                        .gatewayFieldTraits()
                        .modifier(GatewayFlowInputChrome(theme: theme))

                    GatewayFootnote(theme: theme,
                                    text: gatewayMode == .cloud ? copy.cloudManualNote(theme.id)
                                                                : copy.obNote1)

                    if auth.phase == .idle, auth.status == nil {
                        GatewayFlowButton(theme: theme, label: copy.obCta1, role: .primary) {
                            probe()
                        }
                    } else {
                        GatewayAuthPhasePanel(auth: auth, theme: theme, copy: copy,
                                              onRetry: { probe() },
                                              onDemoSelect: nil)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .onChange(of: auth.phase) { _, phase in
            if phase == .done { save() }
        }
        .onChange(of: urlString) { _, _ in
            // Editing the URL after a finished probe restarts the flow from
            // the Continue button (an in-flight browser round trip survives).
            if auth.phase == .idle, auth.status != nil { auth.reset() }
        }
        .onChange(of: gatewayMode) { _, mode in
            if mode == .cloud { directory.start() }
        }
        .onDisappear {
            auth.cancelSignIn()
            directory.cancel()
        }
    }

    private var sheetHeader: some View {
        HStack(alignment: .center) {
            Button {
                auth.cancelSignIn()
                dismiss()
            } label: {
                Text(copy.cancel)
                    .font(cancelFont)
                    .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.55) : (theme.id == .control ? theme.sub : theme.accent))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(sheetTitle)
                .font(titleFont)
                .foregroundStyle(theme.ink)

            Spacer()

            // Balance the layout so the title stays centered.
            Text(copy.cancel).font(cancelFont).hidden()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    /// The sheet's title, derived from the themed add-gateway row copy
    /// ("+ Add gateway — URL or Hermes Cloud" → "Add gateway").
    private var sheetTitle: String {
        var text = copy.addGateway
        if text.hasPrefix("+") { text.removeFirst() }
        for separator in [" — ", " – ", " - "] {
            if let range = text.range(of: separator) {
                text = String(text[..<range.lowerBound])
                break
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private var cancelFont: Font {
        switch theme.id {
        case .soft: theme.body(14, weight: .semibold)
        case .control: theme.mono(11, weight: .semibold)
        case .ink: theme.body(14, weight: .semibold).smallCaps()
        }
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.body(16, weight: .heavy)
        case .control: theme.body(15, weight: .heavy)
        case .ink: theme.display(20, weight: .bold).smallCaps()
        }
    }

    /// A discovered cloud agent is an ordinary gated gateway at its dashboard
    /// URL — fill the field and run the same probe → PKCE sign-in.
    private func pick(_ agent: CloudAgent) {
        guard let url = agent.dashboardURL else { return }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = agent.name }
        urlString = url.absoluteString
        auth.reset()
        Task { await auth.probe(url.absoluteString) }
    }

    private func probe() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await auth.probe(trimmed) }
    }

    /// Persist the authenticated gateway (metadata → registry/UserDefaults,
    /// credential → Keychain) and surface it as a Connections row.
    private func save() {
        guard let base = auth.baseURL, let credential = auth.credential else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let saved = ConnectionRegistry.shared.upsert(
            urlString: base.absoluteString,
            name: trimmedName.isEmpty ? nil : trimmedName,
            kind: gatewayMode.kindHint,
            credential: credential)

        if let row = auth.makeConnection(named: trimmedName.isEmpty ? saved?.name : trimmedName,
                                         kindHint: gatewayMode.kindHint ?? saved?.kind) {
            if let idx = model.connections.firstIndex(where: {
                $0.id == row.id || $0.address == row.address
            }) {
                model.connections[idx] = row
            } else {
                model.connections.append(row)
            }
        }

        if let saved {
            Task { @MainActor in
                await model.refreshConnectionHealth()
                // First gateway on the device, or the user is still in the demo
                // world: adopt it as the live link rather than saving a row
                // nothing is connected to.
                if model.client == nil { await model.switchGateway(to: saved) }
                if model.mode == .live {
                    model.connections = ConnectionRegistry.shared.rows
                }
            }
        }
        dismiss()
    }
}

// MARK: - Hermes Cloud panel

/// Portal-backed agent discovery. Every state is honest about what Talaria can
/// actually see: without a portal token there is no list to show, and a portal
/// that refuses the device-code credential for `/api/agents` says so instead of
/// pretending the org is empty. The manual dashboard-URL field below stays
/// usable throughout.
private struct CloudAgentPanel: View {
    let theme: ThemePack
    let copy: CopyPack
    var directory: CloudDirectory
    var onPick: (CloudAgent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GatewaySectionLabel(theme: theme, text: copy.cloudSection(theme.id))

            switch directory.phase {
            case .signedOut:
                GatewayFootnote(theme: theme, text: copy.cloudSignedOutNote(theme.id))
                GatewayFlowButton(theme: theme, label: copy.cloudSignIn(theme.id),
                                  role: .primary) {
                    directory.signIn()
                }

            case .requestingCode:
                progress(copy.cloudRequesting(theme.id))

            case .awaitingApproval(let code):
                progress(copy.cloudApproveNote(theme.id, code: code))
                GatewayFlowButton(theme: theme, label: copy.cancel, role: .secondary) {
                    directory.cancel()
                }

            case .discovering:
                progress(copy.cloudDiscovering(theme.id))

            case .chooseOrg:
                GatewayFootnote(theme: theme, text: copy.cloudOrgPrompt(theme.id))
                ForEach(directory.orgs) { org in
                    Button { directory.selectOrg(org) } label: {
                        pickRow(title: org.name,
                                detail: org.isPersonal ? org.role.lowercased()
                                                       : "\(org.queryValue) · \(org.role.lowercased())",
                                enabled: true)
                    }
                    .buttonStyle(.plain)
                }

            case .ready:
                if directory.agents.isEmpty {
                    GatewayFootnote(theme: theme, text: copy.cloudEmpty(theme.id))
                } else {
                    ForEach(directory.agents) { agent in
                        Button { onPick(agent) } label: {
                            pickRow(title: agent.name,
                                    detail: agent.isReachable
                                        ? "\(agent.status) · \(agent.gatewayState)"
                                        : copy.cloudProvisioning(theme.id),
                                    enabled: agent.isReachable)
                        }
                        .buttonStyle(.plain)
                        .disabled(!agent.isReachable)
                    }
                }
                signOutLink

            case .discoveryRefused:
                GatewayFootnote(theme: theme, text: copy.cloudRefusedNote(theme.id))
                signOutLink

            case .failed(let detail):
                Text(detail)
                    .font(theme.id == .control ? theme.mono(10) : theme.body(12.5))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                GatewayFlowButton(theme: theme, label: copy.cloudRetry(theme.id),
                                  role: .secondary) {
                    directory.retry()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CloudApprovalPresenter(directory: directory, theme: theme))
    }

    private var signOutLink: some View {
        Button { directory.signOut() } label: {
            Text(copy.cloudSignOut(theme.id))
                .font(theme.id == .control ? theme.mono(9.5, weight: .semibold)
                                           : theme.body(11.5, weight: .semibold))
                .foregroundStyle(theme.faint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(theme.accent)
            Text(label)
                .font(theme.id == .soft ? theme.body(12.5) : theme.mono(10))
                .foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pickRow(title: String, detail: String, enabled: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(theme.id == .ink ? theme.body(15, weight: .bold)
                                           : theme.body(13.5, weight: .bold))
                    .foregroundStyle(enabled ? theme.ink : theme.faint)
                    .lineLimit(1)
                Text(detail)
                    .font(theme.id == .control ? theme.mono(9) : theme.body(10.5))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if enabled {
                Text(verbatim: "›")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.inset)
        .clipShape(RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : 10, style: .continuous)
            .strokeBorder(theme.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// The portal's approval page, in-app on iOS: the device-code poll has to keep
/// running while the user approves, and a hop out to Safari suspends it.
private struct CloudApprovalPresenter: ViewModifier {
    var directory: CloudDirectory
    var theme: ThemePack

    func body(content: Content) -> some View {
        #if os(iOS)
        content.sheet(item: Binding(
            get: { directory.approvalRequest },
            set: { if $0 == nil { directory.approvalSheetDismissed() } }
        )) { request in
            AuthWebSheet(request: request, theme: theme,
                         onCallback: { _ in },
                         onCancel: { directory.cancel() })
        }
        #else
        content
        #endif
    }
}

// MARK: - Entrance (file-scoped copy)

private struct ConnRowEntrance: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.38).delay(delay)) { shown = true }
            }
    }
}

// MARK: - Copy (gateway rows, actions, Hermes Cloud)

extension CopyPack {

    /// What a gateway's agents are called in this voice.
    func botsNoun(_ t: ThemeID) -> String {
        switch t {
        case .soft: "bots"
        case .control: "agents"
        case .ink: "familiars"
        }
    }

    func connRetrying(_ t: ThemeID) -> String {
        switch t {
        case .soft: "retrying"
        case .control: "RETRYING"
        case .ink: "seeking"
        }
    }

    func authModeLabel(_ mode: GatewayDiagnostics.AuthMode, _ t: ThemeID) -> String {
        switch mode {
        case .open:
            switch t {
            case .soft: return "open"
            case .control: return "OPEN"
            case .ink: return "unbarred"
            }
        case .oauth:
            switch t {
            case .soft: return "oauth"
            case .control: return "OAUTH"
            case .ink: return "sealed"
            }
        case .gated:
            switch t {
            case .soft: return "gated"
            case .control: return "GATED"
            case .ink: return "barred"
            }
        case .unknown:
            switch t {
            case .soft: return "unreached"
            case .control: return "NO PROBE"
            case .ink: return "unsounded"
            }
        }
    }

    func connActive(_ t: ThemeID) -> String {
        switch t {
        case .soft: "LIVE"
        case .control: "LINKED"
        case .ink: "IN USE"
        }
    }

    func connActions(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway actions"
        case .control: "UPLINK ACTIONS"
        case .ink: "acts upon this way"
        }
    }

    func connConnect(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Connect"
        case .control: "SWITCH LINK"
        case .ink: "travel this way"
        }
    }

    func connDisconnect(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Disconnect"
        case .control: "DROP LINK"
        case .ink: "close the way"
        }
    }

    func connRename(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Rename"
        case .control: "RENAME"
        case .ink: "rename this way"
        }
    }

    func connRenameTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Rename gateway"
        case .control: "RENAME UPLINK"
        case .ink: "a new name"
        }
    }

    func connSave(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Save"
        case .control: "COMMIT"
        case .ink: "inscribe"
        }
    }

    func connSignOut(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sign out"
        case .control: "SIGN OUT"
        case .ink: "surrender the seal"
        }
    }

    func connRemove(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Remove gateway"
        case .control: "DELETE UPLINK"
        case .ink: "strike this way out"
        }
    }

    func connRemoveNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Signing out or removing deletes this gateway's credential from the Keychain. Your bots keep running."
        case .control: "SIGN OUT / DELETE PURGES THE KEYCHAIN CREDENTIAL. AGENTS CONTINUE SERVER-SIDE."
        case .ink: "To surrender the seal, or strike the way out, unmakes the token kept in the Keychain. The familiars work on regardless."
        }
    }

    // MARK: Hermes Cloud

    func cloudSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Your cloud agents"
        case .control: "CLOUD INVENTORY"
        case .ink: "THE HOSTED FAMILIARS"
        }
    }

    func cloudSignedOutNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sign in to Nous Portal to list the agents on your account — the same device-code sign-in the hermes CLI uses."
        case .control: "NOUS PORTAL SIGN-IN REQUIRED TO ENUMERATE HOSTED AGENTS (DEVICE-CODE GRANT, SAME AS THE CLI)."
        case .ink: "Present yourself at the Nous Portal and your hosted familiars will be named — the same rite the hermes CLI performs."
        }
    }

    func cloudSignIn(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sign in to Nous Portal"
        case .control: "PORTAL SIGN-IN"
        case .ink: "present yourself"
        }
    }

    func cloudRequesting(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Asking the portal for a code…"
        case .control: "REQUESTING DEVICE CODE…"
        case .ink: "asking the portal for a token…"
        }
    }

    func cloudApproveNote(_ t: ThemeID, code: String) -> String {
        switch t {
        case .soft: "Approve code \(code) in the portal window."
        case .control: "APPROVE CODE \(code) IN THE PORTAL WINDOW."
        case .ink: "Grant the code \(code) at the portal."
        }
    }

    func cloudDiscovering(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Looking for your agents…"
        case .control: "ENUMERATING AGENTS…"
        case .ink: "counting the familiars…"
        }
    }

    func cloudOrgPrompt(_ t: ThemeID) -> String {
        switch t {
        case .soft: "You belong to more than one organisation — pick one."
        case .control: "MULTIPLE ORGS — SELECT SCOPE."
        case .ink: "You keep more than one house. Choose."
        }
    }

    func cloudEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No agents on this account yet — create one at portal.nousresearch.com."
        case .control: "NO HOSTED AGENTS ON THIS ACCOUNT."
        case .ink: "No hosted familiars answer to this name yet."
        }
    }

    func cloudProvisioning(_ t: ThemeID) -> String {
        switch t {
        case .soft: "provisioning — no dashboard yet"
        case .control: "PROVISIONING — NO DASHBOARD"
        case .ink: "still being made"
        }
    }

    /// The honest degrade: signed in, but the portal will not enumerate for
    /// this credential (desktop's discovery rides a browser Privy session).
    func cloudRefusedNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The portal would not list agents for this sign-in — it may only answer browser sessions. Paste the agent's dashboard URL below instead."
        case .control: "PORTAL REFUSED THE DEVICE CREDENTIAL FOR /API/AGENTS — BROWSER SESSION MAY BE REQUIRED. USE THE DASHBOARD URL BELOW."
        case .ink: "The portal will not name your familiars to this token; it may hear only browser sessions. Give the dashboard's address below instead."
        }
    }

    func cloudSignOut(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Forget this portal sign-in"
        case .control: "DROP PORTAL TOKEN"
        case .ink: "forget the portal"
        }
    }

    func cloudRetry(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Try again"
        case .control: "RETRY"
        case .ink: "try once more"
        }
    }

    /// Replaces the pre-discovery `cloudURLHint` for this panel: discovery now
    /// exists, so the manual path is the fallback, not the only route.
    func cloudManualNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Or paste an agent's dashboard URL from portal.nousresearch.com — it signs in with the same Nous OAuth flow."
        case .control: "OR PASTE AN AGENT DASHBOARD URL — SAME NOUS OAUTH FLOW."
        case .ink: "Or set down the dashboard's address from the portal — the same Nous rite opens it."
        }
    }
}
