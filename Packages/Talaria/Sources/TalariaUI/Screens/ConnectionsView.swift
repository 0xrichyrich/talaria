import SwiftUI
import TalariaKit
import TalariaTheme

// Connections — pushed from the Roster's net chip. Three sections, ported
// from Talaria.dc.html `data-screen-label="Connections"`:
//   Appearance — the three theme swatch cards, switching + persisting live.
//   Gateways   — saved connections with state dot, themed state word, ping
//                and bot count; a dashed "+ add gateway" row → sheet that
//                reuses the AuthController sign-in flow.
//   Notify me when — push prefs with the CRITICAL/CRIT/GRAVE tag, and the
//                APNs push-relay footnote.

public struct ConnectionsView: View {
    private let model: AppModel
    private let onBack: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var showAddSheet = false

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

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: listGap) {
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
                        ConnectionRow(connection: conn, theme: theme)
                            .modifier(ConnRowEntrance(delay: Double(index) * 0.055))
                    }

                    addGatewayRow

                    GatewaySectionLabel(theme: theme, text: copy.notifySec)
                        .padding(.top, 12)
                        .padding(.horizontal, 2)

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
        .task {
            // Saved gateways get a fresh health probe whenever the screen
            // appears; in live mode the rows come straight from the registry.
            guard model.mode == .live, !ConnectionRegistry.shared.saved.isEmpty else { return }
            await ConnectionRegistry.shared.probeAll()
            model.connections = ConnectionRegistry.shared.rows
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
    let theme: ThemePack

    @State private var pulse = false

    private var isUp: Bool { connection.state == .connected }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            stateDot
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .font(nameFont)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(verbatim: "\(connection.kind.rawValue) · \(connection.address)")
                    .font(metaFont)
                    .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.5) : theme.faint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(stateWord)
                    .font(stateFont)
                    .foregroundStyle(stateColor)
                Text(metaLine)
                    .font(theme.id == .soft ? theme.body(11, weight: .medium) : theme.mono(theme.id == .ink ? 9 : 10))
                    .foregroundStyle(theme.faint)
            }
        }
        .modifier(ConnRowChrome(theme: theme))
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

    /// "12ms · 6 bots" when up (ink: "familiars"); "2 bots · retrying" when not.
    private var metaLine: String {
        if isUp {
            let noun = theme.id == .ink ? "familiars" : "bots"
            return "\(connection.ping) · \(connection.botCount) \(noun)"
        }
        return "\(connection.botCount) bots · retrying"
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

    private var stateFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(14, weight: .bold).smallCaps()
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

// MARK: - Add-gateway sheet (reuses the AuthController flow)

private struct AddGatewaySheet: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var auth = AuthController()
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

                    TextField(OnboardingView.placeholderURL, text: $urlString)
                        .gatewayFieldTraits()
                        .modifier(GatewayFlowInputChrome(theme: theme))

                    GatewayFootnote(theme: theme, text: copy.obNote1)

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
        .onDisappear { auth.cancelSignIn() }
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
                await ConnectionRegistry.shared.probe(saved)
                if model.mode == .live {
                    model.connections = ConnectionRegistry.shared.rows
                }
            }
        }
        dismiss()
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
